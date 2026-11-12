# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0

"""The difference between this library and Pillow, counted rather than described.

    python scripts/samples/delta.py [--moon PATH] [--report PATH]

`check.py` asks whether two implementations agree, and answers yes or no at a
tolerance. This asks how far apart they are, and it answers two different
questions for every format the writer produces:

- **What Pillow says about the file this library wrote.** Both readers are
  handed the same bytes, so a difference here is a disagreement between two
  decoders and nothing else. It is the number that has to be zero, or one step
  where a decoder rounds, and it is the number `check.py` bounds.
- **What the format cost.** The file is read back by this library and counted
  against the picture that went in, which is the library's own PNG of the
  fixture — lossless, and read exactly by Pillow, so a row that says zero means
  the same bytes of picture came out.

A lossy format is expected to differ from the fixture; what would be wrong is
two readers differing about what it says. A format with no loss is expected to
say zero in both columns, and a row that says otherwise is a bug in one of the
two directions rather than a tolerance to widen.

A file that carries sixteen bits a sample is compared at sixteen bits, by the
same two readers, because bringing both down to eight first loses more than the
disagreement being measured.

A format neither Pillow nor OpenEXR's library can read — a farbfeld, a
half-float surface — is left out with the reason rather than filled in with a
zero.
"""

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check  # the readers, the harness build, and the formats that are written


def channels_carried(mine, reference):
    """How many channels the format holds.

    A format with no alpha plane gives back an opaque picture whatever went in,
    and counting the fixture's alpha against that reads as a difference of a
    hundred and ninety steps in a file that lost nothing but the plane it cannot
    store. Three channels is the answer when the file came back opaque and the
    fixture was not.
    """
    if reference.shape != mine.shape:
        return 4
    if np.unique(reference[:, :, 3]).size > 1 and np.unique(mine[:, :, 3]).size == 1:
        return 3
    return 4


def pair_channels(mine, theirs):
    """How many channels two readers can disagree about.

    A format may carry something the other reader cannot see — this library
    writes the alpha of a Sun raster into the fourth byte of a pixel, which
    every other reader calls padding — and counting that as a disagreement
    would report a difference of a hundred steps between two readers that agree
    about every colour.
    """
    if mine is None or theirs is None or mine.shape != theirs.shape:
        return 4
    if np.unique(theirs[:, :, 3]).size == 1 and np.unique(mine[:, :, 3]).size > 1:
        return 3
    return 4


def distance(mine, theirs, channels=4):
    """The distance between two pictures, in the terms a reader can check."""
    if mine is None or theirs is None or mine.shape != theirs.shape:
        return None
    if channels < 4:
        mine = mine[:, :, :channels]
        theirs = theirs[:, :, :channels]
    difference = np.abs(mine.astype(np.float64) - theirs.astype(np.float64))
    squared = float((difference * difference).mean())
    if squared == 0.0:
        psnr = float("inf")
    else:
        psnr = 10.0 * np.log10(255.0 * 255.0 / squared)
    return {
        "max": int(difference.max()),
        "mean": float(difference.mean()),
        "rmse": float(np.sqrt(squared)),
        "psnr": psnr,
        "differing": int((difference > 0).sum()),
        "samples": int(difference.size),
    }


def baseline(moon: Path, work: Path):
    """The fixture as this library writes it losslessly, read back by Pillow."""
    path = work / "baseline.png"
    outcome = subprocess.run(
        [str(moon), "write", "png", str(path)], capture_output=True, text=True
    )
    if outcome.returncode != 0:
        sys.exit("cannot write the baseline: " + outcome.stdout + outcome.stderr)
    picture = check.read_pillow(path)
    if picture is None:
        sys.exit("Pillow cannot read back the library's own PNG")
    return picture


def other_reader(path: Path):
    """What a reader that is not this library says, and which one it was."""
    sixteen = check.read_pillow16(path)
    if sixteen is not None:
        return sixteen, "Pillow", True
    picture = check.read_pillow(path)
    if picture is not None:
        return picture, "Pillow", False
    if path.suffix.lower() == ".exr":
        picture = check.read_openexr(path)
        if picture is not None:
            return picture, "OpenEXR", False
    return None, "", False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--moon", help="the conformance command, built already")
    parser.add_argument("--report", type=Path, help="write the table here as markdown")
    parser.add_argument("--keep", action="store_true", help="keep the scratch files")
    arguments = parser.parse_args()

    moon = Path(arguments.moon) if arguments.moon else check.build_moon()
    work = Path(tempfile.mkdtemp(prefix="moonimage-delta-"))
    try:
        reference = baseline(moon, work)
        rows = []
        for name, suffix, _tolerance, _readers in check.WRITTEN:
            path = work / ("delta" + suffix)
            outcome = subprocess.run(
                [str(moon), "write", name, str(path)],
                capture_output=True,
                text=True,
            )
            if outcome.returncode != 0:
                rows.append((name, 0, None, None, "cannot write", 0))
                continue
            size = path.stat().st_size
            theirs, who, deep = other_reader(path)
            if theirs is None:
                rows.append((name, size, None, None, "neither Pillow nor OpenEXR reads it", 0))
                continue
            if deep:
                mine, _ = check.read_ours16(moon, path, work)
            else:
                mine, _ = check.read_ours(moon, path, work)
            if mine is None:
                rows.append((name, size, None, None, "cannot read it back", 0))
                continue
            ours = distance(mine, theirs, pair_channels(mine, theirs))
            alpha = channels_carried(mine, reference)
            cost = distance(mine, reference, alpha) if not deep else None
            rows.append(
                (name, size, ours, cost, "" if cost is not None else "16-bit, " + who, alpha)
            )

        print(
            "the fixture is %d by %d; its PNG is lossless and Pillow reads it exactly"
            % (reference.shape[1], reference.shape[0])
        )
        print()
        lines = [
            "| Format | Bytes | Reader | Channels | Same file: largest | Same file: mean | vs fixture: largest | vs fixture: RMSE | vs fixture: PSNR |",
            "|:--|--:|:--|:-:|--:|--:|--:|--:|--:|",
        ]
        for line in lines:
            print(line)
        for name, size, ours, cost, complaint, alpha in rows:
            if ours is None:
                line = "| %s | %d | — | — | — | — | — | — | %s |" % (name, size, complaint)
            else:
                psnr = "exact" if cost is None else (
                    "exact" if cost["psnr"] == float("inf") else "%.2f dB" % cost["psnr"]
                )
                line = "| %s | %d | %s | %d | %d | %.4f | %s | %s | %s |" % (
                    name,
                    size,
                    "Pillow" if complaint == "" else "Pillow, 16-bit",
                    alpha,
                    ours["max"],
                    ours["mean"],
                    "—" if cost is None else str(cost["max"]),
                    "—" if cost is None else "%.4f" % cost["rmse"],
                    "—" if cost is None else psnr,
                )
            lines.append(line)
            print(line)
        print()

        compared = sum(1 for _, _, ours, _, _, _ in rows if ours is not None)
        agreeing = sum(1 for _, _, ours, _, _, _ in rows if ours is not None and ours["max"] == 0)
        lossless = [
            (name, ours, cost)
            for name, _, ours, cost, _, _ in rows
            if ours is not None and cost is not None and cost["max"] == 0
        ]
        print(
            "%d formats compared, %d read the same by both libraries, %d lossless"
            % (compared, agreeing, len(lossless))
        )

        if arguments.report:
            arguments.report.write_text("\n".join(lines) + "\n", encoding="utf-8")
            print("wrote %s" % arguments.report)
    finally:
        if arguments.keep:
            print("scratch kept in %s" % work)
        else:
            shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
