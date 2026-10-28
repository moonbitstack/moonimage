// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// How much image a caller is willing to be handed.
//
// Every reader in the library takes this, because every format lets the file
// declare its own size before any pixels arrive, and a decoder that trusts the
// declaration is a decoder that allocates whatever a hostile file asks for. The
// ceiling is checked before the allocation, not after.

///|
/// The ceilings a decoder works under.
///
/// The defaults are the ones a desktop application can live with: a texture no
/// larger than a modern GPU takes, and a megabyte of pixels at the very most.
/// A caller reading files from the network should set them lower; a caller
/// reading its own assets can leave them alone.
pub(all) struct Limits {
  /// The widest image accepted, in pixels.
  width : Int32
  /// The tallest image accepted, in pixels.
  height : Int32
  /// The most pixels accepted, whatever the shape: this is the one that stops a
  /// long thin image from slipping past the two above.
  pixels : Int32
  /// The most bytes a decoder may produce while unpacking: a compressed stream
  /// can expand without limit, so the expansion is capped separately.
  bytes : Int32
}

///|
/// The desktop defaults: a million pixels a side, 256 megapixels in all, and a
/// gigabyte of expansion.
pub fn Limits::default() -> Limits {
  {
    width: 1_048_576,
    height: 1_048_576,
    pixels: 268_435_456,
    bytes: 1_073_741_824,
  }
}

///|
/// What a viewer of untrusted uploads would choose: 8192 square, 64 megapixels,
/// 256 MiB of expansion.
pub fn Limits::strict() -> Limits {
  { width: 8192, height: 8192, pixels: 67_108_864, bytes: 268_435_456, }
}

///|
/// Whether an image of this shape is inside the limits.
pub fn Limits::allows(self : Limits, width : Int32, height : Int32) -> Bool {
  width >= 0 &&
  height >= 0 &&
  width <= self.width &&
  height <= self.height &&
  width.to_int64() * height.to_int64() <= self.pixels.to_int64()
}

///|
/// Refuse an image of this shape unless the limits allow it.
///
/// The pixel count is multiplied in 64 bits so that a declaration of
/// 65535 × 65535 cannot wrap into a small number and pass.
pub fn Limits::check(
  self : Limits,
  width : Int32,
  height : Int32,
) -> Unit raise Refused {
  if width < 0 || height < 0 {
    raise Unexpected(at=0, got="negative size", want="a width and a height")
  }
  if width > self.width {
    raise OverLimit(limit=self.width, got=width)
  }
  if height > self.height {
    raise OverLimit(limit=self.height, got=height)
  }
  let pixels = width.to_int64() * height.to_int64()
  if pixels > self.pixels.to_int64() {
    raise OverLimit(
      limit=self.pixels,
      got=if pixels > 2_147_483_647L { 2_147_483_647 } else { pixels.to_int() },
    )
  }
}

///|
/// Refuse a buffer of this many bytes unless the limits allow it.
pub fn Limits::check_bytes(self : Limits, bytes : Int32) -> Unit raise Refused {
  if bytes > self.bytes {
    raise OverLimit(limit=self.bytes, got=bytes)
  }
}
