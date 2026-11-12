#!/usr/bin/env python3
# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0
"""Dump dav1d's quantiser matrices as MoonBit.

A frame header may say it weights each coefficient of a transform by a matrix
before quantising it, and the matrices themselves are not in the specification:
they are tables in the reference implementation, fifteen of them, each in two
variants (one for luma and one for chroma), for each transform size.

The tables are large and entirely mechanical, so they are dumped rather than
transcribed. Tables that the reference points at twice — a sixty-four point
transform borrows the thirty-two point one — are stored once.

    python3 scripts/fixtures/av1_qm_tables.py --source /path/to/dav1d-1.5.4
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

CONFIG_H = """\
#define HAVE_ASM 0
#define ARCH_AARCH64 0
#define ARCH_ARM 0
#define ARCH_X86 0
#define ARCH_X86_32 0
#define ARCH_X86_64 0
#define CONFIG_16BPC 0
#define CONFIG_8BPC 1
#define ENDIANNESS_BIG 0
#define HAVE_C11_GENERIC 1
#define HAVE_POSIX_MEMALIGN 0
#define HAVE_UNISTD_H 0
#define STACK_ALIGNMENT 16
"""

HARNESS = r"""
#include <stdint.h>
#include <stdio.h>
#include "src/tables.h"
#include "src/levels.h"
#include "src/qm.h"

int main(void) {
    dav1d_init_qm_tables();
    const uint8_t *seen[1024];
    int ids[1024];
    int count = 0;
    for (int level = 0; level < 16; level++) {
        for (int variant = 0; variant < 2; variant++) {
            for (int tx = 0; tx < N_RECT_TX_SIZES; tx++) {
                const uint8_t *table = dav1d_qm_tbl[level][variant][tx];
                if (!table) {
                    printf("PTR %d %d %d -1\n", level, variant, tx);
                    continue;
                }
                int id = -1;
                for (int i = 0; i < count; i++)
                    if (seen[i] == table) id = ids[i];
                if (id < 0) {
                    id = count;
                    seen[count] = table;
                    ids[count] = id;
                    count++;
                    const int w = dav1d_txfm_dimensions[tx].w * 4 < 32 ?
                                  dav1d_txfm_dimensions[tx].w * 4 : 32;
                    const int h = dav1d_txfm_dimensions[tx].h * 4 < 32 ?
                                  dav1d_txfm_dimensions[tx].h * 4 : 32;
                    printf("DATA %d %d", id, w * h);
                    for (int i = 0; i < w * h; i++) printf(" %d", table[i]);
                    printf("\n");
                }
                printf("PTR %d %d %d %d\n", level, variant, tx, id);
            }
        }
    }
    return 0;
}
"""


def compile_and_run(source: Path, cc: str) -> str:
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        (work / "config.h").write_text(CONFIG_H, encoding="utf-8", newline="\n")
        (work / "harness.c").write_text(HARNESS, encoding="utf-8", newline="\n")
        outcome = subprocess.run(
            [
                cc, "-O0", "-std=c11", "-w",
                "-I", str(work),
                "-I", str(source / "include"),
                "-I", str(source),
                str(work / "harness.c"),
                str(source / "src/qm.c"),
                str(source / "src/tables.c"),
                "-o", str(work / "harness"),
            ],
            capture_output=True,
            text=True,
        )
        if outcome.returncode != 0:
            sys.exit("cannot compile the reference matrices:\n" + outcome.stderr)
        run = subprocess.run([str(work / "harness")], capture_output=True, text=True)
        if run.returncode != 0:
            sys.exit("the matrix harness failed: " + run.stderr)
        return run.stdout


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    parser.add_argument("--out", type=Path, default=ROOT / "src/avif/qm_tables.mbt")
    arguments = parser.parse_args()

    data = {}
    pointers = {}
    for line in compile_and_run(arguments.source, arguments.cc).splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "DATA":
            data[int(parts[1])] = [int(v) for v in parts[3:]]
        elif parts[0] == "PTR":
            pointers[(int(parts[1]), int(parts[2]), int(parts[3]))] = int(parts[4])

    order = sorted(data)
    offsets = {}
    flat = []
    for index in order:
        offsets[index] = len(flat)
        flat.extend(data[index])

    rows = []
    for start in range(0, len(flat), 24):
        rows.append("  " + ", ".join(str(v) for v in flat[start:start + 24]) + ",")

    index_rows = []
    for level in range(16):
        for variant in range(2):
            for tx in range(19):
                entry = pointers[(level, variant, tx)]
                # The dump numbers the distinct tables; the decoder needs where
                # each of them starts.
                index_rows.append(-1 if entry < 0 else offsets[entry])

    lines = [
        "// Copyright 2026 Leo Cheng",
        "// SPDX-License-Identifier: Apache-2.0",
        "//",
        "// Generated by scripts/fixtures/av1_qm_tables.py. Do not edit.",
        "//",
        "// The quantiser matrices: fifteen weightings, two variants of each (luma",
        "// and chroma), for each transform size. The index is",
        "// (level * 2 + variant) * 19 + transform, and -1 means the level is off.",
        "",
        "///|",
        "let qm_all : FixedArray[Int32] = [",
        "\n".join(rows),
        "]",
        "",
        "///|",
        "/// Where each level's matrix for a transform begins, as an index into the",
        "/// array above, or nought when the frame does not weight that plane.",
        "let qm_index : FixedArray[Int32] = [",
        "  " + ", ".join(str(v) for v in index_rows[:96]) + ",",
        "  " + ", ".join(str(v) for v in index_rows[96:192]) + ",",
        "  " + ", ".join(str(v) for v in index_rows[192:288]) + ",",
        "  " + ", ".join(str(v) for v in index_rows[288:384]) + ",",
        "  " + ", ".join(str(v) for v in index_rows[384:480]) + ",",
        "  " + ", ".join(str(v) for v in index_rows[480:576]) + ",",
        "  " + ", ".join(str(v) for v in index_rows[576:]) + ",",
        "]",
        "",
    ]
    arguments.out.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print("wrote %s: %d entries" % (arguments.out, len(flat)))


if __name__ == "__main__":
    main()
