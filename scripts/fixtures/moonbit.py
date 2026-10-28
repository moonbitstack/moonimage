# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0

"""Writing the test fixtures as MoonBit source.

A test that needs a file needs the file inside the binary, because the tests run
on four backends and three of them have no file system. So every fixture is
generated into a `.mbt` file as a byte literal, next to a digest of the pixels a
reference implementation produced from it.

The digest is FNV-1a over the raw bytes of the image, sixty-four bits of it, as
lower-case hexadecimal. That is enough to catch a decoder that is off by one
sample anywhere, and it keeps the fixture file to the size of the image itself
rather than four times that.
"""

import io
import os

FNV_OFFSET = 0xCBF29CE484222325
FNV_PRIME = 0x100000001B3
MASK = 0xFFFFFFFFFFFFFFFF


def digest(data: bytes) -> str:
    """The digest both sides compute: FNV-1a, 64 bits, hexadecimal."""
    value = FNV_OFFSET
    for byte in data:
        value = ((value ^ byte) * FNV_PRIME) & MASK
    return "%016x" % value


def literal(data: bytes, width: int = 96) -> str:
    r"""A byte literal, wrapped so that a diff of the fixture reads line by line.

    Every byte outside the printable range becomes `\xNN`, and a quote or a
    backslash is escaped the same way, so that no split can land inside an escape
    and leave a line that looks like it ends early.
    """
    tokens = []
    for byte in data:
        if 0x20 <= byte < 0x7F and byte not in (0x22, 0x5C):
            tokens.append(chr(byte))
        else:
            tokens.append("\\x%02x" % byte)
    lines = []
    current = ""
    for token in tokens:
        if len(current) + len(token) > width and current:
            lines.append(current)
            current = ""
        current += token
    if current or not lines:
        lines.append(current)
    out = 'b"%s"' % lines[0]
    for line in lines[1:]:
        out += ' +\n      b"%s"' % line
    return out


def png_of(image) -> bytes:
    """The image as PNG bytes, which is how a reference picture travels."""
    handle = io.BytesIO()
    image.save(handle, format="PNG", optimize=False)
    return handle.getvalue()


def write(path: str, header: str, body: str) -> None:
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(header.rstrip() + "\n\n")
        handle.write(body.rstrip() + "\n")
    print("wrote %s (%d bytes)" % (path, os.path.getsize(path)))
