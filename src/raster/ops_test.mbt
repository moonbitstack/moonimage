// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Moving pixels: the three operations that are pure permutation, checked by the
// one thing a permutation can be wrong about, which is where each pixel landed.

///|
/// A crop, with the refusal turned into a test failure: these rectangles fit.
fn cropped(
  image : @raster.Image,
  x : Int32,
  y : Int32,
  width : Int32,
  height : Int32,
) -> @raster.Image {
  image.crop(x, y, width, height) catch {
    error => abort("the rectangle fits: \{error}")
  }
}

///|
test "flipping left to right reverses each row and leaves the rows alone" {
  let flipped = sample().flip_horizontal()
  assert_eq(flipped.width, 3)
  assert_eq(flipped.height, 2)
  assert_eq(
    bytes_of(flipped),
    b"\x46\x50\x5a\xff\x28\x32\x3c\xff\x0a\x14\x1e\xff" +
    b"\xa0\xaa\xb4\xff\x82\x8c\x96\xff\x64\x6e\x78\xff",
  )
}

///|
test "flipping top to bottom swaps whole rows" {
  let flipped = sample().flip_vertical()
  assert_eq(
    bytes_of(flipped),
    b"\x64\x6e\x78\xff\x82\x8c\x96\xff\xa0\xaa\xb4\xff" +
    b"\x0a\x14\x1e\xff\x28\x32\x3c\xff\x46\x50\x5a\xff",
  )
  // Twice is what it started as.
  assert_eq(bytes_of(flipped.flip_vertical()), bytes_of(sample()))
}

///|
test "a quarter turn swaps the axes and puts the first column last" {
  let turned = sample().rotate()
  assert_eq(turned.width, 2)
  assert_eq(turned.height, 3)
  assert_eq(
    bytes_of(turned),
    b"\x64\x6e\x78\xff\x0a\x14\x1e\xff" +
    b"\x82\x8c\x96\xff\x28\x32\x3c\xff" +
    b"\xa0\xaa\xb4\xff\x46\x50\x5a\xff",
  )
}

///|
test "four quarter turns are no turn, and anticlockwise is three" {
  let image = sample()
  assert_eq(bytes_of(image.rotate(quarters=0)), bytes_of(image))
  assert_eq(bytes_of(image.rotate(quarters=4)), bytes_of(image))
  assert_eq(
    bytes_of(image.rotate(quarters=-1)),
    bytes_of(image.rotate(quarters=3)),
  )
  assert_eq(
    bytes_of(image.rotate(quarters=-1).rotate(quarters=1)),
    bytes_of(image),
  )
  assert_eq(
    bytes_of(image.rotate(quarters=2).rotate(quarters=2)),
    bytes_of(image),
  )
}

///|
test "half a turn reverses the whole run of pixels" {
  let turned = sample().rotate(quarters=2)
  assert_eq(turned.width, 3)
  assert_eq(turned.height, 2)
  assert_eq(
    bytes_of(turned),
    b"\xa0\xaa\xb4\xff\x82\x8c\x96\xff\x64\x6e\x78\xff" +
    b"\x46\x50\x5a\xff\x28\x32\x3c\xff\x0a\x14\x1e\xff",
  )
}

///|
test "a crop is a window, and it keeps the stride tight" {
  let window = cropped(sample(), 1, 1, 2, 1)
  assert_eq(window.width, 2)
  assert_eq(window.height, 1)
  assert_eq(window.stride, 8)
  assert_eq(bytes_of(window), b"\x82\x8c\x96\xff\xa0\xaa\xb4\xff")
  let whole = cropped(sample(), 0, 0, 3, 2)
  assert_eq(bytes_of(whole), bytes_of(sample()))
}

///|
test "a crop that reaches outside the image is refused" {
  let outside = try {
    ignore(sample().crop(2, 0, 2, 1))
    false
  } catch {
    @raster.Refused::OverLimit(..) => true
    _ => false
  }
  assert_true(outside)
  let behind = try {
    ignore(sample().crop(-1, 0, 1, 1))
    false
  } catch {
    @raster.Refused::Unexpected(..) => true
    _ => false
  }
  assert_true(behind)
}

///|
test "operations keep the format, the alpha convention and the metadata" {
  let image = image_of(1, 1, @raster.PixelFormat::Gray16, b"\x12\x34")
  let turned = image.rotate(quarters=1)
  assert_eq(turned.format, @raster.PixelFormat::Gray16)
  assert_eq(turned.premultiplied, false)
  assert_eq(bytes_of(turned), b"\x12\x34")
}
