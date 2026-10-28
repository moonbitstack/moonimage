// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Moving pixels around without looking at what they are.
//
// A flip, a quarter turn and a crop are the three operations a caller needs to
// fix an image that arrived the wrong way up, and all three are the same kind of
// work: copy a pixel from here to there. Because the format is never consulted,
// a 16-bit image and a grey one go through the same code, and no precision is
// lost on the way.

///|
/// The image reflected left to right.
pub fn Image::flip_horizontal(self : Image) -> Image {
  ignore(self)
  abort("moonimage: not implemented yet")
}

///|
/// The image reflected top to bottom.
pub fn Image::flip_vertical(self : Image) -> Image {
  ignore(self)
  abort("moonimage: not implemented yet")
}

///|
/// The image turned a quarter turn clockwise, `quarters` times.
///
/// Negative counts turn anticlockwise, and anything beyond four wraps: this is
/// a total function because a rotation is.
pub fn Image::rotate(self : Image, quarters? : Int32) -> Image {
  ignore((self, quarters))
  abort("moonimage: not implemented yet")
}

///|
/// The rectangle at (`x`, `y`) of the given size, as an image of its own.
///
/// Raises when the rectangle does not fit: a crop is a claim about the image,
/// and a crop that reaches outside it is a bug in the caller.
pub fn Image::crop(
  self : Image,
  x : Int32,
  y : Int32,
  width : Int32,
  height : Int32,
) -> Image raise Refused {
  ignore((self, x, y, width, height))
  raise Unsupported(at=0, got="crop is not implemented yet")
}
