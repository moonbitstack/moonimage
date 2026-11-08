// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Laying one picture over another: the source-over formula, the opacity, and
// the clipping at the edge of the canvas.

///|
test "an opaque source replaces what is under it" {
  let under = image_of(2, 2, @raster.PixelFormat::Rgba8, solid(2, 2, 0x10))
  let over = image_of(1, 1, @raster.PixelFormat::Rgba8, solid(1, 1, 0x80))
  let drawn = under.composite(over, x=1, y=1)
  assert_eq(at(drawn, 0, 0), (0x10, 0x10, 0x10, 255))
  assert_eq(at(drawn, 1, 1), (0x80, 0x80, 0x80, 255))
}

///|
test "a half transparent source mixes half of each" {
  let under = image_of(1, 1, @raster.PixelFormat::Rgba8, b"\x00\x00\x00\xff")
  let over = image_of(1, 1, @raster.PixelFormat::Rgba8, b"\xff\xff\xff\x80")
  let drawn = under.composite(over)
  // Half of white over black is a mid grey, and the result is opaque because
  // what was under it was.
  let (r, g, b, a) = at(drawn, 0, 0)
  assert_true(r >= 127 && r <= 128)
  assert_eq(g, r)
  assert_eq(b, r)
  assert_eq(a, 255)
}

///|
test "opacity scales what the source lays down" {
  let under = image_of(1, 1, @raster.PixelFormat::Rgba8, b"\x00\x00\x00\xff")
  let over = image_of(1, 1, @raster.PixelFormat::Rgba8, b"\xff\xff\xff\xff")
  let faint = under.composite(over, opacity=0.25)
  let (r, _, _, _) = at(faint, 0, 0)
  assert_true(r >= 63 && r <= 64)
}

///|
test "a source larger than the canvas is clipped, not refused" {
  let under = image_of(2, 1, @raster.PixelFormat::Rgba8, solid(2, 1, 0x00))
  let over = image_of(4, 4, @raster.PixelFormat::Rgba8, solid(4, 4, 0xff))
  let drawn = under.composite(over, x=1, y=0)
  assert_eq(drawn.width, 2)
  assert_eq(drawn.height, 1)
  assert_eq(at(drawn, 0, 0), (0, 0, 0, 255))
  assert_eq(at(drawn, 1, 0), (255, 255, 255, 255))
}

///|
test "a source entirely outside the canvas changes nothing" {
  let under = image_of(2, 2, @raster.PixelFormat::Rgba8, solid(2, 2, 0x42))
  let over = image_of(1, 1, @raster.PixelFormat::Rgba8, solid(1, 1, 0xff))
  assert_eq(bytes_of(under.composite(over, x=9, y=9)), bytes_of(under))
  assert_eq(bytes_of(under.composite(over, opacity=0.0)), bytes_of(under))
}

///|
test "a source in another format is converted on the way in" {
  let under = image_of(1, 1, @raster.PixelFormat::Rgb8, b"\x00\x00\x00")
  let over = image_of(1, 1, @raster.PixelFormat::Gray8, b"\xff")
  let drawn = under.composite(over)
  assert_eq(drawn.format, @raster.PixelFormat::Rgb8)
  assert_eq(at(drawn, 0, 0), (255, 255, 255, 255))
}

///|
fn solid(width : Int32, height : Int32, value : Int32) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(width * height * 4, b'\x00')
  for i in 0..<(width * height) {
    out[i * 4] = value.to_byte()
    out[i * 4 + 1] = value.to_byte()
    out[i * 4 + 2] = value.to_byte()
    out[i * 4 + 3] = b'\xFF'
  }
  Bytes::from_array(out.clamped_view())
}
