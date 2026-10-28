# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0

"""Generating the QOI fixtures.

    python scripts/fixtures/qoi.py

The reference is the format's own C implementation, qoi.h, compiled here and
driven through raw pixels. Every fixture is therefore a file qoi.h wrote from
pixels Pillow produced, and a digest of the pixels qoi.h read back from it. The
library has to agree on both: decode to the same pixels, and encode back to the
same bytes.

Two corpora. The published test images — the eight pictures the format ships as
its own set — go in whole, because they are the files a decoder has to agree
with. Beside them is a wider set made of PngSuite and synthetic images, which is
what covers the opcode set exhaustively: runs, cache hits, differences, lumas,
literals with and without alpha, and every size from one pixel up.
"""

import base64
import io
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import moonbit
import sources

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "src" / "qoi" / "vectors_test.mbt"
PUBLISHED_TARGET = ROOT / "src" / "qoi" / "published_test.mbt"
QOI_H = "https://raw.githubusercontent.com/phoboslab/qoi/master/qoi.h"
PUBLISHED = "https://qoiformat.org/qoi_test_images.zip"
# Characters of base64 per binding. Half a megabyte is comfortably inside the
# compiler's text segment limit and large enough that the join is trivial.
PART = 512 * 1024

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


def published() -> list[tuple[str, bytes]]:
    """The pictures the format publishes as its own test set.

    The reference repository holds the encoder and no images, and the API
    addresses that used to carry them answer 404, so the corpus arrives as the
    one archive the project still serves. Eight pictures, each as a PNG and the
    QOI made from it; the QOI is the artifact, because it is what a decoder has
    to agree with.
    """
    archive = sources._fetch(PUBLISHED, "qoi_test_images.zip")
    out = []
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        for entry in sorted(bundle.namelist()):
            if entry.endswith(".qoi"):
                out.append((Path(entry).stem, bundle.read(entry)))
    if not out:
        raise SystemExit("the published archive held no QOI files")
    return out


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


def wrapped(text: str, width: int = 96) -> str:
    r"""A long string as a chain of short literals, so a diff reads line by line.

    The text is already base64 — a photograph is three and a half megabytes,
    which as `b"\xNN"` escapes would be ten megabytes of source, so the corpus
    is stored encoded and decoded in the one test that reads it. This only
    decides where the line breaks go.
    """
    lines = [text[i : i + width] for i in range(0, len(text), width)] or [""]
    out = '"%s"' % lines[0]
    for line in lines[1:]:
        out += ' +\n      "%s"' % line
    return out


def format_generated() -> None:
    """Run the formatter, because the tree is checked for being formatted.

    A generated file is a source file like any other: if `moon fmt` would change
    a line of it, continuous integration fails on the difference. Formatting
    here means a rerun of this script produces something ready to commit.
    """
    subprocess.run(
        ["moon", "fmt"],
        cwd=ROOT,
        check=True,
        shell=(sys.platform == "win32"),
        capture_output=True,
    )


def write_published(binary: Path) -> None:
    rows = []
    for name, file in published():
        width, height, pixels = decode(binary, file)
        channels = file[12]
        # The published files are the reference encoder's own output, so feeding
        # its decoding back in has to give the same bytes. If it ever does not,
        # the file is not canonical, and promising "written back byte for byte"
        # about it would be a statement about somebody's encoder rather than
        # about the format.
        # `qoi_decode` is asked for four channels above, so the pixels arrive
        # that way whatever the file declares; `encode` narrows them for a file
        # that carries three.
        again = encode(binary, Image.frombytes("RGBA", (width, height), pixels), channels)
        # One of the eight is not canonical: `edgecase` is the same picture
        # written with different opcodes — the same length, a valid file, and
        # not what the encoder emits today. So "these bytes come back" is a
        # property of seven of them, and for the eighth the claim is that the
        # writing matches the reference encoder's, which is recorded beside it.
        rows.append(
            (
                name,
                file,
                width,
                height,
                moonbit.digest(pixels),
                b"" if again == file else again,
            )
        )

    # The compiler refuses a top-level item whose text segment runs past a
    # megabyte or so, and one picture here is two megabytes of base64. So each
    # picture is stored as a list of shorter strings, one binding each, and the
    # test joins them: a list of names costs nothing, a list of literals would be
    # the same megabyte problem again.
    body = []
    for name, file, width, height, expected, canonical in rows:
        text = base64.b64encode(file).decode("ascii")
        parts = [text[i : i + PART] for i in range(0, len(text), PART)]
        names = []
        for index, part in enumerate(parts):
            bind = "qoi_published_%s_%d" % (name, index)
            names.append(bind)
            body.append("///|")
            body.append("let %s : String = %s" % (bind, wrapped(part)))
            body.append("")
        body.append("///|")
        body.append("/// %s, in %d parts." % (name, len(parts)))
        body.append(
            "let qoi_published_%s : Array[String] = [%s]"
            % (name, ", ".join(names))
        )
        body.append("")

    body.append("///|")
    body.append(
        "let qoi_published : Array[(String, Array[String], Int, Int, String, String)] = ["
    )
    for name, file, width, height, expected, canonical in rows:
        body.append(
            '  (\n    "%s",\n    qoi_published_%s,\n    %d,\n    %d,\n    "%s",\n    %s,\n  ),'
            % (
                name,
                name,
                width,
                height,
                expected,
                '"%s"' % base64.b64encode(canonical).decode("ascii") if canonical else '""',
            )
        )
    body.append("]")

    header = r"""// Generated by scripts/fixtures/qoi.py. Do not edit.
//
// The pictures the format publishes as its own test set:
// https://qoiformat.org/qoi_test_images.zip
//
// They are embedded as they are distributed, with the digest of the pixels the
// reference decoder reads from each. Decoding has to land on that digest and
// writing has to give these bytes back, so a decoder that is close, or an
// encoder that chooses a different opcode, fails here by name.
//
// The last field is empty when the file as distributed is the reference
// encoder's own output, which is the case for seven of the eight. For the one
// where it is not — `edgecase`, the same picture written with different
// opcodes — it holds what the encoder emits for those pixels, so the test can
// state the property that actually holds.
//
// They are photographs, so they are base64 rather than byte literals: three and
// a half megabytes, which as `b"\\xNN"` escapes would be ten megabytes of
// source. The longest is stored as several bindings, because the compiler will
// not take a two-megabyte top-level string."""
    moonbit.write(PUBLISHED_TARGET, header, "\n".join(body))


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
        write_published(binary)

    format_generated()


if __name__ == "__main__":
    main()
