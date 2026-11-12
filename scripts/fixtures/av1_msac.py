"""Generate reference vectors for the AV1 multi-symbol arithmetic decoder.

The vectors are produced by compiling dav1d's own ``src/msac.c`` (the scalar C
implementation, with assembly disabled) into a small harness, feeding it a
deterministic byte stream, and recording every decoded symbol and the final
state of every adapted CDF. The MoonBit decoder is then held to those numbers.

Usage (a C compiler and the pinned dav1d source are needed only to regenerate
the committed vectors):

    python3 scripts/fixtures/av1_msac.py --source /path/to/dav1d-1.5.4

The pinned source is the same as scripts/fixtures/av1_cdf.py, tag 1.5.4.
"""

from __future__ import annotations

import argparse
import os
import random
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
#define TRIM_DSP_FUNCTIONS 0
#define BITDEPTH_MAX 8
"""

OPS = ("SYMBOL", "BOOL", "BOOL_ADAPT", "EQUI", "UNIFORM", "SUBEXP", "HI_TOK")


def build_inputs():
    """A deterministic stream, CDF set, and script of decode operations.

    Three kinds of CDF, because dav1d asserts on their shape: a symbol CDF has
    its count at cdf[n_symbols], a boolean at cdf[1], and a hi-token at cdf[3].
    """
    rng = random.Random(0x415631)  # "AV1"
    stream = bytes(rng.randrange(256) for _ in range(384))
    cdfs: list[list[int]] = []
    # Twelve symbol CDFs, of two to thirteen symbols.
    for index in range(12):
        nsyms = 2 + index
        remaining = 32768
        row: list[int] = []
        for i in range(nsyms):
            step = rng.randrange(1, max(2, remaining // (nsyms - i) * 2))
            step = min(step, max(1, remaining - (nsyms - i - 1)))
            remaining -= step
            row.append(remaining)
        row.append(0)  # the count
        row += [0] * (16 - len(row))
        cdfs.append(row)
    # Six boolean CDFs: one probability, then the count.
    for _ in range(6):
        row = [rng.randrange(1, 32767), 0] + [0] * 14
        cdfs.append(row)
    # Six hi-token CDFs: three probabilities, then the count at index three.
    for _ in range(6):
        row = [rng.randrange(20000, 32000), rng.randrange(8000, 19999),
               rng.randrange(1, 7999), 0] + [0] * 12
        cdfs.append(row)
    ops: list[tuple[int, int, int]] = []
    for _ in range(2400):
        kind = rng.randrange(len(OPS))
        if kind == 0:
            cdf_id = rng.randrange(12)
            param = 2 + cdf_id
        elif kind == 2:
            cdf_id = rng.randrange(12, 18)
            param = 0
        elif kind == 6:
            cdf_id = rng.randrange(18, 24)
            param = 3
        else:
            cdf_id = rng.randrange(24)
            param = 0
        if kind == 1:
            param = rng.randrange(1, 32768)
        elif kind == 4:
            param = rng.randrange(2, 65)
        elif kind == 5:
            # dav1d_msac_decode_subexp requires n >> k == 8, so n = 8 << k.
            param = rng.randrange(0, 5)
        ops.append((kind, cdf_id, param))
    return stream, cdfs, ops


def c_array(name: str, values, width: int = 12) -> str:
    rows = []
    for start in range(0, len(values), width):
        rows.append("  " + ", ".join(str(v) for v in values[start : start + width]) + ",")
    return "static const %s %s[] = {\n%s\n};" % (
        "uint8_t" if max(values, default=0) < 256 else "uint16_t",
        name,
        "\n".join(rows),
    )


def build_harness(stream: bytes, cdfs, ops) -> str:
    flat_cdf = [v for row in cdfs for v in row]
    op_kind = [o[0] for o in ops]
    op_cdf = [o[1] for o in ops]
    op_param = [o[2] for o in ops]
    body = r"""
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include "src/msac.h"

__STREAM__
__CDFS__
__OPKIND__
__OPCDF__
__OPPARAM__

static uint64_t fnv_state(const uint16_t *cdf) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (int i = 0; i < 24 * 16; i++)
        for (int b = 0; b < 2; b++) {
            const unsigned byte = (cdf[i] >> (8 * b)) & 0xff;
            h ^= byte;
            h *= 0x100000001b3ULL;
        }
    return h;
}

int main(void) {
    MsacContext s;
    dav1d_msac_init(&s, stream, sizeof(stream), 0);
    uint16_t cdf[24][16];
    memcpy(cdf, flat_cdf, sizeof(cdf));
    for (size_t i = 0; i < sizeof(op_kind) / sizeof(op_kind[0]); i++) {
        const int kind = op_kind[i];
        const int id = op_cdf[i];
        const int p = op_param[i];
        unsigned v = 0;
        switch (kind) {
        case 0: v = dav1d_msac_decode_symbol_adapt_c(&s, cdf[id], (size_t)p); break;
        case 1: v = dav1d_msac_decode_bool_c(&s, (unsigned)p); break;
        case 2: v = dav1d_msac_decode_bool_adapt_c(&s, cdf[id]); break;
        case 3: v = dav1d_msac_decode_bool_equi_c(&s); break;
        case 4: v = (unsigned)dav1d_msac_decode_uniform(&s, (unsigned)p); break;
        case 5: v = (unsigned)dav1d_msac_decode_subexp(&s, 3, 8 << p, p); break;
        case 6: v = dav1d_msac_decode_hi_tok_c(&s, cdf[id]); break;
        }
        printf("%u ", v);
        printf("%016llx ", (unsigned long long)fnv_state((const uint16_t *)cdf));
        printf("%016llx:%u:%d:%d ", (unsigned long long)s.dif, s.rng, s.cnt,
               (int)(s.buf_pos - stream));
    }
    printf("\nSTATE\n");
    for (int i = 0; i < 24; i++)
        for (int j = 0; j < 16; j++)
            printf("%u ", (unsigned)cdf[i][j]);
    printf("\n");
    return 0;
}
"""
    return (
        body.replace("__STREAM__", c_array("stream", list(stream), 16))
        .replace("__CDFS__", c_array("flat_cdf", flat_cdf, 16))
        .replace("__OPKIND__", c_array("op_kind", op_kind, 16))
        .replace("__OPCDF__", c_array("op_cdf", op_cdf, 16))
        .replace("__OPPARAM__", c_array("op_param", op_param, 16))
    )


def compile_and_run(source: Path, cc: str, stream, cdfs, ops):
    harness = build_harness(stream, cdfs, ops)
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        (work / "config.h").write_text(CONFIG_H, encoding="utf-8")
        (work / "harness.c").write_text(harness, encoding="utf-8")
        outcome = subprocess.run(
            [
                cc,
                "-O0",
                "-std=c11",
                "-w",
                "-I",
                str(work),
                "-I",
                str(source / "include"),
                "-I",
                str(source),
                str(work / "harness.c"),
                str(source / "src/msac.c"),
                "-lm",
                "-o",
                str(work / "harness"),
            ],
            capture_output=True,
            text=True,
        )
        if outcome.returncode != 0:
            sys.exit("cannot compile the dav1d symbol decoder:\n" + outcome.stderr)
        run = subprocess.run([str(work / "harness")], capture_output=True, text=True)
        if run.returncode != 0:
            sys.exit("the reference harness failed: " + run.stderr)
    values, _, state = run.stdout.partition("STATE\n")
    tokens = values.split()
    results = [int(tokens[3 * i]) for i in range(len(ops))]
    hashes = [tokens[3 * i + 1] for i in range(len(ops))]
    states = [tokens[3 * i + 2] for i in range(len(ops))]
    final = [int(v) for v in state.split()]
    if len(tokens) != 3 * len(ops):
        sys.exit("expected %d result/state triples, got %d tokens" % (3 * len(ops), len(tokens)))
    if len(final) != 24 * 16:
        sys.exit("expected 384 CDF entries, got %d" % len(final))
    return results, hashes, states, final


def bytes_literal(data: bytes) -> str:
    return "b\"" + "".join("\\x%02x" % b for b in data) + "\""


def int_rows(values, width: int = 16) -> str:
    rows = []
    for start in range(0, len(values), width):
        rows.append("  " + ", ".join(str(v) for v in values[start : start + width]) + ",")
    return "\n".join(rows)


def write_moonbit(stream, cdfs, ops, results, hashes, states, final, out: Path) -> None:
    flat_cdf = [v for row in cdfs for v in row]
    parts = [
        "// Copyright 2026 Leo Cheng",
        "// SPDX-License-Identifier: Apache-2.0",
        "//",
        "// Generated by scripts/fixtures/av1_msac.py. Do not edit.",
        "//",
        "// 2,400 symbols decoded by dav1d %s's scalar msac.c from one byte" % PINNED,
        "// stream, with the adapted CDFs recorded at the end. Every operation",
        "// is (kind, cdf index, parameter); the kinds are symbol, bool, adapted",
        "// bool, equiprobable bool, uniform, subexponential and hi-token.",
        "",
        "///|",
        "let msac_stream : Bytes = " + bytes_literal(stream),
        "",
        "///|",
        "let msac_cdfs : FixedArray[Int32] = [",
        int_rows(flat_cdf),
        "]",
        "",
        "///|",
        "let msac_ops : Array[(Int32, Int32, Int32)] = [",
    ]
    for kind, cdf_id, param in ops:
        parts.append("  (%d, %d, %d)," % (kind, cdf_id, param))
    parts += [
        "]",
        "",
        "///|",
        "let msac_expected : FixedArray[Int32] = [",
        int_rows(results),
        "]",
        "",
        "///|",
        "let msac_state_hashes : Array[String] = [",
        "\n".join('  "%s",' % h for h in hashes),
        "]",
        "",
        "///|",
        "let msac_machine_states : Array[String] = [",
        "\n".join('  "%s",' % s for s in states),
        "]",
        "",
        "///|",
        "let msac_final_cdfs : FixedArray[Int32] = [",
        int_rows(final),
        "]",
        "",
        "///|",
        "test \"every symbol is the one dav1d reads, and every CDF ends where it does\" {",
        "  let coder = @avif.Msac::new(msac_stream)",
        "  let cdfs : FixedArray[Int32] = FixedArray::make(msac_cdfs.length(), 0)",
        "  for i in 0..<msac_cdfs.length() {",
        "    cdfs[i] = msac_cdfs[i]",
        "  }",
        "  for i in 0..<msac_ops.length() {",
        "    let (kind, id, param) = msac_ops[i]",
        "    let at = id * 16",
        "    let got = if kind == 0 {",
        "      coder.symbol(cdfs, at, param)",
        "    } else if kind == 1 {",
        "      coder.bool(param)",
        "    } else if kind == 2 {",
        "      coder.bool_adapt(cdfs, at)",
        "    } else if kind == 3 {",
        "      coder.bool_equi()",
        "    } else if kind == 4 {",
        "      coder.uniform(param)",
        "    } else if kind == 5 {",
        "      coder.subexp(3, 8 << param, param)",
        "    } else {",
        "      coder.hi_tok(cdfs, at)",
        "    }",
        "    if got != msac_expected[i] {",
        "      abort(\"operation \\{i} (kind \\{kind}): got \\{got}, want \\{msac_expected[i]}\")",
        "    }",
        "    let mut hash : UInt64 = 0xCBF29CE484222325",
        "    for k in 0..<cdfs.length() {",
        "      for b in 0..<2 {",
        "        let byte = (cdfs[k] >> (b * 8)) & 0xFF",
        "        hash = (hash ^ byte.to_uint64()) * 0x100000001B3",
        "      }",
        "    }",
        "    let digits = \"0123456789abcdef\"",
        "    let mut text = \"\"",
        "    for place in 0..<16 {",
        "      let nibble = ((hash >> ((15 - place) * 4)) & 0xF).to_int()",
        "      text = text + digits[nibble:nibble + 1].to_owned()",
        "    }",
        "    if coder.debug_state() != msac_machine_states[i] {",
        "      abort(\"operation \\{i} (kind \\{kind}): machine \\{coder.debug_state()}, want \\{msac_machine_states[i]}\")",
        "    }",
        "    if text != msac_state_hashes[i] {",
        "      abort(\"operation \\{i} (kind \\{kind}): CDF state \\{text}, want \\{msac_state_hashes[i]}\")",
        "    }",
        "  }",
        "  for i in 0..<cdfs.length() {",
        "    if cdfs[i] != msac_final_cdfs[i] {",
        "      abort(\"CDF entry \\{i}: got \\{cdfs[i]}, want \\{msac_final_cdfs[i]}\")",
        "    }",
        "  }",
        "}",
        "",
    ]
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(parts), encoding="utf-8")


def fetch_source(cache: Path) -> Path:
    target = cache / ("dav1d-" + PINNED)
    if (target / "src/msac.c").exists():
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
    parser.add_argument("--source", type=Path)
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    parser.add_argument("--out", type=Path, default=ROOT / "src/avif/msac_vectors_test.mbt")
    args = parser.parse_args()

    source = args.source or fetch_source(
        args.cache or Path(tempfile.gettempdir()) / "moonimage-av1ref"
    )
    if not (source / "src/msac.c").exists():
        sys.exit("the reference source is missing src/msac.c")

    stream, cdfs, ops = build_inputs()
    results, hashes, states, final = compile_and_run(source, args.cc, stream, cdfs, ops)
    write_moonbit(stream, cdfs, ops, results, hashes, states, final, args.out)
    print(
        "wrote %s: %d operations, %d CDF entries, first results %s"
        % (args.out, len(ops), len(final), results[:8])
    )


if __name__ == "__main__":
    main()
