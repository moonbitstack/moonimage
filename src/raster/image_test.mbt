// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The image itself: how it is laid out, what it refuses, and what it says about
// the pixels in it.

///|
test "a new image is the size it says, with tight rows and zeros" {
  let image = @raster.Image::new(4, 3, @raster.PixelFormat::Rgb8)
  assert_eq(image.width, 4)
  assert_eq(image.height, 3)
  assert_eq(image.stride, 12)
  assert_eq(image.pixels.length(), 36)
  assert_eq(image.premultiplied, false)
  assert_eq(image.metadata.is_empty(), true)
  assert_eq(at(image, 3, 2), (0, 0, 0, 255))
}

///|
test "an image over existing bytes keeps its stride, and refuses a short one" {
  let pixels = Bytes::new(2 * 20)
  let padded = @raster.Image::of(
    2,
    2,
    @raster.PixelFormat::Rgba8,
    pixels,
    stride=20,
  ) catch {
    error => abort("a padded image is well formed: \{error}")
  }
  assert_eq(padded.stride, 20)
  let too_short = try {
    ignore(@raster.Image::of(2, 2, @raster.PixelFormat::Rgba8, Bytes::new(8)))
    None
  } catch {
    error => Some(error)
  }
  assert_eq(too_short, Some(@raster.Refused::Truncated(at=8, want=8)))
  let narrow = try {
    ignore(
      @raster.Image::of(
        2,
        2,
        @raster.PixelFormat::Rgba8,
        Bytes::new(32),
        stride=4,
      ),
    )
    None
  } catch {
    error => Some(error)
  }
  assert_true(narrow is Some(_))
}

///|
test "rows and pixels outside the image are refused, not wrapped" {
  let image = sample()
  let row = image.row(1) catch {
    error => abort("the second row is in range: \{error}")
  }
  assert_eq(row.length(), 12)
  let outside = try {
    ignore(image.row(2))
    None
  } catch {
    error => Some(error)
  }
  assert_eq(outside, Some(@raster.Refused::OverLimit(limit=2, got=2)))
  let behind = try {
    ignore(image.pixel(-1, 0))
    None
  } catch {
    error => Some(error)
  }
  assert_eq(behind, Some(@raster.Refused::OverLimit(limit=3, got=-1)))
}

///|
test "a pixel reads back as the four samples it was written with" {
  let image = sample()
  assert_eq(at(image, 0, 0), (10, 20, 30, 255))
  assert_eq(at(image, 2, 0), (70, 80, 90, 255))
  assert_eq(at(image, 1, 1), (130, 140, 150, 255))
}

///|
test "the formats describe themselves consistently" {
  let formats = [
    @raster.PixelFormat::Gray8,
    @raster.PixelFormat::GrayAlpha8,
    @raster.PixelFormat::Rgb8,
    @raster.PixelFormat::Rgba8,
    @raster.PixelFormat::Gray16,
    @raster.PixelFormat::GrayAlpha16,
    @raster.PixelFormat::Rgb16,
    @raster.PixelFormat::Rgba16,
    @raster.PixelFormat::RgbaF32,
  ]
  for format in formats {
    assert_eq(format.bytes(), format.channels() * (format.bits() / 8))
    assert_eq(
      format.has_alpha(),
      format.channels() == 2 || format.channels() == 4,
    )
    assert_eq(format.is_float(), format == @raster.PixelFormat::RgbaF32)
  }
  assert_eq(@raster.PixelFormat::Gray16.is_gray(), true)
  assert_eq(@raster.PixelFormat::Rgb8.is_gray(), false)
}

///|
test "the limits count both the shape and the area" {
  let limits = @raster.Limits::default()
  assert_true(limits.allows(640, 480))
  assert_eq(limits.allows(20_000, 20_000), false)
  let narrow : @raster.Limits = {
    width: 100,
    height: 100,
    pixels: 1_000,
    bytes: 4_000,
  }
  assert_eq(narrow.allows(100, 100), false)
  assert_true(narrow.allows(40, 25))
  let refused = try {
    narrow.check(100, 11)
    None
  } catch {
    error => Some(error)
  }
  // The shape fits; the area does not.
  assert_eq(refused, Some(@raster.Refused::OverLimit(limit=1_000, got=1_100)))
  let too_wide = try {
    narrow.check(101, 1)
    None
  } catch {
    error => Some(error)
  }
  assert_eq(too_wide, Some(@raster.Refused::OverLimit(limit=100, got=101)))
  let bytes_refused = try {
    narrow.check_bytes(4_001)
    None
  } catch {
    error => Some(error)
  }
  assert_eq(
    bytes_refused,
    Some(@raster.Refused::OverLimit(limit=4_000, got=4_001)),
  )
}

///|
test "a refusal says where and what" {
  let message = @raster.Refused::Unexpected(
    at=12,
    got="0x00",
    want="a chunk type",
  ).to_string()
  assert_eq(message, "at 12: got 0x00, want a chunk type")
  let shown = @raster.Refused::Truncated(at=40, want=8).to_string()
  assert_eq(shown, "at 40: 8 bytes wanted")
}
