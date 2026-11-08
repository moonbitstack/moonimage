// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The seam to the colour package: a pixel out, a colour back, and the hue
// rotation that is built on it.

///|
test "a pixel becomes a colour and comes back" {
  let pixel : @raster.Pixel = { r: 0.25, g: 0.5, b: 0.75, a: 1.0, }
  let colour = pixel.to_color()
  assert_eq(colour.to_srgb().x, 0.25)
  let back = @raster.Pixel::of_color(colour)
  assert_eq(back, pixel)
}

///|
test "a colour in another space arrives as sRGB samples" {
  // Half lightness is grey in HSL, whatever the hue.
  let colour = @moonrgba.Color::hsl(120.0, 1.0, 0.5, alpha=0.25)
  let pixel = @raster.Pixel::of_color(colour)
  assert_eq(pixel.a, 0.25)
  // A fully saturated green at half lightness is the green of the sRGB cube.
  assert_true(pixel.g > 0.99)
  // The conversion goes through a matrix and back, so the two channels that
  // should be nought are a rounding error away from it.
  assert_true(pixel.r.abs() < 1.0e-9)
  assert_true(pixel.b.abs() < 1.0e-9)
}

///|
test "a grey has no hue to turn" {
  let grey : @raster.Pixel = { r: 0.4, g: 0.4, b: 0.4, a: 1.0, }
  assert_eq(grey.rotate_hue(90.0), grey)
}

///|
test "turning the hue of a colour leaves its lightness alone" {
  let red : @raster.Pixel = { r: 1.0, g: 0.0, b: 0.0, a: 1.0, }
  let green = red.rotate_hue(120.0)
  assert_true(green.g > 0.99)
  assert_true(green.r < 0.01)
  // And going round in a circle is where it started.
  let round = red.rotate_hue(360.0)
  assert_true((round.r - red.r).abs() < 0.01)
  assert_true((round.g - red.g).abs() < 0.01)
}
