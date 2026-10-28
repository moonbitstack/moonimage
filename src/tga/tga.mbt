// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// TGA: the format that shipped with a graphics card and never left.
//
// https://www.dca.fee.unicamp.br/~martino/disciplinas/ea978/tgaffs.pdf
//
// TGA has no signature, an eighteen-byte header whose fields were sized for
// 1984, and two ways of storing a row: as it is, or as runs. What it does have
// is the only alpha channel anyone had for a decade, so it is still what a
// texture pipeline is handed.
//
// Reading covers colour-mapped, true-colour and grey images, with and without
// runs, at 8, 15, 16, 24 and 32 bits, and both row orders. Writing produces
// thirty-two or twenty-four bit true-colour, run-length coded unless told not.

///|
/// How wide a pixel is written.
pub(all) enum Depth {
  /// Three bytes per pixel. Alpha is dropped.
  Bits24
  /// Four bytes per pixel, alpha last.
  Bits32
} derive(Eq, Debug)

///|
pub extend Depth with Eq::{equal, not_equal}

///|
pub extend Depth with Debug::{to_repr}

///|
/// What to write.
pub(all) struct EncodeOptions {
  /// How wide a pixel is.
  depth : Depth
  /// Whether to run-length code the pixels, which is smaller whenever there are
  /// areas of one colour and never much larger.
  rle : Bool
  /// Whether to store the top row first. TGA's own convention is bottom first.
  top_down : Bool
}

///|
/// Thirty-two bits per pixel, run-length coded, bottom row first.
pub fn EncodeOptions::default() -> EncodeOptions {
  { depth: Bits32, rle: true, top_down: false, }
}

///|
/// The image in a TGA file.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  ignore((bytes, limits))
  raise @raster.Unsupported(at=0, got="NOT IMPLEMENTED")
}

///|
/// The image as a TGA file.
pub fn encode(image : @raster.Image, options? : EncodeOptions) -> Bytes {
  ignore((image, options))
  abort("moonimage: not implemented yet")
}
