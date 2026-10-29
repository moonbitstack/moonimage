# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0

"""Drawing the plate the homepage shows.

    python scripts/docs/plate.py

A lens test plate, drawn here rather than photographed: concentric rings for
resolution, a colour strip, a step wedge, and rulings of falling pitch. It is
written once and committed, so the page has an image of a known size and known
pixels; the demo then reads it with the library, which is the point.

Everything is deterministic — the grain is a seeded generator — so a rerun of
this script gives the same file back.
"""

import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "docs" / "plate.png"

WIDTH, HEIGHT = 1200, 800

PAPER = (238, 229, 212)
INK = (38, 30, 24)
FAINT = (150, 133, 110)

# A muted strip: these are patches to look at, not to print with.
COLOURS = [
    (222, 208, 184),
    (196, 152, 74),
    (86, 128, 108),
    (58, 84, 110),
    (150, 72, 62),
    (124, 96, 128),
    (44, 42, 40),
    (246, 241, 230),
]


def serif(size):
    """The plate's lettering. A missing face falls back to the one Pillow has."""
    for name in ("georgia.ttf", "times.ttf", "DejaVuSerif.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def spaced(draw, xy, text, font, fill, tracking=3):
    """Lettering with the letters spread out, as an engraving would have it."""
    x, y = xy
    for character in text:
        draw.text((x, y), character, font=font, fill=fill)
        x += draw.textlength(character, font=font) + tracking


def star(draw, centre, radius, spokes=48):
    """A Siemens star: wedges meeting at the centre, so blur shows at the hub."""
    cx, cy = centre
    for index in range(spokes):
        start = index * 360 / spokes
        end = start + 180 / spokes
        if index % 2 == 0:
            draw.pieslice(
                [cx - radius, cy - radius, cx + radius, cy + radius],
                start=start - 90,
                end=end - 90,
                fill=INK,
            )


def rulings(draw, box, pitch, vertical=False):
    """A patch of lines at a fixed pitch, for judging how far detail survives."""
    x0, y0, x1, y1 = box
    draw.rectangle(box, outline=FAINT, width=1)
    if vertical:
        x = x0 + pitch
        while x < x1 - 1:
            draw.line([(x, y0 + 2), (x, y1 - 2)], fill=INK, width=1)
            x += pitch * 2
    else:
        y = y0 + pitch
        while y < y1 - 1:
            draw.line([(x0 + 2, y), (x1 - 2, y)], fill=INK, width=1)
            y += pitch * 2


def plate():
    image = Image.new("RGB", (WIDTH, HEIGHT), PAPER)
    draw = ImageDraw.Draw(image)

    # The paper is lit from the top left, and the fall-off is what a photograph
    # of paper looks like: a slight darkening towards the far corner.
    for y in range(HEIGHT):
        for step in range(0, WIDTH, 4):
            shade = 1.0 - 0.10 * ((step / WIDTH) ** 2 + (y / HEIGHT) ** 2)
            value = tuple(int(channel * shade) for channel in PAPER)
            draw.rectangle([step, y, step + 3, y], fill=value)

    # Two rules, as on a plate that was meant to be handled.
    draw.rectangle([36, 36, WIDTH - 37, HEIGHT - 37], outline=INK, width=2)
    draw.rectangle([48, 48, WIDTH - 49, HEIGHT - 49], outline=FAINT, width=1)

    # Corner registration marks.
    for cx, cy, dx, dy in (
        (48, 48, 1, 1),
        (WIDTH - 49, 48, -1, 1),
        (48, HEIGHT - 49, 1, -1),
        (WIDTH - 49, HEIGHT - 49, -1, -1),
    ):
        draw.line([(cx, cy), (cx + 46 * dx, cy)], fill=INK, width=2)
        draw.line([(cx, cy), (cx, cy + 46 * dy)], fill=INK, width=2)

    title = serif(30)
    small = serif(17)
    spaced(draw, (110, 82), "MOONIMAGE", title, INK, tracking=6)
    draw.text((110, 124), "TEST PLATE 07", font=small, fill=FAINT)
    draw.text(
        (110, 148),
        "%d x %d  -  grey, colour, resolution, rulings" % (WIDTH, HEIGHT),
        font=small,
        fill=FAINT,
    )

    # The star sits where the eye lands first.
    star(draw, (390, 430), 210)
    draw.ellipse([176, 216, 604, 644], outline=FAINT, width=1)
    draw.text((352, 668), "SIEMENS STAR / 48", font=small, fill=FAINT)

    # Grey wedge: sixteen steps, black to paper.
    left, right, top, bottom = 686, 1104, 560, 626
    step = (right - left) / 16
    for index in range(16):
        value = int(round(255 * (index / 15)))
        x0 = left + index * step
        draw.rectangle([x0, top, x0 + step, bottom], fill=(value, value, value))
    draw.rectangle([left, top, right, bottom], outline=INK, width=1)
    draw.text((left, bottom + 12), "STEP WEDGE / 16", font=small, fill=FAINT)

    # Colour patches, above the wedge.
    left, right, top = 686, 1104, 186
    width = (right - left) / len(COLOURS)
    for index, colour in enumerate(COLOURS):
        x0 = left + index * width
        draw.rectangle([x0, top, x0 + width, top + 110], fill=colour)
    draw.rectangle([left, top, right, top + 110], outline=INK, width=1)
    draw.text((left, top + 122), "COLOUR / 8", font=small, fill=FAINT)

    # Rulings: four patches, two of them finely pitched, to see where a codec
    # stops resolving. A quarter-tone picture is the hardest thing to keep.
    rulings(draw, (686, 330, 886, 430), 4)
    rulings(draw, (906, 330, 1104, 430), 2)
    rulings(draw, (686, 450, 886, 540), 3, vertical=True)
    rulings(draw, (906, 450, 1104, 540), 2, vertical=True)

    # What the plate is for, in the space under the star.
    caption = serif(19)
    spaced(draw, (110, 700), "SIDE A", caption, FAINT, tracking=4)
    draw.text(
        (110, 730),
        "read and written by the library, in the browser",
        font=small,
        fill=FAINT,
    )

    # Grain, so the flat areas are not flat: a few levels either way, in blocks
    # of two pixels. Per-pixel grain would be truer to film and would triple the
    # file, because nothing about it repeats.
    noise = random.Random(7)
    pixels = image.load()
    for y in range(0, HEIGHT, 2):
        for x in range(0, WIDTH, 2):
            level = noise.randint(-4, 4)
            for dy in range(2):
                for dx in range(2):
                    if x + dx < WIDTH and y + dy < HEIGHT:
                        r, g, b = pixels[x + dx, y + dy]
                        pixels[x + dx, y + dy] = (r + level, g + level, b + level)

    return image


def main():
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    image = plate()
    image.save(TARGET, format="PNG", optimize=True)
    print("wrote %s (%d bytes)" % (TARGET, TARGET.stat().st_size))


if __name__ == "__main__":
    main()
