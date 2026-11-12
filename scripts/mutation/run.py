# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0

"""A mutation has to be caught: one change at a time, and the suite's answer.

    python scripts/mutation/run.py [--only ID]... [--list] [--report PATH]

A test that passes is worth nothing on its own; what it is worth is what it
notices. This script breaks one line of the library in a way that still
compiles, runs the package that line belongs to, and records whether the suite
said anything. A mutation the tests do not catch is either a gap in the tests or
a guard that no picture in the repository reaches, and both are worth knowing.

Each entry in `MUTATIONS` is a literal replacement: the exact text to find, the
text to put in its place, and why the change is a mistake rather than a
different way of doing the same thing. The text has to appear exactly once, so a
mutation cannot quietly apply to the wrong function after a refactor.

The tree has to be clean before this runs, and every mutation is reverted with
`git checkout` whether the run passed or failed: nothing here is left behind.
"""

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# One change per entry. `package` is a directory, because that is what the test
# runner takes; `what` says what the mutant is, in the terms a reader needs to
# judge whether the suite should have caught it.
MUTATIONS = [
    {
        "id": "png-paeth-tie",
        "package": "src/png",
        "file": "src/png/decode.mbt",
        "find": "  if to_left <= to_up && to_left <= to_corner {",
        "replace": "  if to_up <= to_left && to_up <= to_corner {",
        "what": "the Paeth predictor takes the neighbour above when the gradient is equidistant",
    },
    {
        "id": "qoi-hash-mask",
        "package": "src/qoi",
        "file": "src/qoi/decode.mbt",
        "find": "  (r * 3 + g * 5 + b * 7 + a * 11) & 63",
        "replace": "  (r * 3 + g * 5 + b * 7 + a * 11) & 31",
        "what": "the running index is sixty-four slots in the specification and thirty-two here",
    },
    {
        "id": "gif-interlace-bit",
        "package": "src/gif",
        "file": "src/gif/decode.mbt",
        "find": "  let interlaced = (packed & 0x40) != 0",
        "replace": "  let interlaced = (packed & 0x20) != 0",
        "what": "the interlaced flag is read from the bit beside it",
    },
    {
        "id": "dds-bc1-lerp",
        "package": "src/dds",
        "file": "src/dds/dds.mbt",
        "find": "      ((c0.0.to_int() * 2 + c1.0.to_int()) / 3).to_byte(),",
        "replace": "      ((c0.0.to_int() * 2 + c1.0.to_int()) / 4).to_byte(),",
        "what": "the two-thirds weight of a BC1 line is divided by four",
    },
    {
        "id": "exr-b44-halfway",
        "package": "src/exr",
        "file": "src/exr/b44.mbt",
        "find": "  let halfway = (1 << shift) - 1",
        "replace": "  let halfway = (1 << shift) >> 1",
        "what": "a B44 shift rounds at half a step instead of at the halfway point",
    },
    {
        "id": "jpeg-zigzag-order",
        "package": "src/jpeg",
        "file": "src/jpeg/decode.mbt",
        "find": "        values[zigzag(step)] = body[position + step].to_int()",
        "replace": "        values[step] = body[position + step].to_int()",
        "what": "a block's coefficients are stored in scan order and read as if it were raster order",
    },
    {
        "id": "raster-lanczos-support",
        "package": "src/raster",
        "file": "src/raster/scale.mbt",
        "find": "      Lanczos => 3.0",
        "replace": "      Lanczos => 2.0",
        "what": "the Lanczos window is two lobes wide instead of three",
    },
    {
        "id": "hdr-rgbe-exponent",
        "package": "src/hdr",
        "file": "src/hdr/hdr.mbt",
        "find": "      let (r, g, b) = to_float(at, green, blue, exponent)",
        "replace": "      let (r, g, b) = to_float(at, green, blue, exponent + 1)",
        "what": "every Radiance pixel is read one power of two too bright",
    },
]


def clean_tree() -> bool:
    """Only tracked files matter here: a mutation is applied to one of them and
    reverted with `git checkout`, and an untracked file cannot be either."""
    outcome = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=no"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    return outcome.returncode == 0 and not outcome.stdout.strip()


def apply(mutation) -> str:
    """Put the mutation in place, or say why it cannot be applied."""
    path = ROOT / mutation["file"]
    text = path.read_text(encoding="utf-8")
    count = text.count(mutation["find"])
    if count != 1:
        return "the text to find appears %d times, not once" % count
    path.write_text(
        text.replace(mutation["find"], mutation["replace"]), encoding="utf-8"
    )
    return ""


def revert(mutation) -> None:
    subprocess.run(
        ["git", "checkout", "--", mutation["file"]],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )


def catching_test(output: str) -> str:
    """The first test that failed, as the runner names it.

    Two shapes have to be read: a test that returns a failure prints
    `test <file>:<line> ("<name>") failed`, and a test that panics stops the
    executable, which the runner reports with the test that was running.
    """
    for line in output.splitlines():
        marker = line.find('") failed')
        if marker > 0 and "test " in line:
            start = line.find("test ")
            return line[start : marker + 1]
    lines = output.splitlines()
    for index, line in enumerate(lines):
        if "Active test at executable exit:" in line:
            for candidate in lines[index + 1 :]:
                if "test" in candidate and ".mbt:" in candidate:
                    return candidate.strip().lstrip("- ").split("\\")[-1]
    return ""


def built(output: str) -> bool:
    """Whether the package compiled at all. A mutation that does not build has
    tested the compiler rather than the suite, and is not a caught mutation."""
    return "failed when checking project" not in output and "Failed with" not in output


def run(mutation):
    """Apply, run the package, revert, and say what happened."""
    complaint = apply(mutation)
    if complaint:
        return "UNUSABLE", complaint
    try:
        outcome = subprocess.run(
            ["moon", "test", mutation["package"], "--target", "native"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        output = outcome.stdout + outcome.stderr
        if outcome.returncode == 0:
            return "SURVIVED", "the suite passed with the change in place"
        if not built(output):
            return "BROKEN", "did not build"
        caught = catching_test(output)
        if caught:
            return "CAUGHT", caught
        return "BROKEN", "failed without naming a test"
    finally:
        revert(mutation)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", action="append", default=[], help="one mutant, by id")
    parser.add_argument("--list", action="store_true", help="the catalogue, and stop")
    parser.add_argument("--report", type=Path, help="write the table here as markdown")
    arguments = parser.parse_args()

    if arguments.list:
        for mutation in MUTATIONS:
            print("%-24s %-12s %s" % (mutation["id"], mutation["package"], mutation["what"]))
        return 0

    chosen = MUTATIONS
    if arguments.only:
        wanted = set(arguments.only)
        chosen = [one for one in MUTATIONS if one["id"] in wanted]
        missing = wanted - {one["id"] for one in chosen}
        if missing:
            sys.exit("no such mutant: " + ", ".join(sorted(missing)))

    if not clean_tree():
        sys.exit("the tree has changes; commit or stash them before mutating it")

    rows = []
    failures = 0
    for mutation in chosen:
        verdict, detail = run(mutation)
        rows.append((mutation["id"], verdict, detail))
        if verdict != "CAUGHT":
            failures += 1
        print("%-10s %-26s %s" % (verdict, mutation["id"], detail))

    caught = sum(1 for _, verdict, _ in rows if verdict == "CAUGHT")
    print()
    print("%d mutations, %d caught" % (len(rows), caught))

    if arguments.report:
        lines = ["| Change | Outcome |", "|:--|:--|"]
        for mutation, (_, verdict, detail) in zip(chosen, rows):
            lines.append(
                "| %s | %s, %s |" % (mutation["what"], verdict.lower(), detail or "-")
            )
        arguments.report.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("wrote %s" % arguments.report)

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
