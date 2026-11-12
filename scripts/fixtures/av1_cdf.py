"""Generate the AV1 default CDF tables for the MoonBit decoder.

The AV1 syntax elements are entropy coded with adaptive cumulative distribution
functions whose starting values are not in the specification: they live in the
reference implementation's source. Rather than transcribe several thousand
numbers, this script compiles a small C dumper against dav1d's ``cdf.c`` and
prints every table, then writes the numbers into a MoonBit module.

The dumper is compiled from the reference source rather than parsed, because
dav1d's initializers use designated array indices (``[BS_4x4] = {...}``) in a
different order from the enum: a C compiler is the authority on where each
number lands.

Usage (a C compiler and the pinned dav1d source are required only to regenerate
the committed table, never to build the library):

    python3 scripts/fixtures/av1_cdf.py --source /path/to/dav1d-1.5.4

The pinned source is https://github.com/videolan/dav1d/archive/refs/tags/1.5.4.tar.gz
(BSD-2-Clause; ``src/cdf.c``, ``src/cdf.h``, ``src/levels.h``,
``include/dav1d/headers.h``).
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE_URL = "https://codeload.github.com/videolan/dav1d/tar.gz/refs/tags/1.5.4"
PINNED = "1.5.4"

# The dimensions in cdf.h name constants from levels.h and dav1d/headers.h.
# Only the ones an array dimension actually mentions are needed here; the enum
# blocks themselves are lifted verbatim from the reference headers below.
EXTRA_DEFINES = """
#define DAV1D_MAX_SEGMENTS 8
#define ALIGN(decl, n) decl
"""

FILTER_ENUM = """
enum Dav1dFilterMode {
    DAV1D_FILTER_8TAP_REGULAR,
    DAV1D_FILTER_8TAP_SMOOTH,
    DAV1D_FILTER_8TAP_SHARP,
    DAV1D_N_SWITCHABLE_FILTERS,
    DAV1D_FILTER_BILINEAR = DAV1D_N_SWITCHABLE_FILTERS,
    DAV1D_N_FILTERS,
    DAV1D_FILTER_SWITCHABLE = DAV1D_N_FILTERS,
};
"""


def enum_blocks(text: str) -> str:
    """Every plain enum declaration, which is all levels.h needs to give us."""
    return "\n".join(re.findall(r"enum\s+\w+\s*\{[^}]*\}\s*;", text, re.S))


def struct_blocks(text: str) -> str:
    """Only the three table structs; the thread/context structs pull in the
    rest of the decoder's headers and hold no CDF numbers."""
    wanted = ("CdfModeContext", "CdfCoefContext", "CdfMvComponent")
    blocks = re.findall(r"typedef struct Cdf\w+\s*\{.*?\}\s*Cdf\w+\s*;", text, re.S)
    kept = [b for b in blocks if any(("} " + name + ";") in b for name in wanted)]
    if len(kept) != len(wanted):
        raise SystemExit("expected the three CDF structs in cdf.h")
    return "\n".join(kept)


def fields_of(cdf_h: str, struct: str) -> list[tuple[str, str]]:
    """(field name, dimension expression) for every CDF array of a struct."""
    body = re.search(
        r"typedef struct " + struct + r"\s*\{(.*?)\}\s*" + struct + r"\s*;",
        cdf_h,
        re.S,
    )
    if body is None:
        raise SystemExit("no struct " + struct + " in cdf.h")
    found = re.findall(
        r"ALIGN\(\s*uint16_t\s+(\w+)\s*((?:\[[^]]*\])+)\s*,\s*\d+\s*\)",
        body.group(1),
    )
    if not found:
        raise SystemExit("no fields in " + struct)
    return found


def initializer_slice(cdf_c: str) -> str:
    """The macro definitions and the two static initializers, nothing else."""
    first = cdf_c.index("#define CDF1(x)")
    mark = cdf_c.index("static const CdfCoefContext default_coef_cdf[4] = {")
    end = cdf_c.index("\n};\n", mark) + len("\n};\n")
    return cdf_c[first:end]


def build_dumper(source: Path, fields_mode, fields_coef, fields_mv) -> str:
    levels = (source / "src/levels.h").read_text(encoding="utf-8")
    headers = (source / "include/dav1d/headers.h").read_text(encoding="utf-8")
    cdf_h = (source / "src/cdf.h").read_text(encoding="utf-8")
    cdf_c = (source / "src/cdf.c").read_text(encoding="utf-8")

    preamble = "\n".join(
        [
            "#include <stdint.h>",
            "#include <stdio.h>",
            "#include <string.h>",
            enum_blocks(levels),
            enum_blocks(headers),
            EXTRA_DEFINES,
            struct_blocks(cdf_h),
            initializer_slice(cdf_c),
            "",
        ]
    )

    calls = []

    def dump(label: str, expr: str, dims: str = "") -> None:
        # The row width is what a (field, context) address needs: the C arrays
        # pad the last dimension, so the number of symbols is not the stride.
        ranks = dims.count("[")
        width = {
            0: "1",
            1: "sizeof(%s) / sizeof(uint16_t)" % expr,
            2: "sizeof((%s)[0]) / sizeof(uint16_t)" % expr,
            3: "sizeof((%s)[0][0]) / sizeof(uint16_t)" % expr,
            4: "sizeof((%s)[0][0][0]) / sizeof(uint16_t)" % expr,
        }.get(ranks, "sizeof((%s)[0]) / sizeof(uint16_t)" % expr)
        calls.append('    DUMP("%s", %s, %s);' % (label, expr, width))

    for name, dims in fields_mode:
        dump("m_" + name, "default_cdf.m." + name, dims)
    for name, dims in fields_mv:
        dump("mv_" + name, "default_cdf.mv.comp." + name, dims)
    dump("mv_joint", "default_cdf.mv.joint")
    dump("kfym", "default_cdf.kfym", "[5][5][N_INTRA_PRED_MODES + 3]")
    for q in range(4):
        for name, dims in fields_coef:
            dump("coef%d_%s" % (q, name), "default_coef_cdf[%d].%s" % (q, name), dims)

    main = """
#define DUMP(label, field, width) do {                                 \\
    const uint16_t *p = (const uint16_t *)(const void *)&(field);       \\
    const size_t n = sizeof(field) / sizeof(uint16_t);                  \\
    printf("FIELD %s %zu %zu\\n", label, n, (size_t)(width));           \\
    for (size_t i = 0; i < n; i++) printf("%u ", (unsigned)p[i]);       \\
    printf("\\n");                                                      \\
} while (0)

int main(void) {
__CALLS__
    return 0;
}
""".replace("__CALLS__", "\n".join(calls))
    return preamble + main


def compile_and_run(source: Path, cc: str):
    cdf_h = (source / "src/cdf.h").read_text(encoding="utf-8")
    mode = fields_of(cdf_h, "CdfModeContext")
    coef = fields_of(cdf_h, "CdfCoefContext")
    mv = fields_of(cdf_h, "CdfMvComponent")
    program = build_dumper(source, mode, coef, mv)

    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        (work / "dump.c").write_text(program, encoding="utf-8")
        outcome = subprocess.run(
            [cc, "-O0", "-std=c11", "-w", "-o", str(work / "dump"), str(work / "dump.c")],
            capture_output=True,
            text=True,
        )
        if outcome.returncode != 0:
            sys.exit("cannot compile the reference dumper:\n" + outcome.stderr)
        run = subprocess.run([str(work / "dump")], capture_output=True, text=True)
        if run.returncode != 0:
            sys.exit("the reference dumper failed: " + run.stderr)

    lines = run.stdout.splitlines()
    tables: dict[str, list[int]] = {}
    widths: dict[str, int] = {}
    i = 0
    while i < len(lines):
        head = lines[i].split()
        if head and head[0] == "FIELD":
            name = head[1]
            count = int(head[2])
            width = int(head[3])
            values = [int(v) for v in lines[i + 1].split()]
            if len(values) != count:
                sys.exit("field %s: expected %d values, got %d" % (name, count, len(values)))
            if any(v < 0 or v > 0xFFFF for v in values):
                sys.exit("field %s: a value is outside uint16_t" % name)
            tables[name] = values
            widths[name] = width
            i += 2
        else:
            i += 1
    if not tables:
        sys.exit("the dumper produced no tables")
    for name, values in tables.items():
        if len(values) % widths[name]:
            sys.exit("field %s: %d entries is not a whole number of rows" %
                     (name, len(values)))
    return tables, widths


def verify_against_source(source: Path, tables: dict[str, list[int]]) -> int:
    """A second, independent path from the C source to the numbers.

    The dumper is authoritative about *where* designated initializers put a
    row. This check is authoritative about *what* the numbers are: it reads
    every ``CDFn(a, b, ...)`` invocation straight out of cdf.c, turns each
    argument into ``32768 - arg``, and requires that exact run to appear in the
    dumped data. A compiler bug, a wrong struct layout or a transcription error
    cannot survive both paths agreeing.
    """
    cdf_c = (source / "src/cdf.c").read_text(encoding="utf-8")
    text = initializer_slice(cdf_c)
    flat: list[int] = []
    for values in tables.values():
        flat.extend(values)
    needle = " ".join(str(v) for v in flat)
    checked = 0
    for match in re.finditer(r"CDF(\d+)\(([^)]*)\)", text, re.S):
        n = int(match.group(1))
        args = [int(v) for v in re.findall(r"\d+", match.group(2))]
        # The macro definitions themselves use letter names, not numbers.
        if len(args) != n:
            continue
        row = " ".join(str(32768 - value) for value in args[:n])
        if row not in needle:
            sys.exit("a CDF row from cdf.c is missing from the dump: " + row[:80])
        checked += 1
    if checked < 1000:
        sys.exit("expected thousands of CDF rows, checked only %d" % checked)
    return checked


def moonbit_literal(values: list[int]) -> str:
    rows = []
    for start in range(0, len(values), 16):
        rows.append("  " + ", ".join(str(v) for v in values[start : start + 16]) + ",")
    return "\n".join(rows)


def write_moonbit(tables: dict[str, list[int]], widths: dict[str, int],
                  out: Path) -> str:
    """One flat array per syntax element, plus a table of mutable copies."""
    names = list(tables)
    # FNV-1a over the little-endian uint16 entries, which is the digest the
    # MoonBit test computes from the compiled table. The same hash the other
    # fixture generators use, so one helper covers every generated file.
    value = 0xCBF29CE484222325
    for name in names:
        for v in tables[name]:
            for byte in (v & 0xFF, (v >> 8) & 0xFF):
                value = ((value ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    hexdigest = "%016x" % value

    parts = [
        "// Copyright 2026 Leo Cheng",
        "// SPDX-License-Identifier: Apache-2.0",
        "//",
        "// Generated by scripts/fixtures/av1_cdf.py. Do not edit.",
        "//",
        "// The default cumulative distribution functions of every AV1 syntax",
        "// element, from dav1d %s's src/cdf.c. The C source stores each entry as" % PINNED,
        "// 32768 - p; these are the CDF entries themselves, in Q15, with the",
        "// final count entry at index n_symbols. A decoder copies them into a",
        "// mutable table before a frame, because every symbol adapts the CDF",
        "// it was read from.",
        "",
        "///|",
        "/// The FNV-1a of every entry as two little-endian bytes, in the order",
        "/// below. The test that holds the compiled table to the reference source.",
        "pub let cdf_reference_digest : String = \"%s\"" % hexdigest,
        "",
    ]
    # A single flat table with named offsets, so the decoder can address a CDF
    # by (field, context) without a struct of sixty separately allocated arrays.
    offsets: dict[str, int] = {}
    flat: list[int] = []
    for name in names:
        offsets[name] = len(flat)
        flat.extend(tables[name])
    parts += [
        "///|",
        "/// Every table concatenated. `cdf_offset` says where a syntax",
        "/// element's contexts begin, and `cdf_names` which one a number means.",
        "/// The order is the order of the fields in dav1d's cdf.h.",
        "let cdf_all : FixedArray[Int32] = [",
        moonbit_literal(flat),
        "]",
        "",
        "///|",
        "pub fn cdf_offset(field : Int32) -> Int32 {",
        "  cdf_offsets[field]",
        "}",
        "",
        "///|",
        "let cdf_offsets : FixedArray[Int32] = [",
        moonbit_literal([offsets[n] for n in names]),
        "]",
        "",
        "///|",
        "pub let cdf_lengths : FixedArray[Int32] = [",
        moonbit_literal([len(tables[n]) for n in names]),
        "]",
        "",
        "///|",
        "/// How wide one context of each element is, in entries, count included.",
        "/// The reference pads a row so that a context can be addressed without a",
        "/// multiply by the number of symbols, and the offsets follow the padding.",
        "pub let cdf_widths : FixedArray[Int32] = [",
        moonbit_literal([widths[n] for n in names]),
        "]",
        "",
        "///|",
        "pub let cdf_names : Array[String] = [",
        "\n".join('  "%s",' % n for n in names),
        "]",
        "",
        "///|",
        "/// The index of each syntax element's table, so the tile decoder names",
        "/// what it is reading rather than counting fields in a struct.",
        "\n".join(
            '///|\npub const CDF_%s : Int32 = %d' % (
                n.upper().replace("-", "_"), i
            )
            for i, n in enumerate(names)
        ),
        "",
        "///|",
        "/// Where a context's CDF begins in the flat working table.",
        "pub fn cdf_context(field : Int32, context : Int32, width : Int32) -> Int32 {",
        "  cdf_offsets[field] + context * width",
        "}",
        "",
        "///|",
        "/// A fresh, mutable copy of the defaults: the frame's working CDFs.",
        "pub fn cdf_fresh() -> FixedArray[Int32] {",
        "  let out : FixedArray[Int32] = FixedArray::make(cdf_all.length(), 0)",
        "  for i in 0..<cdf_all.length() {",
        "    out[i] = cdf_all[i]",
        "  }",
        "  out",
        "}",
        "",
    ]
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(parts))
    return hexdigest


def fetch_source(cache: Path) -> Path:
    """Download the pinned reference source if it is not already in the cache."""
    target = cache / ("dav1d-" + PINNED)
    if (target / "src/cdf.c").exists():
        return target
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / ("dav1d-" + PINNED + ".tar.gz")
    if not archive.exists():
        import urllib.request

        urllib.request.urlretrieve(SOURCE_URL, archive)
    with tempfile.TemporaryDirectory() as directory:
        subprocess.run(
            ["tar", "xzf", str(archive), "-C", directory], check=True
        )
        shutil.move(str(Path(directory) / ("dav1d-" + PINNED)), str(target))
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="a dav1d source tree")
    parser.add_argument("--cache", type=Path, help="where to download it")
    parser.add_argument(
        "--cc", default=os.environ.get("CC", "cc"), help="the C compiler"
    )
    parser.add_argument(
        "--out", type=Path, default=ROOT / "src/avif/cdf_tables.mbt"
    )
    args = parser.parse_args()

    source = args.source or fetch_source(
        args.cache or Path(tempfile.gettempdir()) / "moonimage-av1ref"
    )
    for needed in (
        "src/cdf.c",
        "src/cdf.h",
        "src/levels.h",
        "include/dav1d/headers.h",
    ):
        if not (source / needed).exists():
            sys.exit("the reference source is missing " + needed)

    tables, widths = compile_and_run(source, args.cc)
    checked = verify_against_source(source, tables)
    digest = write_moonbit(tables, widths, args.out)
    total = sum(len(v) for v in tables.values())
    print(
        "wrote %s: %d tables, %d entries, %d CDF rows checked, fnv %s"
        % (args.out, len(tables), total, checked, digest)
    )


if __name__ == "__main__":
    main()
