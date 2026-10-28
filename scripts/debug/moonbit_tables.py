# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0

"""The VP8 constant tables, read back out of the generated MoonBit source.

The reference decoder in `vp8_ref.py` needs the same probabilities the reader
uses. Rather than keep a second copy that can drift, they are parsed out of
`src/webp/vp8_tables.mbt`, so the two implementations are comparing their
algorithms and not their tables.
"""

import re
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[2] / "src" / "webp" / "vp8_tables.mbt"


def _array(name: str) -> list[int]:
    text = SOURCE.read_text(encoding="utf-8")
    head = text.index("let %s : Array[Int] = [" % name)
    start = head + len("let %s : Array[Int] = [" % name)
    body = text[start:text.index("\n]", start)]
    return [int(token) for token in re.findall(r"-?\d+", body)]


coeff_update = _array("coeff_update")
default_coeff_probs = _array("default_coeff_probs")
bmode_probs = _array("bmode_probs")
dc_quant = _array("dc_quant")
ac_quant = _array("ac_quant")
