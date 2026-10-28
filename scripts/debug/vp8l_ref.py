#!/usr/bin/env python3
"""A reference VP8L decoder, written from the specification, for debugging.

This is not part of the library: it exists so that the MoonBit decoder has
something independent to be compared against, step by step, when a file comes
out wrong. It prints the structure it finds — transforms, groups, the entropy
image, the predictor modes — which is what a diff needs.

    python scripts/debug/vp8l_ref.py file.webp [--pixels out.bin]
"""

from __future__ import annotations

import struct
import sys


_VERBOSE_CODES = False


class Bits:
    def __init__(self, data: bytes, at: int = 0):
        self.data = data
        self.at = at
        self.buffer = 0
        self.held = 0

    def take(self, count: int) -> int:
        if count == 0:
            return 0
        while self.held < count:
            if self.at >= len(self.data):
                raise EOFError("out of bits")
            self.buffer |= self.data[self.at] << self.held
            self.at += 1
            self.held += 8
        value = self.buffer & ((1 << count) - 1)
        self.buffer >>= count
        self.held -= count
        return value

    def bit(self) -> int:
        return self.take(1)


def huffman(lengths: list[int]):
    """Canonical decoding tables, and a symbol() that reads one code."""
    counts = [0] * 16
    for length in lengths:
        if length:
            counts[length] += 1
    used = [s for s, length in enumerate(lengths) if length]
    if not used:
        raise ValueError("empty tree")
    if len(used) == 1:
        only = used[0]

        def single(br: Bits) -> int:
            return only

        return single
    offsets, running = [0] * 16, 0
    for length in range(1, 16):
        offsets[length] = running
        running += counts[length]
    symbols = [0] * running
    cursor = offsets[:]
    for symbol, length in enumerate(lengths):
        if length:
            symbols[cursor[length]] = symbol
            cursor[length] += 1

    def symbol(br: Bits) -> int:
        code = first = index = 0
        for length in range(1, 16):
            code = (code << 1) | br.bit()
            count = counts[length]
            if code >= first and code - first < count:
                return symbols[index + code - first]
            index += count
            first = (first + count) << 1
        raise ValueError("no code")

    return symbol


def read_code(br: Bits, alphabet: int, trace=None):
    start = br.at * 8 - br.held
    lengths = [0] * alphabet
    if br.bit():
        count = br.bit() + 1
        wide = br.bit()
        lengths[br.take(1 + 7 * wide)] = 1
        if count == 2:
            lengths[br.take(8)] = 1
    else:
        order = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
        cl = [0] * 19
        used = 4 + br.take(4)
        for i in range(used):
            cl[order[i]] = br.take(3)
        table = huffman(cl)
        limit = alphabet
        if br.bit():
            width = 2 + 2 * br.take(3)
            limit = 2 + br.take(width)
        symbol, previous = 0, 8
        budget = limit
        while symbol < alphabet and budget > 0:
            budget -= 1
            code = table(br)
            if code < 16:
                lengths[symbol] = code
                if code:
                    previous = code
                symbol += 1
            elif code == 16:
                run = 3 + br.take(2)
                if symbol + run > alphabet:
                    raise ValueError("repeat past the alphabet")
                for _ in range(run):
                    lengths[symbol] = previous
                    symbol += 1
            elif code == 17:
                symbol += 3 + br.take(3)
            else:
                symbol += 11 + br.take(7)
    if trace is not None:
        trace.append((start, alphabet, [l for l in lengths if l]))
    if __debug__ and _VERBOSE_CODES:
        print(f"    code {start}->{br.at * 8 - br.held} alphabet {alphabet} nonzero {sum(1 for l in lengths if l)}")
    return huffman(lengths)


def value_of(code: int, br: Bits) -> int:
    if code < 4:
        return code + 1
    extra = (code - 2) >> 1
    offset = (2 + (code & 1)) << extra
    return offset + br.take(extra) + 1


PLACES = [
    (0, 1), (1, 0), (1, 1), (-1, 1), (0, 2), (2, 0), (1, 2), (-1, 2), (2, 1),
    (-2, 1), (2, 2), (-2, 2), (0, 3), (3, 0), (1, 3), (-1, 3), (3, 1), (-3, 1),
    (2, 3), (-2, 3), (3, 2), (-3, 2), (0, 4), (4, 0), (1, 4), (-1, 4), (4, 1),
    (-4, 1), (3, 3), (-3, 3), (2, 4), (-2, 4), (4, 2), (-4, 2), (0, 5), (3, 4),
    (-3, 4), (4, 3), (-4, 3), (5, 0), (1, 5), (-1, 5), (5, 1), (-5, 1), (2, 5),
    (-2, 5), (5, 2), (-5, 2), (4, 4), (-4, 4), (3, 5), (-3, 5), (5, 3), (-5, 3),
    (0, 6), (6, 0), (1, 6), (-1, 6), (6, 1), (-6, 1), (2, 6), (-2, 6), (6, 2),
    (-6, 2), (4, 5), (-4, 5), (5, 4), (-5, 4), (3, 6), (-3, 6), (6, 3), (-6, 3),
    (0, 7), (7, 0), (1, 7), (-1, 7), (5, 5), (-5, 5), (7, 1), (-7, 1), (4, 6),
    (-4, 6), (6, 4), (-6, 4), (2, 7), (-2, 7), (7, 2), (-7, 2), (3, 7), (-3, 7),
    (7, 3), (-7, 3), (5, 6), (-5, 6), (6, 5), (-6, 5), (8, 0), (4, 7), (-4, 7),
    (7, 4), (-7, 4), (8, 1), (8, 2), (6, 6), (-6, 6), (8, 3), (5, 7), (-5, 7),
    (7, 5), (-7, 5), (8, 4), (6, 7), (-6, 7), (7, 6), (-7, 6), (8, 5), (7, 7),
    (-7, 7), (8, 6), (8, 7),
]


def distance_of(code: int, width: int) -> int:
    if code > 120:
        return code - 120
    xi, yi = PLACES[code - 1]
    return max(1, xi + yi * width)


def add_pixels(a: int, b: int) -> int:
    out = 0
    for shift in (0, 8, 16, 24):
        out |= ((((a >> shift) & 0xFF) + ((b >> shift) & 0xFF)) & 0xFF) << shift
    return out


def add_green(p: int) -> int:
    g = (p >> 8) & 0xFF
    r = (((p >> 16) & 0xFF) + g) & 0xFF
    b = ((p & 0xFF) + g) & 0xFF
    return (p & 0xFF00FF00) | (r << 16) | b


def avg(a: int, b: int) -> int:
    return (a + b) // 2


def select(l, t, tl):
    p_l = p_t = 0
    for shift in (0, 8, 16, 24):
        a = (l >> shift) & 0xFF
        b = (t >> shift) & 0xFF
        c = (tl >> shift) & 0xFF
        estimate = a + b - c
        p_l += abs(estimate - a)
        p_t += abs(estimate - b)
    return l if p_l < p_t else t


def predictor(mode, l, t, tl, tr):
    if mode == 11:
        return select(l, t, tl)
    if mode == 0:
        return 0xFF000000
    if mode == 1:
        return l
    if mode == 2:
        return t
    if mode == 3:
        return tr
    if mode == 4:
        return tl
    out = 0
    for shift in (0, 8, 16, 24):
        a = (l >> shift) & 0xFF
        b = (t >> shift) & 0xFF
        c = (tl >> shift) & 0xFF
        d = (tr >> shift) & 0xFF
        if mode == 5:
            v = avg(avg(a, d), b)
        elif mode == 6:
            v = avg(a, c)
        elif mode == 7:
            v = avg(a, b)
        elif mode == 8:
            v = avg(c, b)
        elif mode == 9:
            v = avg(b, d)
        elif mode == 10:
            v = avg(avg(a, c), avg(b, d))
        elif mode == 11:
            v = a
        elif mode == 12:
            v = min(255, max(0, a + b - c))
        elif mode == 13:
            v = min(255, max(0, avg(a, b) + (avg(a, b) - c) // 2))
        else:
            v = a
        out |= v << shift
    return out


class Plane:
    def __init__(self, width, height, pixels):
        self.width = width
        self.height = height
        self.pixels = pixels


def decode_stream(br: Bits, width: int, height: int, level0: bool, verbose=False):
    if verbose:
        print("  stream", width, "x", height, "level0", level0, "at bit", br.at * 8 - br.held)
    xsize, ysize = width, height
    transforms = []
    if level0:
        while br.bit():
            kind = br.take(2)
            if kind == 0:
                bits = br.take(3) + 2
                bw, bh = (xsize + (1 << bits) - 1) >> bits, (ysize + (1 << bits) - 1) >> bits
                sub = decode_stream(br, bw, bh, False, verbose)
                transforms.append(("predictor", bits, bw, sub))
                if verbose:
                    modes = [(p >> 8) & 0xFF for p in sub.pixels]
                    print("  predictor bits", bits, "block", bw, "x", bh)
                    for y in range(bh):
                        print("   ", modes[y * bw : (y + 1) * bw])
            elif kind == 1:
                bits = br.take(3) + 2
                bw, bh = (xsize + (1 << bits) - 1) >> bits, (ysize + (1 << bits) - 1) >> bits
                sub = decode_stream(br, bw, bh, False, verbose)
                transforms.append(("color", bits, bw, sub))
                if verbose:
                    print("  color bits", bits, "block", bw, "x", bh)
                    for y in range(bh):
                        row = []
                        for x in range(bw):
                            p = sub.pixels[y * bw + x]
                            row.append(((p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF))
                        print("   ", row)
            elif kind == 2:
                transforms.append(("subtract-green",))
                if verbose:
                    print("  subtract-green")
            else:
                size = br.take(8) + 1
                bits = 0 if size > 16 else 1 if size > 4 else 2 if size > 2 else 3
                before = xsize
                xsize = (xsize + (1 << bits) - 1) >> bits
                sub = decode_stream(br, size, 1, False, verbose)
                palette = sub.pixels[:]
                for i in range(1, size):
                    palette[i] = add_pixels(palette[i], palette[i - 1])
                transforms.append(("palette", bits, before, size, palette))
                if verbose:
                    print("  palette", size, "bits", bits)
    cache_bits = 0
    has_cache = br.bit()
    if has_cache:
        cache_bits = br.take(4)
    cache_size = 0 if cache_bits == 0 else 1 << cache_bits
    entropy = None
    prefix_bits = 0
    groups = 1
    if level0 and br.bit():
        prefix_bits = br.take(3) + 2
        ew = (xsize + (1 << prefix_bits) - 1) >> prefix_bits
        eh = (ysize + (1 << prefix_bits) - 1) >> prefix_bits
        entropy = decode_stream(br, ew, eh, False, verbose)
        groups = max((p >> 8) & 0xFFFF for p in entropy.pixels) + 1
        if verbose:
            print("  entropy", ew, "x", eh, "prefix_bits", prefix_bits, "groups", groups)
            for y in range(eh):
                print("   ", [(p >> 8) & 0xFFFF for p in entropy.pixels[y * ew : (y + 1) * ew]])
    if verbose:
        print("  cache bit", has_cache, "bits", cache_bits)

    if __debug__ and _VERBOSE_CODES:
        print(f"  coding groups={groups} cache={cache_bits} size={xsize}x{ysize} level0={level0} at bit {br.at * 8 - br.held}")
    codes = []
    for _ in range(groups):
        codes.append(read_code(br, 256 + 24 + cache_size))
        codes.append(read_code(br, 256))
        codes.append(read_code(br, 256))
        codes.append(read_code(br, 256))
        codes.append(read_code(br, 40))

    total = xsize * ysize
    pixels = [0] * total
    cache = [0] * max(1, cache_size)
    position = 0
    while position < total:
        group = 0
        if entropy is not None:
            x, y = position % xsize, position // xsize
            group = (entropy.pixels[(y >> prefix_bits) * entropy.width + (x >> prefix_bits)] >> 8) & 0xFFFF
        base = group * 5
        at_bit = br.at * 8 - br.held
        symbol = codes[base](br)
        if __debug__ and _VERBOSE_CODES and (xsize, ysize) == (8, 6):
            print(f"    pixel {position} bit {at_bit} symbol {symbol}")
        if symbol < 256:
            red = codes[base + 1](br)
            blue = codes[base + 2](br)
            alpha = codes[base + 3](br)
            argb = (alpha << 24) | (red << 16) | (symbol << 8) | blue
            pixels[position] = argb
            if cache_size:
                cache[((argb * 0x1E35A7BD) & 0xFFFFFFFF) >> (32 - cache_bits)] = argb
            position += 1
        elif symbol < 280:
            length = value_of(symbol - 256, br)
            distance = distance_of(value_of(codes[base + 4](br), br), xsize)
            if verbose and (xsize, ysize) in ((8, 6),):
                print("    pos", position, "copy", length, "back", distance)
            for _ in range(length):
                value = pixels[position - distance]
                pixels[position] = value
                if cache_size:
                    cache[((value * 0x1E35A7BD) & 0xFFFFFFFF) >> (32 - cache_bits)] = value
                position += 1
        else:
            value = cache[symbol - 280]
            pixels[position] = value
            if cache_size:
                cache[((value * 0x1E35A7BD) & 0xFFFFFFFF) >> (32 - cache_bits)] = value
            position += 1

    plane = Plane(xsize, ysize, pixels)
    for transform in reversed(transforms):
        if transform[0] == "subtract-green":
            plane.pixels = [add_green(p) for p in plane.pixels]
        elif transform[0] == "predictor":
            _, bits, data_width, sub = transform
            width_, height_ = plane.width, plane.height
            out = plane.pixels
            for y in range(height_):
                for x in range(width_):
                    at = y * width_ + x
                    mode = (sub.pixels[(y >> bits) * data_width + (x >> bits)] >> 8) & 0xFF
                    left = out[at - 1] if x else 0
                    top = out[at - width_] if y else 0
                    tl = out[at - width_ - 1] if x and y else 0
                    if y:
                        tr = out[at - width_ + 1] if x + 1 < width_ else out[at - width_ - x]
                    else:
                        tr = 0
                    if x == 0 and y == 0:
                        prediction = 0xFF000000
                    elif y == 0:
                        prediction = left
                    elif x == 0:
                        prediction = top
                    else:
                        prediction = predictor(mode, left, top, tl, tr)
                    out[at] = add_pixels(out[at], prediction)
        elif transform[0] == "color":
            _, bits, data_width, sub = transform
            width_, height_ = plane.width, plane.height
            out = plane.pixels
            for y in range(height_):
                for x in range(width_):
                    at = y * width_ + x
                    element = sub.pixels[(y >> bits) * data_width + (x >> bits)]
                    green_to_red = element & 0xFF
                    green_to_blue = (element >> 8) & 0xFF
                    red_to_blue = (element >> 16) & 0xFF
                    p = out[at]
                    g = (p >> 8) & 0xFF
                    r = (p >> 16) & 0xFF
                    b = p & 0xFF

                    def delta(t, c):
                        t = t - 256 if t >= 128 else t
                        c = c - 256 if c >= 128 else c
                        return (t * c) >> 5

                    new_r = (r + delta(green_to_red, g)) & 0xFF
                    new_b = (b + delta(green_to_blue, g) + delta(red_to_blue, new_r)) & 0xFF
                    out[at] = (p & 0xFF00FF00) | (new_r << 16) | new_b
        else:
            _, bits, before, size, palette = transform
            per_byte = 1 << bits
            index_bits = 8 >> bits
            mask = (1 << index_bits) - 1
            packed_width = plane.width
            out = [0] * (before * plane.height)
            for y in range(plane.height):
                for x in range(before):
                    packed = plane.pixels[y * packed_width + x // per_byte]
                    byte = (packed >> 8) & 0xFF
                    index = (byte >> ((x % per_byte) * index_bits)) & mask
                    out[y * before + x] = palette[index] if index < size else 0
            plane = Plane(before, plane.height, out)
    return plane


def payload_of(data: bytes) -> bytes:
    if data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        raise ValueError("not a WebP")
    position = 12
    while position + 8 <= len(data):
        name = data[position : position + 4]
        size = struct.unpack("<I", data[position + 4 : position + 8])[0]
        if name == b"VP8L":
            return data[position + 8 : position + 8 + size]
        position += 8 + size + (size & 1)
    raise ValueError("no VP8L chunk")


def decode(data: bytes, verbose: bool = False):
    payload = payload_of(data)
    if payload[0] != 0x2F:
        raise ValueError("not lossless")
    br = Bits(payload, 1)
    width, height = br.take(14) + 1, br.take(14) + 1
    br.take(1)
    version = br.take(3)
    if verbose:
        print("size", width, height, "version", version)
    plane = decode_stream(br, width, height, True, verbose)
    return plane


def main() -> None:
    data = open(sys.argv[1], "rb").read()
    verbose = "--quiet" not in sys.argv
    plane = decode(data, verbose)
    if "--pixels" in sys.argv:
        out = bytearray()
        for pixel in plane.pixels:
            out += bytes(((pixel >> 16) & 0xFF, (pixel >> 8) & 0xFF, pixel & 0xFF, (pixel >> 24) & 0xFF))
        open(sys.argv[sys.argv.index("--pixels") + 1], "wb").write(bytes(out))
    print("decoded", plane.width, plane.height)


if __name__ == "__main__":
    main()
