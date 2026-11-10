# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0

"""Fetching the official sample pictures the conformance run decodes.

    python scripts/samples/fetch.py --cache DIR

Three corpora, each pinned to a commit so that a run tomorrow decodes the same
bytes as a run today:

- the test images of libtiff, the implementation the TIFF reader is measured
  against;
- the pictures of openexr-images, the collection OpenEXR publishes with the
  format;
- the portable anymaps of Netpbm, which define PBM, PGM, PPM and PAM.

Files are taken from the GitHub API, one at a time, so that a run downloads a few
hundred kilobytes rather than a hundred megabytes of pictures nobody asked for.
The cache is keyed by repository and commit: a second run reads from disk.
"""

import argparse
import http.client
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# The commit each corpus is frozen at. The names beside them are only for the
# report: a commit is what the download actually depends on.
CORPORA = {
    "libtiff": {
        "repository": "vadz/libtiff",
        "commit": "cda4b06914040aae5302b4da511ea266dad8a104",
        "files": [
            "test/images/miniswhite-1c-1b.tiff",
            "test/images/minisblack-1c-8b.tiff",
            "test/images/minisblack-1c-16b.tiff",
            "test/images/minisblack-2c-8b-alpha.tiff",
            "test/images/palette-1c-4b.tiff",
            "test/images/palette-1c-8b.tiff",
            "test/images/rgb-3c-8b.tiff",
            "test/images/rgb-3c-16b.tiff",
            "test/images/quad-tile.jpg.tiff",
            "test/images/logluv-3c-16b.tiff",
            "test/images/miniswhite-1c-1b.pbm",
            "test/images/minisblack-1c-8b.pgm",
            "test/images/rgb-3c-8b.ppm",
        ],
    },
    "openexr": {
        "repository": "AcademySoftwareFoundation/openexr-images",
        "commit": "f17e353fbfcde3406fe02675f4d92aeae422a560",
        "files": [
            "TestImages/GrayRampsHorizontal.exr",
            "TestImages/GammaChart.exr",
            "TestImages/GrayRampsDiagonal.exr",
            "DisplayWindow/t01.exr",
            "ScanLines/Cannon.exr",
        ],
    },
    "netpbm": {
        "repository": "leahneukirchen/netpbm-mirror",
        "commit": "5b0fcf2f01a118bee0d6d02076e7171bc7546341",
        "files": [
            "test/testimg.ppm",
            "converter/ppm/pcxstd.ppm",
        ],
    },
}


def download(repository: str, commit: str, path: str) -> bytes:
    """One file, from the API, at the raw media type."""
    url = "https://api.github.com/repos/%s/contents/%s?ref=%s" % (
        repository,
        path,
        commit,
    )
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github.raw",
            "User-Agent": "moonimage-conformance",
        },
    )
    # A picture of a megabyte over a slow link is a read that times out rather
    # than fails, so a run tries again before it gives up.
    last = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                return response.read()
        except (
            urllib.error.URLError,
            http.client.IncompleteRead,
            TimeoutError,
            ConnectionError,
        ) as error:
            last = error
            time.sleep(2 + attempt * 4)
    raise last


def fetch(cache: Path) -> int:
    total = 0
    for name, corpus in CORPORA.items():
        directory = cache / name / corpus["commit"]
        directory.mkdir(parents=True, exist_ok=True)
        for path in corpus["files"]:
            target = directory / Path(path).name
            if target.exists() and target.stat().st_size > 0:
                continue
            try:
                data = download(corpus["repository"], corpus["commit"], path)
            except urllib.error.HTTPError as error:
                print("  %s: %s (%s)" % (path, error.code, error.reason))
                return 1
            target.write_bytes(data)
            total += len(data)
            print("  %s (%d bytes)" % (path, len(data)))
    manifest = cache / "manifest.json"
    manifest.write_text(
        json.dumps(
            {
                name: {
                    "repository": corpus["repository"],
                    "commit": corpus["commit"],
                    "files": [Path(one).name for one in corpus["files"]],
                }
                for name, corpus in CORPORA.items()
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print("fetched %d bytes into %s" % (total, cache))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--cache",
        default=os.environ.get("MOONIMAGE_SAMPLES")
        or str(Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "moonimage-samples"),
        help="where the pictures are kept between runs",
    )
    arguments = parser.parse_args()
    return fetch(Path(arguments.cache))


if __name__ == "__main__":
    sys.exit(main())
