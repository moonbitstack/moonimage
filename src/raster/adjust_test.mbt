// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The four knobs that change how a picture looks: brightness, contrast, hue and
// inversion. Each is one line of arithmetic, so each is checked against the line
// it is meant to be.

///|
test "brightness multiplies and clamps" {
  let image = image_of(
    3,
    1,
    @raster.PixelFormat::Rgba8,
    b"\x40\x80\xc0\xff\x00\x00\x00\x80\xff\xff\xff\xff",
  )
  let dimmer = image.brightness(0.5)
  assert_eq(at(dimmer, 0, 0), (32, 64, 96, 255))
  // Alpha is not a colour: half as bright is not half as opaque.
  assert_eq(at(dimmer, 1, 0), (0, 0, 0, 128))
  let brighter = image.brightness(4.0)
  assert_eq(at(brighter, 0, 0), (255, 255, 255, 255))
}

///|
test "contrast turns about mid grey" {
  let image = image_of(3, 1, @raster.PixelFormat::Gray8, b"\x00\x80\xff")
  let flat = image.contrast(0.0)
  assert_eq(at(flat, 0, 0).0, 128)
  assert_eq(at(flat, 2, 0).0, 128)
  let harder = image.contrast(2.0)
  // 0.5 stays where it is, and the two ends move away from it and clamp.
  assert_eq(at(harder, 0, 0).0, 0)
  // Mid grey is 128 of 255, which is a hair above a half, so doubling the
  // contrast about a half moves it up by a step rather than leaving it.
  assert_eq(at(harder, 1, 0).0, 129)
  assert_eq(at(harder, 2, 0).0, 255)
}

///|
test "a hue rotation keeps a grey grey" {
  let image = image_of(1, 1, @raster.PixelFormat::Rgb8, b"\x80\x80\x80")
  assert_eq(at(image.hue_rotate(120.0), 0, 0), (128, 128, 128, 255))
}

///|
test "a hue rotation takes red to green and green to blue" {
  let red = image_of(1, 1, @raster.PixelFormat::Rgb8, b"\xff\x00\x00")
  assert_eq(at(red.hue_rotate(120.0), 0, 0), (0, 255, 0, 255))
  let green = image_of(1, 1, @raster.PixelFormat::Rgb8, b"\x00\xff\x00")
  assert_eq(at(green.hue_rotate(120.0), 0, 0), (0, 0, 255, 255))
  // And all the way round is where it started.
  assert_eq(at(red.hue_rotate(360.0), 0, 0), (255, 0, 0, 255))
}

///|
test "inverting twice is not inverting" {
  let image = sample()
  let there = image.invert()
  let back = there.invert()
  for y in 0..<2 {
    for x in 0..<3 {
      let (r, g, b, a) = at(image, x, y)
      assert_eq(at(there, x, y), (255 - r, 255 - g, 255 - b, a))
      assert_eq(at(back, x, y), (r, g, b, a))
    }
  }
}

///|
test "an adjustment keeps the format it was given" {
  let wide = image_of(
    2,
    1,
    @raster.PixelFormat::Rgba16,
    b"\x00\x10\x00\x20\x00\x30\xff\xff\xff\xff\x00\x00\x00\x00\x80\x00",
  )
  assert_eq(wide.brightness(0.5).format, @raster.PixelFormat::Rgba16)
  assert_eq(wide.invert().format, @raster.PixelFormat::Rgba16)
}
