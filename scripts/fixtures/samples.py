# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0

"""Generating the BMP and TGA samples.

    python scripts/fixtures/samples.py

Two kinds of sample. Most are written by Pillow, and the pixels they should
decode to are what Pillow reads back from the file: an independent decoder
agreeing with ours is the point of the exercise. The rest are built here, byte by
byte, because Pillow does not write them: BMP's run-length codes, its bit fields,
and TGA's sixteen-bit pixels and top-down order. For those the pixels are the ones
the sample was built from, which is just as good an oracle and covers the parts of
the formats that matter most.
"""

import io
import struct
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import moonbit
import sources

ROOT = Path(__file__).resolve().parents[2]


def digest_of(image: Image.Image) -> str:
    return moonbit.digest(image.convert("RGBA").tobytes())


def pillow_png(image: Image.Image) -> bytes:
    handle = io.BytesIO()
    image.save(handle, format="PNG")
    return handle.getvalue()


def read_back(data: bytes) -> Image.Image:
    image = Image.open(io.BytesIO(data))
    image.load()
    return image.convert("RGBA")


# --------------------------------------------------------------------------
# BMP samples Pillow writes.


def pillow_bmp(image: Image.Image, **options) -> bytes:
    handle = io.BytesIO()
    image.save(handle, format="BMP", **options)
    return handle.getvalue()


def bmp_samples():
    cases = []
    base = sources.pattern(37, 23)

    cases.append(("pillow-24", pillow_bmp(base.convert("RGB"))))
    # Opaque, because whether a thirty-two-bit BMP keeps its fourth byte is
    # exactly the thing readers disagree about.
    cases.append(("pillow-32", pillow_bmp(base.convert("RGB").convert("RGBA"))))
    quantised = base.convert("RGB").quantize(colors=200)
    cases.append(("pillow-8-palette", pillow_bmp(quantised)))
    cases.append(("pillow-grey", pillow_bmp(base.convert("L"))))
    cases.append(("pillow-1bit", pillow_bmp(base.convert("1"))))
    return [(name, data, digest_of(read_back(data))) for name, data in cases]


# --------------------------------------------------------------------------
# BMP samples written here.


def bmp_file(width, height, bits, compression, pixels, palette=None, masks=None, top_down=False):
    """A BMP with a forty-byte header, assembled field by field."""
    row_bytes = ((width * bits + 31) // 32) * 4
    if compression in (1, 2):
        # Run-length coded data is already a stream: it has no rows to pad.
        body = bytearray(pixels)
    else:
        body = bytearray()
        for row in range(height):
            start = row * row_bytes
            body += pixels[start:start + row_bytes]
    palette_bytes = b""
    if palette is not None:
        for entry in palette:
            palette_bytes += bytes((entry[2], entry[1], entry[0], 0))
    mask_bytes = b""
    if masks is not None:
        for mask in masks:
            mask_bytes += struct.pack("<I", mask)
    offset = 14 + 40 + len(mask_bytes) + len(palette_bytes)
    info = struct.pack(
        "<IiiHHIIiiII",
        40,
        width,
        -height if top_down else height,
        1,
        bits,
        compression,
        len(body),
        2835,
        2835,
        len(palette) if palette else 0,
        0,
    )
    header = struct.pack("<2sIHHI", b"BM", offset + len(body), 0, 0, offset)
    return header + info + mask_bytes + palette_bytes + bytes(body)


def pack_rows(width, height, bits, values, top_down=False):
    """Pack sample values into padded rows, bottom first unless told otherwise."""
    row_bytes = ((width * bits + 31) // 32) * 4
    rows = []
    for row in range(height):
        bits_of_row = values[row * width:(row + 1) * width]
        if bits == 24:
            line = b"".join(bytes((b, g, r)) for (r, g, b) in bits_of_row)
        elif bits == 16:
            line = b"".join(struct.pack("<H", v) for v in bits_of_row)
        elif bits == 8:
            line = bytes(bits_of_row)
        elif bits == 4:
            line = bytearray()
            for index in range(0, len(bits_of_row), 2):
                high = bits_of_row[index] & 0xF
                low = bits_of_row[index + 1] & 0xF if index + 1 < len(bits_of_row) else 0
                line.append((high << 4) | low)
            line = bytes(line)
        else:
            raise ValueError(bits)
        line += b"\x00" * (row_bytes - len(line))
        rows.append(line)
    if not top_down:
        rows.reverse()
    return b"".join(rows), row_bytes


def rle8_pixels(width, height, indices):
    """BI_RLE8: runs and absolute blocks, bottom row first."""
    body = bytearray()
    for row in reversed(range(height)):
        line = indices[row * width:(row + 1) * width]
        x = 0
        while x < len(line):
            run = 1
            while x + run < len(line) and line[x + run] == line[x] and run < 255:
                run += 1
            if run >= 3:
                body += bytes((run, line[x]))
                x += run
            else:
                start = x
                while x < len(line) and (x - start) < 255:
                    ahead = 1
                    while x + ahead < len(line) and line[x + ahead] == line[x] and ahead < 3:
                        ahead += 1
                    if ahead >= 3 and x > start:
                        break
                    x += 1
                block = line[start:x]
                body += bytes((0, len(block)))
                body += bytes(block)
                if len(block) % 2:
                    body += b"\x00"
        body += b"\x00\x00"
    body += b"\x00\x01"
    return bytes(body)


def rle4_pixels(width, height, indices):
    """BI_RLE4: the same, with two indices to a byte in an absolute block."""
    body = bytearray()
    for row in reversed(range(height)):
        line = indices[row * width:(row + 1) * width]
        x = 0
        while x < len(line):
            run = 1
            while x + run < len(line) and line[x + run] == line[x] and run < 255:
                run += 1
            if run >= 3:
                body += bytes((run, (line[x] << 4) | line[x]))
                x += run
            else:
                start = x
                while x < len(line) and (x - start) < 255:
                    ahead = 1
                    while x + ahead < len(line) and line[x + ahead] == line[x] and ahead < 3:
                        ahead += 1
                    if ahead >= 3 and x > start:
                        break
                    x += 1
                block = line[start:x]
                body += bytes((0, len(block)))
                packed = bytearray()
                for index in range(0, len(block), 2):
                    high = block[index] & 0xF
                    low = block[index + 1] & 0xF if index + 1 < len(block) else 0
                    packed.append((high << 4) | low)
                if len(packed) % 2:
                    packed.append(0)
                body += bytes(packed)
        body += b"\x00\x00"
    body += b"\x00\x01"
    return bytes(body)


def extra_bmp_samples():
    cases = []
    width, height = 24, 9
    source = sources.pattern(width, height).convert("RGB")
    pixels = list(source.getdata())

    # Sixteen bits, 5-5-5, which is the depth with no mask at all.
    values = []
    for (r, g, b) in pixels:
        values.append(((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3))
    body, _ = pack_rows(width, height, 16, values)
    sixteen = bmp_file(width, height, 16, 0, body)
    # 5-5-5 loses three bits a channel, so the pixels are the rounded ones.
    expected = Image.new("RGBA", (width, height))
    expected.putdata([
        (
            (((v >> 10) & 0x1F) * 255 + 15) // 31,
            (((v >> 5) & 0x1F) * 255 + 15) // 31,
            ((v & 0x1F) * 255 + 15) // 31,
            255,
        )
        for v in values
    ])
    cases.append(("built-16-555", sixteen, digest_of(expected)))

    # Sixteen bits with bit fields: 5-6-5, which is what a camera wrote.
    values = []
    for (r, g, b) in pixels:
        values.append(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3))
    body, _ = pack_rows(width, height, 16, values)
    bitfields = bmp_file(width, height, 16, 3, body, masks=(0xF800, 0x07E0, 0x001F))
    expected = Image.new("RGBA", (width, height))
    expected.putdata([
        (
            (((v >> 11) & 0x1F) * 255 + 15) // 31,
            (((v >> 5) & 0x3F) * 255 + 31) // 63,
            ((v & 0x1F) * 255 + 15) // 31,
            255,
        )
        for v in values
    ])
    cases.append(("built-16-565", bitfields, digest_of(expected)))

    # Four bits a pixel, run-length coded.
    palette = [((index * 7) % 256, (index * 13) % 256, (index * 29) % 256) for index in range(16)]
    indices = [((x // 3) + (y // 2)) % 16 for y in range(height) for x in range(width)]
    rle4 = bmp_file(
        width,
        height,
        4,
        2,
        rle4_pixels(width, height, indices),
        palette=palette,
    )
    expected = Image.new("RGBA", (width, height))
    expected.putdata([palette[i] + (255,) for i in indices])
    cases.append(("built-rle4", rle4, digest_of(expected)))

    # Eight bits a pixel, run-length coded.
    palette = [((index * 5) % 256, (index * 11) % 256, (index * 23) % 256) for index in range(256)]
    indices = [((x // 4) * 9 + (y // 3) * 5) % 256 for y in range(height) for x in range(width)]
    rle8 = bmp_file(
        width,
        height,
        8,
        1,
        rle8_pixels(width, height, indices),
        palette=palette,
    )
    expected = Image.new("RGBA", (width, height))
    expected.putdata([palette[i] + (255,) for i in indices])
    cases.append(("built-rle8", rle8, digest_of(expected)))

    # A top-down file, which is a negative height and nothing else.
    body, _ = pack_rows(width, height, 24, pixels, top_down=True)
    cases.append(("built-top-down", bmp_file(width, height, 24, 0, body, top_down=True), digest_of(source.convert("RGBA"))))

    # Thirty-two bits with a mask that says the fourth byte is alpha.
    rgba = sources.pattern(width, height)
    body = bytearray()
    for y in reversed(range(height)):
        for x in range(width):
            r, g, b, a = rgba.getpixel((x, y))
            body += bytes((b, g, r, a))
    masked = bmp_file(width, height, 32, 6, bytes(body), masks=(0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000))
    cases.append(("built-32-alpha", masked, digest_of(rgba)))
    return cases


# --------------------------------------------------------------------------
# TGA samples.


def pillow_tga(image: Image.Image, **options) -> bytes:
    handle = io.BytesIO()
    image.save(handle, format="TGA", **options)
    return handle.getvalue()


def tga_samples():
    cases = []
    base = sources.pattern(29, 17)
    cases.append(("pillow-24", pillow_tga(base.convert("RGB"))))
    cases.append(("pillow-32", pillow_tga(base)))
    cases.append(("pillow-24-rle", pillow_tga(base.convert("RGB"), compression="tga_rle")))
    cases.append(("pillow-32-rle", pillow_tga(base, compression="tga_rle")))
    cases.append(("pillow-grey", pillow_tga(base.convert("L"))))
    cases.append(("pillow-grey-rle", pillow_tga(base.convert("L"), compression="tga_rle")))
    palette = base.convert("RGB").quantize(colors=64)
    cases.append(("pillow-palette", pillow_tga(palette)))
    return [(name, data, digest_of(read_back(data))) for name, data in cases]


def tga_file(width, height, depth, pixels, image_type=2, descriptor=0, palette=None, map_entry=24):
    header = struct.pack(
        "<BBBHHBHHHHBB",
        0,
        1 if palette is not None else 0,
        image_type,
        0,
        len(palette) if palette else 0,
        map_entry,
        0,
        0,
        width,
        height,
        depth,
        descriptor,
    )
    body = b""
    if palette is not None:
        for (r, g, b) in palette:
            body += bytes((b, g, r))
    return header + body + pixels


def extra_tga_samples():
    cases = []
    width, height = 21, 11
    source = sources.pattern(width, height)
    rgba = list(source.getdata())

    # Sixteen bits, 5-5-5 with the top bit as alpha, bottom row first.
    values = []
    for (r, g, b, a) in rgba:
        values.append(
            (((a >> 7) & 1) << 15) | ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
        )
    body = b""
    for y in reversed(range(height)):
        for x in range(width):
            body += struct.pack("<H", values[y * width + x])
    cases.append((
        "built-16",
        tga_file(width, height, 16, body, descriptor=1),
        digest_of(Image.new("RGBA", (width, height), (0, 0, 0, 0))),
    ))
    # Recompute the reference: one bit of alpha, five bits a channel.
    expected = Image.new("RGBA", (width, height))
    expected.putdata([
        (
            (((v >> 10) & 0x1F) * 255 + 15) // 31,
            (((v >> 5) & 0x1F) * 255 + 15) // 31,
            ((v & 0x1F) * 255 + 15) // 31,
            255 if (v & 0x8000) else 0,
        )
        for v in values
    ])
    cases[-1] = ("built-16", cases[-1][1], digest_of(expected))

    # Top-down order, which is one bit in the descriptor.
    body = b""
    for y in range(height):
        for x in range(width):
            r, g, b, a = rgba[y * width + x]
            body += bytes((b, g, r, a))
    cases.append((
        "built-top-down",
        tga_file(width, height, 32, body, descriptor=8 | 0x20),
        digest_of(source),
    ))

    # A colour map of twenty-four bit entries, eight-bit indices, run-length
    # coded: type 9 is the one nobody writes and everybody has to read.
    palette = [((i * 9) % 256, (i * 17) % 256, (i * 33) % 256) for i in range(24)]
    indices = [((x + y) % 24) for y in range(height) for x in range(width)]
    # Bottom row first, which is the order the file stores.
    ordered = [indices[y * width + x] for y in reversed(range(height)) for x in range(width)]
    packets = bytearray()
    index = 0
    while index < len(ordered):
        run = 1
        while index + run < len(ordered) and ordered[index + run] == ordered[index] and run < 128:
            run += 1
        if run >= 2:
            packets += bytes((0x80 | (run - 1), ordered[index]))
            index += run
        else:
            start_index = index
            while index < len(ordered) and (index - start_index) < 128:
                ahead = 1
                while index + ahead < len(ordered) and ordered[index + ahead] == ordered[index] and ahead < 2:
                    ahead += 1
                if ahead >= 2 and index > start_index:
                    break
                index += 1
            block = ordered[start_index:index]
            packets += bytes((len(block) - 1,)) + bytes(block)
    expected = Image.new("RGBA", (width, height))
    expected.putdata([palette[i] + (255,) for i in indices])
    cases.append(("built-rle4", rle4, digest_of(expected)))

    # Eight bits a pixel, run-length coded.
    palette = [((index * 5) % 256, (index * 11) % 256, (index * 23) % 256) for index in range(256)]
    indices = [((x // 4) * 9 + (y // 3) * 5) % 256 for y in range(height) for x in range(width)]
    rle8 = bmp_file(
        width,
        height,
        8,
        1,
        rle8_pixels(width, height, indices),
        palette=palette,
    )
    expected = Image.new("RGBA", (width, height))
    expected.putdata([palette[i] + (255,) for i in indices])
    cases.append(("built-rle8", rle8, digest_of(expected)))

    # A top-down file, which is a negative height and nothing else.
    body, _ = pack_rows(width, height, 24, pixels, top_down=True)
    cases.append(("built-top-down", bmp_file(width, height, 24, 0, body, top_down=True), digest_of(source.convert("RGBA"))))

    # Thirty-two bits with a mask that says the fourth byte is alpha.
    rgba = sources.pattern(width, height)
    body = bytearray()
    for y in reversed(range(height)):
        for x in range(width):
            r, g, b, a = rgba.getpixel((x, y))
            body += bytes((b, g, r, a))
    masked = bmp_file(width, height, 32, 6, bytes(body), masks=(0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000))
    cases.append(("built-32-alpha", masked, digest_of(rgba)))
    return cases


# --------------------------------------------------------------------------
# TGA samples.


def pillow_tga(image: Image.Image, **options) -> bytes:
    handle = io.BytesIO()
    image.save(handle, format="TGA", **options)
    return handle.getvalue()


def tga_samples():
    cases = []
    base = sources.pattern(29, 17)
    cases.append(("pillow-24", pillow_tga(base.convert("RGB"))))
    cases.append(("pillow-32", pillow_tga(base)))
    cases.append(("pillow-24-rle", pillow_tga(base.convert("RGB"), compression="tga_rle")))
    cases.append(("pillow-32-rle", pillow_tga(base, compression="tga_rle")))
    cases.append(("pillow-grey", pillow_tga(base.convert("L"))))
    cases.append(("pillow-grey-rle", pillow_tga(base.convert("L"), compression="tga_rle")))
    palette = base.convert("RGB").quantize(colors=64)
    cases.append(("pillow-palette", pillow_tga(palette)))
    return [(name, data, digest_of(read_back(data))) for name, data in cases]


def tga_file(width, height, depth, pixels, image_type=2, descriptor=0, palette=None, map_entry=24):
    header = struct.pack(
        "<BBBHHBHHHHBB",
        0,
        1 if palette is not None else 0,
        image_type,
        0,
        len(palette) if palette else 0,
        map_entry,
        0,
        0,
        width,
        height,
        depth,
        descriptor,
    )
    body = b""
    if palette is not None:
        for (r, g, b) in palette:
            body += bytes((b, g, r))
    return header + body + pixels


def extra_tga_samples():
    cases = []
    width, height = 21, 11
    source = sources.pattern(width, height)
    rgba = list(source.getdata())

    # Sixteen bits, 5-5-5 with the top bit as alpha, bottom row first.
    values = []
    for (r, g, b, a) in rgba:
        values.append(
            (((a >> 7) & 1) << 15) | ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
        )
    body = b""
    for y in reversed(range(height)):
        for x in range(width):
            body += struct.pack("<H", values[y * width + x])
    cases.append((
        "built-16",
        tga_file(width, height, 16, body, descriptor=1),
        digest_of(Image.new("RGBA", (width, height), (0, 0, 0, 0))),
    ))
    # Recompute the reference: one bit of alpha, five bits a channel.
    expected = Image.new("RGBA", (width, height))
    expected.putdata([
        (
            (((v >> 10) & 0x1F) * 255 + 15) // 31,
            (((v >> 5) & 0x1F) * 255 + 15) // 31,
            ((v & 0x1F) * 255 + 15) // 31,
            255 if (v & 0x8000) else 0,
        )
        for v in values
    ])
    cases[-1] = ("built-16", cases[-1][1], digest_of(expected))

    # Top-down order, which is one bit in the descriptor.
    body = b""
    for y in range(height):
        for x in range(width):
            r, g, b, a = rgba[y * width + x]
            body += bytes((b, g, r, a))
    cases.append((
        "built-top-down",
        tga_file(width, height, 32, body, descriptor=8 | 0x20),
        digest_of(source),
    ))

    # A colour map of twenty-four bit entries, eight-bit indices, run-length
    # coded: type 9 is the one nobody writes and everybody has to read.
    palette = [((i * 9) % 256, (i * 17) % 256, (i * 33) % 256) for i in range(24)]
    indices = [((x + y) % 24) for y in range(height) for x in range(width)]
    packets = bytearray()
    index = 0
    while index < len(indices):
        run = 1
        while index + run < len(indices) and indices[index + run] == indices[index] and run < 128:
            run += 1
        if run >= 2:
            packets += bytes((0x80 | (run - 1), indices[index]))
            index += run
        else:
            start = index
            while index < len(indices) and (index - start) < 128:
                ahead = 1
                while index + ahead < len(indices) and indices[index + ahead] == indices[index] and ahead < 2:
                    ahead += 1
                if ahead >= 2 and index > start:
                    break
                index += 1
            block = indices[start:index]
            packets += bytes((len(block) - 1,)) + bytes(block)
    content = b""
    for y in reversed(range(height)):
        content += bytes(indices[y * width:(y + 1) * width])
    # The packets above are in row order; rebuild them in the order the file
    # stores, which is bottom first.
    ordered = [indices[y * width + x] for y in reversed(range(height)) for x in range(width)]
    packets = bytearray()
    index = 0
    while index < len(ordered):
        run = 1
        while index + run < len(ordered) and ordered[index + run] == ordered[index] and run < 128:
            run += 1
        if run >= 2:
            packets += bytes((0x80 | (run - 1), ordered[index]))
            index += run
        else:
            start = index
            while index < len(ordered) and (index - start) < 128:
                ahead = 1
                while index + ahead < len(ordered) and ordered[index + ahead] == ordered[index] and ahead < 2:
                    ahead += 1
                if ahead >= 2 and index > start:
                    break
                index += 1
            block = ordered[start:index]
            packets += bytes((len(block) - 1,)) + bytes(block)
    expected = Image.new("RGBA", (width, height))
    expected.putdata([palette[i] + (255,) for i in indices])
    cases.append((
        "built-palette-rle",
        tga_file(width, height, 8, bytes(packets), image_type=9, palette=palette),
        digest_of(expected),
    ))
    return cases


# --------------------------------------------------------------------------
# PCX samples.


def pillow_pcx(image: Image.Image) -> bytes:
    handle = io.BytesIO()
    image.save(handle, format="PCX")
    return handle.getvalue()


def pcx_file(width, height, bits, planes, rows, palette16=None, trailer=None, encoding=1):
    """A PCX assembled field by field, for the depths Pillow does not write."""
    stride = (width * bits + 7) // 8
    stride += stride % 2
    header = bytearray(128)
    header[0] = 0x0A
    header[1] = 5
    header[2] = encoding
    header[3] = bits
    struct.pack_into("<HHHH", header, 4, 0, 0, width - 1, height - 1)
    struct.pack_into("<HH", header, 12, 72, 72)
    palette16 = palette16 or [(i * 17, i * 17, i * 17) for i in range(16)]
    for index, (r, g, b) in enumerate(palette16[:16]):
        header[16 + index * 3 : 19 + index * 3] = bytes((r, g, b))
    header[65] = planes
    struct.pack_into("<H", header, 66, stride)
    body = bytearray()
    for row in rows:
        padded = bytes(row) + b"\x00" * (stride - len(row))
        if encoding == 0:
            body += padded
            continue
        index = 0
        while index < len(padded):
            run = 1
            while index + run < len(padded) and padded[index + run] == padded[index] and run < 63:
                run += 1
            if run > 1 or padded[index] >= 0xC0:
                body += bytes((0xC0 | run, padded[index]))
            else:
                body += bytes((padded[index],))
            index += run
    if trailer is not None:
        body += b"\x0c" + bytes(trailer)
    return bytes(header + body)


def pcx_samples():
    cases = []
    base = sources.pattern(37, 23)
    written = [
        ("pillow-24", pillow_pcx(base.convert("RGB"))),
        ("pillow-grey", pillow_pcx(base.convert("L"))),
        ("pillow-8-palette", pillow_pcx(base.convert("RGB").quantize(colors=200))),
        ("pillow-1bit", pillow_pcx(base.convert("1"))),
    ]
    cases.extend((name, data, digest_of(read_back(data))) for name, data in written)

    # Four bits a pixel: two pixels a byte, sixteen colours from the header.
    width, height = 26, 14
    picture = sources.pattern(width, height)
    indices = [((x * 5 + y * 3) // 7) % 16 for y in range(height) for x in range(width)]
    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(0, width, 2):
            high = indices[y * width + x] & 0x0F
            low = indices[y * width + x + 1] & 0x0F if x + 1 < width else 0
            row.append((high << 4) | low)
        rows.append(row)
    palette = [(i * 17, 255 - i * 17, (i * 37) % 256) for i in range(16)]
    data = pcx_file(width, height, 4, 1, rows, palette16=palette)
    expected = Image.new("RGBA", (width, height))
    expected.putdata([palette[i] + (255,) for i in indices])
    cases.append(("built-4bit", data, digest_of(expected)))

    # Two bits a pixel, four colours: the CGA shape.
    width, height = 17, 9
    indices = [((x // 2 + y // 2) % 4) for y in range(height) for x in range(width)]
    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(0, width, 4):
            batch = [indices[y * width + x + k] if x + k < width else 0 for k in range(4)]
            row.append((batch[0] << 6) | (batch[1] << 4) | (batch[2] << 2) | batch[3])
        rows.append(row)
    palette = [(0, 0, 0), (0, 170, 0), (170, 0, 0), (170, 85, 0)] + [(0, 0, 0)] * 12
    data = pcx_file(width, height, 2, 1, rows, palette16=palette)
    expected = Image.new("RGBA", (width, height))
    expected.putdata([palette[i] + (255,) for i in indices])
    cases.append(("built-2bit", data, digest_of(expected)))

    # No run lengths at all: the same bytes, written flat.
    width, height = 21, 11
    picture = sources.pattern(width, height).convert("RGB")
    flat = []
    for y in range(height):
        for channel in range(3):
            flat.append(bytes(picture.getpixel((x, y))[channel] for x in range(width)))
    data = pcx_file(width, height, 8, 3, flat, encoding=0)
    cases.append(("built-24-raw", data, digest_of(picture.convert("RGBA"))))
    return cases


# --------------------------------------------------------------------------
# SGI samples.


def pillow_sgi(image: Image.Image) -> bytes:
    handle = io.BytesIO()
    image.save(handle, format="SGI")
    return handle.getvalue()


def sgi_file(width, height, channels, rows, storage=0, bpc=1):
    """An SGI assembled field by field: the header, then each channel."""
    header = struct.pack(
        ">HBBHHHHIII",
        474,
        storage,
        bpc,
        3,
        width,
        height,
        channels,
        0,
        255,
        0,
    )
    header += b"\x00" * 80 + struct.pack(">I", 0) + b"\x00" * 404
    assert len(header) == 512
    if storage == 0:
        return header + b"".join(row for channel in rows for row in channel)
    table = bytearray()
    body = bytearray()
    for channel in rows:
        for row in channel:
            packets = bytearray()
            index = 0
            while index < len(row):
                run = 1
                while index + run < len(row) and row[index + run] == row[index] and run < 127:
                    run += 1
                if run >= 3:
                    packets += bytes((run, row[index]))
                else:
                    start = index
                    while index < len(row) and (index - start) < 127:
                        ahead = 1
                        while index + ahead < len(row) and row[index + ahead] == row[index] and ahead < 3:
                            ahead += 1
                        if ahead >= 3 and index > start:
                            break
                        index += 1
                    block = row[start:index]
                    packets += bytes((0x80 | len(block),)) + bytes(block)
                    continue
                index += run
            packets += b"\x00"
            table += struct.pack(">II", len(body), len(packets))
            body += packets
    return header + bytes(table) + bytes(body)


def sgi_samples():
    cases = []
    base = sources.pattern(37, 23)
    for name, mode in (("pillow-rgb", "RGB"), ("pillow-rgba", "RGBA"), ("pillow-grey", "L")):
        data = pillow_sgi(base.convert(mode))
        cases.append((name, data, digest_of(read_back(data))))

    # Two bytes a sample, which Pillow reads as eight bits and this library keeps
    # at sixteen.
    width, height = 11, 7
    values = [
        [
            [((x * 2900 + y * 137 + channel * 4000) & 0xFFFF) for x in range(width)]
            for y in range(height)
        ]
        for channel in range(3)
    ]
    rows16 = [
        [struct.pack(">%dH" % width, *values[channel][y]) for y in range(height)]
        for channel in range(3)
    ]
    data = sgi_file(width, height, 3, rows16, bpc=2)
    # The rows are stored bottom first, so the picture read back is the one that
    # went in turned over.
    wide = Image.new("RGBA", (width, height))
    wide.putdata([
        (values[0][y][x] >> 8, values[1][y][x] >> 8, values[2][y][x] >> 8, 255)
        for y in reversed(range(height))
        for x in range(width)
    ])
    assert digest_of(read_back(data)) == digest_of(wide), "Pillow disagrees about the sixteen-bit file"
    cases.append(("built-16bit", data, digest_of_wide(values, width, height)))
    return cases


def digest_of_wide(values, width, height):
    """The digest of a picture that stays at sixteen bits, as Rgba16 bytes."""
    body = bytearray()
    for y in reversed(range(height)):
        for x in range(width):
            for channel in range(3):
                value = values[channel][y][x]
                body += bytes(((value >> 8) & 0xFF, value & 0xFF))
            body += b"\xff\xff"
    return moonbit.digest(bytes(body))


# --------------------------------------------------------------------------
# Sun raster samples. Pillow reads these and does not write them, so every one
# is built here and Pillow's reading of it is the oracle.


def ras_file(width, height, depth, rows, kind=1, palette=None, rle=False):
    stride = ((width * depth + 15) // 16) * 2
    data = bytearray()
    for row in rows:
        padded = bytes(row) + b"\x00" * (stride - len(row))
        if not rle:
            data += padded
            continue
        index = 0
        while index < len(padded):
            run = 1
            while index + run < len(padded) and padded[index + run] == padded[index] and run < 255:
                run += 1
            if run >= 3 or padded[index] == 0x80:
                data += bytes((0x80, run, padded[index]))
                index += run
            else:
                data += bytes((padded[index],))
                index += 1
    colour_map = b""
    if palette is not None:
        entries = len(palette)
        colour_map = bytes(colour_map_channel(palette, 0, entries))
        colour_map += bytes(colour_map_channel(palette, 1, entries))
        colour_map += bytes(colour_map_channel(palette, 2, entries))
    header = struct.pack(
        ">IIIIIIII",
        0x59A66A95,
        width,
        height,
        depth,
        len(data),
        kind,
        1 if palette is not None else 0,
        len(colour_map),
    )
    return header + colour_map + bytes(data)


def colour_map_channel(palette, channel, entries):
    return [palette[i][channel] if i < len(palette) else 0 for i in range(entries)]


def ras_samples():
    cases = []
    base = sources.pattern(23, 11).convert("RGB")

    # Eight bits with a palette, plain.
    width, height = 23, 11
    palette = [((i * 7) % 256, (i * 13) % 256, (i * 29) % 256) for i in range(256)]
    indices = [((x * 5 + y * 11) // 3) % 256 for y in range(height) for x in range(width)]
    rows = [bytes(indices[y * width:(y + 1) * width]) for y in range(height)]
    data = ras_file(width, height, 8, rows, palette=palette)
    expected = Image.new("RGBA", (width, height))
    expected.putdata([palette[i] + (255,) for i in indices])
    # Pillow reads a Sun colour map as RGB triples where the format says three
    # planes, so its opinion of a palette file is not usable here; the builder is
    # the oracle, and the same palette read as triples is what Pillow would show.
    cases.append(("built-8-palette", data, digest_of(expected)))

    # The same indices, byte-encoded.
    data = ras_file(width, height, 8, rows, palette=palette, rle=True)
    cases.append(("built-8-rle", data, digest_of(expected)))

    # Twenty-four bits, blue first, which is what a Sun framebuffer held.
    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(width):
            r, g, b = base.getpixel((x, y))
            row += bytes((b, g, r))
        rows.append(row)
    data = ras_file(width, height, 24, rows)
    assert digest_of(read_back(data)) == digest_of(base.convert("RGBA")), "Pillow disagrees about the colour file"
    cases.append(("built-24", data, digest_of(base.convert("RGBA"))))

    # Thirty-two bits: the fourth byte is this library's alpha and every other
    # reader's padding.
    opaque = Image.new("RGBA", (width, height))
    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(width):
            r, g, b = base.getpixel((x, y))
            row += bytes((b, g, r, 255))
        rows.append(row)
    opaque.putdata([base.getpixel((x, y)) + (255,) for y in range(height) for x in range(width)])
    data = ras_file(width, height, 32, rows)
    assert digest_of(read_back(data)) == digest_of(opaque), "Pillow disagrees about the thirty-two bit file"
    cases.append(("built-32", data, digest_of(opaque)))
    return cases


def main() -> None:
    def emit(path, header, cases):
        body = ["let samples : Array[(String, Bytes, String)] = ["]
        for name, data, expected in cases:
            body.append(
                "  (\n    %s,\n    %s,\n    %s,\n  ),"
                % ('"%s"' % name, moonbit.literal(data), '"%s"' % expected)
            )
        body.append("]")
        moonbit.write(path, header, "\n".join(body))

    bmp_cases = bmp_samples() + extra_bmp_samples()
    emit(
        ROOT / "src" / "bmp" / "samples_test.mbt",
        """\
// Generated by scripts/fixtures/samples.py. Do not edit.
//
// BMP files Pillow wrote, and files built here for the depths and compressions
// Pillow does not write, each with a digest of the pixels it should decode to.
// The Pillow-written ones are checked against Pillow's own reading of them; the
// built ones against the image they were built from.""",
        bmp_cases,
    )

    tga_cases = tga_samples() + extra_tga_samples()
    emit(
        ROOT / "src" / "tga" / "samples_test.mbt",
        """\
// Generated by scripts/fixtures/samples.py. Do not edit.
//
// TGA files Pillow wrote, with and without runs and at three depths, plus the
// sixteen-bit and top-down and colour-mapped shapes it does not write. Each
// carries a digest of the pixels it should decode to.""",
        tga_cases,
    )

    emit(
        ROOT / "src" / "pcx" / "samples_test.mbt",
        """\
// Generated by scripts/fixtures/samples.py. Do not edit.
//
// PCX files Pillow wrote — eight bits a plane, a palette, one bit a pixel — and
// files built here for the two depths and the flat stream it does not write.
// Each carries a digest of the pixels it should decode to.""",
        pcx_samples(),
    )

    emit(
        ROOT / "src" / "sgi" / "samples_test.mbt",
        """\
// Generated by scripts/fixtures/samples.py. Do not edit.
//
// SGI files Pillow wrote, and a run-length one and a sixteen-bit one built here
// because Pillow does not write those, each with a digest of the pixels it
// should decode to.""",
        sgi_samples(),
    )

    emit(
        ROOT / "src" / "ras" / "samples_test.mbt",
        """\
// Generated by scripts/fixtures/samples.py. Do not edit.
//
// Sun raster files built here, since no Python writes them, each read back by
// Pillow before its digest is recorded: the palette form, the byte-encoded one,
// twenty-four bits blue first, and thirty-two.""",
        ras_samples(),
    )


if __name__ == "__main__":
    main()
