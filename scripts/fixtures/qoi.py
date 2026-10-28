# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0

"""Generating the QOI fixtures.

    python scripts/fixtures/qoi.py

The reference is the format's own C implementation, qoi.h, compiled here and
driven through raw pixels. Every fixture is therefore a file qoi.h wrote from
pixels Pillow produced, and a digest of the pixels qoi.h read back from it. The
library has to agree on both: decode to the same pixels, and encode back to the
same bytes.

The corpus is PngSuite plus a handful of synthetic images, because the official
test images are no longer published at a fixed address. What the corpus has to
cover is the opcode set, and it does: runs, cache hits, differences, lumas,
literals with and without alpha.
"""

import io
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import moonbit
import sources

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "src" / "qoi" / "vectors_test.mbt"
QOI_H = "https://raw.githubusercontent.com/phoboslab/qoi/master/qoi.h"

REFERENCE = r"""
#define QOI_IMPLEMENTATION
#include "qoi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <io.h>
#include <fcntl.h>
#endif

int main(int argc, char **argv) {
#ifdef _WIN32
  _setmode(_fileno(stdin), _O_BINARY);
  _setmode(_fileno(stdout), _O_BINARY);
  _setmode(_fileno(stderr), _O_BINARY);
#endif
  if (argc < 2) return 2;
  if (!strcmp(argv[1], "enc")) {
    if (argc < 5) return 2;
    int w = atoi(argv[2]), h = atoi(argv[3]), channels = atoi(argv[4]);
    long long expect = (long long)w * h * channels;
    unsigned char *data = (unsigned char *)malloc((size_t)expect);
    if (!data) return 3;
    if ((long long)fread(data, 1, (size_t)expect, stdin) != expect) return 4;
    qoi_desc desc;
    desc.width = (unsigned int)w;
    desc.height = (unsigned int)h;
    desc.channels = (unsigned char)channels;
    desc.colorspace = QOI_SRGB;
    int length = 0;
    void *encoded = qoi_encode(data, &desc, &length);
    if (!encoded) return 5;
    if (fwrite(encoded, 1, (size_t)length, stdout) != (size_t)length) return 6;
    free(encoded);
    free(data);
    return 0;
  }
  if (!strcmp(argv[1], "dec")) {
    static unsigned char buffer[1 << 24];
    size_t length = fread(buffer, 1, sizeof(buffer), stdin);
    qoi_desc desc;
    void *pixels = qoi_decode(buffer, (int)length, &desc, 4);
    if (!pixels) return 7;
    fprintf(stderr, "%u %u\n", desc.width, desc.height);
    size_t bytes = (size_t)desc.width * desc.height * 4;
    if (fwrite(pixels, 1, bytes, stdout) != bytes) return 8;
    free(pixels);
    return 0;
  }
  return 9;
}
"""


def build(workdir: Path) -> Path:
    header = workdir / "qoi.h"
    if not header.exists():
        header.write_bytes(sources._fetch(QOI_H, "qoi.h"))
    source = workdir / "reference.c"
    source.write_text(REFERENCE, encoding="utf-8")
    binary = workdir / "qoi-reference"
    if not binary.exists():
        subprocess.run(
            ["gcc", "-O2", "-o", str(binary), str(source), "-I", str(workdir)],
            check=True,
        )
    return binary


def encode(binary: Path, image: Image.Image, channels: int) -> bytes:
    image = image.convert("RGBA" if channels == 4 else "RGB")
    raw = image.tobytes()
    result = subprocess.run(
        [str(binary), "enc", str(image.width), str(image.height), str(channels)],
        input=raw,
        capture_output=True,
        check=True,
    )
    return result.stdout


def decode(binary: Path, data: bytes) -> tuple[int, int, bytes]:
    result = subprocess.run(
        [str(binary), "dec"], input=data, capture_output=True, check=True
    )
    width, height = (int(part) for part in result.stderr.split())
    return width, height, result.stdout


def corpus() -> list[tuple[str, Image.Image, int]]:
    images = sources.png_suite()
    chosen = [
        "basn0g01",
        "basn2c08",
        "basn3p02",
        "basn3p08",
        "basn4a08",
        "basn6a08",
        "basi0g08",
        "basi2c08",
        "basi4a08",
        "basi6a16",
        "basn0g16",
        "basn6a16",
        "bgai4a08",
        "bgan6a16",
        "tbwn3p08",
        "tp1n3p08",
    ]
    cases = []
    for name in chosen:
        if name in images:
            cases.append((name, Image.open(io.BytesIO(images[name])).convert("RGBA"), 4))
    cases.append(("pattern", sources.pattern(64, 48), 4))
    cases.append(("pattern-opaque", sources.pattern(37, 23), 3))
    cases.append(("flat", sources.flat(90, 5), 4))
    cases.append(("one", sources.flat(1, 1, (3, 5, 7, 200)), 4))
    cases.append(("odd", sources.pattern(63, 7), 4))
    return cases


def main() -> None:
    with tempfile.TemporaryDirectory() as directory:
        binary = build(Path(directory))
        rows = []
        for name, image, channels in corpus():
            file = encode(binary, image, channels)
            width, height, pixels = decode(binary, file)
            if (width, height) != (image.width, image.height):
                raise SystemExit("%s: qoi.h read back the wrong size" % name)
            rows.append((name, file, moonbit.digest(pixels), image.width, image.height))

    body = ["let qoi_vectors : Array[(String, Bytes, String)] = ["]
    for name, file, expected, width, height in rows:
        body.append(
            "  (\n    %s,\n    %s,\n    %s,\n  ),"
            % (
                '"%s"' % name,
                moonbit.literal(file),
                '"%s"' % expected,
            )
        )
    body.append("]")

    header = """\
// Generated by scripts/fixtures/qoi.py. Do not edit.
//
// Files written by qoi.h, and a digest of the pixels qoi.h read back out of
// them. Decoding has to land on that digest and encoding has to land on those
// bytes, so a difference in either direction shows up as a failing case with a
// name rather than as a diff of a binary blob."""
    moonbit.write(TARGET, header, "\n".join(body))


if __name__ == "__main__":
    main()
