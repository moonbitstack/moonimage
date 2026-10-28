// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Reading and writing the numbers a file format is made of.
//
// Every format here is a run of big-endian or little-endian integers, and the
// only interesting question is what happens when the run ends early. The answer
// is one refusal, `Truncated`, raised at the offset where the bytes ran out, so
// that a decoder can stop at the first sign of damage instead of branching after
// every read.
//
// A cursor moves through bytes that already exist; a writer builds bytes that do
// not. The two are separate types because a decoder never writes and an encoder
// never seeks backwards — or rather, an encoder that seeks backwards is a
// format with length fields, and those are easier to build bottom-up.

///|
/// A position in a run of bytes.
///
/// Public as an opaque handle: the cursor is state, and a caller that could
/// reach the position could make it disagree with the data.
pub struct Cursor {
  data : BytesView
  mut pos : Int32
}

///|
/// A cursor at the start of `data`.
pub fn Cursor::new(data : BytesView) -> Cursor {
  { data, pos: 0, }
}

///|
/// Where the cursor is.
pub fn Cursor::at(self : Cursor) -> Int32 {
  self.pos
}

///|
/// How many bytes are left.
pub fn Cursor::left(self : Cursor) -> Int32 {
  self.data.length() - self.pos
}

///|
/// Whether the cursor has reached the end.
pub fn Cursor::is_empty(self : Cursor) -> Bool {
  self.pos >= self.data.length()
}

///|
/// The bytes the cursor has not read yet.
pub fn Cursor::rest(self : Cursor) -> BytesView {
  self.data.clamped_view(start=self.pos, end=self.data.length())
}

///|
/// Move to an absolute offset, which may be behind the cursor.
pub fn Cursor::seek(self : Cursor, at : Int32) -> Unit raise @raster.Refused {
  if at < 0 || at > self.data.length() {
    raise @raster.OverLimit(limit=self.data.length(), got=at)
  }
  self.pos = at
}

///|
/// Move forward.
pub fn Cursor::skip(self : Cursor, count : Int32) -> Unit raise @raster.Refused {
  self.need(count)
  self.pos = self.pos + count
}

///|
/// The next byte, as an unsigned number.
pub fn Cursor::u8(self : Cursor) -> Int32 raise @raster.Refused {
  self.need(1)
  let value = self.data[self.pos].to_int()
  self.pos = self.pos + 1
  value
}

///|
/// The next `count` bytes, without copying.
pub fn Cursor::bytes(
  self : Cursor,
  count : Int32,
) -> BytesView raise @raster.Refused {
  self.need(count)
  let start = self.pos
  self.pos = start + count
  self.data.exact_view(start~, end=start + count)
}

///|
/// A big-endian sixteen-bit number, which is what PNG and JPEG count in.
pub fn Cursor::u16_be(self : Cursor) -> Int32 raise @raster.Refused {
  self.need(2)
  let b = self.data
  let p = self.pos
  let value = b[p].to_int() * 256 + b[p + 1].to_int()
  self.pos = self.pos + 2
  value
}

///|
/// A little-endian sixteen-bit number, which is what BMP and TGA count in.
pub fn Cursor::u16_le(self : Cursor) -> Int32 raise @raster.Refused {
  self.need(2)
  let b = self.data
  let p = self.pos
  let value = b[p + 1].to_int() * 256 + b[p].to_int()
  self.pos = self.pos + 2
  value
}

///|
/// A little-endian twenty-four-bit number, which BMP and TGA size fields use.
pub fn Cursor::u24_le(self : Cursor) -> Int32 raise @raster.Refused {
  self.need(3)
  let b = self.data
  let p = self.pos
  let value = b[p + 2].to_int() * 65536 +
    b[p + 1].to_int() * 256 +
    b[p].to_int()
  self.pos = self.pos + 3
  value
}

///|
/// A big-endian thirty-two-bit number, which is what PNG chunk lengths are.
///
/// A field that does not fit in 31 bits is refused rather than wrapped: every
/// use of a 32-bit field in these formats is a length or a size, and a size of
/// two gigabytes is already past every limit the library will accept.
pub fn Cursor::u32_be(self : Cursor) -> Int32 raise @raster.Refused {
  self.need(4)
  let b = self.data
  let p = self.pos
  let high = b[p].to_int() * 256 + b[p + 1].to_int()
  let low = b[p + 2].to_int() * 256 + b[p + 3].to_int()
  self.pos = p + 4
  check_word(high, low, p)
}

///|
/// A little-endian thirty-two-bit number, which is what BMP and RIFF use.
pub fn Cursor::u32_le(self : Cursor) -> Int32 raise @raster.Refused {
  self.need(4)
  let b = self.data
  let p = self.pos
  let high = b[p + 3].to_int() * 256 + b[p + 2].to_int()
  let low = b[p + 1].to_int() * 256 + b[p].to_int()
  self.pos = p + 4
  check_word(high, low, p)
}

///|
/// A big-endian thirty-two-bit number as bits, for a field that is not a size and
/// may use the whole range: a checksum, a mask, a fixed tag.
pub fn Cursor::bits_be(self : Cursor) -> UInt32 raise @raster.Refused {
  self.need(4)
  let b = self.data
  let p = self.pos
  let value = (b[p].to_int().reinterpret_as_uint() << 24) |
    (b[p + 1].to_int().reinterpret_as_uint() << 16) |
    (b[p + 2].to_int().reinterpret_as_uint() << 8) |
    b[p + 3].to_int().reinterpret_as_uint()
  self.pos = p + 4
  value
}

///|
/// The value of a thirty-two-bit field split into halves, or a refusal when it
/// is too large to be a length anyone meant.
fn check_word(
  high : Int32,
  low : Int32,
  at : Int32,
) -> Int32 raise @raster.Refused {
  if high > 0x7FFF {
    raise @raster.Unexpected(
      at~,
      got="a 32-bit field above 2^31",
      want="a length this library can hold",
    )
  }
  high * 65536 + low
}

///|
/// A little-endian signed thirty-two-bit number: BMP heights are negative when
/// the rows are stored top-down.
pub fn Cursor::i32_le(self : Cursor) -> Int32 raise @raster.Refused {
  self.need(4)
  let b = self.data
  let p = self.pos
  let low = b[p].to_int() + b[p + 1].to_int() * 256 + b[p + 2].to_int() * 65536
  let high = b[p + 3].to_int()
  self.pos = p + 4
  if high >= 128 {
    low + (high - 256) * 16777216
  } else {
    low + high * 16777216
  }
}

///|
/// Refuse unless `count` bytes are still there.
fn Cursor::need(self : Cursor, count : Int32) -> Unit raise @raster.Refused {
  if count < 0 || self.pos + count > self.data.length() {
    raise @raster.Truncated(
      at=self.pos,
      want=self.pos + count - self.data.length(),
    )
  }
}

///|
/// A buffer being built, with the same conveniences in reverse.
pub struct Writer {
  buffer : Buffer
}

///|
/// An empty writer.
pub fn Writer::new() -> Writer {
  { buffer: @buffer.Buffer::Buffer(), }
}

///|
/// How many bytes have been written.
pub fn Writer::length(self : Writer) -> Int32 {
  self.buffer.length()
}

///|
/// The bytes written so far.
pub fn Writer::to_bytes(self : Writer) -> Bytes {
  self.buffer.to_bytes()
}

///|
/// One byte, from a number that may be larger than a byte: the low eight bits
/// are what a format means when it stores a number in a byte.
pub fn Writer::u8(self : Writer, value : Int32) -> Unit {
  self.buffer.write_byte(value.to_byte())
}

///|
/// Bytes, unchanged.
pub fn Writer::bytes(self : Writer, value : BytesView) -> Unit {
  self.buffer.write_bytesview(value)
}

///|
/// A big-endian sixteen-bit number.
pub fn Writer::u16_be(self : Writer, value : Int32) -> Unit {
  self.u8(value >> 8)
  self.u8(value)
}

///|
/// A little-endian sixteen-bit number.
pub fn Writer::u16_le(self : Writer, value : Int32) -> Unit {
  self.u8(value)
  self.u8(value >> 8)
}

///|
/// A little-endian twenty-four-bit number.
pub fn Writer::u24_le(self : Writer, value : Int32) -> Unit {
  self.u8(value)
  self.u8(value >> 8)
  self.u8(value >> 16)
}

///|
/// A big-endian thirty-two-bit number.
pub fn Writer::u32_be(self : Writer, value : Int32) -> Unit {
  self.u8(value >> 24)
  self.u8(value >> 16)
  self.u8(value >> 8)
  self.u8(value)
}

///|
/// A little-endian thirty-two-bit number.
pub fn Writer::u32_le(self : Writer, value : Int32) -> Unit {
  self.u8(value)
  self.u8(value >> 8)
  self.u8(value >> 16)
  self.u8(value >> 24)
}

///|
/// A run of `count` zero bytes, for a field that is filled in later.
pub fn Writer::zeros(self : Writer, count : Int32) -> Unit {
  for _ in 0..<count {
    self.u8(0)
  }
}
