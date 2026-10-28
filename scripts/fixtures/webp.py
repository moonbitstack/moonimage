# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0

"""Generating the WebP fixtures.

    python scripts/fixtures/webp.py

Neither codec has a range of acceptable answers — a lossless file has one correct
decoding, and a lossy one has whatever libwebp reconstructs, which is what the
reader here reproduces — so the reference is a digest of the pixels libwebp reads
back: no tolerance, no colour conversion, a byte out of place is a failure.

The shapes are the ones that exercise a different part of the format — a plain
picture, one with alpha, a flat one that is all back-references, one with few
enough colours for the palette transform, a size that is not a multiple of the
block grid, a single pixel, and a picture big enough for libwebp to split into
several prefix code groups. The lossy half adds quality settings from ten to a
hundred, which decide how much residue there is to get wrong and how hard the
encoder filters, and a transparent picture whose alpha lives in its own chunk.
"""

import hashlib
import io
import subprocess
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import moonbit
import sources

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "src" / "webp" / "samples_test.mbt"


def lossless(image: Image.Image, **options) -> bytes:
    handle = io.BytesIO()
    image.save(handle, format="WEBP", lossless=True, quality=100, **options)
    return handle.getvalue()


def lossy(image: Image.Image, quality: int = 90, method: int = 6) -> bytes:
    """A lossy WebP: the other codec, and the one with a loop filter."""
    handle = io.BytesIO()
    image.save(handle, format="WEBP", lossless=False, quality=quality, method=method)
    return handle.getvalue()


def digest_of(data: bytes) -> str:
    """The digest the decoder's own `digest` helper computes, of RGBA bytes."""
    return moonbit.digest(data)


def reference(data: bytes) -> tuple[bytes, int, int]:
    decoded = Image.open(io.BytesIO(data))
    decoded.load()
    rgba = decoded.convert("RGBA")
    return rgba.tobytes(), rgba.width, rgba.height


def build_stills() -> list[tuple[str, bytes]]:
    base = sources.pattern(64, 48).convert("RGB")
    cases = [
        ("lossless-rgb", lossless(base, method=6)),
        ("lossless-rgba", lossless(sources.pattern(64, 48), method=6)),
        ("lossless-flat", lossless(sources.flat(40, 30), method=6)),
        (
            "lossless-palette",
            lossless(
                base.convert("P", palette=Image.ADAPTIVE, colors=8).convert("RGB"),
                method=6,
            ),
        ),
        ("lossless-odd", lossless(base.crop((0, 0, 37, 23)), method=6)),
        ("lossless-one", lossless(Image.new("RGBA", (1, 1), (7, 9, 11, 200)))),
        ("lossless-wide", lossless(sources.pattern(160, 120), method=6)),
    ]
    # The same picture at the encoder's fastest setting, which picks different
    # transforms and different trees.
    cases.append(("lossless-fast", lossless(base, method=0)))
    # The lossy codec. VP8 reconstructs by prediction and residue, so what it
    # exercises is nothing like the lossless path: the mode trees, the three
    # coefficient contexts, the transforms, the loop filter, and the chroma
    # upsampling. Quality decides how much residue there is to get wrong and how
    # hard the encoder filters, so the range runs from almost transparent to
    # very lossy.
    cases.append(("lossy-pattern", lossy(base, 90)))
    cases.append(("lossy-flat", lossy(sources.flat(40, 30).convert("RGB"), 90)))
    cases.append(("lossy-odd", lossy(base.crop((0, 0, 37, 23)), 90)))
    cases.append(("lossy-wide", lossy(sources.pattern(160, 120, "RGB"), 75)))
    cases.append(("lossy-low", lossy(base, 10)))
    cases.append(("lossy-clean", lossy(base, 100)))
    cases.append(("lossy-one", lossy(Image.new("RGB", (1, 1), (9, 200, 90)), 90)))
    # Transparency in a lossy file lives in its own chunk, coded with the other
    # codec and filtered along the rows, so it is a separate path to get right.
    cases.append(("lossy-alpha", lossy(sources.pattern(64, 48), 80)))
    cases.append(("lossy-alpha-odd", lossy(sources.pattern(37, 23), 80)))
    # The alpha chunk's four row filters. The first is what an encoder picks in
    # practice; the other three are built and then confirmed against libwebp.
    cases.extend(alpha_filtered_files())
    return cases


def build_animations() -> list[tuple[str, bytes]]:
    """Animated files, one of each codec.

    Every frame is the whole canvas, which is the only shape where the digest of
    what the decoder composes can be compared with what Pillow composes. The
    third frame is translucent, so blending a frame over the one before it is
    part of what is being checked; in a lossy file its alpha travels in an
    `ALPH` chunk inside the frame record, which is a path no still image reaches.
    """
    base = sources.pattern(64, 48)
    frames = [
        base,
        base.rotate(180),
        sources.flat(64, 48, (200, 40, 90, 128)),
    ]
    out = []
    for name, lossless_flag in (("animation-lossy", False), ("animation-lossless", True)):
        handle = io.BytesIO()
        frames[0].save(
            handle,
            format="WEBP",
            save_all=True,
            append_images=frames[1:],
            duration=[100, 60, 90],
            loop=3,
            lossless=lossless_flag,
            quality=80,
            method=6,
        )
        out.append((name, handle.getvalue()))
    return out


def alpha_filter(plane: bytes, width: int, height: int, method: int) -> bytes:
    """The forward filter the `ALPH` chunk applies, one of the four methods.

    The inverse is a predictor added back to each residual, so this is the same
    predictor subtracted: the pixel to the left for a horizontal row, the one
    above for a vertical column, and the clamped left-plus-above-minus-corner for
    the gradient. The first row has nothing above it and uses the horizontal rule
    alone, which is what the decoder does too.
    """
    out = bytearray(len(plane))

    def at(x, y):
        return plane[y * width + x]

    for y in range(height):
        for x in range(width):
            if method == 0:
                predicted = 0
            elif method == 1:
                predicted = at(x - 1, y) if x > 0 else (at(0, y - 1) if y > 0 else 0)
            elif y == 0:
                predicted = at(x - 1, y) if x > 0 else 0
            elif method == 2:
                predicted = at(x, y - 1)
            else:
                left = at(x - 1, y) if x > 0 else at(0, y - 1)
                above = at(x, y - 1)
                corner = at(x - 1, y - 1) if x > 0 else above
                predicted = min(255, max(0, left + above - corner))
            out[y * width + x] = (at(x, y) - predicted) & 0xFF
    return bytes(out)


def alpha_filtered_files() -> list[tuple[str, bytes]]:
    """The same picture with its alpha stored each of the four ways.

    A transparent lossy file says in one byte how its alpha is filtered, and the
    encoders in the wild pick the first method almost always, so the other three
    would never be reached by a fixture written by an encoder. They are built here
    instead: the plane is filtered by hand and the chunk is dropped into a real
    file, and the result is kept only if libwebp reads the alpha back unchanged,
    which is what makes it a reference rather than an assertion about our own
    arithmetic. What compression each file uses is still whatever the encoder
    chose, so only the filter differs.
    """
    source = lossy(sources.pattern(64, 48), 80)
    image = Image.open(io.BytesIO(source)).convert("RGBA")
    width, height = image.size
    plane = image.getchannel("A").tobytes()
    structure = {}
    at = 12
    while at + 8 <= len(source):
        name = source[at:at + 4]
        size = int.from_bytes(source[at + 4:at + 8], "little")
        if name in (b"VP8X", b"VP8 "):
            structure[name] = source[at + 8:at + 8 + size]
        at += 8 + size + (size & 1)

    def chunk(name, payload):
        body = name + len(payload).to_bytes(4, "little") + payload
        return body + (b"\x00" if len(payload) & 1 else b"")

    out = []
    for method in (0, 1, 2, 3):
        # The order is the format's: the extended header, then the alpha it
        # announces, then the picture that has none of its own.
        payload = bytes([method << 2]) + alpha_filter(plane, width, height, method)
        body = b"WEBP"
        body += chunk(b"VP8X", structure[b"VP8X"])
        body += chunk(b"ALPH", payload)
        body += chunk(b"VP8 ", structure[b"VP8 "])
        file = b"RIFF" + len(body).to_bytes(4, "little") + body
        back = Image.open(io.BytesIO(file)).convert("RGBA").getchannel("A").tobytes()
        if back != plane:
            raise SystemExit("libwebp disagrees about alpha filter %d" % method)
        out.append(("lossy-alpha-filter-%d" % method, file))
    return out


def vp8_payload(data: bytes) -> tuple[bytes, int, int]:
    """The `VP8 ` chunk on its own, with the size it decodes to."""
    at = 12
    while at + 8 <= len(data):
        name = data[at:at + 4]
        size = int.from_bytes(data[at + 4:at + 8], "little")
        if name == b"VP8 ":
            image = Image.open(io.BytesIO(data))
            return data[at + 8:at + 8 + size], image.width, image.height
        at += 8 + size + (size & 1)
    raise SystemExit("no VP8 chunk")


def alpha_chunk(data: bytes) -> tuple[bytes, int, int]:
    """The `ALPH` payload of a file, with the size it decodes to."""
    at = 12
    while at + 8 <= len(data):
        name = data[at:at + 4]
        size = int.from_bytes(data[at + 4:at + 8], "little")
        if name == b"ALPH":
            x, y = Image.open(io.BytesIO(data)).size
            return data[at + 8:at + 8 + size], x, y
        at += 8 + size + (size & 1)
    raise SystemExit("no ALPH chunk")


def format_generated() -> None:
    """Run the formatter, because the tree is checked for being formatted.

    The generated file is a source file like any other: if `moon fmt` would
    change a line of it, the continuous integration run fails on the difference.
    Formatting here means a rerun of this script produces a file that is ready to
    commit, rather than one that needs a second step nobody remembers.
    """
    subprocess.run(["moon", "fmt"], cwd=ROOT, check=True, shell=(sys.platform == "win32"))


_CACHE: dict[str, list[tuple[str, bytes]]] = {}


def stills() -> list[tuple[str, bytes]]:
    """The still pictures, encoded once however many times they are asked for.

    Encoding is the slow part of this script — every picture goes through the
    reference encoder at its slowest setting — and the lists below each want the
    same set, so the work is done on the first call and kept.
    """
    if "stills" not in _CACHE:
        _CACHE["stills"] = build_stills()
    return _CACHE["stills"]


def animations() -> list[tuple[str, bytes]]:
    """The animated files, encoded once."""
    if "animations" not in _CACHE:
        _CACHE["animations"] = build_animations()
    return _CACHE["animations"]


def main() -> None:
    lines = ["// Copyright 2026 Leo Cheng", "// SPDX-License-Identifier: Apache-2.0", ""]
    lines.append("// Generated by scripts/fixtures/webp.py. Do not edit by hand.")
    lines.append("")
    lines.append("///|")
    lines.append(
        "/// WebP files written by libwebp, with a digest of the pixels it reads back."
    )
    lines.append("let webp_samples : Array[(String, Bytes, String)] = [")
    for name, data in stills():
        pixels, width, height = reference(data)
        digest = digest_of(pixels)
        lines.append("  (")
        lines.append('    "%s",' % name)
        lines.append("    %s," % moonbit.literal(data))
        lines.append('    "%s",' % digest)
        lines.append("  ),")
    lines.append("]")
    lines.append("")
    lines.append("///|")
    lines.append("/// Animated files written by libwebp: the bytes, and the digest of every")
    lines.append("/// frame as Pillow composes it onto the canvas.")
    lines.append("let webp_animations : Array[(String, Bytes)] = [")
    for name, data in animations():
        lines.append("  (")
        lines.append('    "%s",' % name)
        lines.append("    %s," % moonbit.literal(data))
        lines.append("  ),")
    lines.append("]")
    lines.append("")
    lines.append("///|")
    lines.append("let webp_animation_frames : Array[(String, Array[String])] = [")
    for name, data in animations():
        digests = []
        decoded = Image.open(io.BytesIO(data))
        for index in range(decoded.n_frames):
            decoded.seek(index)
            digests.append(moonbit.digest(decoded.convert("RGBA").tobytes()))
        lines.append(
            '  ("%s", [%s]),' % (name, ", ".join('"%s"' % d for d in digests))
        )
    lines.append("]")
    lines.append("")
    lines.append("///|")
    lines.append("let webp_animation_shape : Array[(String, Int, Int, Int)] = [")
    for name, data in animations():
        decoded = Image.open(io.BytesIO(data))
        lines.append(
            '  ("%s", %d, %d, %d),'
            % (name, decoded.width, decoded.height, decoded.n_frames)
        )
    lines.append("]")
    lines.append("")
    lines.append("///|")
    lines.append("/// One `ALPH` chunk on its own, with the size and the alpha bytes it")
    lines.append("/// decodes to, so that the chunk reader can be tested without a container.")
    lines.append("let webp_alpha_chunk : (Bytes, Int, Int, String) = (")
    chunk, chunk_width, chunk_height = alpha_chunk(dict(stills())["lossy-alpha"])
    alpha_bytes = Image.open(io.BytesIO(dict(stills())["lossy-alpha"])).convert("RGBA")
    plane = bytes(
        alpha_bytes.getpixel((x, y))[3]
        for y in range(alpha_bytes.height)
        for x in range(alpha_bytes.width)
    )
    lines.append("  %s," % moonbit.literal(chunk))
    lines.append("  %d," % chunk_width)
    lines.append("  %d," % chunk_height)
    lines.append('  "%s",' % moonbit.digest(plane))
    lines.append(")")
    lines.append("")
    lines.append("///|")
    lines.append("/// The `VP8 ` chunk of one sample on its own, so that the codec's own")
    lines.append("/// guards can be tested without a container around them.")
    lines.append("let webp_lossy_payload : (Bytes, Int, Int) = (")
    payload, payload_width, payload_height = vp8_payload(dict(stills())["lossy-pattern"])
    lines.append("  %s," % moonbit.literal(payload))
    lines.append("  %d," % payload_width)
    lines.append("  %d," % payload_height)
    lines.append(")")
    lines.append("")
    lines.append("///|")
    lines.append("/// The shape each sample decodes to, so that a failure can say which one.")
    lines.append("let webp_samples_size : Array[(String, Int, Int)] = [")
    for name, data in stills():
        _, width, height = reference(data)
        lines.append('  ("%s", %d, %d),' % (name, width, height))
    lines.append("]")
    TARGET.write_text("\n".join(lines) + "\n", encoding="utf-8")
    format_generated()
    print("wrote", TARGET, "with", len(stills()), "samples")


if __name__ == "__main__":
    main()
