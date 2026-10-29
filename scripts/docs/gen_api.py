#!/usr/bin/env python3
# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0
"""Render docs/api.html from the interfaces and the source comments.

`moon info` writes one `pkg.generated.mbti` per package: the public surface, with
the parameter names of a signature already gone. The `///` blocks in the source
keep those names and the prose, so the page is built from both — the mbti decides
what exists, the source says what it means.

The output is deterministic: no timestamps, no ordering that depends on the file
system, so continuous integration can regenerate it and compare.
"""

from __future__ import annotations

import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "src"
OUT = ROOT / "docs" / "api.html"

# The order the page lists them in: the entry point, the pixels, then the
# formats by name. `anchor` is what the other pages link to.
PACKAGES = [
    ("moonimage", "Every format, one door", "Format detection, decoding, encoding and animation, all of it delegating to the packages below."),
    ("raster", "Pictures and pixels", "The picture itself: layouts, conversion, geometry, scaling, animation frames, metadata, limits and the one error type."),
    ("bmp", "Windows bitmap", "Every header version, one to thirty-two bits a pixel, the two run-length encodings and both row orders."),
    ("gif", "GIF", "Palettes, transparency, interlacing, the LZW stream, and animation with its disposal rules."),
    ("jpeg", "JPEG", "Baseline and progressive files, every subsampling, restart markers, and EXIF orientation."),
    ("png", "PNG", "Every colour type and bit depth, Adam7, the five filters, text and colour chunks, and APNG."),
    ("qoi", "Quite OK Image", "Six opcodes and a run-length code: the smallest complete codec in the package."),
    ("tga", "Truevision TGA", "Paletted, true colour and grey, optional run-length, and both row orders."),
    ("webp", "WebP", "Lossless and lossy pictures, the alpha chunk that travels beside a lossy one, and animation."),
]

# Derive writes these; they are the same on every type and say nothing about the
# type. `to_string` stays: a caller does call it.
MECHANICAL = {"equal", "not_equal", "to_repr", "output"}


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def collapse(text: str) -> str:
    """One line, for a table or a page. Space is only ever wasted in code."""
    text = " ".join(text.split())
    for old, new in (("( ", "("), (" )", ")"), (" ,", ","), (",)", ")"), ("((", "("), ("))", ")")):
        text = text.replace(old, new)
    return text


# --------------------------------------------------------------------------
# The source: doc comments, and the signatures that keep their parameter names.
# --------------------------------------------------------------------------


def doc_paragraphs(lines):
    text = "\n".join(line[3:].lstrip() if len(line) > 3 else "" for line in lines)
    return [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]


def scan_source(package_dir: Path):
    """Map a name to its doc paragraphs and, for functions, its signature."""
    docs = {}
    fields = {}
    variants = {}
    signatures = {}

    files = sorted(p for p in package_dir.glob("*.mbt") if "test" not in p.name)
    for path in files:
        lines = read(path).split("\n")
        i = 0
        while i < len(lines):
            if lines[i].strip() != "///|":
                i += 1
                continue
            block = []
            i += 1
            while i < len(lines) and lines[i].startswith("///"):
                block.append(lines[i])
                i += 1
            while i < len(lines) and not lines[i].strip():
                i += 1
            if i >= len(lines):
                break
            decl = lines[i].strip()
            paragraphs = doc_paragraphs(block)

            struct = re.match(r"pub(?:\(all\))? (struct|enum|suberror) ([A-Za-z_][A-Za-z0-9_]*)", decl)
            function = re.match(r"pub fn ([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)?)", decl)
            value = re.match(r"pub let ([A-Za-z_][A-Za-z0-9_]*)", decl)

            if struct:
                name = struct.group(2)
                docs[name] = paragraphs
                i = collect_members(lines, i, name, fields, variants)
                continue
            if function:
                name = function.group(1)
                docs[name] = paragraphs
                signatures[name] = read_signature(lines, i)
            elif value:
                docs[value.group(1)] = paragraphs
            i += 1

    return docs, fields, variants, signatures


def collect_members(lines, start, type_name, fields, variants):
    """Read the body of a struct, enum or error for per-member comments."""
    i = start
    while i < len(lines) and "{" not in lines[i]:
        i += 1
    depth = 0
    body = []
    while i < len(lines):
        depth += lines[i].count("{") - lines[i].count("}")
        body.append(lines[i])
        if depth == 0 and i > start:
            break
        i += 1

    pending = []
    for line in body[1:-1] if len(body) > 2 else []:
        stripped = line.strip()
        if stripped.startswith("///"):
            pending.append(stripped)
            continue
        if not stripped or stripped.startswith("//"):
            continue
        member = re.match(r"(?:mut )?([A-Za-z_][A-Za-z0-9_]*)\s*[:({]?", stripped)
        member_alt = re.match(r"([A-Z][A-Za-z0-9_]*)\b", stripped)
        name = None
        if member and not stripped.startswith("pub"):
            name = member.group(1)
        elif member_alt and not stripped.startswith("pub"):
            name = member_alt.group(1)
        if pending and name:
            text = doc_paragraphs(pending)
            if text:
                if re.match(r"^[a-z_]", name):
                    fields[(type_name, name)] = text
                else:
                    variants[(type_name, name)] = text
        pending = []
    return i


def read_signature(lines, start):
    """A declaration from its first line to the body brace, as one line."""
    depth = 0
    collected = []
    for line in lines[start:]:
        collected.append(line.strip())
        for ch in line:
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
        if depth == 0 and "{" in line:
            break
    text = " ".join(collected)
    if "{" in text:
        text = text.split("{", 1)[0]
    return collapse(text)


# --------------------------------------------------------------------------
# The interface: what the package actually exposes.
# --------------------------------------------------------------------------


class Entry:
    def __init__(self, kind, name, signature=None):
        self.kind = kind  # struct, enum, error, function, value
        self.name = name
        self.signature = signature or ""
        self.fields = []  # (name, type, is_mut)
        self.variants = []  # (name, payload)
        self.methods = []


def parse_mbti(path: Path):
    text = read(path)
    entries = []
    by_name = {}
    current = None

    for raw in text.split("\n"):
        stripped = raw.rstrip().strip()
        if not stripped or stripped.startswith("//"):
            continue

        if stripped.startswith(("pub(all) struct ", "pub struct ")):
            name = stripped.split("struct ", 1)[1].split(" {")[0].strip()
            current = Entry("struct", name)
            entries.append(current)
            by_name[name] = current
            continue
        if stripped.startswith(("pub(all) enum ", "pub enum ")):
            name = stripped.split("enum ", 1)[1].split(" {")[0].strip()
            current = Entry("enum", name)
            entries.append(current)
            by_name[name] = current
            continue
        if stripped.startswith(("pub(all) suberror ", "pub suberror ")):
            name = stripped.split("suberror ", 1)[1].split(" {")[0].strip()
            current = Entry("error", name)
            entries.append(current)
            by_name[name] = current
            continue
        if stripped.startswith("pub fn "):
            signature = stripped[3:]
            name = signature.split("fn ", 1)[1].split("(")[0].strip()
            if "::" in name:
                owner = name.split("::", 1)[0]
                if owner in by_name:
                    by_name[owner].methods.append(signature)
                    continue
            entries.append(Entry("function", name, signature))
            continue
        if stripped.startswith("pub let "):
            entries.append(
                Entry("value", stripped.split("let ", 1)[1].split(":")[0].strip(), stripped)
            )
            continue
        if stripped.startswith("pub using "):
            continue
        if stripped == "}":
            current = None
            continue
        if current is not None:
            if current.kind == "struct":
                field = re.match(r"(mut )?([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.+)", stripped)
                if field:
                    current.fields.append(
                        (field.group(2), field.group(3).strip(), bool(field.group(1)))
                    )
            elif current.kind in ("enum", "error"):
                variant = re.match(r"([A-Za-z_][A-Za-z0-9_]*)(?:\((.*)\))?", stripped)
                if variant:
                    current.variants.append(
                        (variant.group(1), (variant.group(2) or "").strip())
                    )

    return entries


# --------------------------------------------------------------------------
# Rendering.
# --------------------------------------------------------------------------


def code_span(text):
    """Escape text and turn `backticked` runs into code."""
    escaped = html.escape(text, quote=False)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)


def escape_doc(paragraphs):
    out = []
    for paragraph in paragraphs:
        text = html.escape(" ".join(paragraph.split()), quote=False)
        text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
        out.append("<p>%s</p>" % text)
    return "\n".join(out)


def signature_html(signature):
    escaped = html.escape(signature, quote=False)
    match = re.match(r"(pub(?:\(all\))? (?:fn|struct|enum|suberror|let)) (.+)", escaped)
    if match:
        return '<span class="kw">%s</span> %s' % (match.group(1), match.group(2))
    return escaped


def render_package(package, title, blurb):
    base = SRC if package == "moonimage" else SRC / package
    docs, field_docs, variant_docs, signatures = scan_source(base)
    entries = parse_mbti(base / "pkg.generated.mbti")

    types = [e for e in entries if e.kind in ("struct", "enum", "error")]
    functions = [e for e in entries if e.kind == "function"]
    values = [e for e in entries if e.kind == "value"]

    for entry in types + functions:
        entry.methods = [
            m
            for m in entry.methods
            if m.split("(")[0].split("::")[-1] not in MECHANICAL
        ]
    functions = [
        f for f in functions if f.name.split("(")[0].split("::")[-1] not in MECHANICAL
    ]

    parts = []
    parts.append('    <section class="pkg" id="%s">' % package)
    parts.append("      <h2>%s <span>%s</span></h2>" % (package, html.escape(title)))
    parts.append("      <p>%s</p>" % html.escape(blurb))

    count = 0
    for entry in sorted(types, key=lambda e: e.name.lower()):
        parts.append('      <div class="entry">')
        parts.append('        <span class="kind">%s</span>' % entry.kind)
        declaration = {
            "struct": "pub(all) struct " + entry.name,
            "enum": "pub(all) enum " + entry.name,
            "error": "pub(all) suberror " + entry.name,
        }[entry.kind]
        parts.append('        <code class="sig">%s</code>' % signature_html(declaration))
        doc = docs.get(entry.name)
        if doc:
            parts.append('        <div class="doc">%s</div>' % escape_doc(doc))

        if entry.fields:
            parts.append('        <ul class="fields">')
            for name, type_, is_mut in entry.fields:
                note = field_docs.get((entry.name, name))
                note_html = (
                    " <em>%s</em>" % code_span(" ".join(note)) if note else ""
                )
                parts.append(
                    "          <li><b>%s%s</b><span>%s</span>%s</li>"
                    % (
                        "mut " if is_mut else "",
                        name,
                        html.escape(type_, quote=False),
                        note_html,
                    )
                )
            parts.append("        </ul>")
        if entry.variants:
            parts.append('        <ul class="variants">')
            for name, payload in entry.variants:
                note = variant_docs.get((entry.name, name))
                note_html = (
                    " <em>%s</em>" % code_span(" ".join(note)) if note else ""
                )
                shown = name + ("(" + payload + ")" if payload else "")
                parts.append(
                    "          <li>%s%s</li>"
                    % (html.escape(shown, quote=False), note_html)
                )
            parts.append("        </ul>")

        for method in sorted(entry.methods, key=lambda m: m.split("(")[0].lower()):
            name = method.split("fn ", 1)[1].split("(")[0].strip()
            body = signatures.get(name, collapse("pub " + method))
            parts.append('        <div class="entry method">')
            parts.append('          <code class="sig">%s</code>' % signature_html(body))
            doc = docs.get(name)
            if doc:
                parts.append('          <div class="doc">%s</div>' % escape_doc(doc))
            parts.append("        </div>")
            count += 1

        parts.append("      </div>")
        count += 1

    if functions:
        parts.append('      <div class="group"><span class="kind">functions</span></div>')
        for entry in sorted(functions, key=lambda e: e.name.lower()):
            body = signatures.get(entry.name, "pub " + entry.signature)
            parts.append('      <div class="entry">')
            parts.append('        <span class="kind">function</span>')
            parts.append('        <code class="sig">%s</code>' % signature_html(body))
            doc = docs.get(entry.name)
            if doc:
                parts.append('        <div class="doc">%s</div>' % escape_doc(doc))
            parts.append("      </div>")
            count += 1

    if values:
        parts.append('      <div class="group"><span class="kind">values</span></div>')
        for entry in sorted(values, key=lambda e: e.name.lower()):
            parts.append('      <div class="entry">')
            parts.append('        <span class="kind">value</span>')
            parts.append('        <code class="sig">%s</code>' % signature_html(entry.signature))
            doc = docs.get(entry.name)
            if doc:
                parts.append('        <div class="doc">%s</div>' % escape_doc(doc))
            parts.append("      </div>")
            count += 1

    parts.append("    </section>")
    return "\n".join(parts), count


def main():
    bodies = []
    counts = {}
    for package, title, blurb in PACKAGES:
        body, count = render_package(package, title, blurb)
        bodies.append(body)
        counts[package] = count

    nav = "\n".join(
        '        <a href="#%s" title="%s">%s<span>%d</span></a>'
        % (package, html.escape(title, quote=True), package, counts[package])
        for package, title, _ in PACKAGES
    )

    page = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>API reference — moonimage</title>
<meta name="description" content="Every public type, function, method and value in moonimage, generated from the packages' interfaces and their documentation comments.">
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Cormorant+Garamond:wght@500;600&family=EB+Garamond:ital,wght@0,400;0,600;1,400&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
<link rel="stylesheet" href="style.css">
</head>
<body>

<header class="top">
  <nav>
    <a class="brand" href="index.html"><b>moonimage</b><span>image codecs</span></a>
    <a class="link" href="guide.html">Guide</a>
    <a class="link" href="api.html" aria-current="page">API</a>
    <a class="icon-link" href="https://github.com/moonbitstack/moonimage" aria-label="The repository" title="github.com/moonbitstack/moonimage">
      <svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/></svg>
    </a>
  </nav>
</header>

<main class="wrap">
  <div class="page-head" style="padding-block: 40px 8px;">
    <p class="eyebrow">Reference</p>
    <h1 style="font-size: 2.6rem; max-width: none;">Everything public</h1>
    <p class="lede" style="margin-top: 12px;">
      Every type, method, function and value, grouped by package. The signatures
      are the ones the compiler sees; the prose is the comment the source
      carries. Generated from those two, so the page cannot drift from the code.
    </p>
  </div>

  <div class="api">
    <nav aria-label="Packages">
%s
    </nav>
    <div>
<!-- generated by scripts/docs/gen_api.py; edit the source comments, not this file -->
%s
    </div>
  </div>
</main>

<footer>
  <div class="wrap row">
    <span class="mark">moonimage</span>
    <a href="index.html">Home</a>
    <a href="guide.html">Guide</a>
    <a href="https://github.com/moonbitstack/moonimage">Repository</a>
    <a href="https://mooncakes.io/docs/#/moonbitstack/moonimage/">mooncakes</a>
    <span>Apache-2.0</span>
  </div>
</footer>

</body>
</html>
""" % (nav, "\n".join(bodies))

    OUT.write_text(page, encoding="utf-8", newline="\n")
    total = sum(counts.values())
    print(
        "wrote %s (%d entries across %d packages)"
        % (OUT.relative_to(ROOT), total, len(PACKAGES))
    )


if __name__ == "__main__":
    sys.exit(main())
