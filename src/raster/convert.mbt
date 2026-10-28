// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Changing how pixels are spelled without changing what they say.
//
// A conversion here is one of five moves: widening 8 bits to 16 or to a float,
// narrowing back, adding an alpha channel, dropping one, and turning grey into
// equal parts red, green and blue. Nothing is gamma-corrected, because nothing
// here knows what gamma the image means; nothing is premultiplied, unless asked.
//
// Narrowing rounds rather than truncates. Truncation costs half a step of
// brightness on average, which over a photograph is a visible darkening, and
// costs nothing to avoid.

///|
/// The same image, in another sample format.
///
/// Colour is preserved as far as the target can hold it: a grey image becomes
/// grey, an image without alpha becomes opaque, and narrowing rounds to nearest.
pub fn Image::convert(self : Image, format : PixelFormat) -> Image {
  ignore((self, format))
  abort("moonimage: not implemented yet")
}

///|
/// The same image with colour multiplied by alpha.
///
/// Idempotent: an image that already says it is premultiplied comes back
/// unchanged, so a caller can ask without checking first.
pub fn Image::to_premultiplied(self : Image) -> Image {
  ignore(self)
  abort("moonimage: not implemented yet")
}

///|
/// The same image with alpha divided back out.
///
/// The inverse of `to_premultiplied` up to rounding, which is why a round trip
/// is only exact for images whose colour is already premultiplied.
pub fn Image::to_straight(self : Image) -> Image {
  ignore(self)
  abort("moonimage: not implemented yet")
}
