// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Making an image a different size.
//
// Three filters, because the three answer different questions. Nearest is what
// a pixel artist wants: a pixel becomes a square, and no colour that was not in
// the original appears. Bilinear is what a photograph wants when it is being
// scaled a little: cheap, and smooth enough that the result does not crawl.
// Lanczos is what it wants when it is being scaled a lot or viewed still: six
// taps per axis, sharp edges, and a small amount of ringing that is the price of
// the sharpness.
//
// Alpha is resampled premultiplied even when the image is not stored that way.
// A transparent pixel usually has an arbitrary colour behind its alpha, and
// averaging that colour into its neighbours is how a sprite gets a dark fringe.

///|
/// How a scaler decides what an unknown pixel is worth.
pub(all) enum Sampling {
  /// The nearest pixel, and nothing else: no new colours.
  Nearest
  /// A weighted average of the four nearest, weights linear in distance.
  Bilinear
  /// A weighted average of the six nearest per axis, weights from the Lanczos
  /// window with a = 3.
  Lanczos
} derive(Eq, Debug)

///|
pub extend Sampling with Eq::{equal, not_equal}

///|
pub extend Sampling with Debug::{to_repr}

///|
/// The image at a new size.
///
/// Raises when either dimension is not positive, and when the result would be
/// larger than `Limits::default()` — a scaler is easy to point at a huge size by
/// accident.
pub fn Image::scale(
  self : Image,
  width : Int32,
  height : Int32,
  sampling? : Sampling,
) -> Image raise Refused {
  ignore((self, width, height, sampling))
  raise Unsupported(at=0, got="scaling is not implemented yet")
}
