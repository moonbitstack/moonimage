// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Composition: the four rules the three animated formats share, applied in the
// order a viewer applies them. What is checked here is not a file format but the
// arithmetic the formats agree on, so the cases are the ones that go wrong when
// it is implemented from the description rather than from a viewer: a frame that
// covers part of the canvas, a frame that is transparent where it overlaps, and
// a frame that asks for what was underneath it to come back.

///|
fn frame(
  pixels : Bytes,
  width : Int32,
  height : Int32,
  x : Int32,
  y : Int32,
  delay : Int32,
  dispose : @raster.Dispose,
  blend : @raster.Blend,
) -> @raster.Frame {
  @raster.Frame::new(
    image_of(width, height, @raster.PixelFormat::Rgba8, pixels),
    x~,
    y~,
    delay~,
    dispose~,
    blend~,
  )
}

///|
test "an animation composes its frames onto the canvas in order" {
  let red = Bytes::repeat(b"\xff\x00\x00\xff", 4)
  let animation = @raster.Animation::new(2, 2, [
    frame(red, 2, 2, 0, 0, 100, @raster.Dispose::Keep, @raster.Blend::Source),
    frame(
      b"\x00\xff\x00\xff",
      1,
      1,
      1,
      1,
      50,
      @raster.Dispose::Keep,
      @raster.Blend::Over,
    ),
    frame(
      b"\x00\x00\xff\xff",
      1,
      1,
      0,
      0,
      25,
      @raster.Dispose::Keep,
      @raster.Blend::Source,
    ),
  ])
  let pictures = animation.compose()
  assert_eq(pictures.length(), 3)
  // The first frame covers the canvas.
  assert_eq(at(pictures[0], 0, 0), (255, 0, 0, 255))
  assert_eq(at(pictures[0], 1, 1), (255, 0, 0, 255))
  // The second paints one pixel of it green.
  assert_eq(at(pictures[1], 0, 0), (255, 0, 0, 255))
  assert_eq(at(pictures[1], 1, 1), (0, 255, 0, 255))
  // The third paints another blue, and the green stays.
  assert_eq(at(pictures[2], 0, 0), (0, 0, 255, 255))
  assert_eq(at(pictures[2], 1, 1), (0, 255, 0, 255))
}

///|
test "blending over a transparent canvas keeps the frame's own alpha" {
  let animation = @raster.Animation::new(2, 1, [
    frame(
      b"\x10\x20\x30\x80\x10\x20\x30\x80",
      2,
      1,
      0,
      0,
      10,
      @raster.Dispose::Keep,
      @raster.Blend::Over,
    ),
  ])
  let pictures = animation.compose()
  assert_eq(at(pictures[0], 0, 0), (16, 32, 48, 128))
}

///|
test "a frame that clears its rectangle leaves nothing behind" {
  let animation = @raster.Animation::new(2, 1, [
    frame(
      b"\xff\x00\x00\xff\xff\x00\x00\xff",
      2,
      1,
      0,
      0,
      10,
      @raster.Dispose::Background,
      @raster.Blend::Source,
    ),
    frame(
      b"\x00\xff\x00\xff",
      1,
      1,
      0,
      0,
      10,
      @raster.Dispose::Keep,
      @raster.Blend::Source,
    ),
  ])
  let pictures = animation.compose()
  // The first frame is shown as it is.
  assert_eq(at(pictures[0], 0, 0), (255, 0, 0, 255))
  // Then its rectangle is cleared, so the second frame sits on transparency.
  assert_eq(at(pictures[1], 0, 0), (0, 255, 0, 255))
  assert_eq(at(pictures[1], 1, 0), (0, 0, 0, 0))
}

///|
test "a frame that asks for what was underneath gets it back" {
  let animation = @raster.Animation::new(3, 1, [
    frame(
      b"\xff\xff\xff\xff\x00\x00\x00\xff\xff\xff\xff\xff",
      3,
      1,
      0,
      0,
      10,
      @raster.Dispose::Keep,
      @raster.Blend::Source,
    ),
    frame(
      b"\xff\x00\x00\xff",
      1,
      1,
      1,
      0,
      10,
      @raster.Dispose::Previous,
      @raster.Blend::Source,
    ),
    frame(
      b"\x00\x00\xff\xff",
      1,
      1,
      1,
      0,
      10,
      @raster.Dispose::Keep,
      @raster.Blend::Source,
    ),
  ])
  let pictures = animation.compose()
  assert_eq(at(pictures[1], 1, 0), (255, 0, 0, 255))
  // The middle pixel was black before the red frame and is black again after it.
  assert_eq(at(pictures[2], 1, 0), (0, 0, 255, 255))
  assert_eq(at(pictures[2], 0, 0), (255, 255, 255, 255))
}

///|
test "every frame of a composed animation is the whole canvas" {
  let red = Bytes::repeat(b"\xff\x00\x00\xff", 4)
  let animation = @raster.Animation::new(2, 2, [
    frame(red, 2, 2, 0, 0, 10, @raster.Dispose::Keep, @raster.Blend::Source),
    frame(red, 2, 2, 0, 0, 10, @raster.Dispose::Keep, @raster.Blend::Source),
  ])
  for picture in animation.compose() {
    assert_eq(picture.width, 2)
    assert_eq(picture.height, 2)
    assert_eq(bytes_of(picture).length(), 2 * 2 * 8)
  }
}

///|
test "a frame outside the canvas is clipped, not written past it" {
  let animation = @raster.Animation::new(2, 1, [
    frame(
      b"\x00\xff\x00\xff",
      1,
      1,
      5,
      5,
      10,
      @raster.Dispose::Keep,
      @raster.Blend::Source,
    ),
  ])
  let pictures = animation.compose()
  assert_eq(at(pictures[0], 0, 0), (0, 0, 0, 0))
  assert_eq(at(pictures[0], 1, 0), (0, 0, 0, 0))
}

///|
test "an animation with no frames composes to nothing, and one frame to itself" {
  let empty = @raster.Animation::new(3, 3, [])
  assert_eq(empty.compose().length(), 0)
  assert_eq(empty.loops, 0)
  let one = @raster.Animation::new(1, 1, [
    frame(
      b"\x01\x02\x03\x04",
      1,
      1,
      0,
      0,
      70,
      @raster.Dispose::Keep,
      @raster.Blend::Over,
    ),
  ])
  assert_eq(one.frames[0].delay, 70)
  assert_eq(rgba8_of(one.compose()[0]), b"\x01\x02\x03\x04")
}
