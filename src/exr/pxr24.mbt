// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// PXR24, the compression that keeps twenty-four bits of every sample.
//
// A float has twenty-three bits of mantissa, and the bottom byte of one is worth
// less than the noise in the light it came from, so PXR24 drops it and stores
// three bytes instead of four. Half samples are kept whole at two bytes, and
// integers at four.
//
// What is left is split by significance: every high byte of the picture goes
// together, then every byte below it, and so on, and each plane is differenced
// from the sample before it, so a smooth picture is a long run of zero
// differences. Deflate does the rest.
//
// It is the one lossy compression this library reads and writes: a float loses
// the last eight bits of its mantissa, and nothing else changes.

///|
/// The 24 bits a float sample is stored as: its sign, its exponent, and the top
/// sixteen bits of its significand, rounded to nearest.
fn sample24(bits : Int32) -> Int32 {
  let raw = bits.reinterpret_as_uint()
  let sign = raw & 0x80000000U
  let exponent = raw & 0x7F800000U
  let mantissa = raw & 0x007FFFFFU
  let value = if exponent == 0x7F800000U {
    if mantissa != 0U {
      // A NaN keeps its sign and its fifteen top bits; a significand of zero
      // would make it an infinity, so one bit is left in.
      let held = mantissa >> 8
      (exponent >> 8) | held | (if held == 0U { 1U } else { 0U })
    } else {
      exponent >> 8
    }
  } else {
    let rounded = ((exponent | mantissa) + (mantissa & 0x00000080U)) >> 8
    if rounded >= 0x007F8000U {
      // A value near the largest float whose rounding carried into the
      // exponent: truncate rather than overflow.
      (exponent | mantissa) >> 8
    } else {
      rounded
    }
  }
  ((sign >> 8) | value).reinterpret_as_int()
}

///|
/// How many bytes of a sample one plane holds.
fn plane_count(kind : Int32) -> Int32 {
  match kind {
    1 => 2
    2 => 3
    _ => 4
  }
}

///|
/// A chunk as PXR24 bytes.
fn pxr24_pack(
  raw : BytesView,
  channels : Array[Channel],
  width : Int32,
  lines : Int32,
) -> Bytes {
  let writer = @wire.Writer::new()
  for line in 0..<lines {
    for c in 0..<channels.length() {
      let kind = channels[c].kind
      let planes = plane_count(kind)
      // The chunk arrives row by row, one channel after another inside each row.
      let start = (line * channels.length() + c) * width * channels[c].sample
      let coded : FixedArray[Int32] = FixedArray::make(width, 0)
      let mut previous = 0
      for x in 0..<width {
        let at = start + x * channels[c].sample
        let whole = if kind == 1 {
          words_at(raw, at, 1)
        } else if kind == 2 {
          sample24(words_at(raw, at, 2))
        } else {
          words_at(raw, at, 2)
        }
        coded[x] = whole - previous
        previous = whole
      }
      for plane in 0..<planes {
        let shift = (planes - 1 - plane) * 8
        for x in 0..<width {
          writer.u8((coded[x] >> shift) & 0xFF)
        }
      }
    }
  }
  @zlib.zlib(writer.to_bytes())
}

///|
/// A chunk PXR24 holds.
fn pxr24_unpack(
  body : BytesView,
  want : Int32,
  channels : Array[Channel],
  width : Int32,
  lines : Int32,
) -> Bytes raise @raster.Refused {
  let packed = @zlib.unzlib(body, limit=want * 2) catch {
    _ =>
      raise @raster.Unexpected(
        at=0,
        got="a deflate stream that does not inflate",
        want="a deflate stream",
      )
  }
  let out : FixedArray[Byte] = FixedArray::make(want, b'\x00')
  let mut at = 0
  for line in 0..<lines {
    for c in 0..<channels.length() {
      let kind = channels[c].kind
      let planes = plane_count(kind)
      // The planes are laid one after another: every high byte of the row, then
      // every byte below them, and so on.
      let bytes = planes * width
      if at + bytes > packed.length() {
        raise @raster.Truncated(at~, want=bytes)
      }
      let count = channels[c].sample / 2
      let mut held = 0
      for x in 0..<width {
        let mut difference = 0
        for plane in 0..<planes {
          let byte = packed[at + plane * width + x].to_int()
          difference = difference | (byte << ((planes - 1 - plane) * 8))
        }
        held = held + difference
        // A float's twenty-four bits go back to the top of the word; a half
        // and an integer keep everything that was written.
        let bits = if kind == 2 { held << 8 } else { held }
        // The chunk comes out row by row, channel after channel inside each row.
        let to = ((line * channels.length() + c) * width + x) *
          channels[c].sample
        for k in 0..<(count * 2) {
          if to + k < want {
            out[to + k] = ((bits >> (k * 8)) & 0xFF).to_byte()
          }
        }
      }
      at = at + bytes
    }
  }
  Bytes::from_array(out.clamped_view())
}

///|
/// One sample's words, little-endian, as a number: the low word first.
fn words_at(raw : BytesView, at : Int32, words : Int32) -> Int32 {
  let mut value = 0
  for k in 0..<words {
    value = value |
      (raw[at + k * 2].to_int() << (k * 16)) |
      (raw[at + k * 2 + 1].to_int() << (k * 16 + 8))
  }
  value
}
