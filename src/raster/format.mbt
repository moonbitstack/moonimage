// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Which format a run of bytes is, decided by what the format starts with.
//
// Every format worth the name puts a signature at the front, so the first four
// to twelve bytes are enough. The exception is TGA, which has none: it was
// designed when a file was told what it was by its extension. TGA is recognised
// by its end-of-file signature where one exists, and otherwise by a header that
// could not be anything else — a real TGA is the last resort, after every
// format with a signature has been ruled out.

///|
/// The formats this library reads and writes.
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
} derive(Eq, Debug)

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
  if length >= 2 && bytes.has_prefix(b"BM") {
    return Bmp
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
/// A few bytes as hexadecimal, for the `got` field of a refusal.
pub fn hex(bytes : BytesView, at : Int32, count : Int32) -> String {
  let mut out = ""
  let end = if at + count > bytes.length() {
    bytes.length()
  } else {
    at + count
  }
  for i in at..<end {
    if i > at {
      out = out + " "
    }
    out = out + hex_byte(bytes[i].to_int())
  }
  out
}

///|
fn hex_byte(value : Int32) -> String {
  let digits = "0123456789abcdef"
  let hi = (value >> 4) & 0xF
  let lo = value & 0xF
  digits[hi:hi + 1].to_owned() + digits[lo:lo + 1].to_owned()
}
