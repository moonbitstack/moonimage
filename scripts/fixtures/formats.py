# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0

"""Generating the samples for the formats added after the first release.

    python scripts/fixtures/formats.py

Two kinds again. TIFF, ICO and the portable anymap are written by Pillow, and
what they should decode to is what Pillow reads back: an independent decoder
agreeing with ours is the point. Radiance HDR, OpenEXR, farbfeld and DDS are
built here, byte by byte, because Pillow does not write them; for those the
expected values are the ones the sample was built from, computed here from the
bytes rather than taken from our own decoder.

The scaling and blurring comparison is separate: Pillow resamples the same
picture with the same filter, and the page is expected to agree with it to
within one step of an eight-bit sample.

Run `moon fmt` afterwards: the byte literals this writes are wrapped for reading,
and the formatter rewraps them, which is what CI compares against.
"""

import io
import math
import os
import random
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
import moonbit

ROOT = Path(__file__).resolve().parents[2]


def picture(width: int, height: int, alpha: bool = True) -> Image.Image:
    """A picture whose every pixel is different, so a shift cannot pass."""
    mode = "RGBA" if alpha else "RGB"
    image = Image.new(mode, (width, height))
    for y in range(height):
        for x in range(width):
            red = (x * 37 + y * 11) % 256
            green = (x * 5 + y * 61) % 256
            blue = (x * 97 + y * 3) % 256
            if alpha:
                image.putpixel((x, y), (red, green, blue, (x * 29 + y * 43) % 256))
            else:
                image.putpixel((x, y), (red, green, blue))
    return image


def digest(image: Image.Image) -> str:
    return moonbit.digest(image.convert("RGBA").tobytes())


def emit(path: Path, header: str, body: str) -> None:
    moonbit.write(str(path), header, body)


def array_of_samples(samples) -> str:
    out = ["///|", "let samples : Array[(String, Bytes, String)] = ["]
    for name, data, expected in samples:
        out.append("  (")
        out.append('    "%s",' % name)
        out.append("    %s," % moonbit.literal(data))
        out.append('    "%s",' % expected)
        out.append("  ),")
    out.append("]")
    return "\n".join(out)


# ---------------------------------------------------------------- TIFF

def tiff_samples():
    out = []
    base = picture(9, 7)
    flat = picture(9, 7, alpha=False)
    grey = base.convert("L")
    palette = base.convert("P", palette=Image.ADAPTIVE, colors=16)
    for name, image, extra in [
        ("none-rgba", base, {}),
        ("lzw-rgba", base, {"compression": "tiff_lzw"}),
        ("deflate-rgb", flat, {"compression": "tiff_adobe_deflate"}),
        ("packbits-rgb", flat, {"compression": "packbits"}),
        ("lzw-grey", grey, {"compression": "tiff_lzw"}),
        ("none-palette", palette, {}),
    ]:
        handle = io.BytesIO()
        image.save(handle, format="TIFF", **extra)
        data = handle.getvalue()
        back = Image.open(io.BytesIO(data))
        out.append((name, data, digest(back)))
    for name, extra in [
        ("lzw-predictor", {"compression": "tiff_lzw"}),
        ("deflate-predictor", {"compression": "tiff_adobe_deflate"}),
    ]:
        handle = io.BytesIO()
        flat.save(handle, format="TIFF", tiffinfo={317: 2}, **extra)
        data = handle.getvalue()
        out.append((name, data, digest(Image.open(io.BytesIO(data)))))
    # A picture big enough that the LZW table grows past nine bits, which is the
    # only way the early widening is exercised at all.
    large = picture(72, 72, alpha=False)
    handle = io.BytesIO()
    large.save(handle, format="TIFF", compression="tiff_lzw")
    data = handle.getvalue()
    out.append(("lzw-large", data, digest(Image.open(io.BytesIO(data)))))
    wide = Image.new("I;16", (7, 5))
    for y in range(5):
        for x in range(7):
            wide.putpixel((x, y), (x * 9000 + y * 1300) % 65536)
    handle = io.BytesIO()
    wide.save(handle, format="TIFF", compression="tiff_lzw")
    data = handle.getvalue()
    back = Image.open(io.BytesIO(data)).convert("I")
    # Sixteen-bit grey becomes eight-bit by the same rounding this library uses:
    # the sample over sixty-five thousand five hundred and thirty-five, times
    # two hundred and fifty-five, rounded.
    samples = []
    for value in back.getdata():
        byte = min(255, int(value * 255 / 65535 + 0.5))
        samples.append(bytes([byte, byte, byte, 255]))
    out.append(("lzw-16bit", data, moonbit.digest(b"".join(samples))))
    return out


def tiff_pages():
    first = picture(6, 4)
    second = picture(6, 4).rotate(180)
    third = picture(6, 4).transpose(Image.FLIP_LEFT_RIGHT)
    handle = io.BytesIO()
    first.save(
        handle,
        format="TIFF",
        save_all=True,
        append_images=[second, third],
        compression="tiff_lzw",
    )
    data = handle.getvalue()
    pages = []
    with Image.open(io.BytesIO(data)) as opened:
        for index in range(opened.n_frames):
            opened.seek(index)
            pages.append(digest(opened))
    return data, pages


# ---------------------------------------------------------------- ICO

def ico_samples():
    out = []
    for name, size in [("icon-16", 16), ("icon-32", 32)]:
        image = picture(size, size)
        handle = io.BytesIO()
        image.save(handle, format="ICO", sizes=[(size, size)])
        data = handle.getvalue()
        back = Image.open(io.BytesIO(data))
        out.append((name, data, digest(back)))
    return out


# ---------------------------------------------------------------- PNM

def pam_bytes(image: Image.Image, depth: int, tuple_type: bytes, top: int) -> bytes:
    """A PAM header over samples that are already in the order PAM wants."""
    width, height = image.size
    header = b"P7\n"
    header += b"WIDTH %d\nHEIGHT %d\nDEPTH %d\nMAXVAL %d\n" % (
        width,
        height,
        depth,
        top,
    )
    header += b"TUPLTYPE %s\nENDHDR\n" % tuple_type
    if depth == 4:
        body = image.convert("RGBA").tobytes()
    elif depth == 3:
        body = image.convert("RGB").tobytes()
    elif depth == 2:
        body = bytes(
            byte
            for y in range(height)
            for x in range(width)
            for byte in (
                image.convert("LA").getpixel((x, y))[0],
                image.convert("LA").getpixel((x, y))[1],
            )
        )
    else:
        body = image.convert("L").tobytes()
    return header + body


def pnm_samples():
    out = []
    base = picture(9, 7, alpha=False)
    for name, image, scale in [
        ("p4-bitmap", base.convert("1"), 1),
        ("p5-grey", base.convert("L"), 1),
        ("p6-rgb", base, 1),
    ]:
        handle = io.BytesIO()
        image.save(handle, format="PPM")
        data = handle.getvalue()
        back = Image.open(io.BytesIO(data))
        out.append((name, data, digest(back)))
    handle = io.BytesIO()
    base.save(handle, format="PPM")
    out.append(("p3-ascii", to_ascii(handle.getvalue(), b"P6", b"P3"), digest(base)))
    handle = io.BytesIO()
    base.convert("L").save(handle, format="PPM")
    out.append(
        (
            "p2-ascii",
            to_ascii(handle.getvalue(), b"P5", b"P2"),
            digest(base.convert("L")),
        )
    )
    out.append(
        (
            "p5-maxval15",
            b"P5\n4 2\n15\n" + bytes([0, 5, 10, 15, 3, 8, 12, 1]),
            digest(Image.open(io.BytesIO(b"P5\n4 2\n15\n" + bytes([0, 5, 10, 15, 3, 8, 12, 1])))),
        )
    )
    out.append(
        (
            "p7-rgba",
            pam_bytes(picture(9, 7), 4, b"RGB_ALPHA", 255),
            digest(picture(9, 7)),
        )
    )
    out.append(
        (
            "p7-gray-alpha",
            pam_bytes(picture(9, 7).convert("LA"), 2, b"GRAYSCALE_ALPHA", 255),
            digest(picture(9, 7).convert("LA")),
        )
    )
    return out


def to_ascii(data: bytes, raw_magic: bytes, ascii_magic: bytes) -> bytes:
    """The same picture with the samples as digits rather than bytes."""
    if not data.startswith(raw_magic):
        return data
    at = len(raw_magic)
    fields = []
    while len(fields) < 3:
        while data[at : at + 1].isspace():
            at += 1
        if data[at : at + 1] == b"#":
            while data[at : at + 1] != b"\n":
                at += 1
            continue
        start = at
        while not data[at : at + 1].isspace():
            at += 1
        fields.append(data[start:at])
    at += 1
    width, height, top = (int(field) for field in fields)
    channels = 3 if raw_magic == b"P6" else 1
    body = data[at : at + width * height * channels]
    numbers = " ".join(str(byte) for byte in body)
    return ascii_magic + b"\n" + b" ".join(fields) + b"\n" + numbers.encode() + b"\n"


# ---------------------------------------------------------------- farbfeld

def farbfeld_samples():
    image = picture(5, 4)
    rows = []
    for y in range(4):
        for x in range(5):
            red, green, blue, alpha = image.getpixel((x, y))
            rows.append(struct.pack(">HHHH", red * 257, green * 257, blue * 257, alpha * 257))
    data = b"farbfeld" + struct.pack(">II", 5, 4) + b"".join(rows)
    return [("plain", data, digest(image))]


# ---------------------------------------------------------------- HDR

def rgbe(red: float, green: float, blue: float):
    brightest = max(red, green, blue)
    if brightest < 1e-32:
        return (0, 0, 0, 0)
    mantissa, exponent = math.frexp(brightest)
    scale = mantissa * 256.0 / brightest
    return (
        max(0, min(255, int(red * scale))),
        max(0, min(255, int(green * scale))),
        max(0, min(255, int(blue * scale))),
        exponent + 128,
    )


def rgbe_to_float(red, green, blue, exponent):
    if exponent == 0:
        return (0.0, 0.0, 0.0)
    scale = 2.0 ** (exponent - 136)
    return tuple((value + 0.5) * scale for value in (red, green, blue))


def float_digest(pixels) -> str:
    """FNV-1a over the four floats of every pixel, little endian, as stored."""
    data = b"".join(struct.pack("<4f", *pixel) for pixel in pixels)
    return moonbit.digest(data)


def hdr_samples():
    width, height = 8, 5
    pixels = []
    body = bytearray()
    for y in range(height):
        line = bytearray([2, 2, (width >> 8) & 0xFF, width & 0xFF])
        planes = [bytearray() for _ in range(4)]
        for x in range(width):
            red = (x + 1) * 0.25 * (1 + y)
            green = (y + 1) * 0.5
            blue = 1.0 + x * 0.125
            packed = rgbe(red, green, blue)
            for channel in range(4):
                planes[channel].append(packed[channel])
            pixels.append(rgbe_to_float(*packed) + (1.0,))
        for channel in range(4):
            values = planes[channel]
            at = 0
            while at < width:
                run = 1
                while at + run < width and run < 127 and values[at + run] == values[at]:
                    run += 1
                if run >= 3:
                    line += bytes([128 + run, values[at]])
                    at += run
                else:
                    start = at
                    fresh = 0
                    while at < width and fresh < 128:
                        if (
                            at + 2 < width
                            and values[at + 1] == values[at]
                            and values[at + 2] == values[at]
                        ):
                            break
                        at += 1
                        fresh += 1
                    line += bytes([fresh]) + bytes(values[start:at])
        body += line
    header = b"#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y %d +X %d\n" % (height, width)
    return [("coded", header + bytes(body), float_digest(pixels))]


# ---------------------------------------------------------------- OpenEXR

def half(value: float) -> int:
    bits = struct.unpack("<I", struct.pack("<f", value))[0]
    sign = (bits >> 16) & 0x8000
    exponent = (bits >> 23) & 0xFF
    mantissa = bits & 0x7FFFFF
    if exponent == 0xFF:
        return sign | 0x7C00 | (0x200 if mantissa else 0)
    shifted = exponent - 127 + 15
    if shifted >= 0x1F:
        return sign | 0x7C00
    if shifted <= 0:
        if shifted < -10:
            return sign
        mant = (mantissa | 0x800000) >> (14 - shifted)
        return sign | ((mant + 1) >> 1)
    mant = (mantissa + 0x1000) >> 13
    if mant >= 0x400:
        return sign | ((shifted + 1) << 10)
    return sign | (shifted << 10) | mant


def half_to_float(bits: int) -> float:
    sign = -1.0 if bits & 0x8000 else 1.0
    exponent = (bits >> 10) & 0x1F
    mantissa = bits & 0x3FF
    if exponent == 0:
        return sign * mantissa * 2.0 ** -24
    if exponent == 31:
        return sign * float("inf")
    return sign * (1 + mantissa / 1024.0) * 2.0 ** (exponent - 15)


def attribute(name: bytes, kind: bytes, body: bytes) -> bytes:
    return name + b"\x00" + kind + b"\x00" + struct.pack("<i", len(body)) + body


def exr_file(width, height, channels, compression, lines_per_chunk, payload):
    head = b""
    chlist = b""
    for name, kind in channels:
        chlist += name + b"\x00" + struct.pack("<i", kind) + b"\x00\x00\x00\x00"
        chlist += struct.pack("<ii", 1, 1)
    chlist += b"\x00"
    head += attribute(b"channels", b"chlist", chlist)
    head += attribute(b"compression", b"compression", bytes([compression]))
    box = struct.pack("<4i", 0, 0, width - 1, height - 1)
    head += attribute(b"dataWindow", b"box2i", box)
    head += attribute(b"displayWindow", b"box2i", box)
    head += attribute(b"lineOrder", b"lineOrder", b"\x00")
    head += attribute(b"pixelAspectRatio", b"float", struct.pack("<f", 1.0))
    head += attribute(b"screenWindowCenter", b"v2f", struct.pack("<2f", 0.0, 0.0))
    head += attribute(b"screenWindowWidth", b"float", struct.pack("<f", 1.0))
    head += b"\x00"
    chunks = payload
    table_at = 8 + len(head)
    body = b""
    offsets = []
    for first, data in chunks:
        offsets.append(table_at + len(chunks) * 8 + len(body))
        body += struct.pack("<ii", first, len(data)) + data
    table = b"".join(struct.pack("<Q", offset) for offset in offsets)
    return b"\x76\x2f\x31\x01" + struct.pack("<i", 2) + head + table + body


def exr_predict(raw: bytes) -> bytes:
    half = (len(raw) + 1) // 2
    differenced = bytearray(len(raw))
    differenced[0] = raw[0]
    for i in range(1, len(raw)):
        differenced[i] = (raw[i] - raw[i - 1] + 128) & 0xFF
    split = bytearray(len(raw))
    for i, value in enumerate(differenced):
        if i % 2 == 0:
            split[i // 2] = value
        else:
            split[half + i // 2] = value
    return bytes(split)


def exr_samples():
    width, height = 6, 5
    values = []
    for y in range(height):
        for x in range(width):
            values.append(
                (
                    0.25 + x * 0.125,
                    0.5 + y * 0.0625,
                    0.75 + (x + y) * 0.03125,
                    1.0 if (x + y) % 3 else 0.5,
                )
            )
    out = []
    for name, kind, compression, per_chunk in [
        ("none", 1, 0, 16),
        ("rle", 1, 1, 1),
        ("zip", 1, 3, 16),
        ("zips", 1, 2, 1),
        ("float-zip", 2, 3, 16),
    ]:
        channels = [(b"A", kind), (b"B", kind), (b"G", kind), (b"R", kind)]
        chunks = []
        for first in range(0, height, per_chunk):
            lines = min(per_chunk, height - first)
            raw = bytearray()
            for line in range(lines):
                for index in range(len(channels)):
                    for x in range(width):
                        sample = values[(first + line) * width + x][3 - index]
                        if kind == 1:
                            raw += struct.pack(">H", half(sample))
                        else:
                            raw += struct.pack(">f", sample)
            if compression == 0:
                data = bytes(raw)
            else:
                predicted = exr_predict(bytes(raw))
                if compression == 1:
                    data = rle(predicted)
                else:
                    data = zlib.compress(predicted, 6)
            chunks.append((first, data))
        data = exr_file(width, height, channels, compression, per_chunk, chunks)
        out.append((name, data, float_digest(values)))
    return out


def rle(data: bytes) -> bytes:
    out = bytearray()
    at = 0
    while at < len(data):
        run = 1
        while at + run < len(data) and run < 127 and data[at + run] == data[at]:
            run += 1
        if run >= 3:
            out += bytes([256 - run, data[at]])
            at += run
        else:
            start = at
            fresh = 0
            while at < len(data) and fresh < 127:
                if at + 2 < len(data) and data[at + 1] == data[at] and data[at + 2] == data[at]:
                    break
                at += 1
                fresh += 1
            out += bytes([fresh - 1]) + data[start:at]
    return bytes(out)


# ---------------------------------------------------------------- DDS

def dds_header(width, height, fourcc):
    header = bytearray(b"DDS ")
    header += struct.pack("<i", 124)
    header += struct.pack("<i", 0x1007)
    header += struct.pack("<ii", height, width)
    header += struct.pack("<i", 0)
    header += struct.pack("<i", 0)
    header += struct.pack("<i", 0)
    header += b"\x00" * 44
    header += struct.pack("<i", 32)
    header += struct.pack("<i", 4)
    header += fourcc
    header += struct.pack("<5i", 0, 0, 0, 0, 0)
    header += struct.pack("<5i", 0x1000, 0, 0, 0, 0)
    assert len(header) == 128, len(header)
    return bytes(header)


def dds_header10(width: int, height: int, dxgi: int, mips: int = 1) -> bytes:
    """The header of a texture whose format is named by a DXGI number."""
    header = bytearray(b"DDS ")
    header += struct.pack("<i", 124)
    header += struct.pack("<i", 0x1007)
    header += struct.pack("<ii", height, width)
    header += struct.pack("<iii", 0, 0, mips)
    header += b"\x00" * 44
    header += struct.pack("<ii", 32, 4) + b"DX10"
    header += struct.pack("<5i", 0, 0, 0, 0, 0)
    header += struct.pack("<5i", 0x1000, 0, 0, 0, 0)
    assert len(header) == 128, len(header)
    return bytes(header) + struct.pack("<5i", dxgi, 3, 0, 1, 0)


DXGI = {"bc1": 71, "bc2": 74, "bc3": 77, "bc4": 80, "bc5": 83}


def ffmpeg_pixels(data: bytes, width: int, height: int):
    """The texture decoded by ffmpeg, as four bytes a pixel.

    ffmpeg's decoder is the only other one on this machine that knows a block
    format, so the expectations for BC1 to BC5 are its output rather than an
    opinion of ours. It is asked for a PNG of one frame and the PNG is read back
    with Pillow, which is a third implementation agreeing with the second.
    """
    work = Path(tempfile.mkdtemp(prefix="dds-"))
    try:
        (work / "in.dds").write_bytes(data)
        run = subprocess.run(
            [
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-f", "dds_pipe", "-i", str(work / "in.dds"),
                "-update", "1", "-frames:v", "1", str(work / "out.png"),
            ],
            capture_output=True,
        )
        if run.returncode != 0 or not (work / "out.png").exists():
            raise RuntimeError("ffmpeg could not decode the sample: " + run.stderr.decode("utf-8", "replace"))
        image = Image.open(work / "out.png").convert("RGBA")
        assert image.size == (width, height), image.size
        return image.tobytes(), image
    finally:
        shutil.rmtree(work, ignore_errors=True)


def colour_block(first: int, second: int, picks: list[int]) -> bytes:
    """One BC1 block: two endpoints and two bits a pixel."""
    indices = 0
    for index, pick in enumerate(picks):
        indices |= (pick & 3) << (index * 2)
    return struct.pack("<HHI", first, second, indices)


def alpha_block(first: int, second: int, picks: list[int]) -> bytes:
    """One block of eight steps: two endpoints and three bits a pixel."""
    indices = 0
    for index, pick in enumerate(picks):
        indices |= (pick & 7) << (index * 3)
    return bytes([first, second]) + indices.to_bytes(6, "little")


def channel_block(first: int, second: int, picks: list[int]) -> bytes:
    return alpha_block(first, second, picks)


def channel_steps(first: int, second: int) -> list[int]:
    """The eight values a block of one channel can name, in order."""
    if first > second:
        steps = [first, second]
        steps += [((6 - i) * first + (1 + i) * second) // 7 for i in range(6)]
        return steps
    steps = [first, second]
    steps += [((4 - i) * first + (1 + i) * second) // 5 for i in range(4)]
    return steps + [0, 255]


def dds_samples():
    out = []

    # BC1 in its four-colour form: the third and fourth entries are two thirds
    # and one third of the way from the first endpoint to the second.
    picks = [0, 1, 2, 3] * 4
    block = colour_block(0xF800, 0x07E0, picks)
    data = dds_header10(4, 4, DXGI["bc1"]) + block
    pixels, _ = ffmpeg_pixels(data, 4, 4)
    out.append(("bc1-four", data, moonbit.digest(pixels)))

    # BC1 in its three-colour form, which is what a cut-out sprite uses: the
    # fourth entry is transparent black.
    block = colour_block(0x07E0, 0xF800, picks)
    data = dds_header10(4, 4, DXGI["bc1"]) + block
    pixels, _ = ffmpeg_pixels(data, 4, 4)
    out.append(("bc1-punch", data, moonbit.digest(pixels)))

    # The same bytes read as a texture whose alpha is not wanted.
    block = colour_block(0x07E0, 0xF800, picks)
    data = dds_header(4, 4, b"DXT1") + block
    pixels, _ = ffmpeg_pixels(data, 4, 4)
    out.append(("bc1-dxt1", data, moonbit.digest(pixels)))

    # BC2: four bits of alpha a pixel, then a four-colour block.
    alpha = bytes([0x0F, 0x37, 0x5B, 0x7F, 0x9D, 0xBE, 0xDC, 0xF8])
    block = colour_block(0x001F, 0xF800, picks)
    data = dds_header10(4, 4, DXGI["bc2"]) + alpha + block
    pixels, _ = ffmpeg_pixels(data, 4, 4)
    out.append(("bc2", data, moonbit.digest(pixels)))

    # BC3 with the eight-step alpha: the endpoints are ordered.
    alpha = alpha_block(240, 16, [0, 1, 2, 3, 4, 5, 6, 7] * 2)
    block = colour_block(0x001F, 0xF800, picks)
    data = dds_header10(4, 4, DXGI["bc3"]) + alpha + block
    pixels, _ = ffmpeg_pixels(data, 4, 4)
    out.append(("bc3-eight", data, moonbit.digest(pixels)))

    # BC3 with the six-step one: the endpoints are the other way round, and the
    # last two entries are nought and two hundred and fifty-five.
    alpha = alpha_block(16, 240, [0, 1, 2, 3, 4, 5, 6, 7] * 2)
    block = colour_block(0x001F, 0xF800, picks)
    data = dds_header10(4, 4, DXGI["bc3"]) + alpha + block
    pixels, _ = ffmpeg_pixels(data, 4, 4)
    out.append(("bc3-six", data, moonbit.digest(pixels)))

    # BC4: one channel, which is a grey picture.
    block = channel_block(200, 60, [0, 1, 2, 3, 4, 5, 6, 7] * 2)
    data = dds_header10(4, 4, DXGI["bc4"]) + block
    pixels, image = ffmpeg_pixels(data, 4, 4)
    out.append(("bc4", data, moonbit.digest(pixels)))
    assert len({pixel[:3] for pixel in image.getdata()}) == 8, "eight steps of grey"

    # BC5: two channels. ffmpeg paints blue as a display convention, so the
    # expectation is worked out here — red and green from the two blocks, blue
    # at nought — and checked against ffmpeg on the two channels it agrees on.
    red = channel_block(255, 0, [0, 1, 2, 3, 4, 5, 6, 7] * 2)
    green = channel_block(0, 255, [7, 6, 5, 4, 3, 2, 1, 0] * 2)
    data = dds_header10(4, 4, DXGI["bc5"]) + red + green
    _, image = ffmpeg_pixels(data, 4, 4)
    red_steps = channel_steps(255, 0)
    green_steps = channel_steps(0, 255)
    expected = []
    for index in range(16):
        want = (red_steps[index % 8], green_steps[7 - index % 8], 0, 255)
        got = image.getdata()[index]
        assert got[:2] == want[:2], (index, got, want)
        expected.append(bytes(want))
    out.append(("bc5", data, moonbit.digest(b"".join(expected))))

    # A texture that carries a mipmap chain: only the first surface is the
    # picture, and the smaller ones must not be read as if they were.
    block = colour_block(0xF800, 0x07E0, picks)
    small = colour_block(0x001F, 0xFFE0, [0] * 16)
    data = dds_header10(8, 8, DXGI["bc1"], mips=2) + block * 4 + small * 1
    pixels, _ = ffmpeg_pixels(data, 8, 8)
    out.append(("bc1-mipmapped", data, moonbit.digest(pixels)))
    return out


# ---------------------------------------------------------------- block formats

# A reference decoder for the two block formats Pillow and ffmpeg do not know.
# `bcdec.h` is a single header by Sergii Kudlai, MIT licensed, and it is not
# committed here: point `BCDEC` at a copy of it, or drop it beside this file.
REFERENCE_SOURCE = """
#define BCDEC_IMPLEMENTATION
#include "bcdec.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char** argv)
{
    if (argc != 4) { return 2; }
    FILE* in = fopen(argv[2], "rb");
    FILE* out = fopen(argv[3], "wb");
    unsigned char block[16];
    unsigned char rgba[16 * 4];
    unsigned short half[48];
    while (fread(block, 1, 16, in) == 16) {
        if (strcmp(argv[1], "bc7") == 0) {
            bcdec_bc7(block, rgba, 16);
            fwrite(rgba, 1, sizeof(rgba), out);
        } else {
            int is_signed = strcmp(argv[1], "bc6h") == 0;
            /* The pitch is in halves, not bytes: four pixels of three. */
            bcdec_bc6h_half(block, half, 12, is_signed);
            fwrite(half, 2, 16 * 3, out);
        }
    }
    fclose(in);
    fclose(out);
    return 0;
}
"""


def reference_blocks(kind: str, blocks: bytes) -> bytes:
    """Decode blocks with bcdec, which is the only other decoder of them here.

    Returns the decoded bytes, one after another: sixty-four a block for BC7,
    ninety-six for BC6H. The header is compiled rather than linked because it is
    a single file and a compiler is easier to require than a build system.
    """
    header = Path(os.environ.get("BCDEC", str(Path(__file__).resolve().parent / "bcdec.h")))
    if not header.exists():
        raise SystemExit(
            "the BC7 and BC6H samples need bcdec.h; set BCDEC to its path, or "
            "leave the generated file alone"
        )
    work = Path(tempfile.mkdtemp(prefix="bcdec-"))
    try:
        (work / "ref.c").write_text(REFERENCE_SOURCE, encoding="utf-8")
        shutil.copy(header, work / "bcdec.h")
        (work / "blocks.bin").write_bytes(blocks)
        build = subprocess.run(
            ["gcc", "-O2", "-o", str(work / "ref"), str(work / "ref.c")],
            capture_output=True,
        )
        if build.returncode != 0:
            raise SystemExit("gcc could not build the reference decoder: " + build.stderr.decode())
        run = subprocess.run(
            [str(work / "ref"), kind, str(work / "blocks.bin"), str(work / "out.bin")],
            capture_output=True,
        )
        if run.returncode != 0:
            raise SystemExit("the reference decoder failed: " + run.stderr.decode())
        return (work / "out.bin").read_bytes()
    finally:
        shutil.rmtree(work, ignore_errors=True)


def block_cases():
    """Blocks whose decoded form is known, and the digests of that form.

    A block format is decided entirely by its sixteen bytes, so a test of one is
    a test of a pile of them: three blocks per mode, which is what makes every
    branch of the mode switch run, and eight random ones per format, which is
    what catches a field read at the wrong offset.
    """
    rng = random.Random(20260101)

    def bytes_at(count):
        return bytes(rng.randrange(256) for _ in range(count))

    bc7 = []
    for mode in range(8):
        for _ in range(3):
            # A unary mode number: `mode` noughts and then a one, and the rest of
            # the block is whatever the mode makes of it.
            lead = 1 << mode
            mask = (1 << (mode + 1)) - 1
            head = lead | (bytes_at(1)[0] & ~mask & 0xFF)
            bc7.append(bytes([head]) + bytes_at(15))
    for _ in range(8):
        bc7.append(bytes_at(16))

    bc6h = []
    labelled = [0, 1, 2, 3, 7, 11, 15, 6, 10, 14, 18, 22, 26, 30]
    for label in labelled:
        for _ in range(2):
            low = label & 0x03
            rest = (label >> 2) & 0x07
            head = low | (rest << 2) if label > 1 else low
            bc6h.append(bytes([head]) + bytes_at(15))
    for _ in range(4):
        bc6h.append(bytes_at(16))

    return b"".join(bc7), b"".join(bc6h)


def block_digests(bc7_blocks: bytes, bc6h_blocks: bytes):
    bc7_out = reference_blocks("bc7", bc7_blocks)
    signed = reference_blocks("bc6h", bc6h_blocks)
    unsigned = reference_blocks("bc6hu", bc6h_blocks)
    seventh = 64
    ninth = 96
    bc7 = [moonbit.digest(bc7_out[i * seventh:(i + 1) * seventh]) for i in range(len(bc7_out) // seventh)]
    one = [moonbit.digest(signed[i * ninth:(i + 1) * ninth]) for i in range(len(signed) // ninth)]
    two = [moonbit.digest(unsigned[i * ninth:(i + 1) * ninth]) for i in range(len(unsigned) // ninth)]
    return bc7, one, two


# ---------------------------------------------------------------- scaling

def scale_cases():
    source = picture(13, 9, alpha=False)
    cases = []
    for name, pil_filter, code in [
        ("nearest", Image.Resampling.NEAREST, 0),
        ("bilinear", Image.Resampling.BILINEAR, 1),
        ("catmull-rom", Image.Resampling.BICUBIC, 2),
        ("lanczos", Image.Resampling.LANCZOS, 4),
    ]:
        for width, height in [(7, 5), (26, 18), (13, 4)]:
            if name == "bilinear" and (width < 13 or height < 9):
                # Bilinear does not widen its footprint when shrinking, and
                # Pillow does; the downscale comparison is the other filters'.
                continue
            scaled = source.resize((width, height), pil_filter)
            cases.append(
                (
                    "%s-%dx%d" % (name, width, height),
                    width,
                    height,
                    code,
                    source.convert("RGBA").tobytes(),
                    scaled.convert("RGBA").tobytes(),
                )
            )
    return cases


def blur_cases():
    """Pillow's blur and the kernel itself, side by side.

    Pillow approximates a Gaussian with three box blurs, which is fast and close
    enough to look at; this library convolves with the kernel. So the case
    carries both: the analytic result, computed here from the definition, is what
    the library is held to, and Pillow's is what a reader can compare against
    when asking why the two pictures are not identical.
    """
    source = picture(13, 9, alpha=False)
    pixels = np.array(source).astype(float)
    cases = []
    for radius in (0.8, 1.5, 3.0):
        blurred = source.filter(ImageFilter.GaussianBlur(radius))
        cases.append(
            (
                "gaussian-%.1f" % radius,
                radius,
                source.convert("RGBA").tobytes(),
                blurred.convert("RGBA").tobytes(),
                gaussian_of(pixels, radius),
            )
        )
    return cases


def gaussian_of(pixels, radius):
    """The definition, convolved along each axis with the kernel truncated at
    three sigma and renormalised, edges read from the edge."""
    reach = int(math.ceil(3.0 * radius))
    weights = [math.exp(-(i - reach) ** 2 / (2.0 * radius * radius)) for i in range(reach * 2 + 1)]
    total = sum(weights)
    weights = [weight / total for weight in weights]
    out = pixels
    for axis in (1, 0):
        shaped = np.zeros_like(out)
        length = out.shape[axis]
        for index in range(length):
            acc = np.zeros(out.shape[:axis] + out.shape[axis + 1 :])
            for offset, weight in enumerate(weights):
                taken = min(max(index + offset - reach, 0), length - 1)
                acc = acc + np.take(out, taken, axis=axis) * weight
            sl = [slice(None)] * out.ndim
            sl[axis] = index
            shaped[tuple(sl)] = acc
        out = shaped
    out = np.clip(np.round(out), 0, 255).astype(np.uint8)
    return b"".join(
        bytes([int(red), int(green), int(blue), 255])
        for red, green, blue in out.reshape(-1, 3)
    )


def main() -> None:
    emit(
        ROOT / "src" / "tiff" / "samples_test.mbt",
        """// Generated by scripts/fixtures/formats.py. Do not edit.
//
// TIFF files Pillow wrote, each with a digest of the pixels it reads back from
// the same bytes. The pixel data inside them was compressed by libtiff, which is
// the implementation every other one is measured against.""",
        array_of_samples(tiff_samples()),
    )
    data, pages = tiff_pages()
    body = [
        "///|",
        "let pages : Bytes = " + moonbit.literal(data),
        "",
        "///|",
        "let page_digests : Array[String] = [",
    ]
    for page in pages:
        body.append('  "%s",' % page)
    body.append("]")
    with open(ROOT / "src" / "tiff" / "samples_test.mbt", "a", encoding="utf-8", newline="\n") as handle:
        handle.write("\n" + "\n".join(body) + "\n")
    emit(
        ROOT / "src" / "ico" / "samples_test.mbt",
        """// Generated by scripts/fixtures/formats.py. Do not edit.
//
// Icons Pillow wrote as PNG-carrying entries, which is what everything writes
// now, with the pixels it reads back from them.""",
        array_of_samples(ico_samples()),
    )
    emit(
        ROOT / "src" / "pnm" / "samples_test.mbt",
        """// Generated by scripts/fixtures/formats.py. Do not edit.
//
// The four portable shapes, in both spellings, with the pixels Pillow reads
// back from the same bytes.""",
        array_of_samples(pnm_samples()),
    )
    emit(
        ROOT / "src" / "farbfeld" / "samples_test.mbt",
        """// Generated by scripts/fixtures/formats.py. Do not edit.
//
// A farbfeld built here, since nothing else writes one, with the digest of the
// samples it was built from.""",
        array_of_samples(farbfeld_samples()),
    )
    emit(
        ROOT / "src" / "hdr" / "samples_test.mbt",
        """// Generated by scripts/fixtures/formats.py. Do not edit.
//
// A Radiance file built here with the run-length code, and the digest of the
// floats each RGBE triplet stands for, computed from the formula rather than
// from this library.""",
        array_of_samples(hdr_samples()),
    )
    emit(
        ROOT / "src" / "exr" / "samples_test.mbt",
        """// Generated by scripts/fixtures/formats.py. Do not edit.
//
// OpenEXR files built here in each compression the reader supports, with the
// digest of the samples they were built from.""",
        array_of_samples(exr_samples()),
    )
    emit(
        ROOT / "src" / "dds" / "samples_test.mbt",
        """// Generated by scripts/fixtures/formats.py. Do not edit.
//
// DirectDraw surfaces built here, one block each, with the colours worked out by
// hand from the endpoints in the block.""",
        array_of_samples(dds_samples()),
    )

    bc7_blocks, bc6h_blocks = block_cases()
    bc7_digests, signed_digests, unsigned_digests = block_digests(bc7_blocks, bc6h_blocks)
    body = [
        "///|",
        "let bc7_blocks : Bytes = " + moonbit.literal(bc7_blocks),
        "",
        "///|",
        "let bc7_expected : Array[String] = [",
    ]
    for value in bc7_digests:
        body.append('  "%s",' % value)
    body.append("]")
    body += ["", "///|", "let bc6h_blocks : Bytes = " + moonbit.literal(bc6h_blocks), ""]
    body += ["///|", "let bc6h_signed_expected : Array[String] = ["]
    for value in signed_digests:
        body.append('  "%s",' % value)
    body.append("]")
    body += ["", "///|", "let bc6h_unsigned_expected : Array[String] = ["]
    for value in unsigned_digests:
        body.append('  "%s",' % value)
    body.append("]")
    emit(
        ROOT / "src" / "dds" / "block_samples_wbtest.mbt",
        """// Generated by scripts/fixtures/formats.py. Do not edit.
//
// Blocks of BC7 and BC6H with a digest of what a reference decoder made of each
// one. Both formats are decided entirely by their sixteen bytes, so a pile of
// blocks is the whole of their test: three a mode, so that every branch of the
// mode switch runs, and a few random ones besides.""",
        "\n".join(body),
    )

    cases = scale_cases()
    body = ["///|", "let cases : Array[(String, Int32, Int32, Int32, Bytes, Bytes)] = ["]
    for name, width, height, code, source, expected in cases:
        body.append("  (")
        body.append('    "%s",' % name)
        body.append("    %d," % width)
        body.append("    %d," % height)
        body.append("    %d," % code)
        body.append("    %s," % moonbit.literal(source))
        body.append("    %s," % moonbit.literal(expected))
        body.append("  ),")
    body.append("]")
    blur = blur_cases()
    body += [
        "",
        "///|",
        "let blur_cases : Array[(String, Double, Bytes, Bytes, Bytes)] = [",
    ]
    for name, radius, source, pillow, analytic in blur:
        body.append("  (")
        body.append('    "%s",' % name)
        body.append("    %.2f," % radius)
        body.append("    %s," % moonbit.literal(source))
        body.append("    %s," % moonbit.literal(pillow))
        body.append("    %s," % moonbit.literal(analytic))
        body.append("  ),")
    body.append("]")
    emit(
        ROOT / "src" / "raster" / "pillow_test.mbt",
        """// Generated by scripts/fixtures/formats.py. Do not edit.
//
// The same picture resampled and blurred by Pillow, so that the filters here can
// be measured against an implementation nobody in this repository wrote.""",
        "\n".join(body),
    )


if __name__ == "__main__":
    main()
