# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0

"""Generate reference vectors for the AV1 inverse transforms.

The vectors are produced by compiling dav1d's own scalar ``itx_1d.c`` and
``itx_tmpl.c`` (with assembly disabled, eight bits per component) into a
harness that dumps:

* the tables the transform needs -- scan orders, the last-nonzero-column
  lookup, the transform dimensions, the one-dimensional type pairs, and the
  shift for every transform size (read from the source, not transcribed);
* every one-dimensional transform (DCT/ADST/FLIPADST/IDENTITY at every size,
  plus WHT) run over deterministic inputs;
* every valid two-dimensional combination of transform size and transform
  type, run over sparse coefficient blocks and a known picture, recording the
  reconstructed pixels.

The MoonBit implementation is then held to those numbers, transform by
transform. A compiler is needed only to regenerate the committed vectors.

Usage:

    python3 scripts/fixtures/av1_itx.py --source /path/to/dav1d-1.5.4

The pinned source is the same as scripts/fixtures/av1_cdf.py, tag 1.5.4.
"""

from __future__ import annotations

import argparse
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

CONFIG_H = """
#define HAVE_ASM 0
#define ARCH_X86_64 0
#define ARCH_X86_32 0
#define ARCH_X86 0
#define ARCH_AARCH64 0
#define ARCH_ARM 0
#define ARCH_LOONGARCH64 0
#define ARCH_PPC64LE 0
#define ARCH_LOONGARCH 0
#define ARCH_RISCV 0
#define TRIM_DSP_FUNCTIONS 0
#define CONFIG_8BPC 1
#define CONFIG_16BPC 0
"""

HARNESS = r"""
#include "config.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BITDEPTH 8
#include "src/itx.h"
#include "src/itx_1d.h"
#include "src/levels.h"
#include "src/tables.h"
#include "src/scan.h"

#ifdef _WIN32
#include <windows.h>
int dav1d_pthread_once(INIT_ONCE *once, void (*fn)(void)) {
    (void) once;
    fn();
    return 0;
}
#endif

static uint32_t seed = 0x49545831u; /* "ITX1" */

static uint32_t rnd(void) {
    seed = seed * 1664525u + 1013904223u;
    return seed >> 8;
}

static int coef_value(void) {
    const uint32_t r = rnd();
    int mag = (int) (r % 4001u);
    if (r & 0x10000u) mag += 26000;
    if (mag == 0) mag = 1;
    return (r & 0x20000u) ? -mag : mag;
}

static void dump_tables(const Dav1dInvTxfmDSPContext *const dsp) {
    for (int tx = 0; tx < N_RECT_TX_SIZES; tx++) {
        const TxfmInfo *const d = &dav1d_txfm_dimensions[tx];
        const int w = 4 * d->w, h = 4 * d->h;
        const int sw = imin(w, 32), sh = imin(h, 32);
        const int len = sw * sh;
        printf("DIM %d %d %d %d %d\n", tx, w, h, d->lw, d->lh);
        printf("SCAN %d %d", tx, len);
        for (int i = 0; i < len; i++) printf(" %d", dav1d_scans[tx][i]);
        printf("\n");
        printf("LNZ %d %d", tx, len);
        for (int i = 0; i < len; i++)
            printf(" %d", dav1d_last_nonzero_col_from_eob[tx][i]);
        printf("\n");
        int mask = 0;
        for (int t = 0; t < N_TX_TYPES_PLUS_LL; t++)
            if (dsp->itxfm_add[tx][t]) mask |= 1 << t;
        printf("AVAIL %d %d\n", tx, mask);
    }
    for (int t = 0; t < N_TX_TYPES; t++)
        printf("TYPE %d %d %d\n", t, dav1d_tx1d_types[t][0],
               dav1d_tx1d_types[t][1]);
}

static void dump_1d(void) {
    for (int sz = 0; sz < N_TX_SIZES; sz++) {
        const int n = 4 << sz;
        for (int type = 0; type < N_TX_1D_TYPES; type++) {
            if (!dav1d_tx1d_fns[sz][type]) continue;
            for (int rep = 0; rep < 3; rep++) {
                int32_t c[64], before[64];
                for (int i = 0; i < n; i++) before[i] = c[i] = coef_value();
                dav1d_tx1d_fns[sz][type](c, 1, INT16_MIN, INT16_MAX);
                printf("ONE %d %d %d", sz, type, n);
                for (int i = 0; i < n; i++) printf(" %d", before[i]);
                for (int i = 0; i < n; i++) printf(" %d", c[i]);
                printf("\n");
            }
        }
    }
    for (int rep = 0; rep < 3; rep++) {
        int32_t c[4], before[4];
        for (int i = 0; i < 4; i++) before[i] = c[i] = coef_value();
        dav1d_inv_wht4_1d_c(c, 1);
        printf("WHT 4");
        for (int i = 0; i < 4; i++) printf(" %d", before[i]);
        for (int i = 0; i < 4; i++) printf(" %d", c[i]);
        printf("\n");
    }
}

static void dump_2d(const Dav1dInvTxfmDSPContext *const dsp) {
    for (int tx = 0; tx < N_RECT_TX_SIZES; tx++) {
        const TxfmInfo *const d = &dav1d_txfm_dimensions[tx];
        const int w = 4 * d->w, h = 4 * d->h;
        const int sw = imin(w, 32), sh = imin(h, 32);
        const int len = sw * sh;
        for (int txtp = 0; txtp < N_TX_TYPES_PLUS_LL; txtp++) {
            if (!dsp->itxfm_add[tx][txtp]) continue;
            for (int rep = 0; rep < 3; rep++) {
                /* 0 is the DC-only path; the others walk further into the
                   block, including its last coefficient. */
                const int eob = rep == 0 ? 0 :
                                rep == 1 ? imin(len - 1, 7) : len - 1;
                int16_t coeff[1024];
                memset(coeff, 0, sizeof(coeff));
                for (int i = 0; i <= eob; i++) {
                    int v = coef_value();
                    if (i == eob && v == 0) v = 7;
                    coeff[dav1d_scans[tx][i]] = (int16_t) v;
                }
                uint8_t dst[64 * 64];
                for (int y = 0; y < h; y++)
                    for (int x = 0; x < w; x++)
                        dst[y * w + x] = (uint8_t) ((x * 37 + y * 11 + 13) & 255);
                dsp->itxfm_add[tx][txtp](dst, w, coeff, eob);
                printf("TWO %d %d %d %d %d %d", tx, txtp, eob, w, h, eob + 1);
                for (int i = 0; i <= eob; i++)
                    printf(" %d %d", dav1d_scans[tx][i],
                           (int) coeff[dav1d_scans[tx][i]]);
                for (int i = 0; i < w * h; i++) printf(" %02x", dst[i]);
                printf("\n");
            }
        }
    }
}

int main(void) {
    Dav1dInvTxfmDSPContext dsp;
    memset(&dsp, 0, sizeof(dsp));
    dav1d_itx_dsp_init_8bpc(&dsp, 8);
    dump_tables(&dsp);
    dump_1d();
    dump_2d(&dsp);
    return 0;
}
"""

# The transform sizes, in the order of levels.h's RectTxfmSize enum. Used to
# put the shift read from itx_tmpl.c next to the dimensions read from tables.c.
SHIFT_RE = re.compile(
    r"^inv_txfm_fn(?:84|16|32|64)\(\s*[^,]*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)",
    re.M,
)


def read_shifts(source: Path) -> dict[tuple[int, int], int]:
    text = (source / "src/itx_tmpl.c").read_text(encoding="utf-8")
    found = {
        (int(w), int(h)): int(shift) for w, h, shift in SHIFT_RE.findall(text)
    }
    if len(found) != 19:
        sys.exit("expected 19 transform shifts in itx_tmpl.c, got %d" % len(found))
    return found


def compile_and_run(source: Path, cc: str) -> str:
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        (work / "config.h").write_text(CONFIG_H, encoding="utf-8", newline="\n")
        (work / "harness.c").write_text(HARNESS, encoding="utf-8", newline="\n")
        outcome = subprocess.run(
            [
                cc, "-O0", "-std=c11", "-w", "-DBITDEPTH=8",
                "-I", str(work),
                "-I", str(source / "include"),
                "-I", str(source),
                str(work / "harness.c"),
                str(source / "src/itx_1d.c"),
                str(source / "src/itx_tmpl.c"),
                str(source / "src/tables.c"),
                str(source / "src/scan.c"),
                "-o", str(work / "harness"),
            ],
            capture_output=True,
            text=True,
        )
        if outcome.returncode != 0:
            sys.exit("cannot compile the dav1d inverse transforms:\n" + outcome.stderr)
        run = subprocess.run([str(work / "harness")], capture_output=True, text=True)
        if run.returncode != 0:
            sys.exit("the reference harness failed: " + run.stderr)
        return run.stdout


def parse(output: str):
    dims, scan, lnz, avail, types = [], [], [], [], []
    one, wht, two = [], [], []
    for line in output.splitlines():
        head, *rest = line.split()
        if not head:
            continue
        if head == "DIM":
            dims.append([int(v) for v in rest])
        elif head == "SCAN":
            count = int(rest[1])
            values = [int(v) for v in rest[2:]]
            if len(values) != count:
                sys.exit("SCAN: expected %d values, got %d" % (count, len(values)))
            scan.append(values)
        elif head == "LNZ":
            count = int(rest[1])
            values = [int(v) for v in rest[2:]]
            if len(values) != count:
                sys.exit("LNZ: expected %d values, got %d" % (count, len(values)))
            lnz.append(values)
        elif head == "AVAIL":
            avail.append(int(rest[1]))
        elif head == "TYPE":
            types.append([int(rest[1]), int(rest[2])])
        elif head == "ONE":
            sz, kind, n = (int(v) for v in rest[:3])
            values = [int(v) for v in rest[3:]]
            if len(values) != 2 * n:
                sys.exit("ONE: expected %d values, got %d" % (2 * n, len(values)))
            one.append((sz, kind, n, values[:n], values[n:]))
        elif head == "WHT":
            values = [int(v) for v in rest[1:]]
            if len(values) != 8:
                sys.exit("WHT: expected 8 values, got %d" % len(values))
            wht.append((values[:4], values[4:]))
        elif head == "TWO":
            tx, txtp, eob, w, h, pairs = (int(v) for v in rest[:6])
            tail = rest[6:]
            if len(tail) != 2 * pairs + w * h:
                sys.exit(
                    "TWO: expected %d values, got %d"
                    % (2 * pairs + w * h, len(tail))
                )
            coeff = [
                (int(tail[2 * i]), int(tail[2 * i + 1])) for i in range(pairs)
            ]
            pixels = [int(v, 16) for v in tail[2 * pairs:]]
            two.append((tx, txtp, eob, w, h, coeff, pixels))
        else:
            sys.exit("unknown record: " + head)
    if not (len(dims) == len(scan) == len(lnz) == len(avail) == 19):
        sys.exit("the harness did not describe all 19 transform sizes")
    if len(types) != 16:
        sys.exit("expected 16 one-dimensional type pairs")
    if not one or not wht or not two:
        sys.exit("the harness produced no vectors")
    return dims, scan, lnz, avail, types, one, wht, two


def fnv_bytes(values) -> str:
    """FNV-1a over four little-endian bytes of every number, as a hex string."""
    h = 0xCBF29CE484222325
    for value in values:
        for shift in (0, 8, 16, 24):
            byte = (value >> shift) & 0xFF
            h = ((h ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return "%016x" % h


def int_rows(values, width=16) -> str:
    return "\n".join(
        "  " + ", ".join(str(v) for v in values[start : start + width]) + ","
        for start in range(0, len(values), width)
    )


def write_tables(
    out: Path, dims, scan, lnz, avail, types, shifts: dict[tuple[int, int], int]
) -> str:
    dims_flat = [v for row in dims for v in row]
    shift_flat = [shifts[(row[1], row[2])] for row in dims]
    types_flat = [v for row in types for v in row]
    scan_offsets = [0]
    for row in scan:
        scan_offsets.append(scan_offsets[-1] + len(row))
    scan_flat = [v for row in scan for v in row]
    lnz_flat = [v for row in lnz for v in row]
    digest = fnv_bytes(
        dims_flat + shift_flat + types_flat + avail + scan_flat + lnz_flat
    )
    parts = [
        "// Copyright 2026 Leo Cheng",
        "// SPDX-License-Identifier: Apache-2.0",
        "//",
        "// Generated by scripts/fixtures/av1_itx.py. Do not edit.",
        "//",
        "// Every number here was dumped by compiling dav1d %s's scalar inverse" % PINNED,
        "// transforms. The scans, the last-nonzero-column tables, the transform",
        "// dimensions, the one-dimensional type pairs and the shifts are the",
        "// reference decoder's own; a hand-edited value changes the digest.",
        "",
        "///|",
        "let itx_table_digest : String = \"" + digest + "\"",
        "",
        "///|",
        "/// width, height, log2(width/4), log2(height/4), for each transform size.",
        "let itx_dims : FixedArray[Int32] = [",
        int_rows(dims_flat),
        "]",
        "",
        "///|",
        "/// The right shift after the first one-dimensional pass.",
        "let itx_shift : FixedArray[Int32] = [",
        int_rows(shift_flat),
        "]",
        "",
        "///|",
        "/// Which transform types exist for each size, as a bit mask.",
        "let itx_available : FixedArray[Int32] = [",
        int_rows(avail),
        "]",
        "",
        "///|",
        "/// The pair of one-dimensional transforms for each two-dimensional type.",
        "let itx_1d_types : FixedArray[Int32] = [",
        int_rows(types_flat),
        "]",
        "",
        "///|",
        "let itx_scan_offsets : FixedArray[Int32] = [",
        int_rows(scan_offsets),
        "]",
        "",
        "///|",
        "let itx_scans : FixedArray[Int32] = [",
        int_rows(scan_flat),
        "]",
        "",
        "///|",
        "let itx_lnz : FixedArray[Int32] = [",
        int_rows(lnz_flat),
        "]",
        "",
        "///|",
        "pub fn itx_scan(tx : Int32, n : Int32) -> Int32 {",
        "  itx_scans[itx_scan_offsets[tx] + n]",
        "}",
        "",
        "///|",
        "pub fn itx_last_nonzero_col(tx : Int32, eob : Int32) -> Int32 {",
        "  itx_lnz[itx_scan_offsets[tx] + eob]",
        "}",
        "",
    ]
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(parts))
    return digest


def write_vectors(out: Path, one, wht, two, digest: str) -> None:
    one_meta, one_flat = [], []
    for sz, kind, n, before, after in one:
        one_meta.append(sz)
        one_meta.append(kind)
        one_meta.append(n)
        one_meta.append(len(one_flat))
        one_flat.extend(before)
        one_flat.extend(after)
    wht_flat = [v for before, after in wht for v in before + after]
    two_meta, two_coeff, two_pixels = [], [], []
    for tx, txtp, eob, w, h, coeff, pixels in two:
        two_meta.extend((tx, txtp, eob, w, h, len(two_coeff), len(two_pixels)))
        for index, value in coeff:
            two_coeff.extend((index, value))
        two_pixels.extend(pixels)
    parts = [
        "// Copyright 2026 Leo Cheng",
        "// SPDX-License-Identifier: Apache-2.0",
        "//",
        "// Generated by scripts/fixtures/av1_itx.py. Do not edit.",
        "//",
        "// One-dimensional transforms: (size index, 1D type, length, offset)",
        "// into a flat array holding the input coefficients followed by the",
        "// reference output. Two-dimensional transforms: (size index, 2D type,",
        "// eob, width, height, coefficient offset, pixel offset) into a flat",
        "// array of (position, level) pairs and a flat array of pixels.",
        "",
        "///|",
        "let itx_table_digest_expected : String = \"" + digest + "\"",
        "",
        "///|",
        "let itx_1d_cases : FixedArray[Int32] = [",
        int_rows(one_meta),
        "]",
        "",
        "///|",
        "let itx_1d_values : FixedArray[Int32] = [",
        int_rows(one_flat),
        "]",
        "",
        "///|",
        "let itx_wht_values : FixedArray[Int32] = [",
        int_rows(wht_flat),
        "]",
        "",
        "///|",
        "let itx_2d_cases : FixedArray[Int32] = [",
        int_rows(two_meta),
        "]",
        "",
        "///|",
        "let itx_2d_coeff : FixedArray[Int32] = [",
        int_rows(two_coeff),
        "]",
        "",
        "///|",
        "let itx_2d_pixels : FixedArray[Int32] = [",
        int_rows(two_pixels),
        "]",
        "",
    ]
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(parts))


# ---------------------------------------------------------------------------
# The one-dimensional transforms themselves.
#
# These are not transcribed by hand. The generator reads dav1d's scalar
# ``itx_1d.c``, lifts each function body, and translates its straight-line
# arithmetic into MoonBit. Every butterfly constant, every rounding term and
# every place a value is clipped therefore comes from the same bytes the
# reference vectors were compiled from.
# ---------------------------------------------------------------------------

# (C function name, MoonBit name, signature kind)
FUNCTIONS = [
    ("inv_dct4_1d_internal_c", "dct4", "dct"),
    ("inv_dct8_1d_internal_c", "dct8", "dct"),
    ("inv_dct16_1d_internal_c", "dct16", "dct"),
    ("inv_dct32_1d_internal_c", "dct32", "dct"),
    ("inv_dct64_1d_c", "dct64", "dct64"),
    ("inv_adst4_1d_internal_c", "adst4", "adst"),
    ("inv_adst8_1d_internal_c", "adst8", "adst"),
    ("inv_adst16_1d_internal_c", "adst16", "adst"),
    ("inv_identity4_1d_c", "identity4", "plain"),
    ("inv_identity8_1d_c", "identity8", "plain"),
    ("inv_identity16_1d_c", "identity16", "plain"),
    ("inv_identity32_1d_c", "identity32", "plain"),
    ("dav1d_inv_wht4_1d_c", "wht4", "plain"),
]

SIGNATURES = {
    "dct": (
        "(c : FixedArray[Int32], at : Int32, stride : Int32, "
        "min : Int32, max : Int32, tx64 : Bool) -> Unit"
    ),
    "dct64": (
        "(c : FixedArray[Int32], at : Int32, stride : Int32, "
        "min : Int32, max : Int32) -> Unit"
    ),
    "adst": (
        "(c : FixedArray[Int32], in_at : Int32, in_s : Int32, "
        "out_at : Int32, out_s : Int32, min : Int32, max : Int32) -> Unit"
    ),
    "plain": "(c : FixedArray[Int32], at : Int32, stride : Int32) -> Unit",
}

# A recursive internal call in the C source, and the MoonBit call it becomes.
CALLS = {
    "inv_dct4_1d_internal_c": "dct4",
    "inv_dct8_1d_internal_c": "dct8",
    "inv_dct16_1d_internal_c": "dct16",
    "inv_dct32_1d_internal_c": "dct32",
}


def c_function_body(text: str, name: str) -> str:
    """The brace-balanced body of one C function."""
    start = re.search(r"\b" + re.escape(name) + r"\s*\(", text)
    if start is None:
        sys.exit("no C function " + name)
    opening = text.find("{", start.end())
    if opening < 0:
        sys.exit("no body for " + name)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[opening + 1 : index]
    sys.exit("unbalanced C function " + name)


def strip_comment(line: str) -> str:
    quoted = False
    for index, char in enumerate(line):
        if char == '"':
            quoted = not quoted
        elif char == "/" and not quoted and index + 1 < len(line) and line[index + 1] == "/":
            return line[:index]
    return line


def c_statements(body: str):
    """C statements, with continuations joined and structure kept separate."""
    statements = []
    buffer = ""
    for raw in body.splitlines():
        line = strip_comment(raw).strip()
        if not line or line.startswith("assert(") or line.startswith("#"):
            continue
        structural = (
            line == "}"
            or line == "} else {"
            or (line.startswith("if (") and line.endswith("{"))
            or (line.startswith("for (") and line.endswith("{"))
        )
        if structural:
            if buffer:
                statements.append(buffer.strip())
                buffer = ""
            statements.append(line)
            continue
        buffer = (buffer + " " + line).strip() if buffer else line
        if buffer.endswith(";") and buffer.count("(") == buffer.count(")"):
            # `for (...) single_statement;` has no braces in the C source.
            # Give it a pair so the same translation handles both shapes.
            single = re.match(
                r"^(for \(int i = 0; i < \d+; i\+\+\))\s+(.+)$", buffer
            )
            if single:
                statements.append(single.group(1) + " {")
                statements.append(single.group(2))
                statements.append("}")
            else:
                statements.append(buffer)
            buffer = ""
    if buffer:
        statements.append(buffer)
    return statements


def split_declarations(text: str):
    """Split on commas that are not inside parentheses or brackets."""
    parts, depth, current = [], 0, ""
    for char in text:
        if char in "([":
            depth += 1
        elif char in ")]":
            depth -= 1
        if char == "," and depth == 0:
            parts.append(current.strip())
            current = ""
        else:
            current += char
    parts.append(current.strip())
    return parts


def replace_clip(text: str) -> str:
    """The C CLIP(a) macro, with balanced parentheses, becomes clip(a, min, max)."""
    out, index = [], 0
    while index < len(text):
        if text.startswith("CLIP(", index):
            cursor, depth = index + 5, 1
            while cursor < len(text) and depth:
                if text[cursor] == "(":
                    depth += 1
                elif text[cursor] == ")":
                    depth -= 1
                cursor += 1
            inner = replace_clip(text[index + 5 : cursor - 1])
            out.append("clip(" + inner + ", min, max)")
            index = cursor
        else:
            out.append(text[index])
            index += 1
    return "".join(out)


def c_to_moonbit_expr(text: str, kind: str) -> str:
    text = replace_clip(text)
    for c_name, mb_name in CALLS.items():
        text = text.replace(c_name + "(c,", mb_name + "(c, at,")
    # The last argument of the recursive call from inv_dct64 is a literal 1.
    text = re.sub(r"\bdct32\(c, at, stride << 1, min, max, 1\)",
                  "dct32(c, at, stride << 1, min, max, true)", text)
    if kind == "adst":
        text = re.sub(r"\bin\[([^\]]+)\]", r"c[in_at + (\1)]", text)
        text = re.sub(r"\bout\[([^\]]+)\]", r"c[out_at + (\1)]", text)
    else:
        text = re.sub(r"\bc\[([^\]]+)\]", r"c[at + (\1)]", text)
    # `in` is a keyword in MoonBit; the identity transforms use it as a name.
    text = re.sub(r"\bin\b", "sample", text)
    return text


def translate_statement(statement: str, kind: str, assigned: set[str]) -> list[str]:
    if statement == "}":
        return ["}"]
    if statement == "} else {":
        return ["} else {"]
    if statement.startswith("if (") and statement.endswith("{"):
        header = statement[:-1].strip()
        condition = header[4:-1].strip()
        return ["if " + condition + " {"]
    if statement.startswith("for (") and statement.endswith("{"):
        header = statement[5:-1].strip()
        count = re.search(r"<\s*(\d+)\s*;", header)
        if count is None:
            sys.exit("unsupported for loop: " + statement)
        return ["for i in 0..<" + count.group(1) + " {"]

    text = statement.rstrip(";").strip()
    # A doubled assignment, `t0 = t1 = expr`, is two statements in MoonBit.
    doubled = re.match(r"^([A-Za-z_]\w*)\s*=\s*([A-Za-z_]\w*)\s*=\s*(.+)$", text)
    if doubled and doubled.group(1) not in ("c", "out", "in"):
        left, middle, rhs = doubled.groups()
        expression = c_to_moonbit_expr(rhs, kind)
        return [middle + " = " + expression, left + " = " + middle]
    # A compound assignment to an array element.
    compound = re.match(r"^(.+?)\s*(\*=|-=|\+=)\s*(.+)$", text)
    if compound and "[" in compound.group(1):
        target = c_to_moonbit_expr(compound.group(1), kind)
        value = c_to_moonbit_expr(compound.group(3), kind)
        op = compound.group(2)[0]
        return [target + " = " + target + " " + op + " " + value]

    declaration = re.match(r"^(const\s+int|int)\s+(.+)$", text)
    if declaration:
        constant = declaration.group(1).startswith("const")
        lines = []
        for item in split_declarations(declaration.group(2)):
            item = item.strip()
            if not item:
                continue
            if "=" in item:
                name, expression = item.split("=", 1)
                name = re.sub(r"\bin\b", "sample", name.strip())
                value = c_to_moonbit_expr(expression.strip(), kind)
                mutable = "" if constant or name not in assigned else "mut "
                lines.append(
                    "let " + mutable + name + " : Int32 = " + value
                )
            else:
                name = re.sub(r"\bin\b", "sample", item)
                lines.append("let mut " + name + " : Int32 = 0")
        return lines
    return [c_to_moonbit_expr(text, kind)]


def assigned_names(statements) -> set[str]:
    names = set()
    for statement in statements:
        text = statement.strip()
        if text.startswith(("const ", "int ", "if ", "for ", "}")):
            continue
        if text.startswith(("c[", "in[", "out[")):
            continue
        first = re.match(r"^([A-Za-z_]\w*)\s*=(?!=)", text)
        if first:
            names.add(first.group(1))
        for middle in re.findall(r"=\s*([A-Za-z_]\w*)\s*=(?!=)", text):
            names.add(middle)
    return names


def write_1d_code(source: Path, out: Path) -> None:
    text = (source / "src/itx_1d.c").read_text(encoding="utf-8")
    parts = [
        "// Copyright 2026 Leo Cheng",
        "// SPDX-License-Identifier: Apache-2.0",
        "//",
        "// Generated by scripts/fixtures/av1_itx.py. Do not edit.",
        "//",
        "// The one-dimensional inverse transforms, translated from dav1d %s's"
        % PINNED,
        "// scalar src/itx_1d.c. The butterfly constants and the rounding are",
        "// the reference decoder's own; only the syntax was changed.",
        "",
        "///|",
        "fn clip(value : Int32, min : Int32, max : Int32) -> Int32 {",
        "  if value < min {",
        "    min",
        "  } else if value > max {",
        "    max",
        "  } else {",
        "    value",
        "  }",
        "}",
        "",
    ]
    for c_name, mb_name, kind in FUNCTIONS:
        statements = c_statements(c_function_body(text, c_name))
        assigned = assigned_names(statements)
        lines = ["///|", "fn " + mb_name + SIGNATURES[kind] + " {"]
        for statement in statements:
            for translated in translate_statement(statement, kind, assigned):
                lines.append("  " + translated)
        lines.append("}")
        lines.append("")
        parts.extend(lines)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(parts))


def fetch_source(cache: Path) -> Path:
    target = cache / ("dav1d-" + PINNED)
    if (target / "src/itx_1d.c").exists():
        return target
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / ("dav1d-" + PINNED + ".tar.gz")
    if not archive.exists():
        import urllib.request

        urllib.request.urlretrieve(SOURCE_URL, archive)
    with tempfile.TemporaryDirectory() as directory:
        subprocess.run(["tar", "xzf", str(archive), "-C", directory], check=True)
        shutil.move(str(Path(directory) / ("dav1d-" + PINNED)), str(target))
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="a dav1d source tree")
    parser.add_argument("--cache", type=Path, help="where to download it")
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    parser.add_argument(
        "--tables", type=Path, default=ROOT / "src/avif/itx_tables.mbt"
    )
    parser.add_argument(
        "--vectors", type=Path, default=ROOT / "src/avif/itx_vectors_test.mbt"
    )
    parser.add_argument(
        "--code", type=Path, default=ROOT / "src/avif/itx_1d.mbt"
    )
    args = parser.parse_args()

    source = args.source or fetch_source(
        args.cache or Path(tempfile.gettempdir()) / "moonimage-av1ref"
    )
    for needed in (
        "src/itx_1d.c",
        "src/itx_tmpl.c",
        "src/tables.c",
        "src/scan.c",
    ):
        if not (source / needed).exists():
            sys.exit("the reference source is missing " + needed)

    shifts = read_shifts(source)
    dims, scan, lnz, avail, types, one, wht, two = parse(
        compile_and_run(source, args.cc)
    )
    digest = write_tables(args.tables, dims, scan, lnz, avail, types, shifts)
    write_vectors(args.vectors, one, wht, two, digest)
    write_1d_code(source, args.code)
    print(
        "wrote %s, %s and %s: %d 1D, %d WHT, %d 2D vectors, digest %s"
        % (
            args.tables,
            args.vectors,
            args.code,
            len(one),
            len(wht),
            len(two),
            digest,
        )
    )


if __name__ == "__main__":
    main()
