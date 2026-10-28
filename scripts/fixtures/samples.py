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


if __name__ == "__main__":
    main()
