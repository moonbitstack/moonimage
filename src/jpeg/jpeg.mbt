// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// JPEG: the format everybody has and nobody loves.
//
// https://www.w3.org/Graphics/JPEG/itu-t81.pdf
//
// Reading covers what cameras and editors produce: baseline and progressive
// Huffman-coded images, greyscale and three-channel colour, every chroma
// subsampling the standard permits, restart intervals, and the four-channel
// CMYK and YCCK that a print workflow writes. The EXIF orientation is read out
// rather than applied, because a caller compositing into a canvas usually wants
// the pixels as stored.
//
// Writing is baseline only, and deliberately so: progressive saves a little size
// and costs a decoder twice the passes. The quantisation tables follow the
// example tables of the standard, scaled by quality and clamped at one, which is
// what every other encoder does and therefore what a comparison will be against.
//
// What is not read: arithmetic coding, lossless JPEG, and JPEG 2000, none of
// which appears in a file a browser would produce.

///|
/// How much of the colour resolution to give up.
///
/// The eye resolves brightness far better than hue, so the two colour channels
/// are stored at half resolution or a quarter, which is where most of JPEG's
/// size comes from.
pub(all) enum Subsampling {
  /// Full resolution in all three channels.
  Yuv444
  /// Colour at half horizontal resolution.
  Yuv422
  /// Colour at half resolution both ways, which is what a camera writes.
  Yuv420
} derive(Eq, Debug)

///|
pub extend Subsampling with Eq::{equal, not_equal}

///|
pub extend Subsampling with Debug::{to_repr}

///|
/// What to trade when writing a JPEG.
pub(all) struct EncodeOptions {
  /// 1 to 100. 90 is the point where a photograph stops showing artefacts at
  /// normal viewing distance.
  quality : Int32
  /// How much colour resolution to give up.
  subsampling : Subsampling
}

///|
/// Quality 90, colour at half resolution both ways.
pub fn EncodeOptions::default() -> EncodeOptions {
  { quality: 90, subsampling: Yuv420, }
}

///|
/// Quality 95, full colour resolution: for a picture that will be edited again.
pub fn EncodeOptions::best() -> EncodeOptions {
  { quality: 95, subsampling: Yuv444, }
}

///|
/// The eight ways a camera says its picture is rotated, numbered the way EXIF
/// numbers them.
pub(all) enum Orientation {
  /// As stored.
  Normal
  /// Mirrored left to right.
  FlipHorizontal
  /// Upside down.
  Rotate180
  /// Mirrored top to bottom.
  FlipVertical
  /// Mirrored across the main diagonal.
  Transpose
  /// Turned a quarter clockwise.
  Rotate90
  /// Mirrored across the other diagonal.
  Transverse
  /// Turned a quarter anticlockwise.
  Rotate270
} derive(Eq, Debug)

///|
pub extend Orientation with Eq::{equal, not_equal}

///|
pub extend Orientation with Debug::{to_repr}

///|
/// The number EXIF writes for this orientation, 1 to 8.
pub fn Orientation::code(self : Orientation) -> Int32 {
  match self {
    Normal => 1
    FlipHorizontal => 2
    Rotate180 => 3
    FlipVertical => 4
    Transpose => 5
    Rotate90 => 6
    Transverse => 7
    Rotate270 => 8
  }
}

///|
/// The orientation a number stands for, or `None` if it is not one of the eight.
pub fn Orientation::of(code : Int32) -> Orientation? {
  match code {
    1 => Some(Normal)
    2 => Some(FlipHorizontal)
    3 => Some(Rotate180)
    4 => Some(FlipVertical)
    5 => Some(Transpose)
    6 => Some(Rotate90)
    7 => Some(Transverse)
    8 => Some(Rotate270)
    _ => None
  }
}

///|
/// The orientation in the EXIF block of a JPEG, or `None` when there is no EXIF
/// or it says nothing this library understands.
///
/// A damaged EXIF block is not a damaged image: it comes back as `None` rather
/// than as a refusal, because a picture with a broken camera note is still a
/// picture.
pub fn exif_orientation(bytes : BytesView) -> Orientation? {
  ignore(bytes)
  abort("moonimage: not implemented yet")
}

///|
/// The image in a JPEG file.
///
/// With `orient=true` the pixels are rearranged to match the EXIF orientation,
/// which is what a viewer does; without it they are as stored.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
  orient? : Bool,
) -> @raster.Image raise @raster.Refused {
  ignore((bytes, limits, orient))
  raise @raster.Unsupported(at=0, got="NOT IMPLEMENTED")
}

///|
/// The image as a baseline JPEG.
pub fn encode(image : @raster.Image, options? : EncodeOptions) -> Bytes {
  ignore((image, options))
  abort("moonimage: not implemented yet")
}
