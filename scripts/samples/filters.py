# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0

"""The resampling filters and the blur, counted against Pillow pixel by pixel.

    python scripts/samples/filters.py [--moon PATH]

The tests in `src/raster` hold each filter to a bound of one step of a sample.
This is the measurement behind that bound: the same picture, the same
parameters, and a table of how far apart the two implementations land, with the
largest difference and how many pixels are one step away.

Four of the five resampling filters have a Pillow counterpart — nearest,
bilinear, the cubic Pillow calls bicubic, and the Lanczos window. The fifth, a
Gaussian weighted by the distance from the centre of the output pixel, has none:
Pillow's `resize` does not take a kernel, and its Gaussian is a filter applied to
a picture rather than a way to resample one. That row is measured against the
convolution the definition gives, computed here, and it is labelled as such.

The blur has two rows: this library convolves with the kernel, Pillow applies
three box passes, and the library can do either.
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "fixtures"))

ROOT = Path(__file__).resolve().parents[2]

# The picture the fixtures are made from, and the sizes and radii they are made
# at: smaller in both directions, larger in both, and taller than it is wide.
SIZES = [(7, 5), (26, 18), (13, 4)]
RADII = [0.8, 1.5, 3.0]

FILTERS = [
    ("nearest", Image.Resampling.NEAREST),
    ("bilinear", Image.Resampling.BILINEAR),
    ("catmull-rom", Image.Resampling.BICUBIC),
    ("gaussian", None),
    ("lanczos", Image.Resampling.LANCZOS),
]


def build_moon() -> Path:
    """The command the statistics are taken with, built for this machine."""
    subprocess.run(["moon", "work", "sync", "-q"], cwd=ROOT, check=False)
    harness = ROOT / "integration" / "samples"
    outcome = subprocess.run(
        ["moon", "build", "src/main", "--target", "native", "--release"],
        cwd=harness,
        capture_output=True,
        text=True,
    )
    if outcome.returncode != 0:
        sys.exit("cannot build the harness:\n" + outcome.stdout + outcome.stderr)
    for candidate in (
        ROOT
        / "_build/native/release/build/moonbitstack/moonimage-samples/main/main.exe",
        ROOT / "_build/native/release/build/moonbitstack/moonimage-samples/main/main",
    ):
        if candidate.exists():
            return candidate
    sys.exit("the harness was built somewhere unexpected")


def picture(width: int, height: int) -> Image.Image:
    """A gradient that changes in every direction with a hard edge in it, which
    is the picture every fixture in this repository is made from."""
    out = np.zeros((height, width, 4), dtype=np.uint8)
    for y in range(height):
        for x in range(width):
            out[y, x, 0] = (x * 17 + y * 3) % 256
            out[y, x, 1] = (y * 29) % 256
            out[y, x, 2] = 128 + ((x * 7 + y * 3) % 5) * 16
            out[y, x, 3] = 255
    return Image.fromarray(out, "RGBA")


def gaussian_resample(source: Image.Image, size, sigma=0.5, reach=3.0):
    """A Gaussian weighted by the distance from the centre of the output pixel,
    which is the filter this library calls gaussian and Pillow has no name for.

    The footprint widens with the ratio, so a downscale averages everything the
    output pixel stands for instead of sampling one of them.
    """
    pixels = np.asarray(source).astype(np.float64)
    for axis, target in ((1, size[0]), (0, size[1])):
        pixels = resample_axis(pixels, axis, target, sigma, reach)
    return np.clip(np.rint(pixels), 0, 255).astype(np.uint8)


def resample_axis(pixels, axis, target, sigma, reach):
    """One axis of the separable Gaussian: every output position is a weighted
    sum of the input samples its footprint reaches."""
    source_length = pixels.shape[axis]
    ratio = source_length / target
    scale = max(ratio, 1.0)
    support = reach * sigma * scale
    shape = list(pixels.shape)
    shape[axis] = target
    out = np.zeros(shape)
    for i in range(target):
        centre = (i + 0.5) * ratio
        first = int(np.floor(centre - support + 0.5))
        last = int(np.floor(centre + support + 0.5)) - 1
        taps = []
        for index in range(first, last + 1):
            if index < 0 or index >= source_length:
                continue
            offset = (index + 0.5 - centre) / scale
            taps.append((index, float(np.exp(-0.5 * (offset / sigma) ** 2))))
        total = sum(weight for _, weight in taps)
        for index, weight in taps:
            source_slice = [slice(None)] * pixels.ndim
            source_slice[axis] = index
            out_slice = [slice(None)] * out.ndim
            out_slice[axis] = i
            out[tuple(out_slice)] += pixels[tuple(source_slice)] * (weight / total)
    return out


def widest(one: np.ndarray, other: np.ndarray):
    """The largest difference of a sample, and how many pixels are one step
    away from the other implementation in their worst channel."""
    if one.shape != other.shape:
        return None, None, None
    difference = np.abs(one.astype(np.int32) - other.astype(np.int32))
    per_pixel = difference.reshape(-1, difference.shape[-1]).max(axis=1)
    return (
        int(difference.max()),
        int((per_pixel == 1).sum()),
        int(per_pixel.size),
    )


def run(moon: Path, arguments, work: Path) -> np.ndarray:
    out = work / "out.rgba"
    if out.exists():
        out.unlink()
    outcome = subprocess.run(
        [str(moon), *arguments, str(out)], capture_output=True, text=True
    )
    if outcome.returncode != 0:
        sys.exit("the harness refused: " + outcome.stdout + outcome.stderr)
    pixels = np.frombuffer(out.read_bytes(), dtype=np.uint8)
    return pixels


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--moon", help="the harness command, built already")
    arguments = parser.parse_args()
    moon = Path(arguments.moon) if arguments.moon else build_moon()

    work = Path(tempfile.mkdtemp(prefix="moonimage-filters-"))
    source = picture(13, 9)
    (work / "source.rgba").write_bytes(source.tobytes())
    ours_in = np.asarray(source)

    print("| filter | size | largest difference | pixels one step away |")
    print("|:--|:--:|--:|--:|")
    for name, pillow_filter in FILTERS:
        for size in SIZES:
            got = run(
                moon,
                [
                    "resize",
                    str(work / "source.rgba"),
                    "13",
                    "9",
                    str(size[0]),
                    str(size[1]),
                    name,
                ],
                work,
            )
            got = got.reshape((size[1], size[0], 4))
            if pillow_filter is not None:
                theirs = np.asarray(source.resize(size, pillow_filter))
            else:
                theirs = gaussian_resample(source, size)
            gap, near, count = widest(got, theirs)
            print(
                "| %s | %dx%d | %s | %d of %d (%.1f%%) |"
                % (name, size[0], size[1], gap, near, count, 100.0 * near / count)
            )

    print()
    print("| blur | radius | largest difference | pixels one step away |")
    print("|:--|--:|--:|--:|")
    for kernel in ("exact", "boxes"):
        for radius in RADII:
            size = (13, 9)
            got = run(
                moon,
                [
                    "blur",
                    str(work / "source.rgba"),
                    "13",
                    "9",
                    repr(radius),
                    kernel,
                ],
                work,
            )
            got = got.reshape((size[1], size[0], 4))
            theirs = np.asarray(source.filter(ImageFilter.GaussianBlur(radius)))
            gap, near, count = widest(got, theirs)
            print(
                "| %s | %.1f | %s | %d of %d (%.1f%%) |"
                % (kernel, radius, gap, near, count, 100.0 * near / count)
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
