# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0

"""A VP8 decoder in Python, for comparing the MoonBit reader's *parse* with libwebp.

    python scripts/debug/vp8_ref.py .cache/vp8_rgb.webp

This is a transcription of libwebp's C — not of the MoonBit reader — so that the
two can be compared where a byte-for-byte comparison of the finished picture only
says "wrong" without saying where. It prints, per macroblock, the segment, the
block size, the sixteen subblock modes, the chroma mode and how many coefficients
each block has; the same dump from the other side localises a disagreement to one
macroblock, or to one table.

It stops short of the loop filter and of the interpolated chroma, because both
are easy to get right once the parse is: the shipped reader is checked by digest
against libwebp on every fixture, which is the comparison that matters.
"""

import sys
from pathlib import Path

from PIL import Image

DC_QUANT = [
    4, 5, 6, 7, 8, 9, 10, 10, 11, 12, 13, 14, 15, 16, 17, 17,
    18, 19, 20, 20, 21, 21, 22, 22, 23, 23, 24, 25, 25, 26, 27, 28,
    29, 30, 31, 32, 33, 34, 35, 36, 37, 37, 38, 39, 40, 41, 42, 43,
    44, 45, 46, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58,
    59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74,
    75, 76, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89,
    91, 93, 95, 96, 98, 100, 101, 102, 104, 106, 108, 110, 112, 114,
    116, 118, 122, 124, 126, 128, 130, 132, 134, 136, 138, 140, 143,
    145, 148, 151, 154, 157,
]
AC_QUANT = [
    4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
    20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
    36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51,
    52, 53, 54, 55, 56, 57, 58, 60, 62, 64, 66, 68, 70, 72, 74, 76,
    78, 80, 82, 84, 86, 88, 90, 92, 94, 96, 98, 100, 102, 104, 106,
    108, 110, 112, 114, 116, 119, 122, 125, 128, 131, 134, 137, 140,
    143, 146, 149, 152, 155, 158, 161, 164, 167, 170, 173, 177, 181,
    185, 189, 193, 197, 201, 205, 209, 213, 217, 221, 225, 229, 234,
    239, 245, 249, 254, 259, 264, 269, 274, 279, 284,
]

BANDS = [0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0]
ZIGZAG = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15]
MODE_TREE = [0, 1, -1, 2, -2, 3, 4, 6, -3, 5, -4, -5, -6, 7, -7, 8, -8, -9]
CAT = [
    [173, 148, 140],
    [176, 155, 140, 135],
    [180, 157, 141, 134, 130],
    [254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129],
]


class Coder:
    def __init__(self, data, at, end):
        self.data, self.end = data, end
        self.at = at
        self.range, self.value, self.count = 255, 0, 0
        for _ in range(2):
            self.value = (self.value << 8) | (self.byte())

    def byte(self):
        if self.at < self.end:
            b = self.data[self.at]
            self.at += 1
            return b
        return 0

    def bit(self, prob):
        split = 1 + (((self.range - 1) * prob) >> 8)
        big = split << 8
        if self.value >= big:
            answer = 1
            self.range -= split
            self.value -= big
        else:
            answer = 0
            self.range = split
        while self.range < 128:
            self.value <<= 1
            self.range <<= 1
            self.count += 1
            if self.count == 8:
                self.count = 0
                self.value |= self.byte()
        return answer

    def flag(self):
        return self.bit(128)

    def literal(self, bits):
        v = 0
        for _ in range(bits):
            v = (v << 1) | self.flag()
        return v

    def signed(self, bits):
        v = self.literal(bits)
        return -v if self.flag() else v


def clip(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


class Frame:
    pass


def parse(data, verbose=False):
    f = Frame()
    tag = data[0] | (data[1] << 8) | (data[2] << 16)
    assert tag & 1 == 0, "not a key frame"
    partition_length = tag >> 5
    assert data[3:6] == b"\x9d\x01\x2a", "bad key frame signature"
    f.width = (((data[7] << 8) | data[6]) & 0x3FFF)
    f.height = (((data[9] << 8) | data[8]) & 0x3FFF)
    f.mb_w = (f.width + 15) >> 4
    f.mb_h = (f.height + 15) >> 4
    br = Coder(data, 10, 10 + partition_length)
    br.flag()  # colour space
    br.flag()  # clamp
    f.use_segment = br.flag()
    f.update_map = f.absolute_delta = False
    f.segment_quant = [0] * 4
    f.segment_filter = [0] * 4
    f.segment_probs = [255] * 3
    if f.use_segment:
        f.update_map = br.flag()
        if br.flag():
            f.absolute_delta = br.flag()
            for s in range(4):
                f.segment_quant[s] = br.signed(7) if br.flag() else 0
            for s in range(4):
                f.segment_filter[s] = br.signed(6) if br.flag() else 0
        if f.update_map:
            for s in range(3):
                f.segment_probs[s] = br.literal(8) if br.flag() else 255
    f.filter_simple = bool(br.flag())
    f.filter_level = br.literal(6)
    f.sharpness = br.literal(3)
    f.use_lf_delta = bool(br.flag())
    f.ref_lf = [0] * 4
    f.mode_lf = [0] * 4
    if f.use_lf_delta and br.flag():
        for i in range(4):
            if br.flag():
                f.ref_lf[i] = br.signed(6)
        for i in range(4):
            if br.flag():
                f.mode_lf[i] = br.signed(6)
    f.filter_type = 0 if f.filter_level == 0 else (1 if f.filter_simple else 2)

    from moonbit_tables import coeff_update, default_coeff_probs, bmode_probs

    parts_n = 1 << br.literal(2)
    tail = parts_n - 1
    start = 10 + partition_length + 3 * tail
    left = len(data) - start
    parts = []
    for p in range(tail):
        at = 10 + partition_length + 3 * p
        size = data[at] | (data[at + 1] << 8) | (data[at + 2] << 16)
        size = min(size, left)
        parts.append(Coder(data, start, start + size))
        start += size
        left -= size
    parts.append(Coder(data, start, len(data)))

    base = br.literal(7)
    dy1dc = br.signed(4) if br.flag() else 0
    dy2dc = br.signed(4) if br.flag() else 0
    dy2ac = br.signed(4) if br.flag() else 0
    duvdc = br.signed(4) if br.flag() else 0
    duvac = br.signed(4) if br.flag() else 0
    f.quant = []
    for i in range(4):
        if f.use_segment:
            q = f.segment_quant[i] + (0 if f.absolute_delta else base)
        else:
            q = base
        qq = []
        qq.append(DC_QUANT[clip(q + dy1dc, 0, 127)])
        qq.append(AC_QUANT[clip(q, 0, 127)])
        qq.append(DC_QUANT[clip(q + dy2dc, 0, 127)] * 2)
        y2ac_q = (AC_QUANT[clip(q + dy2ac, 0, 127)] * 101581) >> 16
        qq.append(max(8, y2ac_q))
        qq.append(DC_QUANT[clip(q + duvdc, 0, 117)])
        qq.append(AC_QUANT[clip(q + duvac, 0, 127)])
        f.quant.append(qq)

    br.flag()  # update probabilities
    probs = list(default_coeff_probs)
    for i in range(len(probs)):
        if br.bit(coeff_update[i]):
            probs[i] = br.literal(8)
    f.probs = probs
    f.use_skip = bool(br.flag())
    f.skip_prob = br.literal(8) if f.use_skip else 0
    f.parts = parts
    f.br = br
    f.bmode_probs = bmode_probs
    return f


def prob_base(kind, band, ctx):
    return ((kind * 8 + band) * 3 + ctx) * 11


def read_large(br, probs, base):
    if not br.bit(probs[base + 3]):
        if not br.bit(probs[base + 4]):
            return 2
        return 3 + br.bit(probs[base + 5])
    if not br.bit(probs[base + 6]):
        if not br.bit(probs[base + 7]):
            return 5 + br.bit(159)
        return 7 + 2 * br.bit(165) + br.bit(145)
    high = br.bit(probs[base + 8])
    low = br.bit(probs[base + 9 + high])
    category = 2 * high + low
    v = 0
    for p in CAT[category]:
        v += v + br.bit(p)
    return v + 3 + (8 << category)


def read_coeffs(br, probs, kind, ctx, dc, ac, n, out):
    off = prob_base(kind, BANDS[n], ctx)
    while n < 16:
        if not br.bit(probs[off]):
            return n
        while not br.bit(probs[off + 1]):
            n += 1
            if n == 16:
                return 16
            off = prob_base(kind, BANDS[n], 0)
        nxt = prob_base(kind, BANDS[n + 1], 0)
        if not br.bit(probs[off + 2]):
            v = 1
            off = nxt + 11
        else:
            v = read_large(br, probs, off)
            off = nxt + 22
        if br.flag():
            v = -v
        out[ZIGZAG[n]] = v * (ac if n > 0 else dc)
        n += 1
    return 16


def mul1(v):
    return v + ((v * 20091) >> 16)


def mul2(v):
    return (v * 35468) >> 16


def wht(dc, coeffs):
    tmp = [0] * 16
    for i in range(4):
        a0 = dc[i] + dc[12 + i]
        a1 = dc[4 + i] + dc[8 + i]
        a2 = dc[4 + i] - dc[8 + i]
        a3 = dc[i] - dc[12 + i]
        tmp[i] = a0 + a1
        tmp[8 + i] = a0 - a1
        tmp[4 + i] = a3 + a2
        tmp[12 + i] = a3 - a2
    for i in range(4):
        zero = tmp[4 * i] + 3
        a0 = zero + tmp[4 * i + 3]
        a1 = tmp[4 * i + 1] + tmp[4 * i + 2]
        a2 = tmp[4 * i + 1] - tmp[4 * i + 2]
        a3 = zero - tmp[4 * i + 3]
        coeffs[64 * i] = (a0 + a1) >> 3
        coeffs[64 * i + 16] = (a3 + a2) >> 3
        coeffs[64 * i + 32] = (a0 - a1) >> 3
        coeffs[64 * i + 48] = (a3 - a2) >> 3


def transform_one(coeffs, at, plane, base, stride):
    tmp = [0] * 16
    for i in range(4):
        a = coeffs[at + i] + coeffs[at + 8 + i]
        b = coeffs[at + i] - coeffs[at + 8 + i]
        c = mul2(coeffs[at + 4 + i]) - mul1(coeffs[at + 12 + i])
        d = mul1(coeffs[at + 4 + i]) + mul2(coeffs[at + 12 + i])
        tmp[4 * i] = a + d
        tmp[4 * i + 1] = b + c
        tmp[4 * i + 2] = b - c
        tmp[4 * i + 3] = a - d
    for i in range(4):
        dc = tmp[i] + 4
        a = dc + tmp[8 + i]
        b = dc - tmp[8 + i]
        c = mul2(tmp[4 + i]) - mul1(tmp[12 + i])
        d = mul1(tmp[4 + i]) + mul2(tmp[12 + i])
        for x, v in enumerate((a + d, b + c, b - c, a - d)):
            at2 = base + i * stride + x
            plane[at2] = clip(plane[at2] + (v >> 3), 0, 255)


def transform_ac3(coeffs, at, plane, base, stride):
    dc = coeffs[at] + 4
    c4, d4 = mul2(coeffs[at + 4]), mul1(coeffs[at + 4])
    c1, d1 = mul2(coeffs[at + 1]), mul1(coeffs[at + 1])
    rows = (dc + d4, dc + c4, dc - c4, dc - d4)
    for y, r in enumerate(rows):
        for x, v in enumerate((r + d1, r + c1, r - c1, r - d1)):
            at2 = base + y * stride + x
            plane[at2] = clip(plane[at2] + (v >> 3), 0, 255)


def transform_dc(coeffs, at, plane, base, stride):
    dc = (coeffs[at] + 4) >> 3
    for y in range(4):
        for x in range(4):
            at2 = base + y * stride + x
            plane[at2] = clip(plane[at2] + dc, 0, 255)


def avg3(a, b, c):
    return (a + 2 * b + c + 2) >> 2


def avg2(a, b):
    return (a + b + 1) >> 1


def predict4(mode, out, top, left, corner):
    if mode == 0:
        dc = (sum(top[:4]) + sum(left) + 4) >> 3
        for i in range(16):
            out[i] = dc
    elif mode == 1:
        for y in range(4):
            for x in range(4):
                out[x + 4 * y] = clip(left[y] + top[x] - corner, 0, 255)
    elif mode == 2:
        row = [avg3(corner, top[0], top[1]), avg3(top[0], top[1], top[2]),
               avg3(top[1], top[2], top[3]), avg3(top[2], top[3], top[4])]
        for y in range(4):
            for x in range(4):
                out[x + 4 * y] = row[x]
    elif mode == 3:
        vals = [avg3(corner, left[0], left[1]), avg3(left[0], left[1], left[2]),
                avg3(left[1], left[2], left[3]), avg3(left[2], left[3], left[3])]
        for y in range(4):
            for x in range(4):
                out[x + 4 * y] = vals[y]
    elif mode == 4:
        out[12] = avg3(left[1], left[2], left[3])
        out[13] = out[8] = avg3(left[0], left[1], left[2])
        out[14] = out[9] = out[4] = avg3(corner, left[0], left[1])
        out[15] = out[10] = out[5] = out[0] = avg3(top[0], corner, left[0])
        out[11] = out[6] = out[1] = avg3(top[1], top[0], corner)
        out[7] = out[2] = avg3(top[2], top[1], top[0])
        out[3] = avg3(top[3], top[2], top[1])
    elif mode == 5:
        out[0] = out[9] = avg2(corner, top[0])
        out[1] = out[10] = avg2(top[0], top[1])
        out[2] = out[11] = avg2(top[1], top[2])
        out[3] = avg2(top[2], top[3])
        out[12] = avg3(left[2], left[1], left[0])
        out[8] = avg3(left[1], left[0], corner)
        out[4] = out[13] = avg3(left[0], corner, top[0])
        out[5] = out[14] = avg3(corner, top[0], top[1])
        out[6] = out[15] = avg3(top[0], top[1], top[2])
        out[7] = avg3(top[1], top[2], top[3])
    elif mode == 6:
        out[0] = avg3(top[0], top[1], top[2])
        out[4] = out[1] = avg3(top[1], top[2], top[3])
        out[8] = out[5] = out[2] = avg3(top[2], top[3], top[4])
        out[12] = out[9] = out[6] = out[3] = avg3(top[3], top[4], top[5])
        out[13] = out[10] = out[7] = avg3(top[4], top[5], top[6])
        out[14] = out[11] = avg3(top[5], top[6], top[7])
        out[15] = avg3(top[6], top[7], top[7])
    elif mode == 7:
        out[0] = avg2(top[0], top[1])
        out[8] = out[1] = avg2(top[1], top[2])
        out[9] = out[2] = avg2(top[2], top[3])
        out[10] = out[3] = avg2(top[3], top[4])
        out[4] = avg3(top[0], top[1], top[2])
        out[12] = out[5] = avg3(top[1], top[2], top[3])
        out[13] = out[6] = avg3(top[2], top[3], top[4])
        out[14] = out[7] = avg3(top[3], top[4], top[5])
        out[11] = avg3(top[4], top[5], top[6])
        out[15] = avg3(top[5], top[6], top[7])
    elif mode == 8:
        out[0] = out[6] = avg2(left[0], corner)
        out[4] = out[10] = avg2(left[1], left[0])
        out[8] = out[14] = avg2(left[2], left[1])
        out[12] = avg2(left[3], left[2])
        out[3] = avg3(top[0], top[1], top[2])
        out[2] = avg3(corner, top[0], top[1])
        out[1] = out[7] = avg3(left[0], corner, top[0])
        out[5] = out[11] = avg3(left[1], left[0], corner)
        out[9] = out[15] = avg3(left[2], left[1], left[0])
        out[13] = avg3(left[3], left[2], left[1])
    else:
        out[0] = avg2(left[0], left[1])
        out[2] = out[4] = avg2(left[1], left[2])
        out[6] = out[8] = avg2(left[2], left[3])
        out[1] = avg3(left[0], left[1], left[2])
        out[3] = out[5] = avg3(left[1], left[2], left[3])
        out[7] = out[9] = avg3(left[2], left[3], left[3])
        for i in (10, 11, 12, 13, 14, 15):
            out[i] = left[3]


def predict_n(mode, plane, base, stride, size, mb_x, mb_y):
    if mode == 0 and (mb_x == 0 or mb_y == 0):
        mode = 6 if (mb_x == 0 and mb_y == 0) else (5 if mb_x == 0 else 4)
    if mode == 4:
        dc = (size // 2) + sum(plane[base - 1 + j * stride] for j in range(size))
        v = dc >> (4 if size == 16 else 3)
        for y in range(size):
            for x in range(size):
                plane[base + y * stride + x] = v
    elif mode == 5:
        dc = (size // 2) + sum(plane[base - stride + j] for j in range(size))
        v = dc >> (4 if size == 16 else 3)
        for y in range(size):
            for x in range(size):
                plane[base + y * stride + x] = v
    elif mode == 6:
        for y in range(size):
            for x in range(size):
                plane[base + y * stride + x] = 128
    elif mode == 0:
        dc = size + sum(plane[base - 1 + j * stride] + plane[base - stride + j]
                        for j in range(size))
        v = dc >> (5 if size == 16 else 4)
        for y in range(size):
            for x in range(size):
                plane[base + y * stride + x] = v
    elif mode == 1:
        for y in range(size):
            left = plane[base - 1 + y * stride]
            for x in range(size):
                plane[base + y * stride + x] = clip(
                    left + plane[base - stride + x] - plane[base - stride - 1], 0, 255)
    elif mode == 2:
        for y in range(size):
            for x in range(size):
                plane[base + y * stride + x] = plane[base - stride + x]
    else:
        for y in range(size):
            left = plane[base - 1 + y * stride]
            for x in range(size):
                plane[base + y * stride + x] = left


def vp8_payload(data):
    at = 12
    while at + 8 <= len(data):
        name = data[at:at + 4]
        size = int.from_bytes(data[at + 4:at + 8], "little")
        if name == b"VP8 ":
            return data[at + 8:at + 8 + size]
        at += 8 + size + (size & 1)
    raise SystemExit("no VP8 chunk")


def decode(path, verbose=False):
    from moonbit_tables import bmode_probs

    data = Path(path).read_bytes()
    payload = vp8_payload(data)
    f = parse(payload)
    mb_w, mb_h = f.mb_w, f.mb_h
    sy = mb_w * 16 + 16
    sc = mb_w * 8 + 16
    ph, ch = mb_h * 16, mb_h * 8
    py = [0] * ((ph + 2) * sy)
    pu = [0] * ((ch + 2) * sc)
    pv = [0] * ((ch + 2) * sc)

    def at(stride, x, y):
        return (y + 1) * stride + (x + 1)

    for plane, stride, w, h in ((py, sy, mb_w * 16, ph), (pu, sc, mb_w * 8, ch),
                                (pv, sc, mb_w * 8, ch)):
        for y in range(-1, h):
            plane[at(stride, -1, y)] = 129
        for x in range(-1, w):
            plane[at(stride, x, -1)] = 127

    top = [0] * (4 * mb_w)
    left = [0] * 4
    nz_top = [0] * mb_w
    nz_dc_top = [0] * mb_w
    nz_left = [0, 0]
    info = []

    for mb_y in range(mb_h):
        left = [0] * 4
        nz_left = [0, 0]
        tokens = f.parts[mb_y % len(f.parts)]
        for mb_x in range(mb_w):
            modes = [0] * 20
            segment = 0
            if f.use_segment and f.update_map:
                segment = (f.br.bit(f.segment_probs[1]) if not f.br.bit(f.segment_probs[0])
                           else f.br.bit(f.segment_probs[2]) + 2)
            skip = f.br.bit(f.skip_prob) if f.use_skip else 0
            i4x4 = f.br.bit(145) == 0
            if i4x4:
                for y in range(4):
                    mode = left[y]
                    for x in range(4):
                        base = (top[4 * mb_x + x] * 10 + mode) * 9
                        node = MODE_TREE[f.br.bit(bmode_probs[base])]
                        while node > 0:
                            node = MODE_TREE[2 * node + f.br.bit(bmode_probs[base + node])]
                        mode = -node
                        top[4 * mb_x + x] = mode
                        modes[4 * y + x] = mode
                    left[y] = mode
                modes[16] = -1
            else:
                mode = (1 if f.br.bit(128) else 3) if f.br.bit(156) else (2 if f.br.bit(163) else 0)
                for x in range(4):
                    top[4 * mb_x + x] = mode
                for y in range(4):
                    left[y] = mode
                modes[16] = mode
            modes[17] = (0 if not f.br.bit(142) else 2 if not f.br.bit(114)
                         else 1 if f.br.bit(183) else 3)
            q = f.quant[segment]
            coeffs = [0] * 384
            nzy = nzuv = 0
            if not skip:
                first, kind = 0, 3
                if not i4x4:
                    dc = [0] * 16
                    ctx = nz_dc_top[mb_x] + nz_left[1]
                    nz = read_coeffs(tokens, f.probs, 1, ctx, q[2], q[3], 0, dc)
                    nz_dc_top[mb_x] = nz_left[1] = 1 if nz > 0 else 0
                    if nz > 1:
                        wht(dc, coeffs)
                    else:
                        flat = (dc[0] + 3) >> 3
                        for i in range(16):
                            coeffs[16 * i] = flat
                    first, kind = 1, 0
                old = nz_top[mb_x]
                tnz, lnz = old & 0x0F, nz_left[0] & 0x0F
                for y in range(4):
                    l = lnz & 1
                    bits = 0
                    for x in range(4):
                        block = 4 * y + x
                        chunk = coeffs[16 * block:16 * block + 16]
                        nz = read_coeffs(tokens, f.probs, kind, l + (tnz & 1),
                                         q[0], q[1], first, chunk)
                        coeffs[16 * block:16 * block + 16] = chunk
                        l = 1 if nz > first else 0
                        tnz = (tnz >> 1) | (l << 7)
                        code = 3 if nz > 3 else 2 if nz > 1 else (1 if coeffs[16 * block] else 0)
                        bits = (bits << 2) | code
                    tnz >>= 4
                    lnz = (lnz >> 1) | (l << 7)
                    nzy = (nzy << 8) | bits
                top_out, left_out = tnz, lnz >> 4
                for plane in range(2):
                    ctnz = (old >> (4 + 2 * plane)) & 3
                    clnz = (nz_left[0] >> (4 + 2 * plane)) & 3
                    bits = 0
                    for y in range(2):
                        l = clnz & 1
                        for x in range(2):
                            block = 2 * y + x
                            off = 256 + 64 * plane + 16 * block
                            chunk = coeffs[off:off + 16]
                            nz = read_coeffs(tokens, f.probs, 2, l + (ctnz & 1),
                                             q[4], q[5], 0, chunk)
                            coeffs[off:off + 16] = chunk
                            l = 1 if nz > 0 else 0
                            ctnz = (ctnz >> 1) | (l << 3)
                            code = 3 if nz > 3 else 2 if nz > 1 else (1 if coeffs[off] else 0)
                            bits = (bits << 2) | code
                        ctnz >>= 2
                        clnz = (clnz >> 1) | (l << 5)
                    nzuv |= bits << (8 * plane)
                    top_out |= (ctnz << 4) << (2 * plane)
                    left_out |= (clnz & 0xF0) << (2 * plane)
                nz_top[mb_x] = top_out
                nz_left[0] = left_out
            else:
                nz_top[mb_x] = 0
                nz_left[0] = 0
                if not i4x4:
                    nz_dc_top[mb_x] = 0
                    nz_left[1] = 0

            px, pyy = mb_x * 16, mb_y * 16
            base = at(sy, px, pyy)
            if i4x4:
                corner = [py[at(sy, px + 15, pyy - 1)] if mb_x == mb_w - 1
                          else py[at(sy, px + 16 + i, pyy - 1)] for i in range(4)]
                for n in range(16):
                    bx, by = px + (n & 3) * 4, pyy + (n >> 2) * 4
                    here = at(sy, bx, by)
                    tp = [0] * 8
                    for i in range(8):
                        tp[i] = py[here - sy + i] if (i < 4 or bx < px + 12) else corner[i - 4]
                    lf = [py[here - 1 + i * sy] for i in range(4)]
                    out = [0] * 16
                    predict4(modes[n], out, tp, lf, py[here - sy - 1])
                    for y in range(4):
                        for x in range(4):
                            py[here + y * sy + x] = out[x + 4 * y]
                    kind = (nzy >> (30 - 2 * n)) & 3
                    if kind == 3:
                        transform_one(coeffs, 16 * n, py, here, sy)
                    elif kind == 2:
                        transform_ac3(coeffs, 16 * n, py, here, sy)
                    elif kind == 1:
                        transform_dc(coeffs, 16 * n, py, here, sy)
            else:
                predict_n(modes[16], py, base, sy, 16, mb_x, mb_y)
                for n in range(16):
                    here = at(sy, px + (n & 3) * 4, pyy + (n >> 2) * 4)
                    kind = (nzy >> (30 - 2 * n)) & 3
                    if kind == 3:
                        transform_one(coeffs, 16 * n, py, here, sy)
                    elif kind == 2:
                        transform_ac3(coeffs, 16 * n, py, here, sy)
                    elif kind == 1:
                        transform_dc(coeffs, 16 * n, py, here, sy)
            for pi, plane in enumerate((pu, pv)):
                cb = at(sc, mb_x * 8, mb_y * 8)
                predict_n(modes[17], plane, cb, sc, 8, mb_x, mb_y)
                b = (nzuv >> (8 * pi)) & 0xFF
                if b:
                    for n in range(4):
                        here = at(sc, mb_x * 8 + (n & 1) * 4, mb_y * 8 + (n >> 1) * 4)
                        off = 256 + 64 * pi + 16 * n
                        kind = (b >> (6 - 2 * n)) & 3
                        if kind >= 2:
                            transform_one(coeffs, off, plane, here, sc)
                        elif kind == 1 and coeffs[off]:
                            transform_dc(coeffs, off, plane, here, sc)
            if verbose:
                info.append((mb_x, mb_y, segment, "4x4" if i4x4 else "16", modes[:16],
                             modes[17], skip, bin(nzy), bin(nzuv)))
    return f, py, pu, pv, sy, sc, info


def clip8(v):
    if v < 0:
        return 0
    if v > 16383:
        return 255
    return v >> 6


def rgb_triple(y, u, v):
    luma = (y * 19077) >> 8
    return (clip8(luma + ((v * 26149) >> 8) - 14234),
            clip8(luma - ((u * 6419) >> 8) - ((v * 13320) >> 8) + 8708),
            clip8(luma + ((u * 33050) >> 8) - 17685))


def to_rgb(f, py, pu, pv, sy, sc):
    w, h = f.width, f.height
    out = bytearray(w * h * 3)

    def sample(plane, stride, x, y):
        return plane[(y + 1) * stride + x + 1]

    def emit(y_top, y_bottom, c_top, c_bottom):
        row = y_top * w * 3
        low = y_bottom * w * 3 if y_bottom >= 0 else 0
        tl_u, tl_v = sample(pu, sc, 0, c_top), sample(pv, sc, 0, c_top)
        l_u, l_v = sample(pu, sc, 0, c_bottom), sample(pv, sc, 0, c_bottom)
        out[row:row + 3] = bytes(rgb_triple(sample(py, sy, 0, y_top),
                                            (3 * tl_u + l_u + 2) >> 2,
                                            (3 * tl_v + l_v + 2) >> 2))
        if y_bottom >= 0:
            out[low:low + 3] = bytes(rgb_triple(sample(py, sy, 0, y_bottom),
                                                (3 * l_u + tl_u + 2) >> 2,
                                                (3 * l_v + tl_v + 2) >> 2))
        last = (w - 1) >> 1
        for x in range(1, last + 1):
            t_u, t_v = sample(pu, sc, x, c_top), sample(pv, sc, x, c_top)
            h_u, h_v = sample(pu, sc, x, c_bottom), sample(pv, sc, x, c_bottom)
            su, sv = tl_u + t_u + l_u + h_u + 8, tl_v + t_v + l_v + h_v + 8
            near_u, near_v = (su + 2 * (t_u + l_u)) >> 3, (sv + 2 * (t_v + l_v)) >> 3
            far_u, far_v = (su + 2 * (tl_u + h_u)) >> 3, (sv + 2 * (tl_v + h_v)) >> 3
            at = row + (2 * x - 1) * 3
            out[at:at + 3] = bytes(rgb_triple(sample(py, sy, 2 * x - 1, y_top),
                                              (near_u + tl_u) >> 1, (near_v + tl_v) >> 1))
            at = row + 2 * x * 3
            out[at:at + 3] = bytes(rgb_triple(sample(py, sy, 2 * x, y_top),
                                              (far_u + t_u) >> 1, (far_v + t_v) >> 1))
            if y_bottom >= 0:
                at = low + (2 * x - 1) * 3
                out[at:at + 3] = bytes(rgb_triple(sample(py, sy, 2 * x - 1, y_bottom),
                                                  (far_u + l_u) >> 1, (far_v + l_v) >> 1))
                at = low + 2 * x * 3
                out[at:at + 3] = bytes(rgb_triple(sample(py, sy, 2 * x, y_bottom),
                                                  (near_u + h_u) >> 1, (near_v + h_v) >> 1))
            tl_u, tl_v, l_u, l_v = t_u, t_v, h_u, h_v
        if w % 2 == 0 and w > 1:
            column = (w - 1) * 3
            out[row + column:row + column + 3] = bytes(
                rgb_triple(sample(py, sy, w - 1, y_top),
                           (3 * tl_u + l_u + 2) >> 2, (3 * tl_v + l_v + 2) >> 2))
            if y_bottom >= 0:
                out[low + column:low + column + 3] = bytes(
                    rgb_triple(sample(py, sy, w - 1, y_bottom),
                               (3 * l_u + tl_u + 2) >> 2, (3 * l_v + tl_v + 2) >> 2))

    emit(0, -1, 0, 0)
    pair = 0
    while 2 * pair + 2 < h:
        emit(2 * pair + 1, 2 * pair + 2, pair, pair + 1)
        pair += 1
    if h % 2 == 0 and h > 1:
        emit(h - 1, -1, h // 2 - 1, h // 2 - 1)
    return bytes(out)


def main():
    for path in sys.argv[1:]:
        f, py, pu, pv, sy, sc, info = decode(path, verbose=True)
        got = to_rgb(f, py, pu, pv, sy, sc)
        want = Image.open(path).convert("RGB").tobytes()
        bad = sum(1 for a, b in zip(got, want) if a != b)
        worst = max((abs(a - b) for a, b in zip(got, want)), default=0)
        print("%s %dx%d differing %d of %d, worst %d"
              % (path, f.width, f.height, bad, len(want), worst))
        if bad:
            shown = 0
            for i, (a, b) in enumerate(zip(got, want)):
                if a != b and shown < 8:
                    p = i // 3
                    print("   at (%d,%d) ch %d: got %d want %d"
                          % (p % f.width, p // f.width, i % 3, a, b))
                    shown += 1


if __name__ == "__main__":
    main()
