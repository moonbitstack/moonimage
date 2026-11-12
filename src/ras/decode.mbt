// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Reading a Sun raster: thirty-two bytes of header, an optional colour map of
// three planes, and rows padded to a sixteen-bit boundary.
//
// The padding is the detail that catches a reader out: a row of an eight-bit
// picture whose width is odd carries a byte that belongs to nothing, and a
// reader that walks the samples flat rather than row by row reads every
// following row one pixel out.
//
// Byte order inside a pixel depends on the header's type: type three is the RGB
// order every other format in this library uses, and everything else is the
// order a Sun framebuffer wanted, which is blue first.

///|
/// The four bytes every Sun raster starts with, compared a byte at a time
/// because the number they spell does not fit in the signed integer the rest of
/// the header is read into.
fn is_sun(bytes : BytesView) -> Bool {
  bytes.length() >= 4 &&
  bytes[0].to_int() == 0x59 &&
  bytes[1].to_int() == 0xA6 &&
  bytes[2].to_int() == 0x6A &&
  bytes[3].to_int() == 0x95
}

///|
/// Where the header ends.
const HEADER_BYTES : Int32 = 32

///|
/// The byte that introduces a run in the byte-encoded flavour.
const ESCAPE : Int32 = 0x80

///|
fn be32(bytes : BytesView, at : Int32) -> Int32 {
  (bytes[at].to_int() << 24) |
  (bytes[at + 1].to_int() << 16) |
  (bytes[at + 2].to_int() << 8) |
  bytes[at + 3].to_int()
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
  if !is_sun(bytes) {
    raise @raster.Unknown(at=0, got=@raster.hex(bytes, 0, 4))
  }
  let width = be32(bytes, 4)
  let height = be32(bytes, 8)
  let depth = be32(bytes, 12)
  let kind = be32(bytes, 20)
  let map_type = be32(bytes, 24)
  let map_length = be32(bytes, 28)
  if width <= 0 || height <= 0 {
    raise @raster.Unexpected(
      at=4,
      got="\{width} by \{height}",
      want="a size with pixels in it",
    )
  }
  limits.check(width, height)
  if depth != 1 && depth != 8 && depth != 24 && depth != 32 {
    raise @raster.Unsupported(at=12, got="\{depth} bits a pixel")
  }
  if kind != 0 && kind != 1 && kind != 2 && kind != 3 {
    raise @raster.Unsupported(at=20, got="Sun raster type \{kind}")
  }
  if map_length < 0 || HEADER_BYTES + map_length > bytes.length() {
    raise @raster.Truncated(at=HEADER_BYTES, want=map_length)
  }
  let body_at = HEADER_BYTES + map_length
  let stride = (width * depth + 15) / 16 * 2
  let needed = stride * height
  if needed.to_int64() > limits.bytes.to_int64() {
    raise @raster.OverLimit(limit=limits.bytes, got=needed)
  }
  let data : FixedArray[Byte] = FixedArray::make(needed, b'\x00')
  if kind == 2 {
    unwind(bytes, body_at, data, needed)
  } else {
    if bytes.length() - body_at < needed {
      raise @raster.Truncated(
        at=bytes.length(),
        want=needed - (bytes.length() - body_at),
      )
    }
    for i in 0..<needed {
      data[i] = bytes[body_at + i]
    }
  }
  let pixels : FixedArray[Byte] = FixedArray::make(width * height * 4, b'\xFF')
  if depth == 1 || depth == 8 {
    // One plane of indices. A colour map of three planes, each of `entries`
    // bytes, names the colours; without one the file is a grey ramp, which is
    // what an eight-bit Sun raster without a map means.
    let entries = 1 << depth
    // The colours as three bytes each, however the file spelled them: the map
    // of an eight-bit picture is three planes of `entries` bytes, red first.
    let palette : FixedArray[Byte] = FixedArray::make(entries * 3, b'\x00')
    if map_type == 1 && map_length >= entries * 3 {
      for entry in 0..<entries {
        for channel in 0..<3 {
          palette[entry * 3 + channel] = bytes[HEADER_BYTES +
            channel * entries +
            entry]
        }
      }
    } else if map_type == 2 && map_length >= 3 {
      // A map of one colour, which the format allows and nothing writes.
      for entry in 0..<entries {
        for channel in 0..<3 {
          palette[entry * 3 + channel] = bytes[HEADER_BYTES + channel]
        }
      }
    } else {
      for entry in 0..<entries {
        let level = (entry * 255 / (entries - 1)).to_byte()
        palette[entry * 3] = level
        palette[entry * 3 + 1] = level
        palette[entry * 3 + 2] = level
      }
    }
    for y in 0..<height {
      for x in 0..<width {
        let index = if depth == 1 {
          let byte = data[y * stride + x / 8].to_int()
          (byte >> (7 - x % 8)) & 1
        } else {
          data[y * stride + x].to_int()
        }
        let p = (y * width + x) * 4
        pixels[p] = palette[index * 3]
        pixels[p + 1] = palette[index * 3 + 1]
        pixels[p + 2] = palette[index * 3 + 2]
      }
    }
  } else {
    // Three bytes a pixel, blue first unless the header says otherwise, and a
    // fourth byte in a thirty-two bit file which this library writes as alpha
    // and every other reader ignores.
    let bytes_a_pixel = depth / 8
    for y in 0..<height {
      for x in 0..<width {
        let source = y * stride + x * bytes_a_pixel
        let p = (y * width + x) * 4
        let first = data[source]
        let second = data[source + 1]
        let third = data[source + 2]
        if kind == 3 {
          pixels[p] = first
          pixels[p + 1] = second
          pixels[p + 2] = third
        } else {
          pixels[p] = third
          pixels[p + 1] = second
          pixels[p + 2] = first
        }
        if bytes_a_pixel == 4 {
          pixels[p + 3] = data[source + 3]
        }
      }
    }
  }
  @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(pixels.clamped_view()),
  )
}

///|
/// The byte-encoded stream, decoded to exactly `needed` bytes.
///
/// The ESCAPE byte introduces a count and a value; everything else is itself.
/// Runs may cross a row, so the stream is decoded flat and cut into rows after.
fn unwind(
  bytes : BytesView,
  at : Int32,
  out : FixedArray[Byte],
  needed : Int32,
) -> Unit raise @raster.Refused {
  let mut cursor = at
  let mut written = 0
  let length = bytes.length()
  while written < needed {
    if cursor >= length {
      raise @raster.Truncated(at=cursor, want=needed - written)
    }
    let first = bytes[cursor].to_int()
    cursor = cursor + 1
    if first == ESCAPE {
      if cursor + 1 >= length {
        raise @raster.Truncated(at=cursor, want=2)
      }
      let count = bytes[cursor].to_int()
      let value = bytes[cursor + 1]
      cursor = cursor + 2
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
}
