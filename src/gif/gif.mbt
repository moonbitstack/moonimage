// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// GIF: 256 colours, one transparent, and a delay per frame.
//
// https://www.w3.org/Graphics/GIF/spec-gif89a.txt
//
// The format is small and the rules around it are not. A frame may have its own
// palette, may be interlaced, may cover part of the canvas, may be transparent
// in one colour, and may ask for the rectangle to be kept, cleared or restored
// afterwards. All of that is read here, because an animation that ignores the
// disposal rule shows the previous frame bleeding through.
//
// Writing has one hard problem: 256 colours. An image that already has few
// enough is stored exactly; one that does not is reduced by median cut, and
// optionally dithered with Floyd–Steinberg so that a gradient does not band.

///|
/// What to trade when writing a GIF.
pub(all) struct EncodeOptions {
  /// Whether to dither when the image has more colours than a palette holds.
  /// On, a gradient looks like a gradient; off, it bands, and the file is
  /// smaller.
  dither : Bool
  /// Whether to keep alpha as GIF's one transparent colour. Off, alpha becomes
  /// the nearest opaque colour.
  transparent : Bool
}

///|
/// Dither, and keep transparency.
pub fn EncodeOptions::default() -> EncodeOptions {
  { dither: true, transparent: true, }
}
