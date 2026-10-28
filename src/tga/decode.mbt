// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Reading TGA.
//
// Eighteen bytes of header, an optional colour map, an optional image
// identifier, and then either pixels or runs. What makes it interesting is that
// the format was written by a company selling graphics cards, so it grew three
// image types — colour mapped, true colour, grey — and then three more that are
// the same three run-length coded.
//
// The row order is a header bit, and so is a right-to-left order, which nothing
// writes and everything used to read.

///|
/// The header, in the terms the format uses.
priv struct Header {
  image_type : Int32
  map_first : Int32
  map_length : Int32
  map_entry : Int32
  width : Int32
  height : Int32
  depth : Int32
  descriptor : Int32
  data_offset : Int32
}

///|
/// The image in a TGA file.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  if bytes.length() < 18 {
    raise @raster.Truncated(at=bytes.length(), want=18 - bytes.length())
  }
  let cursor = @wire.Cursor::new(bytes)
  let id_length = cursor.u8()
  let map_type = cursor.u8()
  let image_type = cursor.u8()
  let map_first = cursor.u16_le()
  let map_length = cursor.u16_le()
  let map_entry = cursor.u8()
  ignore(cursor.u16_le())
  ignore(cursor.u16_le())
  let width = cursor.u16_le()
  let height = cursor.u16_le()
  let depth = cursor.u8()
  let descriptor = cursor.u8()
  if width == 0 || height == 0 {
    raise @raster.Unexpected(
      at=12,
      got="a header with no pixels",
      want="a width and a height above zero",
    )
  }
  limits.check(width, height)
  let known = match image_type {
    1 | 2 | 3 | 9 | 10 | 11 => true
    _ => false
  }
  if !known {
    raise @raster.Unsupported(at=2, got="image type \{image_type}")
  }
  let mapped = image_type == 1 || image_type == 9
  if mapped && map_type != 1 {
    raise @raster.Unexpected(
      at=1,
      got="no colour map",
      want="a colour map for a mapped image",
    )
  }
  if !mapped && map_type > 1 {
    raise @raster.Unexpected(at=1, got="a colour map", want="no colour map")
  }
  let header = {
    image_type,
    map_first,
    map_length,
    map_entry,
    width,
    height,
    depth,
    descriptor,
    data_offset: 18 + id_length,
  }
  let palette = if map_type == 1 { read_palette(bytes, header) } else { [] }
  let format = format_of(header)
  let pixels = read_pixels(bytes, header, palette)
  assemble_image(header, format, pixels)
}

///|
fn format_of(header : Header) -> @raster.PixelFormat {
  let alpha_bits = header.descriptor & 0x0F
  if header.image_type == 3 || header.image_type == 11 {
    if header.depth == 16 {
      @raster.PixelFormat::GrayAlpha8
    } else {
      @raster.PixelFormat::Gray8
    }
  } else if header.depth == 32 {
    @raster.PixelFormat::Rgba8
  } else if header.depth == 16 && alpha_bits > 0 {
    // Sixteen bits with an attribute bit is five-five-five and one of alpha,
    // and a file that declares the bit means it.
    @raster.PixelFormat::Rgba8
  } else {
    @raster.PixelFormat::Rgb8
  }
}

///|
/// The colour map, as four bytes per entry: the format has no other place for a
/// palette to live.
fn read_palette(
  bytes : BytesView,
  header : Header,
) -> Array[(Int32, Int32, Int32, Int32)] raise @raster.Refused {
  let entries : Array[(Int32, Int32, Int32, Int32)] = []
  let size = (header.map_entry + 7) / 8
  let mut index = 0
  while index < header.map_length {
    let at = header.data_offset + index * size
    if at + size > bytes.length() {
      raise @raster.Truncated(at~, want=size)
    }
    entries.push(read_sample(bytes, at, header.map_entry))
    index = index + 1
  }
  entries
}

///|
/// A pixel as four bytes, in whatever depth the file stores it.
fn read_sample(
  bytes : BytesView,
  at : Int32,
  depth : Int32,
) -> (Int32, Int32, Int32, Int32) {
  match depth {
    8 => (bytes[at].to_int(), bytes[at].to_int(), bytes[at].to_int(), 255)
    15 | 16 => {
      let value = bytes[at].to_int() + bytes[at + 1].to_int() * 256
      let red = (((value >> 10) & 0x1F) * 255 + 15) / 31
      let green = (((value >> 5) & 0x1F) * 255 + 15) / 31
      let blue = ((value & 0x1F) * 255 + 15) / 31
      let alpha = if depth == 16 && (value & 0x8000) == 0 { 0 } else { 255 }
      (red, green, blue, alpha)
    }
    24 =>
      (bytes[at + 2].to_int(), bytes[at + 1].to_int(), bytes[at].to_int(), 255)
    _ =>
      (
        bytes[at + 2].to_int(),
        bytes[at + 1].to_int(),
        bytes[at].to_int(),
        bytes[at + 3].to_int(),
      )
  }
}

///|
/// The pixels, in file order, as four bytes each: run lengths are resolved here
/// and the row order is dealt with afterwards.
fn read_pixels(
  bytes : BytesView,
  header : Header,
  palette : Array[(Int32, Int32, Int32, Int32)],
) -> FixedArray[Byte] raise @raster.Refused {
  let total = header.width * header.height
  let samples : FixedArray[Byte] = FixedArray::make(total * 4, b'\x00')
  let mut position = header.data_offset +
    header.map_length * ((header.map_entry + 7) / 8)
  let size = (header.depth + 7) / 8
  let runs = match header.image_type {
    9 | 10 | 11 => true
    _ => false
  }
  let mut index = 0
  while index < total {
    if runs {
      let packet = byte_at(bytes, position)
      position = position + 1
      let count = (packet & 0x7F) + 1
      if (packet & 0x80) != 0 {
        let pixel = sample_at(bytes, position, header, palette)
        position = position + size
        for _ in 0..<count {
          if index < total {
            put_sample(samples, index, pixel)
            index = index + 1
          }
        }
      } else {
        for _ in 0..<count {
          let pixel = sample_at(bytes, position, header, palette)
          position = position + size
          if index < total {
            put_sample(samples, index, pixel)
            index = index + 1
          }
        }
      }
    } else {
      let pixel = sample_at(bytes, position, header, palette)
      position = position + size
      put_sample(samples, index, pixel)
      index = index + 1
    }
  }
  samples
}

///|
fn byte_at(bytes : BytesView, at : Int32) -> Int32 raise @raster.Refused {
  if at >= bytes.length() {
    raise @raster.Truncated(at~, want=1)
  }
  bytes[at].to_int()
}

///|
/// One pixel, whatever the image type and depth say it is.
fn sample_at(
  bytes : BytesView,
  at : Int32,
  header : Header,
  palette : Array[(Int32, Int32, Int32, Int32)],
) -> (Int32, Int32, Int32, Int32) raise @raster.Refused {
  let size = (header.depth + 7) / 8
  if at + size > bytes.length() {
    raise @raster.Truncated(at~, want=at + size - bytes.length())
  }
  let mapped = header.image_type == 1 || header.image_type == 9
  let grey = header.image_type == 3 || header.image_type == 11
  if mapped {
    let index = if header.depth == 8 {
      bytes[at].to_int() - header.map_first
    } else {
      bytes[at].to_int() + bytes[at + 1].to_int() * 256 - header.map_first
    }
    if index >= 0 && index < palette.length() {
      palette[index]
    } else {
      (0, 0, 0, 255)
    }
  } else if grey && header.depth == 8 {
    let value = bytes[at].to_int()
    (value, value, value, 255)
  } else {
    let (r, g, b, a) = read_sample(bytes, at, header.depth)
    if header.depth == 16 && (header.descriptor & 0x0F) == 0 {
      (r, g, b, 255)
    } else {
      (r, g, b, a)
    }
  }
}

///|
fn put_sample(
  samples : FixedArray[Byte],
  index : Int32,
  pixel : (Int32, Int32, Int32, Int32),
) -> Unit {
  let (r, g, b, a) = pixel
  samples[index * 4] = r.to_byte()
  samples[index * 4 + 1] = g.to_byte()
  samples[index * 4 + 2] = b.to_byte()
  samples[index * 4 + 3] = a.to_byte()
}

///|
fn assemble_image(
  header : Header,
  format : @raster.PixelFormat,
  samples : FixedArray[Byte],
) -> @raster.Image {
  let stride = header.width * format.bytes()
  let out : FixedArray[Byte] = FixedArray::make(stride * header.height, b'\x00')
  let top_down = (header.descriptor & 0x20) != 0
  let right_to_left = (header.descriptor & 0x10) != 0
  for row in 0..<header.height {
    let source_row = if top_down { row } else { header.height - 1 - row }
    for column in 0..<header.width {
      let source_column = if right_to_left {
        header.width - 1 - column
      } else {
        column
      }
      let from = (source_row * header.width + source_column) * 4
      let to = row * stride + column * format.bytes()
      match format {
        @raster.PixelFormat::Gray8 => out[to] = samples[from]
        @raster.PixelFormat::GrayAlpha8 => {
          out[to] = samples[from]
          out[to + 1] = samples[from + 3]
        }
        @raster.PixelFormat::Rgb8 => {
          out[to] = samples[from]
          out[to + 1] = samples[from + 1]
          out[to + 2] = samples[from + 2]
        }
        _ => {
          out[to] = samples[from]
          out[to + 1] = samples[from + 1]
          out[to + 2] = samples[from + 2]
          out[to + 3] = samples[from + 3]
        }
      }
    }
  }
  {
    width: header.width,
    height: header.height,
    format,
    stride,
    pixels: Bytes::from_array(out.clamped_view()),
    premultiplied: false,
    metadata: @raster.Metadata::default(),
  }
}
