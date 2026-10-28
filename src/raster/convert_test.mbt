// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Conversions between sample formats, and the premultiplication that a compositor
// needs. The cases are the ones where the arithmetic has a right answer: a value
// that survives a widening, a value that rounds when it narrows, and the grey a
// colour becomes.

///|
test "widening and narrowing an eight-bit image is the identity" {
  let pixels : Bytes = b"\x00\x01\x7f\x80\xfe\xff\x40\x20"
  let original = image_of(2, 1, @raster.PixelFormat::Rgba8, pixels)
  let round = original
    .convert(@raster.PixelFormat::Rgba16)
    .convert(@raster.PixelFormat::Rgba8)
  assert_eq(bytes_of(round), pixels)
}

///|
test "narrowing rounds to nearest rather than truncating" {
  // 0x8000 is half of 65535, which is 127.5 in eight bits: it rounds up.
  let half = image_of(1, 1, @raster.PixelFormat::Gray16, b"\x80\x00")
  assert_eq(bytes_of(half.convert(@raster.PixelFormat::Gray8)), b"\x80")
  // 0x0080 is far below half of a byte; it rounds to zero, not to one.
  let low = image_of(1, 1, @raster.PixelFormat::Gray16, b"\x00\x80")
  assert_eq(bytes_of(low.convert(@raster.PixelFormat::Gray8)), b"\x00")
  // 0xffff is 255 in eight bits, and 0xff00 is nine tenths of one step short.
  let high = image_of(1, 1, @raster.PixelFormat::Gray16, b"\xff\xff")
  assert_eq(bytes_of(high.convert(@raster.PixelFormat::Gray8)), b"\xff")
  let almost = image_of(1, 1, @raster.PixelFormat::Gray16, b"\xff\x00")
  assert_eq(bytes_of(almost.convert(@raster.PixelFormat::Gray8)), b"\xfe")
}

///|
test "colour to grey is a luminance, and grey to colour fills three channels" {
  let red = image_of(1, 1, @raster.PixelFormat::Rgb8, b"\xff\x00\x00")
  assert_eq(bytes_of(red.convert(@raster.PixelFormat::Gray8)), b"\x4c")
  let white = image_of(1, 1, @raster.PixelFormat::Rgb8, b"\xff\xff\xff")
  assert_eq(bytes_of(white.convert(@raster.PixelFormat::Gray8)), b"\xff")
  let grey = image_of(1, 1, @raster.PixelFormat::Gray8, b"\x40")
  assert_eq(bytes_of(grey.convert(@raster.PixelFormat::Rgb8)), b"\x40\x40\x40")
}

///|
test "dropping alpha keeps the colour, adding it makes the image opaque" {
  let with_alpha = image_of(
    1,
    1,
    @raster.PixelFormat::Rgba8,
    b"\x0a\x14\x1e\x28",
  )
  assert_eq(
    bytes_of(with_alpha.convert(@raster.PixelFormat::Rgb8)),
    b"\x0a\x14\x1e",
  )
  let without = image_of(1, 1, @raster.PixelFormat::Rgb8, b"\x0a\x14\x1e")
  assert_eq(
    bytes_of(without.convert(@raster.PixelFormat::Rgba8)),
    b"\x0a\x14\x1e\xff",
  )
}

///|
test "a float image holds the same numbers as an eight-bit one" {
  let pixels : Bytes = b"\xff\x80\x00\xc0"
  let source = image_of(1, 1, @raster.PixelFormat::Rgba8, pixels)
  let floats = source.convert(@raster.PixelFormat::RgbaF32)
  let pixel = floats.pixel(0, 0) catch { error => abort("in range: \{error}") }
  assert_true((pixel.r - 1.0).abs() < 1.0e-6)
  assert_true((pixel.g - 128.0 / 255.0).abs() < 1.0e-6)
  assert_true(pixel.b.abs() < 1.0e-6)
  assert_true((pixel.a - 192.0 / 255.0).abs() < 1.0e-6)
  assert_eq(bytes_of(floats.convert(@raster.PixelFormat::Rgba8)), pixels)
}

///|
test "premultiplying multiplies, and taking it back is within a step" {
  let source = image_of(1, 1, @raster.PixelFormat::Rgba8, b"\xc8\x64\x32\x80")
  let premultiplied = source.to_premultiplied()
  assert_eq(premultiplied.premultiplied, true)
  assert_eq(bytes_of(premultiplied), b"\x64\x32\x19\x80")
  let straight = premultiplied.to_straight()
  assert_eq(straight.premultiplied, false)
  let back = bytes_of(straight)
  // 200 -> 100 -> 199: one step lost in the rounding, which is what a byte can do.
  assert_eq(back[0].to_int(), 199)
  assert_eq(back[1].to_int(), 100)
  assert_eq(back[2].to_int(), 50)
  assert_eq(back[3].to_int(), 128)
}

///|
test "premultiplying twice is premultiplying once, and opaque alpha changes nothing" {
  let source = image_of(1, 1, @raster.PixelFormat::Rgba8, b"\xc8\x64\x32\x80")
  let once = source.to_premultiplied()
  assert_eq(bytes_of(once.to_premultiplied()), bytes_of(once))
  let solid = image_of(1, 1, @raster.PixelFormat::Rgba8, b"\xc8\x64\x32\xff")
  assert_eq(bytes_of(solid.to_premultiplied()), b"\xc8\x64\x32\xff")
  let no_alpha = image_of(1, 1, @raster.PixelFormat::Rgb8, b"\xc8\x64\x32")
  assert_eq(bytes_of(no_alpha.to_premultiplied()), b"\xc8\x64\x32")
}

///|
test "sixteen-bit premultiplication rounds the same way" {
  let source = image_of(
    1,
    1,
    @raster.PixelFormat::Rgba16,
    b"\xff\xff\x00\x00\x00\x00\x80\x00",
  )
  let premultiplied = source.to_premultiplied()
  // 65535 * 32768 / 65535 = 32768, and the zero channels stay zero.
  assert_eq(bytes_of(premultiplied), b"\x80\x00\x00\x00\x00\x00\x80\x00")
}

///|
test "a float image premultiplies exactly, because it can" {
  let source = image_of(
    1,
    1,
    @raster.PixelFormat::RgbaF32,
    b"\x00\x00\x80\x3f\x00\x00\x00\x3f\x00\x00\x00\x00\x00\x00\x00\x3f",
  )
  let premultiplied = source.to_premultiplied()
  let pixel = premultiplied.pixel(0, 0) catch {
    error => abort("in range: \{error}")
  }
  assert_true((pixel.r - 0.5).abs() < 1.0e-6)
  assert_true((pixel.g - 0.25).abs() < 1.0e-6)
  assert_true(pixel.b.abs() < 1.0e-6)
  assert_true((pixel.a - 0.5).abs() < 1.0e-6)
  let straight = premultiplied.to_straight().pixel(0, 0) catch {
      error => abort("in range: \{error}")
    }
  assert_true((straight.r - 1.0).abs() < 1.0e-6)
  assert_true((straight.g - 0.5).abs() < 1.0e-6)
}
