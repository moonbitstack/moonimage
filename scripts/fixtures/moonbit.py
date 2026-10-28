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
    """A byte literal, wrapped so that a diff of the fixture reads line by line."""
    escapes = []
    for byte in data:
        if byte == 0x22:
            escapes.append('\\"')
        elif byte == 0x5C:
            escapes.append("\\\\")
        elif 0x20 <= byte < 0x7F:
            escapes.append(chr(byte))
        else:
            escapes.append("\\x%02x" % byte)
    body = "".join(escapes)
    if len(body) <= width:
        return 'b"%s"' % body
    lines = []
    limit = max(8, width)
    index = 0
    while index < len(body):
        # never split an escape sequence
        end = min(len(body), index + limit)
        if end < len(body):
            cut = body.rfind("\\x", index, end)
            if cut > index and cut + 4 > end:
                end = cut
            elif body[end - 1] == "\\":
                end -= 1
        lines.append(body[index:end])
        index = end
    first, rest = lines[0], lines[1:]
    out = 'b"%s"' % first
    for line in rest:
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
