// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// QOI: an image format small enough to read in one sitting.
//
// https://qoiformat.org/qoi-specification.pdf
//
// The whole codec is a header, six opcodes, and a run-length code for pixels
// that repeat. There is no compression stream to be compatible with, which is
// the point: the format was designed so that a decoder is an afternoon's work
// and an encoder is byte-for-byte reproducible.
//
// Reading and writing agree on every detail of the encoder the specification
// describes, so an image that comes in and goes out again is the same file.

///|
/// The image in a QOI file.
///
/// A file that declares three channels decodes to `Rgb8`, one that declares four
/// to `Rgba8`; a file that declares three and then uses an alpha opcode is not an
/// error, and decodes to `Rgba8`.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  ignore((bytes, limits))
  raise @raster.Unsupported(at=0, got="NOT IMPLEMENTED")
}

///|
/// The image as a QOI file.
///
/// An image without alpha is written as three channels, one with alpha as four.
/// The encoder follows the reference exactly, so encoding what was decoded
/// reproduces the file byte for byte.
pub fn encode(image : @raster.Image) -> Bytes {
  ignore(image)
  abort("moonimage: not implemented yet")
}
