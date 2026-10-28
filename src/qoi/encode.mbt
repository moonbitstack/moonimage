// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing QOI: the same decisions the reference encoder makes, in the same
// order, so that the file is the one it would have written.
//
// The order matters more than it looks. A pixel that is in the cache is written
// as an index even when a difference would also have been short; a difference is
// tried before a luma; a run is closed the moment it reaches sixty-two. Every one
// of those choices is visible in the bytes, and a decoder would not care, but a
// round trip that is meant to reproduce the file does.

///|
/// The image as a QOI file.
///
/// An image without alpha is written as three channels, one with alpha as four.
/// The encoder follows the reference exactly, so encoding what was decoded
/// reproduces the file byte for byte.
pub fn encode(image : @raster.Image) -> Bytes {
  let channels = if image.format.has_alpha() { 4 } else { 3 }
  let source = image.convert(@raster.PixelFormat::Rgba8)
  let writer = @wire.Writer::new()
  writer.bytes(b"qoif")
  writer.u32_be(image.width)
  writer.u32_be(image.height)
  writer.u8(channels)
  writer.u8(0)
  let index : FixedArray[UInt32] = FixedArray::make(64, 0U)
  let state = State::new()
  let total = image.width * image.height
  for position in 0..<total {
    let pixel = Pixel8::read(source.pixels, position * 4)
    if pixel.same(state.previous) {
      state.run = state.run + 1
      if state.run == 62 || position == total - 1 {
        writer.u8(0xC0 | (state.run - 1))
        state.run = 0
      }
    } else {
      if state.run > 0 {
        writer.u8(0xC0 | (state.run - 1))
        state.run = 0
      }
      write_pixel(writer, index, state.previous, pixel)
    }
    state.previous = pixel
  }
  writer.bytes(b"\x00\x00\x00\x00\x00\x00\x00\x01")
  writer.to_bytes()
}

///|
/// What the encoder remembers between pixels: the last one, and how many times
/// it has repeated since it was written.
priv struct State {
  mut previous : Pixel8
  mut run : Int32
}

///|
fn State::new() -> State {
  { previous: Pixel8::new(0, 0, 0, 255), run: 0, }
}

///|
/// One pixel of the source, unrolled into four numbers so that a comparison is
/// four integer compares rather than four indexed reads.
priv struct Pixel8 {
  r : Int32
  g : Int32
  b : Int32
  a : Int32
}

///|
fn Pixel8::new(r : Int32, g : Int32, b : Int32, a : Int32) -> Pixel8 {
  { r, g, b, a, }
}

///|
fn Pixel8::read(data : BytesView, at : Int32) -> Pixel8 {
  {
    r: data[at].to_int(),
    g: data[at + 1].to_int(),
    b: data[at + 2].to_int(),
    a: data[at + 3].to_int(),
  }
}

///|
fn Pixel8::same(self : Pixel8, other : Pixel8) -> Bool {
  self.r == other.r &&
  self.g == other.g &&
  self.b == other.b &&
  self.a == other.a
}

///|
/// One pixel that is not a repeat of the last: the cache, the difference codes
/// and the literal, in the order the format prefers them.
fn write_pixel(
  writer : @wire.Writer,
  index : FixedArray[UInt32],
  previous : Pixel8,
  pixel : Pixel8,
) -> Unit {
  let slot = hash(pixel.r, pixel.g, pixel.b, pixel.a)
  if index[slot] == packed(pixel) {
    writer.u8(slot)
    return
  }
  index[slot] = packed(pixel)
  if pixel.a != previous.a {
    writer.u8(0xFF)
    writer.u8(pixel.r)
    writer.u8(pixel.g)
    writer.u8(pixel.b)
    writer.u8(pixel.a)
    return
  }
  // The difference is an eight-bit signed number, so a jump from white to black
  // is minus one rather than plus two hundred and fifty-four.
  let dr = delta(pixel.r, previous.r)
  let dg = delta(pixel.g, previous.g)
  let db = delta(pixel.b, previous.b)
  if dr >= -2 && dr <= 1 && dg >= -2 && dg <= 1 && db >= -2 && db <= 1 {
    writer.u8(0x40 | ((dr + 2) << 4) | ((dg + 2) << 2) | (db + 2))
  } else if dg >= -32 && dg <= 31 && near(dr, dg) && near(db, dg) {
    writer.u8(0x80 | (dg + 32))
    writer.u8(((dr - dg + 8) << 4) | (db - dg + 8))
  } else {
    writer.u8(0xFE)
    writer.u8(pixel.r)
    writer.u8(pixel.g)
    writer.u8(pixel.b)
  }
}

///|
/// The difference between two samples, wrapped into a signed byte: the format
/// stores it in seven bits and the encoder has to see it the same way.
fn delta(value : Int32, previous : Int32) -> Int32 {
  ((value - previous + 128) & 0xFF) - 128
}

///|
/// Whether a difference from green fits in the four bits a luma leaves for it.
fn near(value : Int32, green : Int32) -> Bool {
  let delta = value - green
  delta >= -8 && delta <= 7
}

///|
fn packed(pixel : Pixel8) -> UInt32 {
  (pixel.r.reinterpret_as_uint() << 24) |
  (pixel.g.reinterpret_as_uint() << 16) |
  (pixel.b.reinterpret_as_uint() << 8) |
  pixel.a.reinterpret_as_uint()
}
