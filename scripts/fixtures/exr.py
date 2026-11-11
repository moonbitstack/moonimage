# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0

"""Generating the OpenEXR samples.

    python scripts/fixtures/exr.py

Every sample is written by the OpenEXR 3.5.3 library and read back by it, so the
digest beside each one is the format's own answer rather than anything computed
here. That matters most for the compressions that are not a byte code: PIZ is a
wavelet, a colour table and a Huffman table, and the only useful test of it is a
file somebody else wrote.

The digest is the one every other format's samples use: FNV-1a over the floats of
the picture, four bytes each, in the order red, green, blue, alpha.

Requires `pip install OpenEXR` (3.5.3), which is only needed to regenerate the
fixtures; the tests that replay them need nothing but this repository.
"""

import struct
import sys
import tempfile
import zlib
from pathlib import Path

import numpy as np
import OpenEXR

sys.path.insert(0, str(Path(__file__).resolve().parent))
import moonbit

ROOT = Path(__file__).resolve().parents[2]

COMPRESSIONS = {
    "none": OpenEXR.NO_COMPRESSION,
    "rle": OpenEXR.RLE_COMPRESSION,
    "zips": OpenEXR.ZIPS_COMPRESSION,
    "zip": OpenEXR.ZIP_COMPRESSION,
    "piz": OpenEXR.PIZ_COMPRESSION,
    "pxr24": OpenEXR.PXR24_COMPRESSION,
    "b44": OpenEXR.B44_COMPRESSION,
    "b44a": OpenEXR.B44A_COMPRESSION,
    "dwaa": OpenEXR.DWAA_COMPRESSION,
    "dwab": OpenEXR.DWAB_COMPRESSION,
}


def picture(width: int, height: int, alpha: bool, kind):
    """A picture with a gradient, a hard edge and a few flat areas, so that a
    wavelet has both something to smooth and something to keep."""
    names = ["R", "G", "B"] + (["A"] if alpha else [])
    planes = {}
    for index, name in enumerate(names):
        plane = np.zeros((height, width), dtype=kind)
        for y in range(height):
            for x in range(width):
                if index == 0:
                    value = 0.25 + x * 0.03125 + (0.5 if x > width // 2 else 0.0)
                elif index == 1:
                    value = 0.125 * y
                elif index == 2:
                    value = 0.5 + ((x * 7 + y * 3) % 5) * 0.0625
                else:
                    value = 1.0 if (x + y) % 4 else 0.25
                plane[y, x] = value
        planes[name] = plane
    return planes


def read_back(path: Path, alpha: bool) -> bytes:
    """The pixels as the format's own library reads them, in the layout this
    library's decoder produces: red, green, blue, alpha, floats."""
    part = OpenEXR.File(str(path)).parts[0]
    group = "RGBA" if alpha else "RGB"
    planes = part.channels[group].pixels
    height, width = part.height(), part.width()
    out = bytearray()
    for y in range(height):
        for x in range(width):
            for index in range(4 if alpha else 3):
                out += struct.pack("<f", float(planes[y, x, index]))
            if not alpha:
                out += struct.pack("<f", 1.0)
    return bytes(out)


def build(width: int, height: int, alpha: bool, kind, compression: str):
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "sample.exr"
        header = {
            "compression": COMPRESSIONS[compression],
            "type": OpenEXR.scanlineimage,
        }
        OpenEXR.File(header, picture(width, height, alpha, kind)).write(str(path))
        return path.read_bytes(), read_back(path, alpha)


def stacked(width: int, height: int, alpha: bool, kind):
    """The same picture as one array of four samples a pixel, which is the shape
    the library's part constructor takes."""
    planes = picture(width, height, alpha, kind)
    out = np.zeros((height, width, 4), dtype=kind)
    for index, name in enumerate(["R", "G", "B"]):
        out[..., index] = planes[name]
    out[..., 3] = planes["A"] if alpha else 1.0
    return out


def part_pixels(part) -> bytes:
    """One part's pixels, as the floats this library's decoder produces."""
    planes = part.channels["RGBA" if "RGBA" in part.channels else "RGB"].pixels
    height, width = part.height(), part.width()
    out = bytearray()
    for y in range(height):
        for x in range(width):
            for index in range(4):
                value = float(planes[y, x, index]) if index < planes.shape[2] else 1.0
                out += struct.pack("<f", value)
    return bytes(out)


def tiled_cases():
    """Files whose chunks are tiles rather than runs of scanlines, including
    tiles that do not divide the window and so are cropped at the edge."""
    out = []
    plans = [
        (41, 23, 16, 16, "zip"),
        (37, 23, 16, 16, "piz"),
        (19, 14, 17, 9, "none"),
        (33, 17, 16, 16, "b44"),
    ]
    for width, height, across, down, compression in plans:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tiled.exr"
            tile = OpenEXR.TileDescription()
            tile.xSize = across
            tile.ySize = down
            tile.mode = OpenEXR.ONE_LEVEL
            window = ((0, 0), (width - 1, height - 1))
            header = {
                "compression": COMPRESSIONS[compression],
                "type": OpenEXR.tiledimage,
                "tiles": tile,
                "dataWindow": window,
                "displayWindow": window,
            }
            OpenEXR.File(header, {"RGBA": stacked(width, height, True, np.float16)}).write(
                str(path)
            )
            name = "tiled-%dx%d-in-%dx%d-%s" % (width, height, across, down, compression)
            out.append((name, path.read_bytes(), moonbit.digest(part_pixels(OpenEXR.File(str(path)).parts[0]))))
    return out


def tiled_dwa_cases():
    """A tiled file in a compression that stores frequencies, kept apart for the
    reason the scanline ones are: two readers of the same coefficients differ by
    a step of a half, so the pixels travel with the file and are compared with a
    bound."""
    out = []
    width, height, across, down = 33, 17, 16, 16
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "tiled.exr"
        tile = OpenEXR.TileDescription()
        tile.xSize = across
        tile.ySize = down
        tile.mode = OpenEXR.ONE_LEVEL
        window = ((0, 0), (width - 1, height - 1))
        header = {
            "compression": OpenEXR.DWAA_COMPRESSION,
            "type": OpenEXR.tiledimage,
            "tiles": tile,
            "dataWindow": window,
            "displayWindow": window,
        }
        OpenEXR.File(header, {"RGBA": stacked(width, height, True, np.float16)}).write(
            str(path)
        )
        name = "tiled-%dx%d-in-%dx%d-dwaa" % (width, height, across, down)
        out.append((name, path.read_bytes(), zlib.compress(part_pixels(OpenEXR.File(str(path)).parts[0]), 9)))
    return out


def multipart_cases():
    """Files of more than one part: a colour pass and a depth pass of the same
    shot, with different channel lists, compressions and windows."""
    out = []
    window = ((0, 0), (40, 22))
    first = OpenEXR.Part(
        {
            "compression": OpenEXR.ZIP_COMPRESSION,
            "type": OpenEXR.scanlineimage,
            "dataWindow": window,
            "displayWindow": window,
        },
        {"RGBA": stacked(41, 23, True, np.float16)},
        "colour",
    )
    depth_window = ((0, 0), (20, 11))
    depth = np.zeros((12, 21, 3), dtype=np.float32)
    depth[..., 0] = np.arange(21)[None, :] / 8.0
    depth[..., 1] = np.arange(12)[:, None] / 8.0
    depth[..., 2] = 0.75
    second = OpenEXR.Part(
        {
            "compression": OpenEXR.PIZ_COMPRESSION,
            "type": OpenEXR.scanlineimage,
            "dataWindow": depth_window,
            "displayWindow": window,
        },
        {"RGB": depth},
        "depth",
    )
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "parts.exr"
        OpenEXR.File([first, second]).write(str(path))
        file = OpenEXR.File(str(path))
        digests = [moonbit.digest(part_pixels(part)) for part in file.parts]
        out.append(("two-parts", path.read_bytes(), digests))
    # Two tiled parts, whose chunks carry a part number in front of the tile
    # coordinates.
    tiled_window = ((0, 0), (24, 15))
    tile = OpenEXR.TileDescription()
    tile.xSize = 16
    tile.ySize = 16
    tile.mode = OpenEXR.ONE_LEVEL
    left = OpenEXR.Part(
        {
            "compression": OpenEXR.ZIP_COMPRESSION,
            "type": OpenEXR.tiledimage,
            "tiles": tile,
            "dataWindow": tiled_window,
            "displayWindow": tiled_window,
        },
        {"RGBA": stacked(25, 16, True, np.float16)},
        "left",
    )
    right = OpenEXR.Part(
        {
            "compression": OpenEXR.ZIP_COMPRESSION,
            "type": OpenEXR.tiledimage,
            "tiles": tile,
            "dataWindow": tiled_window,
            "displayWindow": tiled_window,
        },
        {"RGB": stacked(25, 16, False, np.float16)},
        "right",
    )
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "tiled-parts.exr"
        OpenEXR.File([left, right]).write(str(path))
        file = OpenEXR.File(str(path))
        digests = [moonbit.digest(part_pixels(part)) for part in file.parts]
        out.append(("two-tiled-parts", path.read_bytes(), digests))
    return out


def cases():
    out = []
    plans = [
        ("half", np.float16, 6, 5, False),
        ("half", np.float16, 41, 23, True),
        ("float", np.float32, 41, 23, True),
    ]
    for kind, dtype, width, height, alpha in plans:
        for compression in [
            "none",
            "rle",
            "zips",
            "zip",
            "piz",
            "pxr24",
            "b44",
            "b44a",
        ]:
            if kind == "float" and compression in ("rle", "zips"):
                continue
            name = "%s-%dx%d-%s" % (kind, width, height, compression)
            data, pixels = build(width, height, alpha, dtype, compression)
            out.append((name, data, moonbit.digest(pixels)))
    return out


def dwa_cases():
    """The two compressions that store a picture as frequencies, with the pixels
    the format's own library reads back.

    They are kept apart from the others because they are lossy in a way a digest
    cannot check: a reader that follows the format to the last bit still differs
    from another by a step of a half here and there, where the transform's
    single-precision constants land differently. The pixels travel with the file,
    deflated, so that the test can compare them with a bound.
    """
    out = []
    plans = [
        ("half", np.float16, 41, 23, True),
        ("float", np.float32, 41, 23, True),
    ]
    for kind, dtype, width, height, alpha in plans:
        for compression in ["dwaa", "dwab"]:
            name = "%s-%dx%d-%s" % (kind, width, height, compression)
            data, pixels = build(width, height, alpha, dtype, compression)
            out.append((name, data, zlib.compress(pixels, 9)))
    return out


def main() -> None:
    rows = []
    for name, data, digest in cases():
        rows.append("  (")
        rows.append('    "%s",' % name)
        rows.append("    %s," % moonbit.literal(data))
        rows.append('    "%s",' % digest)
        rows.append("  ),")
    body = "\n".join(
        ["///|", "let samples : Array[(String, Bytes, String)] = [", "\n".join(rows), "]"]
    )
    moonbit.write(
        str(ROOT / "src" / "exr" / "samples_test.mbt"),
        """// Generated by scripts/fixtures/exr.py. Do not edit.
//
// OpenEXR files written by the format's own library, in each compression this
// reader supports, with the digest of the pixels it read back from them.""",
        body,
    )

    rows = []
    for name, data, digest in tiled_cases():
        rows.append("  (")
        rows.append('    "%s",' % name)
        rows.append("    %s," % moonbit.literal(data))
        rows.append('    "%s",' % digest)
        rows.append("  ),")
    body = "\n".join(
        [
            "///|",
            "let tiled : Array[(String, Bytes, String)] = [",
            "\n".join(rows),
            "]",
        ]
    )
    moonbit.write(
        str(ROOT / "src" / "exr" / "parts_test.mbt"),
        """// Generated by scripts/fixtures/exr.py. Do not edit.
//
// Tiled files, in four compressions, and one file of two parts: written by the
// format's own library, with the digest of the pixels it read back from each
// part.""",
        body,
    )

    rows = []
    for name, data, pixels in tiled_dwa_cases():
        rows.append("  (")
        rows.append('    "%s",' % name)
        rows.append("    %s," % moonbit.literal(data))
        rows.append("    %s," % moonbit.literal(pixels))
        rows.append("  ),")
    body = "\n".join(
        [
            "///|",
            "let tiled_dwa : Array[(String, Bytes, Bytes)] = [",
            "\n".join(rows),
            "]",
        ]
    )
    moonbit.write(
        str(ROOT / "src" / "exr" / "parts_dwa_test.mbt"),
        """// Generated by scripts/fixtures/exr.py. Do not edit.
//
// A tiled file whose chunks are frequencies, with the pixels the format's own
// library reads back from it, deflated.""",
        body,
    )

    rows = []
    for name, data, digests in multipart_cases():
        rows.append("  (")
        rows.append('    "%s",' % name)
        rows.append("    %s," % moonbit.literal(data))
        rows.append("    [%s]," % ", ".join('"%s"' % d for d in digests))
        rows.append("  ),")
    body = "\n".join(
        [
            "///|",
            "let parts : Array[(String, Bytes, Array[String])] = [",
            "\n".join(rows),
            "]",
        ]
    )
    moonbit.write(
        str(ROOT / "src" / "exr" / "parts_data_test.mbt"),
        """// Generated by scripts/fixtures/exr.py. Do not edit.
//
// A file of two parts, with the digest of each part as the format's own library
// reads it.""",
        body,
    )

    rows = []
    for name, data, pixels in dwa_cases():
        rows.append("  (")
        rows.append('    "%s",' % name)
        rows.append("    %s," % moonbit.literal(data))
        rows.append("    %s," % moonbit.literal(pixels))
        rows.append("  ),")
    body = "\n".join(
        [
            "///|",
            "let dwa_samples : Array[(String, Bytes, Bytes)] = [",
            "\n".join(rows),
            "]",
        ]
    )
    moonbit.write(
        str(ROOT / "src" / "exr" / "dwa_test.mbt"),
        """// Generated by scripts/fixtures/exr.py. Do not edit.
//
// The two compressions that store a picture as frequencies, each written by the
// format's own library, with the pixels that library reads back from it,
// deflated.""",
        body,
    )


if __name__ == "__main__":
    main()
