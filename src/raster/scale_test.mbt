// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Scaling, where the three filters have to disagree in the places they should
// and agree in the places they must: a flat image stays flat, a transparent
// pixel contributes nothing, and nearest invents no colours.

///|
fn scaled(
  image : @raster.Image,
  width : Int32,
  height : Int32,
  sampling : @raster.Sampling,
) -> @raster.Image {
  image.scale(width, height, sampling~) catch {
    error => abort("the size is allowed: \{error}")
  }
}

///|
test "nearest turns a pixel into a square and invents nothing" {
  let image = image_of(
    2,
    1,
    @raster.PixelFormat::Rgba8,
    b"\x10\x00\x00\xff\x20\x00\x00\xff",
  )
  let big = scaled(image, 4, 2, @raster.Sampling::Nearest)
  assert_eq(big.width, 4)
  assert_eq(big.height, 2)
  assert_eq(
    bytes_of(big),
    b"\x10\x00\x00\xff\x10\x00\x00\xff\x20\x00\x00\xff\x20\x00\x00\xff" +
    b"\x10\x00\x00\xff\x10\x00\x00\xff\x20\x00\x00\xff\x20\x00\x00\xff",
  )
}

///|
test "every filter leaves a flat image flat" {
  let flat = image_of(
    2,
    2,
    @raster.PixelFormat::Rgba8,
    b"\x05\x06\x07\xff\x05\x06\x07\xff\x05\x06\x07\xff\x05\x06\x07\xff",
  )
  for
    sampling in [
      @raster.Sampling::Nearest,
      @raster.Sampling::Bilinear,
      @raster.Sampling::Lanczos,
    ] {
    let bigger = scaled(flat, 7, 5, sampling)
    assert_eq(bigger.width, 7)
    assert_eq(bigger.height, 5)
    for y in 0..<5 {
      for x in 0..<7 {
        assert_eq(at(bigger, x, y), (5, 6, 7, 255))
      }
    }
  }
}

///|
test "bilinear takes the average of the two it lands between" {
  let ramp = image_of(4, 1, @raster.PixelFormat::Gray8, b"\x00\x64\xc8\xff")
  let half = scaled(ramp, 2, 1, @raster.Sampling::Bilinear)
  // 0 and 100 average to 50; 200 and 255 average to 227.5, which rounds to 228.
  assert_eq(bytes_of(half), b"\x32\xe4")
}

///|
test "a transparent pixel contributes its alpha and not its colour" {
  let image = image_of(
    2,
    1,
    @raster.PixelFormat::Rgba8,
    b"\xff\x00\x00\xff\x00\xff\x00\x00",
  )
  for sampling in [@raster.Sampling::Bilinear, @raster.Sampling::Lanczos] {
    let wide = scaled(image, 5, 1, sampling)
    // The right-hand pixel is fully transparent, so wherever it is mixed in, no
    // green reaches the result: the colour under a zero alpha is not averaged.
    // Where the result is still visible, it is the red of the left-hand pixel.
    for x in 0..<5 {
      let (r, g, b, a) = at(wide, x, 0)
      assert_eq(g, 0)
      assert_eq(b, 0)
      if a > 0 {
        assert_eq(r, 255)
      }
    }
  }
}

///|
test "scaling to a size with no pixels, or past the limits, is refused" {
  let image = sample()
  let empty = try {
    ignore(image.scale(0, 4))
    false
  } catch {
    @raster.Refused::Unexpected(..) => true
    _ => false
  }
  assert_true(empty)
  let huge = try {
    ignore(image.scale(40_000, 40_000))
    false
  } catch {
    @raster.Refused::OverLimit(..) => true
    _ => false
  }
  assert_true(huge)
}

///|
test "scaling to the same size is the same image" {
  let image = sample()
  let same = scaled(image, 3, 2, @raster.Sampling::Lanczos)
  assert_eq(bytes_of(same), bytes_of(image))
}

///|
test "an upscaled ramp stays inside the values it started with" {
  let ramp = image_of(4, 1, @raster.PixelFormat::Gray8, b"\x00\x40\x80\xff")
  let wide = scaled(ramp, 16, 1, @raster.Sampling::Lanczos)
  let bytes = bytes_of(wide)
  let mut previous = 0
  for x in 0..<16 {
    let value = bytes[x].to_int()
    // Monotonic: a ramp scaled up is still a ramp.
    assert_true(value >= previous)
    previous = value
  }
  assert_eq(bytes[15].to_int(), 255)
}
