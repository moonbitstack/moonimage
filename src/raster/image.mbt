// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// A rectangle of samples, the format they are in, and how far apart the rows are.
//
// The row stride is separate from the width because a caller uploading to a GPU
// needs rows padded to a multiple of 256 bytes, and because a decoder that has
// to crop by moving a window would rather not copy. Every reader in this library
// produces tight rows; the stride is there for the caller that needs otherwise.
//
// Pixels are immutable once an image is built. Operations return a new image
// rather than writing into the old one, which costs a copy and buys the property
// that an image a caller is holding never changes under it.

///|
/// An image: its shape, its layout, and the bytes.
pub(all) struct Image {
  /// How many pixels across.
  width : Int32
  /// How many pixels down.
  height : Int32
  /// How each pixel is laid out.
  format : PixelFormat
  /// How many bytes from the start of one row to the start of the next.
  stride : Int32
  /// The samples, row after row, `height * stride` bytes or a little less when
  /// the last row is tight.
  pixels : Bytes
  /// Whether the colour channels have already been multiplied by alpha.
  premultiplied : Bool
  /// What the file said about itself.
  metadata : Metadata
}

///|
/// A black image of this shape, with tight rows.
///
/// `stride` is only needed when the rows must be padded; leave it out and the
/// rows are as wide as the pixels.
pub fn Image::new(
  width : Int32,
  height : Int32,
  format : PixelFormat,
  stride? : Int32,
  premultiplied? : Bool,
  metadata? : Metadata,
) -> Image {
  let tight = width * format.bytes()
  let stride = stride.unwrap_or(tight)
  let length = if height == 0 { 0 } else { stride * (height - 1) + tight }
  {
    width,
    height,
    format,
    stride,
    pixels: Bytes::new(length),
    premultiplied: premultiplied.unwrap_or(false),
    metadata: metadata.unwrap_or(Metadata::default()),
  }
}

///|
/// An image over bytes that already exist.
///
/// Raises when the bytes cannot hold the shape: a stride narrower than a row, or
/// fewer bytes than the last row needs.
pub fn Image::of(
  width : Int32,
  height : Int32,
  format : PixelFormat,
  pixels : Bytes,
  stride? : Int32,
  premultiplied? : Bool,
  metadata? : Metadata,
) -> Image raise Refused {
  if width < 0 || height < 0 {
    raise Unexpected(at=0, got="negative size", want="a width and a height")
  }
  let tight = width * format.bytes()
  let stride = stride.unwrap_or(tight)
  if stride < tight {
    raise Unexpected(at=0, got="stride \{stride}", want="at least \{tight}")
  }
  let needed = if height == 0 { 0 } else { stride * (height - 1) + tight }
  if pixels.length() < needed {
    raise Truncated(at=pixels.length(), want=needed - pixels.length())
  }
  {
    width,
    height,
    format,
    stride,
    pixels,
    premultiplied: premultiplied.unwrap_or(false),
    metadata: metadata.unwrap_or(Metadata::default()),
  }
}

///|
/// One row, without its padding.
pub fn Image::row(self : Image, y : Int32) -> BytesView raise Refused {
  if y < 0 || y >= self.height {
    raise OverLimit(limit=self.height, got=y)
  }
  let start = y * self.stride
  self.pixels.exact_view(start~, end=start + self.width * self.format.bytes())
}

///|
/// The pixel at a coordinate, in the units every operation works in.
///
/// Straight alpha, as stored: an image that says it is premultiplied returns
/// premultiplied samples, because pretending otherwise would be a conversion the
/// caller did not ask for.
pub fn Image::pixel(self : Image, x : Int32, y : Int32) -> Pixel raise Refused {
  if x < 0 || x >= self.width {
    raise OverLimit(limit=self.width, got=x)
  }
  if y < 0 || y >= self.height {
    raise OverLimit(limit=self.height, got=y)
  }
  let offset = y * self.stride + x * self.format.bytes()
  read_pixel(self.pixels, offset, self.format)
}

///|
/// The image over a buffer that has just been filled.
///
/// The buffer must hold `width * height` tight rows; every operation that
/// builds an image builds it that way, so the check `Image::of` does would only
/// ever pass.
fn assemble(
  width : Int32,
  height : Int32,
  format : PixelFormat,
  buffer : FixedArray[Byte],
  premultiplied : Bool,
  metadata : Metadata,
) -> Image {
  {
    width,
    height,
    format,
    stride: width * format.bytes(),
    pixels: Bytes::from_array(buffer.clamped_view()),
    premultiplied,
    metadata,
  }
}
