// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// PNG: the format that replaced GIF and never quite stopped growing.
//
// https://www.w3.org/TR/png-3/
// https://wiki.mozilla.org/APNG_Specification
//
// Everything the specification allows is read: five colour types at every bit
// depth they permit, palettes with alpha, Adam7 interlacing, all five row
// filters, and the chunks that say what the pixels mean. Reading checks every
// CRC, because a damaged PNG that decodes to half an image is worse than one
// that says it is damaged.
//
// Writing produces what a viewer expects: 8 or 16 bits per channel, no palette
// (a palette is smaller only when the image already has few colours, and the
// caller who needs that can ask for it later), adaptive row filtering, and the
// metadata copied through.

///|
/// Which row filter an encoder uses.
///
/// `Adaptive` is the one the specification recommends: try all five, keep the
/// one whose output has the smallest sum of absolute differences. It costs four
/// extra passes over each row and usually pays for itself several times over in
/// what the compressor then has to store.
pub(all) enum Filter {
  /// Pick per row.
  Adaptive
  /// Store the row as it is.
  None
  /// Subtract the pixel to the left.
  Sub
  /// Subtract the pixel above.
  Up
  /// Subtract the average of the two.
  Average
  /// Subtract the one the Paeth predictor picks.
  Paeth
} derive(Eq, Debug)

///|
pub extend Filter with Eq::{equal, not_equal}

///|
pub extend Filter with Debug::{to_repr}

///|
/// What to trade when writing a PNG.
pub(all) struct EncodeOptions {
  /// Deflate level, 0 to 9.
  level : Int32
  /// How rows are filtered before deflating.
  filter : Filter
  /// Whether to write the image in seven passes, which helps a viewer show
  /// something before the last byte arrives and makes the file slightly larger.
  interlace : Bool
  /// Whether to write the metadata the image carries.
  metadata : Bool
  /// Whether to write a picture of at most 256 colours as a palette. A palette
  /// costs a table of colours and saves three quarters of every pixel, which is
  /// the difference between a sprite and a photograph in one flag.
  palette : Bool
}

///|
/// Balanced: level 6, adaptive filtering, not interlaced, metadata kept.
pub fn EncodeOptions::default() -> EncodeOptions {
  {
    level: 6,
    filter: Adaptive,
    interlace: false,
    metadata: true,
    palette: true,
  }
}

///|
/// For when the bytes are going to a screen immediately: level 1, no filtering,
/// no metadata.
pub fn EncodeOptions::fast() -> EncodeOptions {
  { level: 1, filter: None, interlace: false, metadata: false, palette: true, }
}

///|
/// For when the file is going to be stored: level 9, adaptive filtering.
pub fn EncodeOptions::best() -> EncodeOptions {
  {
    level: 9,
    filter: Adaptive,
    interlace: false,
    metadata: true,
    palette: true,
  }
}
