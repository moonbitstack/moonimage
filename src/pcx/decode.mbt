// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Reading a PCX: a header of one hundred and twenty-eight bytes, a run-length
// stream, and for a palette picture a second palette at the end of the file.
//
// The header is the older of the two shapes the format has: sixteen colours
// written as forty-eight bytes inside it, which is all a 1985 paint program
// could hold, and — for a file that says version five and a palette in the
// trailer — two hundred and fifty-six colours appended after the last row,
// behind a marker byte. A reader that stops at the header reads a 256-colour
// picture in sixteen colours and looks wrong rather than broken.
//
// The run encoding is one escape: a byte with its top two bits set is a count
// of one to sixty-three and the byte after it is the value, and every other
// byte is itself. Runs may cross a row, so the stream is decoded flat and then
// cut into rows rather than decoded a row at a time.

///|
/// ZSoft's manufacturer code, the first byte of the file.
let manufacturer : Int32 = 0x0A

///|
/// Where the header ends and the run-length stream begins.
const HEADER_BYTES : Int32 = 128

///|
/// The marker in front of a palette that lives at the end of the file.
const PALETTE_MARKER : Int32 = 0x0C

///|
/// How many colours the header holds.
const HEADER_COLOURS : Int32 = 16

///|
fn le16(bytes : BytesView, at : Int32) -> Int32 {
  bytes[at].to_int() | (bytes[at + 1].to_int() << 8)
}

///|
/// A colour from the header's palette, which stores three bytes a colour for
/// sixteen colours.
fn header_colour(bytes : BytesView, index : Int32) -> (Int32, Int32, Int32) {
  let at = 16 + index * 3
  (bytes[at].to_int(), bytes[at + 1].to_int(), bytes[at + 2].to_int())
}

///|
/// Whether the file ends with the palette a two-hundred-and-fifty-six colour
/// picture needs, and where it starts.
fn trailer_palette(bytes : BytesView) -> Int32? {
  let length = bytes.length()
  if length >= 769 && bytes[length - 769].to_int() == PALETTE_MARKER {
    Some(length - 768)
  } else {
    None
  }
}

///|
/// The run-length stream, decoded to exactly `needed` bytes.
///
/// A run whose value never arrives is a file that stops in the middle of a
/// picture, which is `Truncated` at the byte it stopped on; a stream that ends
/// early is the same thing.
fn unwind(
  bytes : BytesView,
  at : Int32,
  needed : Int32,
) -> FixedArray[Byte] raise @raster.Refused {
  let out : FixedArray[Byte] = FixedArray::make(needed, b'\x00')
  let mut cursor = at
  let mut written = 0
  let length = bytes.length()
  while written < needed {
    if cursor >= length {
      raise @raster.Truncated(at=cursor, want=needed - written)
    }
    let first = bytes[cursor].to_int()
    cursor = cursor + 1
    if first >= 0xC0 {
      let count = first & 0x3F
      if cursor >= length {
        raise @raster.Truncated(at=cursor, want=count)
      }
      let value = bytes[cursor]
      cursor = cursor + 1
      for _ in 0..<count {
        if written < needed {
          out[written] = value
          written = written + 1
        }
      }
    } else {
      out[written] = first.to_byte()
      written = written + 1
    }
  }
  out
}

///|
/// The image in these bytes.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  if bytes.length() < HEADER_BYTES {
    raise @raster.Truncated(at=0, want=HEADER_BYTES)
  }
  if bytes[0].to_int() != manufacturer {
    raise @raster.Unknown(at=0, got=@raster.hex(bytes, 0, 4))
  }
  let encoding = bytes[2].to_int()
  if encoding != 0 && encoding != 1 {
    raise @raster.Unsupported(at=2, got="PCX encoding \{encoding}")
  }
  let bits = bytes[3].to_int()
  let width = le16(bytes, 8) - le16(bytes, 4) + 1
  let height = le16(bytes, 10) - le16(bytes, 6) + 1
  if width <= 0 || height <= 0 {
    raise @raster.Unexpected(
      at=4,
      got="a window of \{width} by \{height}",
      want="a window with pixels in it",
    )
  }
  limits.check(width, height)
  let planes = bytes[65].to_int()
  let palette_info = le16(bytes, 68)
  let stride = le16(bytes, 66)
  if planes < 1 || planes > 4 {
    raise @raster.Unsupported(at=65, got="\{planes} planes")
  }
  if stride < 1 {
    raise @raster.Unexpected(
      at=66,
      got="a row of 0 bytes",
      want="a row with bytes in it",
    )
  }
  let row_bytes = stride * planes
  let needed = row_bytes * height
  if needed.to_int64() > limits.bytes.to_int64() {
    raise @raster.OverLimit(limit=limits.bytes, got=needed)
  }
  let data = if encoding == 1 {
    unwind(bytes, HEADER_BYTES, needed)
  } else {
    if bytes.length() - HEADER_BYTES < needed {
      raise @raster.Truncated(
        at=bytes.length(),
        want=needed - (bytes.length() - HEADER_BYTES),
      )
    }
    let flat : FixedArray[Byte] = FixedArray::make(needed, b'\x00')
    for i in 0..<needed {
      flat[i] = bytes[HEADER_BYTES + i]
    }
    flat
  }
  let pixels : FixedArray[Byte] = FixedArray::make(width * height * 4, b'\x00')
  let trailer = trailer_palette(bytes)
  let indexed = planes == 1 && bits <= 8
  if indexed {
    // One plane of one, two, four or eight bits: an index, either into the
    // sixteen colours in the header or into the two hundred and fifty-six at
    // the end.
    if bits != 1 && bits != 2 && bits != 4 && bits != 8 {
      raise @raster.Unsupported(at=3, got="\{bits} bits in one plane")
    }
    let per_byte = 8 / bits
    let mask = (1 << bits) - 1
    for y in 0..<height {
      let row = y * row_bytes
      for x in 0..<width {
        let byte = data[row + x / per_byte].to_int()
        let shift = 8 - bits * (x % per_byte + 1)
        let index = (byte >> shift) & mask
        let (r, g, b) = if bits == 1 && palette_info == 1 {
          // A greyscale file says so in the header, and its palette is either
          // the ramp written out or — as Pillow writes a one-bit picture —
          // sixteen black entries that mean the ramp anyway.
          let levels = (1 << bits) - 1
          let level = index * 255 / levels
          (level, level, level)
        } else if indexed_by_trailer(bits, trailer) {
          let at = match trailer {
            Some(base) => base + index * 3
            None => 16 + index * 3
          }
          (bytes[at].to_int(), bytes[at + 1].to_int(), bytes[at + 2].to_int())
        } else {
          let capped = if index >= HEADER_COLOURS {
            HEADER_COLOURS - 1
          } else {
            index
          }
          header_colour(bytes, capped)
        }
        let p = (y * width + x) * 4
        pixels[p] = r.to_byte()
        pixels[p + 1] = g.to_byte()
        pixels[p + 2] = b.to_byte()
        pixels[p + 3] = b'\xFF'
      }
    }
  } else if bits == 8 && (planes == 3 || planes == 4) {
    // Planes of a byte each: red, green, blue, and the fourth a mask or an
    // alpha, which the format never says; it is read as alpha because that is
    // what every writer of a thirty-two bit PCX means by it.
    for y in 0..<height {
      let row = y * row_bytes
      for x in 0..<width {
        let p = (y * width + x) * 4
        pixels[p] = data[row + x]
        pixels[p + 1] = data[row + stride + x]
        pixels[p + 2] = data[row + stride * 2 + x]
        pixels[p + 3] = if planes == 4 {
          data[row + stride * 3 + x]
        } else {
          b'\xFF'
        }
      }
    }
  } else if bits == 1 && planes == 4 {
    // Four planes of one bit: a channel a plane, which is how a scanner of the
    // era wrote a picture with a mask in it.
    for y in 0..<height {
      let row = y * row_bytes
      for x in 0..<width {
        let p = (y * width + x) * 4
        for channel in 0..<4 {
          let byte = data[row + stride * channel + x / 8].to_int()
          let bit = (byte >> (7 - x % 8)) & 1
          pixels[p + channel] = if bit == 1 { b'\xFF' } else { b'\x00' }
        }
      }
    }
  } else {
    raise @raster.Unsupported(at=3, got="\{bits} bits in \{planes} planes")
  }
  @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(pixels.clamped_view()),
  )
}

///|
/// Whether a picture of this depth takes its colours from the trailer.
///
/// Eight bits is the case the trailer exists for. A one-bit file that carries
/// one is a black-and-white picture written by a program that also wrote the
/// two hundred and fifty-six colours; the first two entries there are the same
/// two colours, so either palette gives the same picture.
fn indexed_by_trailer(bits : Int32, trailer : Int32?) -> Bool {
  match trailer {
    Some(_) => bits == 8
    None => false
  }
}
