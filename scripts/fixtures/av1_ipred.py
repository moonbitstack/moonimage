# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0

"""Generating the AV1 intra prediction vectors, out of dav1d's own code.

    python scripts/fixtures/av1_ipred.py --source /path/to/dav1d-1.5.4

The vectors are produced by compiling dav1d's scalar ``ipred_tmpl.c`` and asking
it to predict every block size in every mode, over three edge patterns. What is
dumped is the block it produced; the edges it read are dumped with it, so the
test can hand the port the same buffer and ask for the same block.

The edge buffer follows the reference's convention, which is worth writing down
because it is not the obvious one: ``topleft`` points at the corner sample, the
top edge runs forward from ``topleft[1]``, and the left edge runs *backwards*
from ``topleft[-1]``. A caller therefore has to hand over a buffer with room
above the corner, not below it.
"""

import argparse
import os
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import moonbit

ROOT = Path(__file__).resolve().parents[2]

SOURCE_URL = "https://codeload.github.com/videolan/dav1d/tar.gz/refs/tags/1.5.4"
PINNED = "1.5.4"

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
#define HAVE_ASM 0
#define HAVE_C11_GENERIC 1
#define HAVE_POSIX_MEMALIGN 0
#define HAVE_UNISTD_H 0
#define STACK_ALIGNMENT 16
"""

HARNESS = r"""
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "src/ipred.h"
#include "src/levels.h"
#include "src/tables.h"

/* The corner sample sits in the middle of the buffer: the top edge runs forward
   from it and the left edge backwards, which is the reference's convention. */
#define PAD 256

static pixel edge_buffer[2 * PAD];
static pixel block[64 * 64];

/* Three edge patterns: a ramp, a flat one, and one that walks both ways so an
   angle that reads past the nominal edge sees something different from zero. */
static void fill_edges(int pattern, const int width, const int height) {
    pixel *tl = edge_buffer + PAD;
    /* A directional walk reads past the end of the block's own edge: the third
       quarter reaches height + min(width, height) down the left column, and the
       filtered edges convolve two samples beyond. The buffer is filled that far
       and dumped that far, or the port would be compared against zeros it never
       saw. */
    const int reach = width + height;
    for (int i = 1; i <= reach; i++) {
        switch (pattern) {
        case 0: tl[i] = (pixel) ((i * 7 + 13) & 0xFF); break;
        case 1: tl[i] = (pixel) 100; break;
        default: tl[i] = (pixel) ((i * 31 + i * i * 5 + 3) & 0xFF); break;
        }
    }
    for (int i = 1; i <= reach; i++) {
        switch (pattern) {
        case 0: tl[-i] = (pixel) ((i * 11 + 29) & 0xFF); break;
        case 1: tl[-i] = (pixel) 100; break;
        default: tl[-i] = (pixel) ((i * 17 + i * i * 3 + 91) & 0xFF); break;
        }
    }
    switch (pattern) {
    case 0: tl[0] = (pixel) 40; break;
    case 1: tl[0] = (pixel) 100; break;
    default: tl[0] = (pixel) 173; break;
    }
}

static void dump(const char *tag, int mode, int width, int height, int angle,
                 int pattern) {
    printf("P %s %d %d %d %d %d", tag, mode, width, height, angle, pattern);
    const pixel *tl = edge_buffer + PAD;
    printf(" %d", tl[0]);
    const int reach = width + height;
    for (int i = 1; i <= reach; i++) printf(" %d", tl[i]);
    for (int i = 1; i <= reach; i++) printf(" %d", tl[-i]);
    for (int y = 0; y < height; y++)
        for (int x = 0; x < width; x++) printf(" %d", block[y * 64 + x]);
    printf("\n");
}

int main(void) {
    Dav1dIntraPredDSPContext dsp;
    memset(&dsp, 0, sizeof(dsp));
    dav1d_intra_pred_dsp_init_8bpc(&dsp);

    printf("DERIV");
    for (int i = 0; i < 90; i++) printf(" %d", dav1d_dr_intra_derivative[i]);
    printf("\n");
    printf("SMW");
    for (int i = 0; i < 128; i++) printf(" %d", dav1d_sm_weights[i]);
    printf("\n");

    static const struct { int w, h; } sizes[] = {
        { 4, 4 }, { 8, 8 }, { 16, 16 }, { 32, 32 }, { 64, 64 },
        { 4, 8 }, { 8, 4 }, { 8, 16 }, { 16, 8 }, { 16, 32 },
        { 32, 16 }, { 32, 64 }, { 64, 32 }, { 4, 16 }, { 16, 4 },
    };
    /* The base angle of each directional mode, and the steps either side of it
       the format allows: three degrees a step, up to six steps. */
    static const int angles[] = { -9, -6, -3, 0, 3, 6, 9 };

    for (int mode = 0; mode < N_INTRA_PRED_MODES; mode++) {
        for (unsigned s = 0; s < sizeof(sizes) / sizeof(sizes[0]); s++) {
            const int w = sizes[s].w, h = sizes[s].h;
            const int directional = mode >= DIAG_DOWN_LEFT_PRED &&
                                    mode <= VERT_LEFT_PRED;
            const int steps = directional ? (int) (sizeof(angles) / sizeof(angles[0])) : 1;
            for (int step = 0; step < steps; step++) {
                int angle = 0;
                if (directional) {
                    angle = mode == DIAG_DOWN_LEFT_PRED ? 45 :
                            mode == DIAG_DOWN_RIGHT_PRED ? 135 :
                            mode == VERT_RIGHT_PRED ? 113 :
                            mode == HOR_DOWN_PRED ? 157 :
                            mode == HOR_UP_PRED ? 203 : 45;
                    angle += angles[step] * 3;
                    /* Each family of angles has its own quarter: the first runs
                       up to ninety, the second between, the third above a
                       hundred and eighty. A step outside its own quarter is not
                       a prediction the format can ask for. */
                    const int low = mode == HOR_UP_PRED ? 181 : 1;
                    const int high = mode == HOR_UP_PRED ? 269 :
                                     (mode == DIAG_DOWN_LEFT_PRED ||
                                      mode == VERT_LEFT_PRED) ? 89 : 179;
                    if (angle < low || angle > high) continue;
                }
                /* The table is indexed by the quarter the angle falls in, not
                   by the mode: a caller picks the zone from the angle it was
                   handed, and three modes share a zone with another three. */
                angular_ipred_fn predict;
                if (!directional) {
                    predict = dsp.intra_pred[mode];
                } else if (angle < 90) {
                    predict = dsp.intra_pred[Z1_PRED];
                } else if (angle < 180) {
                    predict = dsp.intra_pred[Z2_PRED];
                } else {
                    predict = dsp.intra_pred[Z3_PRED];
                }
                for (int pattern = 0; pattern < 3; pattern++) {
                    memset(block, 0, sizeof(block));
                    fill_edges(pattern, w, h);
                    predict(block, 64, edge_buffer + PAD, w, h, angle, 64, 64);
                    dump("IP", mode, w, h, angle, pattern);
                }
            }
        }
    }
    return 0;
}
"""


def fetch(destination: Path) -> Path:
    """The reference source, unpacked once."""
    if (destination / "src" / "ipred_tmpl.c").exists():
        return destination
    archive = destination.parent / ("dav1d-" + PINNED + ".tar.gz")
    if not archive.exists():
        print("fetching %s" % SOURCE_URL)
        urllib.request.urlretrieve(SOURCE_URL, archive)
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            parts = member.name.split("/", 1)
            if len(parts) != 2:
                continue
            target = destination / parts[1]
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as source, open(target, "wb") as out:
                    out.write(source.read())
    return destination


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
                str(source / "src/ipred_tmpl.c"),
                str(source / "src/tables.c"),
                "-o", str(work / "harness"),
            ],
            capture_output=True,
            text=True,
        )
        if outcome.returncode != 0:
            sys.exit("cannot compile the dav1d intra predictors:\n" + outcome.stderr)
        run = subprocess.run([str(work / "harness")], capture_output=True, text=True)
        if run.returncode != 0:
            sys.exit("the reference harness failed: " + run.stderr)
        return run.stdout


def int_rows(values, width=16) -> str:
    rows = []
    for start in range(0, len(values), width):
        rows.append("  " + ", ".join(str(v) for v in values[start:start + width]) + ",")
    return "\n".join(rows)


CHUNK = 16 * 1024


def write_bulk(lines, name: str, data: bytes) -> None:
    """One array of bytes, in chunks, with an accessor.

    A single literal of a megabyte and a half is one text segment, and the
    toolchain refuses one that long; splitting it, and indexing through a small
    function, keeps each segment well inside the limit without changing what the
    test reads.
    """
    chunks = [data[i:i + CHUNK] for i in range(0, len(data), CHUNK)]
    for index, chunk in enumerate(chunks):
        lines.extend([
            "///|",
            "let %s_%d : Bytes = %s" % (name, index, moonbit.literal(chunk)),
            "",
        ])
    lines.extend([
        "///|",
        "let %s_chunks : Array[Bytes] = [" % name,
    ])
    for index in range(len(chunks)):
        lines.append("  %s_%d," % (name, index))
    lines.extend([
        "]",
        "",
        "///|",
        "pub fn %s_at(index : Int32) -> Int32 {" % name,
        "  %s_chunks[index / %d][index %% %d].to_int()" % (name, CHUNK, CHUNK),
        "}",
        "",
    ])


def write_module(path: Path, records) -> None:
    meta, edges, pixels = [], [], []
    for mode, w, h, angle, pattern, corner, top, left, block in records:
        meta.extend((mode, w, h, angle, pattern, len(edges), len(pixels)))
        edges.append(corner)
        edges.extend(top)
        edges.extend(left)
        pixels.extend(block)
    lines = [
        "// Copyright 2026 Leo Cheng",
        "// SPDX-License-Identifier: Apache-2.0",
        "//",
        "// Generated by scripts/fixtures/av1_ipred.py. Do not edit.",
        "//",
        "// Every intra predictor of the reference, over fifteen block sizes and",
        "// three edge patterns. A record is (mode, width, height, angle,",
        "// pattern, edge offset, pixel offset); the edges are the corner, the row",
        "// above and the column to the left, in that order, and the pixels are the",
        "// block the reference produced from them.",
        "",
        "///|",
        "pub let ipred_cases : FixedArray[Int32] = [",
        int_rows(meta),
        "]",
        "",
    ]
    write_bulk(lines, "ipred_edges", bytes(edges))
    write_bulk(lines, "ipred_pixels", bytes(pixels))
    path.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print("wrote %s: %d cases" % (path, len(records)))


def write_tables(path: Path, tables) -> None:
    body = [
        "// Copyright 2026 Leo Cheng",
        "// SPDX-License-Identifier: Apache-2.0",
        "//",
        "// Generated by scripts/fixtures/av1_ipred.py. Do not edit.",
        "//",
        "// The two tables the intra predictors read: the derivative of the angle",
        "// that says how far along an edge one step across the block moves, and the",
        "// smoothing weights indexed by the side of the block.",
        "",
        "///|",
        "let dr_derivative : FixedArray[Int32] = [",
        int_rows(tables["DERIV"]),
        "]",
        "",
        "///|",
        "let smooth_weights : FixedArray[Int32] = [",
        int_rows(tables["SMW"]),
        "]",
        "",
    ]
    path.write_text("\n".join(body), encoding="utf-8", newline="\n")
    print("wrote %s" % path)


def parse(output: str):
    records = []
    tables = {}
    for line in output.splitlines():
        head, *rest = line.split()
        if head in ("DERIV", "SMW"):
            tables[head] = [int(v) for v in rest]
            continue
        if head != "P" or not rest or rest[0] != "IP":
            continue
        values = [int(v) for v in rest[1:]]
        mode, width, height, angle, pattern = values[:5]
        # The remainder is: corner, the top row, the left column, the block.
        tail = values[5:]
        reach = width + height
        corner = tail[0]
        top = tail[1:1 + reach]
        left = tail[1 + reach:1 + 2 * reach]
        block = tail[1 + 2 * reach:]
        if len(block) != width * height:
            sys.exit("P: expected %d pixels, got %d" % (width * height, len(block)))
        records.append((mode, width, height, angle, pattern, corner, top, left, block))
    if not records:
        sys.exit("the harness produced no vectors")
    if len(tables.get("DERIV", [])) != 90 or len(tables.get("SMW", [])) != 128:
        sys.exit("the harness did not dump both tables")
    return records, tables


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="an unpacked dav1d %s" % PINNED)
    parser.add_argument("--out", type=Path, default=ROOT / "src/avif/ipred_vectors_wbtest.mbt")
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    arguments = parser.parse_args()

    if arguments.source:
        source = arguments.source
    else:
        directory = Path(os.environ.get("TMPDIR", "/tmp")) / ("dav1d-" + PINNED)
        source = fetch(directory)

    output = compile_and_run(source, arguments.cc)
    records, tables = parse(output)
    write_module(arguments.out, records)
    write_tables(arguments.out.parent / "ipred_tables.mbt", tables)
    return 0


if __name__ == "__main__":
    sys.exit(main())
