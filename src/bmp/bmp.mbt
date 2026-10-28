// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// BMP: the format Windows never stopped using.
//
// https://www.digicamsoft.com/bmp/bmp.html
//
// The interesting part of BMP is that it grew: the header was 12 bytes, then 40,
// then 108, then 124, and a reader that only knows the first will meet the last
// in the wild. Every version is read here, along with the three ways the format
// compresses pixels — run lengths in four and eight bits, and bit fields, which
// is how a sixteen or thirty-two-bit image says where its channels are.
//
// Writing sticks to what every reader agrees on: uncompressed rows, twenty-four
// bits per pixel, or thirty-two when the caller asks for alpha.

///|
/// How wide a pixel is written.
pub(all) enum Depth {
  /// Three bytes per pixel. Alpha is dropped.
  Bits24
  /// Four bytes per pixel, alpha last. A BMP with an alpha channel is read by
  /// Windows itself; other readers may ignore the fourth byte.
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
  /// Whether to store the top row first, which the format allows by writing a
  /// negative height. Windows writes bottom first, which is the default.
  top_down : Bool
}

///|
/// Thirty-two bits per pixel, bottom row first.
pub fn EncodeOptions::default() -> EncodeOptions {
  { depth: Bits32, top_down: false, }
}
