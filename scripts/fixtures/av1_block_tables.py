#!/usr/bin/env python3
# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0
"""Dump dav1d's block, transform and filter tables as MoonBit arrays.

The tile decoder needs twenty small tables that say how a partition divides, how
large a transform is, which contexts a coefficient's neighbour falls in, and what
a deblocked pixel is filtered by. None of them can be written down from the
specification by hand without a mistake somewhere in the middle, and a mistake in
any of them is a decoder that reads the wrong number of bits and never resyncs.

So they are dumped from the reference the rest of this package is held to: the
program below includes dav1d's own `src/tables.c`, `src/dequant_tables.c` and
`src/qm.c` and prints each table, and this script writes them out as MoonBit.
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
#include "src/dequant_tables.h"

static void tag(const char *name) { printf("@%s\n", name); }

int main(void) {
    tag("block_dimensions");
    for (int i = 0; i < N_BS_SIZES; i++)
        printf("%d %d %d %d\n", dav1d_block_dimensions[i][0],
               dav1d_block_dimensions[i][1], dav1d_block_dimensions[i][2],
               dav1d_block_dimensions[i][3]);

    tag("block_sizes");
    for (int bl = 0; bl < N_BL_LEVELS; bl++)
        for (int bp = 0; bp < N_PARTITIONS; bp++)
            printf("%d %d\n", dav1d_block_sizes[bl][bp][0],
                   dav1d_block_sizes[bl][bp][1]);

    tag("partition_type_count");
    for (int bl = 0; bl < N_BL_LEVELS; bl++)
        printf("%d\n", dav1d_partition_type_count[bl]);

    tag("max_txfm_size_for_bs");
    for (int i = 0; i < N_BS_SIZES; i++)
        for (int j = 0; j < 4; j++)
            printf("%d\n", dav1d_max_txfm_size_for_bs[i][j]);

    tag("txfm_dimensions");
    for (int i = 0; i < N_RECT_TX_SIZES; i++)
        printf("%d %d %d %d %d %d %d %d\n", dav1d_txfm_dimensions[i].w,
               dav1d_txfm_dimensions[i].h, dav1d_txfm_dimensions[i].lw,
               dav1d_txfm_dimensions[i].lh, dav1d_txfm_dimensions[i].min,
               dav1d_txfm_dimensions[i].max, dav1d_txfm_dimensions[i].sub,
               dav1d_txfm_dimensions[i].ctx);

    tag("tx_types_per_set");
    for (int i = 0; i < 40; i++) printf("%d\n", dav1d_tx_types_per_set[i]);

    tag("tx_type_class");
    for (int i = 0; i < N_TX_TYPES_PLUS_LL; i++)
        printf("%d\n", dav1d_tx_type_class[i]);

    tag("intra_mode_context");
    for (int i = 0; i < N_INTRA_PRED_MODES; i++)
        printf("%d\n", dav1d_intra_mode_context[i]);

    tag("filter_mode_to_y_mode");
    for (int i = 0; i < 5; i++) printf("%d\n", dav1d_filter_mode_to_y_mode[i]);

    tag("lo_ctx_offsets");
    for (int n = 0; n < 3; n++)
        for (int y = 0; y < 5; y++)
            for (int x = 0; x < 5; x++)
                printf("%d\n", dav1d_lo_ctx_offsets[n][y][x]);

    tag("filter_intra_taps");
    for (int m = 0; m < 5; m++)
        for (int i = 0; i < 64; i++)
            printf("%d\n", dav1d_filter_intra_taps[m][i]);

    tag("skip_ctx");
    for (int y = 0; y < 5; y++)
        for (int x = 0; x < 5; x++)
            printf("%d\n", dav1d_skip_ctx[y][x]);

    tag("cdef_directions");
    for (int i = 0; i < 12; i++) printf("%d %d\n", dav1d_cdef_directions[i][0],
                                        dav1d_cdef_directions[i][1]);

    tag("txtp_from_uvmode");
    for (int i = 0; i < N_UV_INTRA_PRED_MODES; i++)
        printf("%d\n", dav1d_txtp_from_uvmode[i]);

    tag("dq_tbl");
    for (int h = 0; h < 2; h++)
        for (int q = 0; q < QINDEX_RANGE; q++)
            printf("%d %d\n", dav1d_dq_tbl[h][q][0], dav1d_dq_tbl[h][q][1]);

    tag("al_part_ctx");
    for (int s = 0; s < 2; s++)
        for (int bl = 0; bl < N_BL_LEVELS; bl++)
            for (int bp = 0; bp < N_PARTITIONS; bp++)
                printf("%d\n", dav1d_al_part_ctx[s][bl][bp]);

    tag("cfl_allowed_mask");
    printf("%u\n", cfl_allowed_mask);

    tag("txfm_count");
    printf("%d %d %d %d\n", N_TX_SIZES, N_RECT_TX_SIZES, N_BS_SIZES, N_BL_LEVELS);

    return 0;
}
"""


def compile_and_run(source: Path, cc: str) -> dict:
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
                str(source / "src/tables.c"),
                str(source / "src/dequant_tables.c"),
                "-o", str(work / "harness"),
            ],
            capture_output=True,
            text=True,
        )
        if outcome.returncode != 0:
            sys.exit("cannot compile the reference tables:\n" + outcome.stderr)
        run = subprocess.run([str(work / "harness")], capture_output=True, text=True)
        if run.returncode != 0:
            sys.exit("the table harness failed: " + run.stderr)
        return parse(run.stdout)


def parse(text: str) -> dict:
    tables = {}
    current = None
    for line in text.splitlines():
        if line.startswith("@"):
            current = line[1:].strip()
            tables[current] = []
        elif current is not None and line.strip():
            tables[current].append([int(v) for v in line.split()])
    return tables


def flat(table) -> list:
    return [v for row in table for v in row]


def rows(values, width=16, indent="  ") -> str:
    out = []
    for start in range(0, len(values), width):
        out.append(indent + ", ".join(str(v) for v in values[start:start + width]) + ",")
    return "\n".join(out)


def write_module(path: Path, tables: dict) -> None:
    dims = tables["block_dimensions"]
    tx = tables["txfm_dimensions"]
    lines = [
        "// Copyright 2026 Leo Cheng",
        "// SPDX-License-Identifier: Apache-2.0",
        "//",
        "// Generated by scripts/fixtures/av1_block_tables.py. Do not edit.",
        "//",
        "// The tables the tile decoder reads: how a partition divides, how large a",
        "// transform is and which context its neighbours put it in, the taps of the",
        "// filter a filter-intra block predicts with, the four taps of each",
        "// direction CDEF filters along, and the quantiser's two curves.",
        "",
        "///|",
        "/// Width and height in four-pixel units, then their logarithms, for each of",
        "/// the twenty-two block sizes.",
        "let block_dimensions : FixedArray[Int32] = [",
        rows(flat(dims)),
        "]",
        "",
        "///|",
        "/// The two block sizes a partition of a block produces, by block level and",
        "/// partition type: a horizontal cut yields two blocks of the first size, a",
        "/// vertical cut two of the second.",
        "let block_sizes : FixedArray[Int32] = [",
        rows(flat(tables["block_sizes"]), 20),
        "]",
        "",
        "///|",
        "/// How many partition types a block level can choose from.",
        "let partition_type_count : FixedArray[Int32] = [",
        rows(flat(tables["partition_type_count"])),
        "]",
        "",
        "///|",
        "/// The largest transform a block size uses, for luma and for each chroma",
        "/// layout.",
        "let max_txfm_size_for_bs : FixedArray[Int32] = [",
        rows(flat(tables["max_txfm_size_for_bs"]), 22),
        "]",
        "",
        "///|",
        "/// Width, height, their logarithms, the smallest and largest of those, the",
        "/// sub-transform a split produces, and the context a coefficient block is",
        "/// read in, for each of the nineteen transform sizes.",
        "let txfm_w : FixedArray[Int32] = [",
        rows([row[0] for row in tx]),
        "]",
        "",
        "///|",
        "let txfm_h : FixedArray[Int32] = [",
        rows([row[1] for row in tx]),
        "]",
        "",
        "///|",
        "let txfm_lw : FixedArray[Int32] = [",
        rows([row[2] for row in tx]),
        "]",
        "",
        "///|",
        "let txfm_lh : FixedArray[Int32] = [",
        rows([row[3] for row in tx]),
        "]",
        "",
        "///|",
        "let txfm_min : FixedArray[Int32] = [",
        rows([row[4] for row in tx]),
        "]",
        "",
        "///|",
        "let txfm_max : FixedArray[Int32] = [",
        rows([row[5] for row in tx]),
        "]",
        "",
        "///|",
        "let txfm_sub : FixedArray[Int32] = [",
        rows([row[6] for row in tx]),
        "]",
        "",
        "///|",
        "let txfm_ctx : FixedArray[Int32] = [",
        rows([row[7] for row in tx]),
        "]",
        "",
        "///|",
        "/// The transform types each of the four intra sets and the two inter sets",
        "/// index into, in the order the sets are laid out.",
        "let tx_types_per_set : FixedArray[Int32] = [",
        rows(flat(tables["tx_types_per_set"])),
        "]",
        "",
        "///|",
        "/// Which axis a transform type runs along: two-dimensional, horizontal or",
        "/// vertical.",
        "let tx_type_class : FixedArray[Int32] = [",
        rows(flat(tables["tx_type_class"])),
        "]",
        "",
        "///|",
        "/// The context a neighbouring luma mode contributes.",
        "let intra_mode_context : FixedArray[Int32] = [",
        rows(flat(tables["intra_mode_context"])),
        "]",
        "",
        "///|",
        "/// The luma mode a filter-intra block is treated as having, by filter index.",
        "let filter_mode_to_y_mode : FixedArray[Int32] = [",
        rows(flat(tables["filter_mode_to_y_mode"])),
        "]",
        "",
        "///|",
        "/// The context offsets a coefficient's neighbours select: three tables, for",
        "/// square transforms and the two rectangular cases, each five by five.",
        "let lo_ctx_offsets : FixedArray[Int32] = [",
        rows(flat(tables["lo_ctx_offsets"]), 25),
        "]",
        "",
        "///|",
        "/// Five filters, sixty-four taps each, in the reference's row order.",
        "let filter_intra_taps : FixedArray[Int32] = [",
        rows(flat(tables["filter_intra_taps"]), 16),
        "]",
        "",
        "///|",
        "/// The context a coefficient block's neighbours put it in, by how much",
        "/// they say they carried.",
        "let skip_ctx : FixedArray[Int32] = [",
        rows(flat(tables["skip_ctx"]), 25),
        "]",
        "",
        "///|",
        "/// The four taps, as a pair of offsets, of each CDEF direction.",
        "let cdef_directions : FixedArray[Int32] = [",
        rows(flat(tables["cdef_directions"]), 24),
        "]",
        "",
        "///|",
        "/// The transform type a chroma plane takes, from the mode it was predicted",
        "/// with.",
        "let txtp_from_uvmode : FixedArray[Int32] = [",
        rows(flat(tables["txtp_from_uvmode"])),
        "]",
        "",
        "///|",
        "/// The dequantiser's dc and ac values for each of the two hundred and",
        "/// fifty-six quantiser indexes, at eight bits and at high bit depth.",
        "let dq_tbl : FixedArray[Int32] = [",
        rows(flat(tables["dq_tbl"]), 24),
        "]",
        "",
        "///|",
        "/// The partition context a neighbouring block contributes, for the two",
        "/// shapes a partition context is read in.",
        "let al_part_ctx : FixedArray[Int32] = [",
        # The reference stores the "no context here" entries as 255 in a
        # uint8_t, which is -1 read as the signed value the decoder wants.
        rows([v - 256 if v > 127 else v for v in flat(tables["al_part_ctx"])], 20),
        "]",
        "",
        "///|",
        "/// Which block sizes may predict chroma from luma, as a bit each.",
        "let cfl_allowed_mask : Int32 = %d" % tables["cfl_allowed_mask"][0][0],
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print("wrote %s" % path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    parser.add_argument(
        "--out",
        type=Path,
        default=ROOT / "src/avif/block_tables.mbt",
    )
    arguments = parser.parse_args()
    tables = compile_and_run(arguments.source, arguments.cc)
    write_module(arguments.out, tables)


if __name__ == "__main__":
    main()
