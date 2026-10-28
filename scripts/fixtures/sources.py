# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0

"""Where the fixtures come from.

Two kinds of source. The PngSuite images are somebody else's test suite, with a
reference decoding published beside them; the samples for the other formats are
generated here, by Pillow, from images this file makes deterministic.

The downloads land in .cache/, which is ignored, so a rerun does not fetch them
again and a fresh checkout needs one network round trip per source.
"""

import io
import json
import os
import urllib.request
import zipfile
from pathlib import Path

from PIL import Image

CACHE = Path(__file__).resolve().parents[2] / ".cache" / "fixtures"

PNG_SUITE = "https://codeload.github.com/lunapaint/pngsuite/zip/refs/heads/main"


def _fetch(url: str, name: str) -> bytes:
    CACHE.mkdir(parents=True, exist_ok=True)
    target = CACHE / name
    if target.exists():
        return target.read_bytes()
    # The environment may tell urllib to use a proxy that is not there; these
    # are plain public downloads and go out directly.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(url, timeout=120) as response:
        data = response.read()
    target.write_bytes(data)
    return data


def png_suite() -> dict[str, bytes]:
    """Every PNG of PngSuite, by name without the extension."""
    archive = _fetch(PNG_SUITE, "pngsuite.zip")
    images = {}
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        for entry in bundle.namelist():
            parts = entry.split("/")
            if len(parts) == 3 and parts[1] == "png" and entry.endswith(".png"):
                images[parts[2][: -len(".png")]] = bundle.read(entry)
    return images


def png_suite_reference() -> dict[str, list[int]]:
    """PngSuite's own reference decoding: four numbers per pixel, r, g, b, a.

    Sixteen-bit images carry sixteen-bit values, eight-bit ones carry eight. The
    generator scales the latter to sixteen so that one digest covers both.
    """
    archive = _fetch(PNG_SUITE, "pngsuite.zip")
    references = {}
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        for entry in bundle.namelist():
            parts = entry.split("/")
            if len(parts) == 3 and parts[1] == "json" and entry.endswith(".json"):
                references[parts[2][: -len(".json")]] = json.loads(bundle.read(entry))
    return references


def pattern(width: int, height: int, mode: str = "RGBA") -> Image.Image:
    """A deterministic image with the parts a codec has to get right.

    Four quadrants: a horizontal ramp, a diagonal of single-pixel noise, a flat
    colour, and a radial gradient with alpha falling off. Between them they
    exercise runs, differences, literals with and without alpha, and edges.
    """
    image = Image.new(mode, (width, height))
    pixels = image.load()
    half_x = width // 2
    half_y = height // 2
    seed = 0x12345678
    for y in range(height):
        for x in range(width):
            if x < half_x and y < half_y:
                r = (x * 255) // max(1, half_x - 1)
                g = (y * 255) // max(1, half_y - 1)
                b = 64
                a = 255
            elif x >= half_x and y < half_y:
                seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
                r = seed & 0xFF
                g = (seed >> 8) & 0xFF
                b = (seed >> 16) & 0xFF
                a = 255
            elif x < half_x and y >= half_y:
                r, g, b, a = 200, 30, 90, 255
            else:
                dx = (x - half_x) - half_x / 2
                dy = (y - half_y) - half_y / 2
                distance = (dx * dx + dy * dy) ** 0.5
                radius = max(1.0, min(half_x, half_y) / 2)
                r = min(255, int(distance * 255 / radius))
                g = min(255, 255 - int(distance * 255 / radius))
                b = 128
                a = max(0, 255 - int(distance * 255 / radius))
            if mode == "RGBA":
                pixels[x, y] = (r, g, b, a)
            else:
                pixels[x, y] = (r, g, b)
    return image


def flat(width: int, height: int, colour=(17, 34, 51, 255)) -> Image.Image:
    """One colour, which is the shortest possible run."""
    return Image.new("RGBA", (width, height), colour)
