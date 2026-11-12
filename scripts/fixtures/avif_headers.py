"""Generate AVIF header vectors for the MoonBit AVIF reader.

The reference here is a second, independent transcription of the AV1 bitstream
syntax: the sequence header and the uncompressed frame header are read bit by
bit from the bytes that libavif wrote, following dav1d's `parse_seq_hdr` and
`parse_frame_hdr`. The values are then checked against the container's own
`ispe`, `pixi`, `av1C` and `colr` boxes, and against the picture Pillow decodes.

Usage:

    python3 scripts/fixtures/avif_headers.py

Requires Pillow with AVIF support. Writes src/avif/header_vectors_test.mbt.
"""

from __future__ import annotations

import io
import struct
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "src/avif/header_vectors_test.mbt"


def leb(data, at):
    value = 0
    shift = 0
    while True:
        byte = data[at]
        at += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if not (byte & 0x80):
            return value, at


class Bits:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def bit(self):
        value = (self.data[self.pos >> 3] >> (7 - (self.pos & 7))) & 1
        self.pos += 1
        return value

    def bits(self, count):
        value = 0
        for _ in range(count):
            value = (value << 1) | self.bit()
        return value

    def signed(self, count):
        value = self.bits(count)
        return value - (1 << count) if value & (1 << (count - 1)) else value

    def align(self):
        self.pos = (self.pos + 7) & ~7
        return self.pos >> 3


def tile_log2(size, target):
    k = 0
    while (size << k) < target:
        k += 1
    return k


def parse_sequence(bits):
    s = {}
    s["profile"] = bits.bits(3)
    s["still"] = bits.bit()
    s["reduced"] = bits.bit()
    if not (s["still"] and s["reduced"]):
        raise ValueError("only reduced still picture headers are in the vectors")
    s["major_level"] = bits.bits(3)
    s["minor_level"] = bits.bits(2)
    s["width_n_bits"] = bits.bits(4) + 1
    s["height_n_bits"] = bits.bits(4) + 1
    s["width"] = bits.bits(s["width_n_bits"]) + 1
    s["height"] = bits.bits(s["height_n_bits"]) + 1
    s["sb128"] = bits.bit()
    s["filter_intra"] = bits.bit()
    s["intra_edge_filter"] = bits.bit()
    s["super_res"] = bits.bit()
    s["cdef"] = bits.bit()
    s["restoration"] = bits.bit()
    s["hbd"] = bits.bit()
    if s["profile"] == 2 and s["hbd"]:
        s["hbd"] += bits.bit()
    s["monochrome"] = bits.bit() if s["profile"] != 1 else 0
    s["color_description"] = bits.bit()
    if s["color_description"]:
        s["pri"] = bits.bits(8)
        s["trc"] = bits.bits(8)
        s["mtrx"] = bits.bits(8)
    else:
        s["pri"] = s["trc"] = s["mtrx"] = 0
    if s["monochrome"]:
        s["color_range"] = bits.bit()
        s["ss_hor"] = s["ss_ver"] = 1
    else:
        s["color_range"] = bits.bit()
        if s["profile"] == 0:
            s["ss_hor"] = s["ss_ver"] = 1
        elif s["profile"] == 1:
            s["ss_hor"] = s["ss_ver"] = 0
        else:
            raise ValueError("profile 2 is not in the vectors")
        if s["ss_hor"] and s["ss_ver"]:
            s["chr"] = bits.bits(2)
    if not s["monochrome"]:
        s["separate_uv_delta_q"] = bits.bit()
    s["film_grain"] = bits.bit()
    return s


def parse_frame(bits, s, payload_length):
    """The reduced-still-picture key frame header, then the tile data span."""
    f = {}
    f["disable_cdf_update"] = bits.bit()
    allow_screen_content = bits.bit()
    f["allow_intrabc"] = 0
    if allow_screen_content:
        bits.bit()  # force_integer_mv, overridden to 1 for a key frame
    # refresh_frame_flags is 0xff for a shown key frame
    # read_frame_size: no override, no super-res bit when the sequence has none
    if s["super_res"]:
        bits.bit()
    f["have_render_size"] = bits.bit()
    if f["have_render_size"]:
        bits.bits(16)
        bits.bits(16)
    if allow_screen_content:
        f["allow_intrabc"] = bits.bit()

    # tiling
    f["uniform"] = bits.bit()
    sbsz_log2 = 6 + s["sb128"]
    sbw = (s["width"] + (64 << s["sb128"]) - 1) >> sbsz_log2
    sbh = (s["height"] + (64 << s["sb128"]) - 1) >> sbsz_log2
    min_log2_cols = tile_log2(4096 >> sbsz_log2, sbw)
    max_log2_cols = tile_log2(1, min(sbw, 64))
    max_log2_rows = tile_log2(1, min(sbh, 64))
    min_log2_tiles = max(
        tile_log2((4096 * 2304) >> (2 * sbsz_log2), sbw * sbh), min_log2_cols
    )
    if f["uniform"]:
        log2_cols = min_log2_cols
        while log2_cols < max_log2_cols and bits.bit():
            log2_cols += 1
        tile_w = 1 + ((sbw - 1) >> log2_cols)
        cols = len(range(0, sbw, tile_w))
        min_log2_rows = max(min_log2_tiles - log2_cols, 0)
        log2_rows = min_log2_rows
        while log2_rows < max_log2_rows and bits.bit():
            log2_rows += 1
        tile_h = 1 + ((sbh - 1) >> log2_rows)
        rows = len(range(0, sbh, tile_h))
    else:
        raise ValueError("non-uniform tiling is not in the vectors")
    f["cols"] = cols
    f["rows"] = rows
    if log2_cols or log2_rows:
        bits.bits(log2_cols + log2_rows)  # tiling.update
        f["n_bytes"] = bits.bits(2) + 1
    else:
        f["n_bytes"] = 0
    n_tiles = cols * rows

    # quantizer
    f["yac"] = bits.bits(8)
    ydc_delta = bits.signed(7) if bits.bit() else 0
    if not s["monochrome"]:
        diff_uv_delta = bits.bit() if s["separate_uv_delta_q"] else 0
        udc_delta = bits.signed(7) if bits.bit() else 0
        uac_delta = bits.signed(7) if bits.bit() else 0
        if diff_uv_delta:
            vdc_delta = bits.signed(7) if bits.bit() else 0
            vac_delta = bits.signed(7) if bits.bit() else 0
        else:
            vdc_delta, vac_delta = udc_delta, uac_delta
    else:
        udc_delta = uac_delta = vdc_delta = vac_delta = 0
    f["ydc_delta"] = ydc_delta
    f["udc_delta"] = udc_delta
    f["uac_delta"] = uac_delta
    f["vdc_delta"] = vdc_delta
    f["vac_delta"] = vac_delta
    f["qm"] = bits.bit()
    if f["qm"]:
        f["qm_y"] = bits.bits(4)
        f["qm_u"] = bits.bits(4)
        f["qm_v"] = bits.bits(4) if s["separate_uv_delta_q"] else f["qm_u"]
    else:
        f["qm_y"] = f["qm_u"] = f["qm_v"] = 0

    # segmentation
    f["segmentation"] = bits.bit()
    if f["segmentation"]:
        # primary_ref_frame is NONE, so update_map and update_data are both 1
        for _ in range(8):
            if bits.bit():
                bits.signed(9)
            for _ in range(4):
                if bits.bit():
                    bits.signed(7)
            if bits.bit():
                bits.bits(3)
            bits.bit()  # skip
            bits.bit()  # globalmv
    all_lossless = (
        f["yac"] == 0
        and not any(
            (ydc_delta, udc_delta, uac_delta, vdc_delta, vac_delta)
        )
    )
    f["all_lossless"] = int(all_lossless)

    # delta q / delta lf
    if f["yac"]:
        if bits.bit():
            bits.bits(2)
            if not f["allow_intrabc"] and bits.bit():
                bits.bits(2)
                bits.bit()

    # loop filter
    if all_lossless or f["allow_intrabc"]:
        f["lf_level"] = [0, 0, 0, 0]
        f["sharpness"] = 0
    else:
        y0 = bits.bits(6)
        y1 = bits.bits(6)
        u = v = 0
        if not s["monochrome"] and (y0 or y1):
            u = bits.bits(6)
            v = bits.bits(6)
        sharpness = bits.bits(3)
        if bits.bit() and bits.bit():
            for _ in range(8):
                if bits.bit():
                    bits.signed(7)
            for _ in range(2):
                if bits.bit():
                    bits.signed(7)
        f["lf_level"] = [y0, y1, u, v]
        f["sharpness"] = sharpness

    # cdef
    f["cdef_damping"] = 0
    f["cdef_bits"] = 0
    if not all_lossless and s["cdef"] and not f["allow_intrabc"]:
        f["cdef_damping"] = bits.bits(2) + 3
        f["cdef_bits"] = bits.bits(2)
        for _ in range(1 << f["cdef_bits"]):
            bits.bits(6)
            if not s["monochrome"]:
                bits.bits(6)
    f["cdef_strengths"] = 1 << f["cdef_bits"]

    # restoration is disabled in these sequences
    f["txfm_mode"] = bits.bit() if not all_lossless else 0
    f["reduced_txtp_set"] = bits.bit()
    header_bytes = bits.align()

    # tile group header: no start/end flag for a single tile, then byte align
    if n_tiles > 1:
        bits.bit()
        size_bytes = bits.align()
    else:
        size_bytes = bits.align()
    f["tile_at"] = size_bytes
    f["tile_length"] = payload_length - size_bytes
    f["header_bytes"] = header_bytes
    return f


def obus(payload):
    at = 0
    out = []
    while at < len(payload):
        head = payload[at]
        at += 1
        kind = (head >> 3) & 0xF
        extension = (head >> 2) & 1
        has_size = (head >> 1) & 1
        if extension:
            at += 1
        if has_size:
            size, at = leb(payload, at)
        else:
            size = len(payload) - at
        out.append((kind, at, size))
        at += size
        if not has_size:
            break
    return out


def box_children(data, start, end):
    at = start
    while at + 8 <= end:
        size = struct.unpack(">I", data[at : at + 4])[0]
        name = data[at + 4 : at + 8].decode("latin1")
        if size == 0:
            size = end - at
        yield name, at + 8, at + size
        at += size


def container_expectations(data):
    """Read the same metadata back from the ISOBMFF boxes."""
    expected = {}
    for name, at, end in box_children(data, 0, len(data)):
        if name == "meta":
            for child, cat, cend in box_children(data, at + 4, end):
                if child == "iprp":
                    for prop, pat, pend in box_children(data, cat, cend):
                        if prop == "ipco":
                            for kind, kt, ke in box_children(data, pat, pend):
                                if kind == "ispe":
                                    expected["width"] = struct.unpack(
                                        ">I", data[kt + 4 : kt + 8]
                                    )[0]
                                    expected["height"] = struct.unpack(
                                        ">I", data[kt + 8 : kt + 12]
                                    )[0]
                                elif kind == "pixi":
                                    expected["channels"] = data[kt + 4]
                                    expected["bits"] = data[kt + 5]
                                elif kind == "av1C":
                                    expected["profile"] = data[kt + 5] >> 5
                                    expected["level"] = data[kt + 5] & 0x1F
                                    expected["ss"] = (data[kt + 6] >> 2) & 3
                                elif kind == "colr":
                                    expected["pri"] = struct.unpack(
                                        ">H", data[kt + 4 : kt + 6]
                                    )[0]
                                    expected["trc"] = struct.unpack(
                                        ">H", data[kt + 6 : kt + 8]
                                    )[0]
                                    expected["mtrx"] = struct.unpack(
                                        ">H", data[kt + 8 : kt + 10]
                                    )[0]
                                    expected["range"] = 1 if data[kt + 10] & 0x80 else 0
    return expected


def make_cases():
    rng = np.random.default_rng(20261112)
    cases = []
    for width, height, quality in ((17, 11, 90), (64, 64, 70), (37, 23, 40), (8, 8, 100)):
        picture = rng.integers(0, 256, (height, width, 3), dtype=np.uint8)
        handle = io.BytesIO()
        Image.fromarray(picture).save(handle, format="AVIF", quality=quality)
        file = handle.getvalue()
        at = file.find(b"mdat") + 4
        payload = file[at:]
        frames = obus(payload)
        seq_obu = next(o for o in frames if o[0] == 1)
        frame_obu = next(o for o in frames if o[0] == 6)
        seq = parse_sequence(Bits(payload[seq_obu[1] : seq_obu[1] + seq_obu[2]]))
        frame = parse_frame(
            Bits(payload[frame_obu[1] : frame_obu[1] + frame_obu[2]]),
            seq,
            frame_obu[2],
        )
        expected = container_expectations(file)
        decoded = Image.open(io.BytesIO(file))
        assert decoded.size == (width, height)
        assert seq["width"] == expected["width"] == width
        assert seq["height"] == expected["height"] == height
        assert seq["profile"] == expected["profile"]
        assert seq["pri"] == expected["pri"]
        assert seq["trc"] == expected["trc"]
        assert seq["mtrx"] == expected["mtrx"]
        assert seq["color_range"] == expected["range"]
        assert expected["bits"] == 8
        assert frame["tile_length"] > 0
        cases.append((f"{width}x{height}-q{quality}", file, seq, frame, expected))
    return cases


def moonbit_bytes(data: bytes) -> str:
    return 'b"' + "".join("\\x%02x" % b for b in data) + '"'


def main() -> None:
    cases = make_cases()
    lines = [
        "// Copyright 2026 Leo Cheng",
        "// SPDX-License-Identifier: Apache-2.0",
        "//",
        "// Generated by scripts/fixtures/avif_headers.py. Do not edit.",
        "//",
        "// AVIF files written by libavif, with the values an independent reading",
        "// of the AV1 sequence and frame headers produced. The reader is held to",
        "// the container's ispe/pixi/av1C/colr boxes and to Pillow's picture.",
        "",
        "///|",
        "let avif_header_cases : Array[(String, Bytes, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)] = [",
    ]
    for name, file, seq, frame, expected in cases:
        lines.append("  (")
        lines.append('    "%s",' % name)
        lines.append("    %s," % moonbit_bytes(file))
        lines.append("    %d, // width" % seq["width"])
        lines.append("    %d, // height" % seq["height"])
        lines.append("    %d, // profile" % seq["profile"])
        lines.append("    %d, // bit depth" % expected["bits"])
        lines.append("    %d, // chroma subsampling x" % seq["ss_hor"])
        lines.append("    %d, // chroma subsampling y" % seq["ss_ver"])
        lines.append("    %d, // primaries" % seq["pri"])
        lines.append("    %d, // transfer" % seq["trc"])
        lines.append("    %d, // matrix" % seq["mtrx"])
        lines.append("    %d, // full range" % seq["color_range"])
        lines.append("    %d, // quantizer index" % frame["yac"])
        lines.append("    %d, // tile data begins at this byte of the frame OBU" % frame["tile_at"])
        lines.append("  ),")
    lines += [
        "]",
        "",
    ]
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(
        "wrote %s: %d AVIF files, %d bytes in total"
        % (OUT, len(cases), sum(len(c[1]) for c in cases))
    )


if __name__ == "__main__":
    main()
