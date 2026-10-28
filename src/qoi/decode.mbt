// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// QOI: an image format small enough to read in one sitting.
//
// https://qoiformat.org/qoi-specification.pdf
//
// The whole codec is a header, six opcodes, and a run-length code for pixels
// that repeat. There is no compression stream to be compatible with, which is
// the point: the format was designed so that a decoder is an afternoon's work
// and an encoder is byte-for-byte reproducible.
//
// Reading and writing agree on every detail of the encoder the specification
// describes, so an image that comes in and goes out again is the same file.

///|
/// The image in a QOI file.
///
/// A file that declares three channels decodes to `Rgb8`, one that declares four
/// to `Rgba8`; a file that declares three and then uses an alpha opcode is not an
/// error, and decodes to `Rgba8`.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  let cursor = @wire.Cursor::new(bytes)
  let magic = cursor.bytes(4)
  if !magic.equal_to_bytes(b"qoif") {
    raise @raster.Unknown(at=0, got=@raster.hex(bytes, 0, 4))
  }
  let width = cursor.u32_be()
  let height = cursor.u32_be()
  let channels = cursor.u8()
  let colorspace = cursor.u8()
  if width == 0 || height == 0 {
    raise @raster.Unexpected(
      at=4,
      got="a header with no pixels",
      want="a width and a height above zero",
    )
  }
  if channels != 3 && channels != 4 {
    raise @raster.Unexpected(
      at=12,
      got="\{channels} channels",
      want="three or four",
    )
  }
  if colorspace > 1 {
    raise @raster.Unexpected(
      at=13,
      got="colour space \{colorspace}",
      want="sRGB or linear",
    )
  }
  limits.check(width, height)
  limits.check_bytes(width * height * 4)
  let buffer : FixedArray[Byte] = FixedArray::make(width * height * 4, b'\x00')
  let index : FixedArray[UInt32] = FixedArray::make(64, 0U)
  let mut r = 0
  let mut g = 0
  let mut b = 0
  let mut a = 255
  let mut run = 0
  let mut saw_alpha = false
  let mut position = 0
  while position < width * height {
    if run > 0 {
      run = run - 1
    } else {
      let opcode = cursor.u8()
      if opcode == 0xFE {
        r = cursor.u8()
        g = cursor.u8()
        b = cursor.u8()
      } else if opcode == 0xFF {
        r = cursor.u8()
        g = cursor.u8()
        b = cursor.u8()
        a = cursor.u8()
        saw_alpha = true
      } else {
        match opcode & 0xC0 {
          0x00 => {
            let packed = index[opcode]
            r = ((packed >> 24) & 0xFF).reinterpret_as_int()
            g = ((packed >> 16) & 0xFF).reinterpret_as_int()
            b = ((packed >> 8) & 0xFF).reinterpret_as_int()
            a = (packed & 0xFF).reinterpret_as_int()
          }
          0x40 => {
            r = wrap_byte(r + ((opcode >> 4) & 0x03) - 2)
            g = wrap_byte(g + ((opcode >> 2) & 0x03) - 2)
            b = wrap_byte(b + (opcode & 0x03) - 2)
          }
          0x80 => {
            let second = cursor.u8()
            let dg = (opcode & 0x3F) - 32
            let dr = dg + ((second >> 4) & 0x0F) - 8
            let db = dg + (second & 0x0F) - 8
            r = wrap_byte(r + dr)
            g = wrap_byte(g + dg)
            b = wrap_byte(b + db)
          }
          _ => run = opcode & 0x3F
        }
      }
      index[hash(r, g, b, a)] = pack_rgba(r, g, b, a)
    }
    let at = position * 4
    buffer[at] = r.to_byte()
    buffer[at + 1] = g.to_byte()
    buffer[at + 2] = b.to_byte()
    buffer[at + 3] = a.to_byte()
    position = position + 1
  }
  check_end_marker(cursor)
  let decoded = @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(buffer.clamped_view()),
  )
  if channels == 4 || saw_alpha {
    decoded
  } else {
    decoded.convert(@raster.PixelFormat::Rgb8)
  }
}

///|
/// The eight bytes every QOI file ends with: seven zeros and a one.
fn check_end_marker(cursor : @wire.Cursor) -> Unit raise @raster.Refused {
  let marker = cursor.rest()
  if marker.length() < 8 {
    raise @raster.Truncated(at=cursor.at(), want=8 - marker.length())
  }
  for i in 0..<7 {
    if marker[i].to_int() != 0 {
      raise @raster.Checksum(
        at=cursor.at() + i,
        got="\{marker[i].to_int()}",
        want="0",
      )
    }
  }
  if marker[7].to_int() != 1 {
    raise @raster.Checksum(
      at=cursor.at() + 7,
      got="\{marker[7].to_int()}",
      want="1",
    )
  }
}

///|
fn wrap_byte(value : Int32) -> Int32 {
  value & 0xFF
}

///|
/// The colour hash the format indexes its cache with: 3, 5, 7 and 11 are the
/// weights, and 64 is the number of entries.
fn hash(r : Int32, g : Int32, b : Int32, a : Int32) -> Int32 {
  (r * 3 + g * 5 + b * 7 + a * 11) & 63
}

///|
fn pack_rgba(r : Int32, g : Int32, b : Int32, a : Int32) -> UInt32 {
  (r.reinterpret_as_uint() << 24) |
  (g.reinterpret_as_uint() << 16) |
  (b.reinterpret_as_uint() << 8) |
  a.reinterpret_as_uint()
}
