// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Sharpening, which is defined as the difference between a picture and its own
// blur, and the premultiplication that keeps a blur from bleeding colour out of
// a transparent pixel.

///|
test "a flat picture is not sharpened into noise" {
  let flat = image_of(
    4,
    4,
    @raster.PixelFormat::Gray8,
    b"\x50\x50\x50\x50\x50\x50\x50\x50\x50\x50\x50\x50\x50\x50\x50\x50",
  )
  assert_eq(
    bytes_of(flat.unsharp_mask(radius=1.0, amount=200.0)),
    bytes_of(flat),
  )
}

///|
test "an edge is pushed out by the amount asked for" {
  // Two flat halves: the blur of the edge is a gradient, and the difference
  // between the two is what is added back.
  let edge = image_of(4, 1, @raster.PixelFormat::Gray8, b"\x00\x00\xff\xff")
  let sharpened = edge.unsharp_mask(radius=1.0, amount=100.0, threshold=0)
  let (dark, _, _, _) = at(sharpened, 0, 0)
  let (bright, _, _, _) = at(sharpened, 3, 0)
  // The dark side goes darker and the bright side brighter, and neither leaves
  // the range it is in.
  assert_true(dark <= 0)
  assert_true(bright >= 255)
}

///|
test "a threshold leaves a small difference alone" {
  let gentle = image_of(3, 1, @raster.PixelFormat::Gray8, b"\x80\x82\x84")
  let untouched = gentle.unsharp_mask(radius=1.0, amount=200.0, threshold=40)
  assert_eq(bytes_of(untouched), bytes_of(gentle))
}

///|
test "a blur keeps a transparent pixel's colour out of its neighbours" {
  // A red pixel with no alpha next to a green one with full alpha: blurring
  // colour and alpha separately would let the red show through.
  let image = image_of(
    3,
    1,
    @raster.PixelFormat::Rgba8,
    b"\xff\x00\x00\x00\x00\xff\x00\xff\x00\xff\x00\x00",
  )
  let blurred = image.blur(1.0)
  for x in 0..<3 {
    let (r, g, _, a) = at(blurred, x, 0)
    if a > 0 {
      // Wherever there is anything to see, it is green: the colour under a
      // zero alpha was not averaged in.
      assert_eq(r, 0)
      assert_eq(g, 255)
    }
  }
}

///|
test "a radius of nought is the picture itself" {
  let image = sample()
  assert_eq(bytes_of(image.blur(0.0)), bytes_of(image))
  assert_eq(bytes_of(image.unsharp_mask(radius=0.0)), bytes_of(image))
}
