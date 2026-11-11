// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Which format a run of bytes is, decided by what the format starts with.
//
// Every format worth the name puts a signature at the front, so the first four
// to twelve bytes are enough. The exceptions are TGA, which has none, and PNM,
// which has six two-byte ones that a text file could also start with; both are
// recognised last, after every format with a distinctive signature has been
// ruled out.

///|
/// The formats this library reads and writes.
#derive(Eq, Debug)
pub(all) enum Format {
  /// PNG, with APNG for animation.
  Png
  /// Quite OK Image.
  Qoi
  /// Windows bitmap.
  Bmp
  /// Truevision TGA.
  Tga
  /// JPEG, baseline and progressive.
  Jpeg
  /// GIF, with animation.
  Gif
  /// WebP, lossless, lossy and animated.
  Webp
  /// TIFF, with pages.
  Tiff
  /// Windows icon, which holds the same picture at several sizes.
  Ico
  /// Windows cursor, which is an icon with a hot spot.
  Cur
  /// The portable anymap family: PBM, PGM, PPM and PAM.
  Pnm
  /// Radiance HDR, whose samples are a shared exponent and three mantissas.
  Hdr
  /// OpenEXR, for pictures that are not yet clamped to a display.
  Exr
  /// Farbfeld: a header and the samples, and nothing else.
  Farbfeld
  /// DirectDraw surface, read for the block-compressed pictures it carries.
  Dds
}

///|
pub extend Format with Eq::{equal, not_equal}

///|
pub extend Format with Debug::{to_repr}

///|
/// A format writes itself as its extension, which is what a person calls it.
pub impl Show for Format with fn output(self, logger) {
  logger.write_string(self.extension())
}

///|
pub extend Format with Show::{to_string, output}

///|
/// The extension a file of this format usually has, without the dot.
pub fn Format::extension(self : Format) -> String {
  match self {
    Png => "png"
    Qoi => "qoi"
    Bmp => "bmp"
    Tga => "tga"
    Jpeg => "jpg"
    Gif => "gif"
    Webp => "webp"
    Tiff => "tiff"
    Ico => "ico"
    Cur => "cur"
    Pnm => "pnm"
    Hdr => "hdr"
    Exr => "exr"
    Farbfeld => "ff"
    Dds => "dds"
  }
}

///|
/// The media type a server would send for this format.
pub fn Format::mime(self : Format) -> String {
  match self {
    Png => "image/png"
    Qoi => "image/qoi"
    Bmp => "image/bmp"
    Tga => "image/x-tga"
    Jpeg => "image/jpeg"
    Gif => "image/gif"
    Webp => "image/webp"
    Tiff => "image/tiff"
    Ico => "image/x-icon"
    Cur => "image/x-cursor"
    Pnm => "image/x-portable-anymap"
    Hdr => "image/vnd.radiance"
    Exr => "image/x-exr"
    Farbfeld => "image/x-farbfeld"
    Dds => "image/vnd-ms.dds"
  }
}

///|
/// Whether the format can hold more than one picture.
///
/// An animated format holds frames over one canvas; TIFF holds pages that are
/// each a picture of its own. Both come out of `decode_animation`, because a
/// caller walking pictures does not care which of the two it was handed.
pub fn Format::is_animated(self : Format) -> Bool {
  match self {
    Png | Gif | Webp | Tiff | Ico | Cur => true
    _ => false
  }
}

///|
/// Which format these bytes are, by signature.
///
/// Raises `Unknown` when nothing matches and `Truncated` when there are too few
/// bytes to tell: two bytes of a PNG are not a PNG, and saying so is better than
/// guessing.
pub fn Format::of(bytes : BytesView) -> Format raise Refused {
  let length = bytes.length()
  if length >= 8 && bytes.has_prefix(png_signature) {
    return Png
  }
  if length >= 3 && bytes.has_prefix(b"\xFF\xD8\xFF") {
    return Jpeg
  }
  if length >= 6 && (bytes.has_prefix(b"GIF87a") || bytes.has_prefix(b"GIF89a")) {
    return Gif
  }
  if length >= 12 &&
    bytes.has_prefix(b"RIFF") &&
    bytes[8:12].equal_to_bytes(b"WEBP") {
    return Webp
  }
  if length >= 4 && bytes.has_prefix(b"qoif") {
    return Qoi
  }
  if length >= 4 && bytes.has_prefix(exr_magic) {
    return Exr
  }
  if length >= 8 && bytes.has_prefix(b"farbfeld") {
    return Farbfeld
  }
  if length >= 4 && bytes.has_prefix(b"DDS ") {
    return Dds
  }
  if length >= 2 && bytes.has_prefix(b"BM") {
    return Bmp
  }
  if is_tiff(bytes) {
    return Tiff
  }
  if length >= 10 &&
    (bytes.has_prefix(b"#?RADIANCE") || bytes.has_prefix(b"#?RGBE")) {
    return Hdr
  }
  if is_icon(bytes) {
    return if bytes[2].to_int() == 2 { Cur } else { Ico }
  }
  if is_pnm(bytes) {
    return Pnm
  }
  if is_tga(bytes) {
    return Tga
  }
  if length < 8 {
    raise Truncated(at=0, want=8)
  }
  raise Unknown(at=0, got=hex(bytes, 0, 8))
}

///|
/// The eight bytes every PNG starts with, which are there to catch a file that
/// travelled through a text mode.
let png_signature : Bytes = b"\x89PNG\r\n\x1a\n"

///|
/// The four bytes every OpenEXR starts with: the same 20000630 in both byte
/// orders, chosen so that a reader can tell which one wrote it.
let exr_magic : Bytes = b"\x76\x2F\x31\x01"

///|
/// Whether these bytes start with a TIFF header.
///
/// Both byte orders, and both of the two versions: BigTIFF raised the offset
/// width to sixty-four bits and marks itself with 43 rather than 42.
fn is_tiff(bytes : BytesView) -> Bool {
  if bytes.length() < 8 {
    return false
  }
  let little = bytes[0].to_int() == 0x49 && bytes[1].to_int() == 0x49
  let big = bytes[0].to_int() == 0x4D && bytes[1].to_int() == 0x4D
  if !little && !big {
    return false
  }
  let version = if little {
    bytes[2].to_int() | (bytes[3].to_int() << 8)
  } else {
    (bytes[2].to_int() << 8) | bytes[3].to_int()
  }
  version == 42 || version == 43
}

///|
/// Whether these bytes are an icon or a cursor.
///
/// The reserved word is zero, the type says which of the two it is, and the
/// count is the number of pictures inside — which has to be at least one, and
/// has to fit in the bytes that are there.
fn is_icon(bytes : BytesView) -> Bool {
  let length = bytes.length()
  if length < 6 {
    return false
  }
  if bytes[0].to_int() != 0 || bytes[1].to_int() != 0 {
    return false
  }
  let kind = bytes[2].to_int() | (bytes[3].to_int() << 8)
  if kind != 1 && kind != 2 {
    return false
  }
  let count = bytes[4].to_int() | (bytes[5].to_int() << 8)
  count > 0 && 6 + count * 16 <= length
}

///|
/// Whether these bytes are a portable anymap of any of the six kinds.
///
/// The signature is two characters, so the third byte has to be whitespace or a
/// comment — otherwise a text file that happens to begin with `P2` would be
/// taken for one.
fn is_pnm(bytes : BytesView) -> Bool {
  let length = bytes.length()
  if length < 3 || bytes[0].to_int() != 0x50 {
    return false
  }
  let kind = bytes[1].to_int()
  if kind < 0x31 || kind > 0x37 {
    return false
  }
  let third = bytes[2].to_int()
  third == 0x0A ||
  third == 0x0D ||
  third == 0x20 ||
  third == 0x09 ||
  third == 0x23
}

///|
/// Whether these bytes are a TGA, which has no signature to say so.
///
/// Two tests, both cheap: the footer TGA 2.0 defines, and a header whose fields
/// only a TGA could have — an image type in the set of six, a pixel depth in the
/// set of four, and a colour map declaration that agrees with the image type.
fn is_tga(bytes : BytesView) -> Bool {
  let length = bytes.length()
  if length >= 26 &&
    bytes[length - 18:length - 16].equal_to_bytes(b"TRUEVISION-XFILE") {
    return true
  }
  if length < 18 {
    return false
  }
  let image_type = bytes[2].to_int()
  let depth = bytes[16].to_int()
  let width = bytes[12].to_int() | (bytes[13].to_int() << 8)
  let height = bytes[14].to_int() | (bytes[15].to_int() << 8)
  let mapped = bytes[1].to_int() <= 1
  let known_type = match image_type {
    1 | 2 | 3 | 9 | 10 | 11 => true
    _ => false
  }
  let known_depth = match depth {
    8 | 15 | 16 | 24 | 32 => true
    _ => false
  }
  let needs_map = match image_type {
    1 | 9 => true
    _ => false
  }
  known_type &&
  known_depth &&
  mapped &&
  (if needs_map { bytes[1].to_int() == 1 } else { true }) &&
  width > 0 &&
  height > 0 &&
  bytes[0].to_int() + 18 < length
}

///|
/// A few bytes as hexadecimal, for the `got` field of a refusal: two digits a
/// byte, in lower case, with a space between the bytes so that a reader can see
/// where one ends and the next begins.
pub fn hex(bytes : BytesView, at : Int32, count : Int32) -> String {
  let start = if at < 0 {
    0
  } else if at > bytes.length() {
    bytes.length()
  } else {
    at
  }
  let end = if start + count > bytes.length() {
    bytes.length()
  } else {
    start + count
  }
  let digits = @base16.encode(bytes.clamped_view(start~, end~))
  let out = StringBuilder()
  for i in 0..<(digits.length() / 2) {
    if i > 0 {
      out.write_char(' ')
    }
    out.write_string(digits[i * 2:i * 2 + 2].to_owned())
  }
  out.to_string()
}
