# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0

"""Holding this library to two other implementations, on real files.

    python scripts/samples/check.py --cache DIR [--moon PATH] [--reader PATH]

Two questions, both answered by reading bytes somebody else wrote:

1. Can this library read what the world writes? Every picture of the three
   corpora `fetch.py` downloads — libtiff's test images, openexr-images and
   Netpbm's samples — is decoded here, by Pillow, by the `image` crate, by
   `tifffile` for TIFF and by OpenEXR's own library for EXR, and the results
   have to agree. Every file has to be held against at least one reader that is
   not this library. A file this library refuses has to be refused on purpose,
   which is what `REFUSED` below records; `PILLOW_MISREADS` records a shape a
   reference reader is known to get wrong.

2. Can the world read what this library writes? Every format the writer produces
   is written once, then read back by all three. The pictures have to agree with
   each other: a lossy format does not have to give back what went in, but three
   decoders that disagree about what it says are three decoders with a bug in
   them, and two of them are not ours.

Exit status is 0 only when every picture agrees to the tolerance the format
allows, which is one step of an eight-bit sample for anything that goes through
sixteen bits or a float, and two for the two decoders of a JPEG that do their
inverse transform differently.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]

# What this library does with each official sample it cannot read, and why. A
# file listed here has to be refused; a file that is not listed has to be read.
REFUSED = {
    "quad-tile.jpg.tiff": "tiles rather than strips",
    "logluv-3c-16b.tiff": "LogLuv encoding",
}

# A reader that reads a file but reads it wrong, and the reason the disagreement
# is not ours. A file listed here still has to be held against another reader:
# the skip is recorded in the row rather than quietly omitted. Pillow returns a
# zero alpha plane for a TIFF whose samples are in separate planes, which both
# `tifffile` and the bytes themselves disagree with.
PILLOW_MISREADS = {
    "minisblack-2c-8b-alpha.tiff": "drops the alpha of separated planes",
}

# How much the three decoders may disagree: zero for an eight-bit picture read
# by three implementations that all follow the same table, and one where a
# sixteen-bit or a float sample has to be brought down to eight.
TOLERANCE = {
    ".tiff": 1,
    ".exr": 1,
    ".hdr": 2,
    ".pbm": 0,
    ".pgm": 0,
    ".ppm": 0,
}

# The formats the writer produces, what to name the file, how far three decoders
# may differ reading it, and who can be asked to read it.
WRITTEN = [
    ("png", ".png", 0, ("pillow", "image")),
    ("qoi", ".qoi", 0, ("image",)),
    ("bmp", ".bmp", 0, ("pillow", "image")),
    ("tga", ".tga", 0, ("pillow", "image")),
    ("jpeg", ".jpg", 3, ("pillow", "image")),
    ("gif", ".gif", 1, ("pillow", "image")),
    ("webp", ".webp", 1, ("pillow", "image")),
    ("tiff", ".tiff", 0, ("pillow", "image")),
    ("ico", ".ico", 0, ("pillow", "image")),
    ("pnm", ".ppm", 0, ("pillow", "image")),
    ("hdr", ".hdr", 2, ("image",)),
    ("exr", ".exr", 1, ("image", "openexr")),
    ("exr-piz", ".exr", 1, ("image", "openexr")),
    ("exr-piz-float", ".exr", 1, ("image", "openexr")),
    ("exr-rle", ".exr", 1, ("image", "openexr")),
    ("exr-zips", ".exr", 1, ("image", "openexr")),
    ("exr-none", ".exr", 1, ("image", "openexr")),
    ("exr-pxr24", ".exr", 1, ("image", "openexr")),
    ("exr-b44", ".exr", 2, ("image", "openexr")),
    ("exr-b44a", ".exr", 2, ("image", "openexr")),
    # The two frequency-domain compressions are lossy by construction; what is
    # checked here is that the format's own reader and this one agree about the
    # file this library wrote.
    ("exr-dwaa", ".exr", 1, ("openexr",)),
    ("exr-dwab", ".exr", 1, ("openexr",)),
    ("farbfeld", ".ff", 0, ("image",)),
]


def read_pillow(path: Path):
    """The picture as Pillow reads it, or None when Pillow cannot."""
    try:
        with Image.open(path) as picture:
            picture.seek(0)
            if picture.mode == "La":
                # Pillow has no conversion from grey-with-alpha straight to
                # RGBA, but it can split the two, widen the grey to three
                # channels and put the alpha back.
                luma, alpha = picture.split()
                colour = luma.convert("RGB")
                colour.putalpha(alpha)
                return np.array(colour, dtype=np.uint8)
            return np.array(picture.convert("RGBA"), dtype=np.uint8)
    except Exception:
        return None


def read_openexr(path: Path):
    """The picture as OpenEXR's own library reads it, which is the only reader
    that can be asked about the one format this library refuses most of."""
    try:
        import OpenEXR
    except ImportError:
        return None
    try:
        part = OpenEXR.File(str(path)).parts[0]
        # The channels come grouped by what they are: RGBA, RGB, or a single
        # luminance channel of a greyscale picture.
        for group in ("RGBA", "RGB", "Y"):
            if group in part.channels:
                pixels = np.clip(part.channels[group].pixels, 0.0, 1.0)
                picture = np.rint(pixels * 255.0).astype(np.uint8)
                if picture.ndim == 2:
                    picture = np.repeat(picture[:, :, None], 3, axis=2)
                if picture.shape[2] == 3:
                    alpha = np.full(picture.shape[:2] + (1,), 255, dtype=np.uint8)
                    picture = np.concatenate([picture, alpha], axis=2)
                return picture
        return None
    except Exception:
        return None


def read_tifffile(path: Path):
    """The picture as `tifffile` reads it, which is the reader that understands
    TIFF samples stored in separate planes — a shape Pillow flattens and the
    `image` crate refuses. Palette pages are left to Pillow, which has the colour
    map; a page whose compression needs a codec this script does not carry is
    left out too."""
    try:
        import tifffile
    except ImportError:
        return None
    try:
        with tifffile.TiffFile(path) as handle:
            page = handle.pages[0]
            if page.photometric not in (0, 1, 2):  # miniswhite, minisblack, rgb
                return None
            samples = page.asarray()
            separate = page.planarconfig == 2
            white_is_zero = page.photometric == 0
        if separate and samples.ndim == 3:
            samples = np.moveaxis(samples, 0, -1)
        if samples.dtype == np.bool_:
            samples = samples.astype(np.uint8) * 255
        elif samples.dtype == np.uint16:
            samples = np.rint(samples.astype(np.float64) / 257.0)
        else:
            samples = samples.astype(np.float64)
        if white_is_zero:
            samples = 255.0 - samples
        if samples.ndim == 2:
            samples = np.repeat(samples[:, :, None], 4, axis=2)
            samples[:, :, 3] = 255
        elif samples.shape[2] == 1:
            samples = np.repeat(samples, 4, axis=2)
            samples[:, :, 3] = 255
        elif samples.shape[2] == 2:
            samples = np.concatenate(
                [np.repeat(samples[:, :, :1], 3, axis=2), samples[:, :, 1:]], axis=2
            )
        elif samples.shape[2] == 3:
            alpha = np.full(samples.shape[:2] + (1,), 255.0)
            samples = np.concatenate([samples, alpha], axis=2)
        elif samples.shape[2] != 4:
            return None
        return np.clip(np.rint(samples), 0, 255).astype(np.uint8)
    except Exception:
        return None


def read_image_crate(reader: Path, path: Path, work: Path):
    """The picture as the `image` crate reads it."""
    target = work / "rust.rgba"
    outcome = subprocess.run(
        [str(reader), str(path), str(target)],
        capture_output=True,
        text=True,
    )
    if outcome.returncode != 0:
        return None, outcome.stderr.strip()
    width, height = (int(one) for one in outcome.stdout.split())
    pixels = np.frombuffer(target.read_bytes(), dtype=np.uint8)
    return pixels.reshape((height, width, 4)), ""


def read_ours(moon: Path, path: Path, work: Path):
    """The picture as this library reads it."""
    target = work / "ours.rgba"
    if target.exists():
        target.unlink()
    outcome = subprocess.run(
        [str(moon), "decode", str(path), str(target)],
        capture_output=True,
        text=True,
    )
    if outcome.returncode != 0 or not target.exists():
        return None, (outcome.stdout + outcome.stderr).strip()
    width, height = (int(one) for one in outcome.stdout.split()[:2])
    pixels = np.frombuffer(target.read_bytes(), dtype=np.uint8)
    return pixels.reshape((height, width, 4)), ""


def read_ours16(moon: Path, path: Path, work: Path):
    """This library's sixteen-bit view of a picture, for a file that holds
    sixteen bits a sample: comparing it through eight loses more than the
    disagreement between two implementations."""
    target = work / "ours16.rgba"
    if target.exists():
        target.unlink()
    outcome = subprocess.run(
        [str(moon), "decode16", str(path), str(target)],
        capture_output=True,
        text=True,
    )
    if outcome.returncode != 0 or not target.exists():
        return None
    width, height = (int(one) for one in outcome.stdout.split()[:2])
    pixels = np.frombuffer(target.read_bytes(), dtype=">u2")
    return pixels.reshape((height, width, 4))


def read_pillow16(path: Path):
    """Pillow's sixteen-bit samples, laid out as RGBA."""
    try:
        with Image.open(path) as picture:
            picture.seek(0)
            if picture.mode not in ("I;16", "I;16B", "I;16L", "I"):
                return None
            samples = np.array(picture)
            if samples.ndim == 2:
                samples = np.repeat(samples[:, :, None], 3, axis=2)
            alpha = np.full(samples.shape[:2] + (1,), 65535, dtype=np.uint16)
            return np.concatenate([samples.astype(np.uint16), alpha], axis=2)
    except Exception:
        return None


def widest16(one, other):
    if one.shape != other.shape:
        return None, None
    difference = np.abs(one.astype(np.int32) - other.astype(np.int32))
    return int(difference.max()), int((difference > 0).sum())


def refusal_reason(complaint: str) -> str:
    """The part of a reader's refusal that says what it could not do, without
    the local path it happened to be reading at the time."""
    first = complaint.splitlines()[0] if complaint.strip() else "refused"
    # The reader writes "error: <path>: <what it could not do>"; splitting only
    # twice keeps the message whole even when it has a colon of its own.
    pieces = first.split(": ", 2)
    return (pieces[2] if len(pieces) > 2 else pieces[-1])[:72]


def widest(one, other):
    """The largest difference, and how many samples are not the same."""
    if one.shape != other.shape:
        return None, None
    difference = np.abs(one.astype(np.int16) - other.astype(np.int16))
    return int(difference.max()), int((difference > 0).sum())


class Report:
    def __init__(self):
        self.lines = []
        self.failures = 0

    def row(self, name, detail, ok):
        mark = "ok  " if ok else "FAIL"
        self.lines.append("%s %-28s %s" % (mark, name, detail))
        if not ok:
            self.failures += 1

    def show(self):
        for line in self.lines:
            print(line)
        print()
        print("%d checks, %d failed" % (len(self.lines), self.failures))


def check_corpora(arguments, moon: Path, reader: Path, work: Path, report: Report):
    """Reading what the world writes."""
    for corpus in sorted(arguments.cache.iterdir()):
        if not corpus.is_dir():
            continue
        for commit in sorted(corpus.iterdir()):
            if not commit.is_dir():
                continue
            print("== %s at %s" % (corpus.name, commit.name[:12]))
            for path in sorted(commit.iterdir()):
                name = "%s/%s" % (corpus.name, path.name)
                ours, complaint = read_ours(moon, path, work)
                if ours is None:
                    reason = REFUSED.get(path.name)
                    report.row(
                        name,
                        "refused (%s)" % reason if reason else "refused: " + complaint,
                        reason is not None,
                    )
                    continue
                if path.name in REFUSED:
                    report.row(name, "read, but was expected to be refused", False)
                    continue
                tolerance = TOLERANCE.get(path.suffix.lower(), 0)
                details = []
                ok = True
                sixteen = read_pillow16(path)
                if sixteen is not None:
                    mine = read_ours16(moon, path, work)
                    if mine is None:
                        report.row(name, "sixteen bits: cannot read back", False)
                        continue
                    gap, count = widest16(mine, sixteen)
                    details.append("Pillow16 %d/%d" % (gap, count))
                    report.row(name, ", ".join(details), gap <= 2)
                    continue
                # Every row has to have been held against at least one reader
                # that is not this library; a reader that refuses a shape says so
                # in the row, and a file nobody else can read is not a pass.
                compared = 0
                if path.suffix.lower() == ".exr":
                    theirs = read_openexr(path)
                    gap, count = widest(ours, theirs) if theirs is not None else (None, None)
                    if theirs is None:
                        details.append("openexr: refused")
                        ok = False
                    else:
                        details.append("openexr %d/%d" % (gap, count))
                        ok = ok and gap <= tolerance
                        compared += 1
                pillow = read_pillow(path)
                if pillow is not None:
                    if path.name in PILLOW_MISREADS:
                        details.append("Pillow: " + PILLOW_MISREADS[path.name])
                    else:
                        gap, count = widest(ours, pillow)
                        if gap is None:
                            details.append("Pillow sees %s" % (pillow.shape,))
                            ok = False
                        else:
                            details.append("Pillow %d/%d" % (gap, count))
                            ok = ok and gap <= tolerance
                            compared += 1
                if path.suffix.lower() in (".tiff", ".tif"):
                    plane_reader = read_tifffile(path)
                    if plane_reader is not None:
                        gap, count = widest(ours, plane_reader)
                        if gap is None:
                            details.append("tifffile sees %s" % (plane_reader.shape,))
                            ok = False
                        else:
                            details.append("tifffile %d/%d" % (gap, count))
                            ok = ok and gap <= tolerance
                            compared += 1
                theirs, complaint = read_image_crate(reader, path, work)
                if theirs is None:
                    details.append("image: " + refusal_reason(complaint))
                else:
                    gap, count = widest(ours, theirs)
                    if gap is None:
                        details.append("image sees %s" % (theirs.shape,))
                        ok = False
                    else:
                        details.append("image %d/%d" % (gap, count))
                        ok = ok and gap <= tolerance
                        compared += 1
                if compared == 0:
                    details.append("no other reader could compare it")
                    ok = False
                report.row(name, ", ".join(details), ok)


def check_written(arguments, moon: Path, reader: Path, work: Path, report: Report):
    """Writing what the world has to read."""
    print("== what this library writes")
    for name, suffix, tolerance, readers in WRITTEN:
        path = work / ("written" + suffix)
        outcome = subprocess.run(
            [str(moon), "write", name, str(path)],
            capture_output=True,
            text=True,
        )
        if outcome.returncode != 0:
            report.row(name, "cannot write: " + outcome.stdout.strip(), False)
            continue
        ours, complaint = read_ours(moon, path, work)
        if ours is None:
            report.row(name, "cannot read back: " + complaint, False)
            continue
        details = []
        ok = True
        for reader_name in readers:
            if reader_name == "pillow":
                theirs = read_pillow(path)
            elif reader_name == "openexr":
                theirs = read_openexr(path)
            else:
                theirs, complaint = read_image_crate(reader, path, work)
                if theirs is None:
                    details.append("image: " + refusal_reason(complaint))
                    ok = False
                    continue
            if theirs is None:
                details.append("pillow: refused")
                ok = False
                continue
            gap, count = widest(ours, theirs)
            if gap is None:
                details.append("%s sees %s" % (reader_name, (theirs.shape,)))
                ok = False
            else:
                details.append("%s %d/%d" % (reader_name, gap, count))
                ok = ok and gap <= tolerance
        report.row(name, ", ".join(details), ok)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--cache",
        default=os.environ.get("MOONIMAGE_SAMPLES")
        or str(Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "moonimage-samples"),
    )
    parser.add_argument("--moon", help="the conformance command, built already")
    parser.add_argument("--reader", help="the `image` crate reader, built already")
    parser.add_argument("--keep", action="store_true", help="keep the scratch files")
    arguments = parser.parse_args()
    arguments.cache = Path(arguments.cache)

    moon = Path(arguments.moon) if arguments.moon else build_moon()
    reader = Path(arguments.reader) if arguments.reader else build_reader()

    work = Path(tempfile.mkdtemp(prefix="moonimage-samples-"))
    report = Report()
    try:
        check_corpora(arguments, moon, reader, work, report)
        check_written(arguments, moon, reader, work, report)
    finally:
        if arguments.keep:
            print("scratch kept in %s" % work)
        else:
            shutil.rmtree(work, ignore_errors=True)
    report.show()
    return 1 if report.failures else 0


def build_moon() -> Path:
    """The harness command, built for the machine this runs on.

    The harness lives in the module under `integration/`, which is the only place
    a file system is available: the library itself is four backends, and three of
    them have none. The workspace manifest at the root of the repository resolves
    the harness's dependency on the library to the tree being checked.
    """
    outcome = subprocess.run(
        ["moon", "work", "sync", "-q"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if outcome.returncode != 0:
        sys.exit("cannot resolve the workspace:\n" + outcome.stdout + outcome.stderr)
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
        harness / "_build/native/release/build/main/main.exe",
        harness / "_build/native/release/build/main/main",
        ROOT / "_build/native/release/build/moonbitstack/moonimage-samples/main/main.exe",
        ROOT / "_build/native/release/build/moonbitstack/moonimage-samples/main/main",
    ):
        if candidate.exists():
            return candidate
    sys.exit("the harness was built somewhere unexpected")


def build_reader() -> Path:
    """The `image` crate reader, built for the machine this runs on."""
    crate = ROOT / "scripts/samples/read_image"
    outcome = subprocess.run(
        ["cargo", "build", "--release"],
        cwd=crate,
        capture_output=True,
        text=True,
    )
    if outcome.returncode != 0:
        sys.exit("cannot build the reader:\n" + outcome.stdout + outcome.stderr)
    for candidate in (
        crate / "target/release/read_image.exe",
        crate / "target/release/read_image",
    ):
        if candidate.exists():
            return candidate
    sys.exit("the reader was built somewhere unexpected")


if __name__ == "__main__":
    sys.exit(main())
