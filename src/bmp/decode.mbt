// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Reading BMP.
//
// A BMP is a file header, a header that says which version of the format it is,
// a palette if the depth calls for one, and rows stored bottom first, each
// padded to four bytes because a 1990 display wanted that.
//
// The version matters: the first header was twelve bytes and held sixteen-bit
// dimensions, and every later one is forty or more with thirty-two-bit
// dimensions and, from forty onwards, a compression field. A reader that only
// handles forty is a reader that fails on the oldest files people still have.

///|
/// The header, normalised: whichever version it came in, it says the same things.
priv struct Info {
  width : Int32
  height : Int32
  top_down : Bool
  bits : Int32
  compression : Int32
  offset : Int32
  header_size : Int32
  palette_entry : Int32
  palette_count : Int32
  red_mask : UInt32
  green_mask : UInt32
  blue_mask : UInt32
  alpha_mask : UInt32
}

///|
/// The image in a BMP file.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  if bytes.length() < 26 || !bytes[0:2].equal_to_bytes(b"BM") {
    raise @raster.Unknown(at=0, got=@raster.hex(bytes, 0, 2))
  }
  let cursor = @wire.Cursor::new(bytes)
  ignore(cursor.u16_le())
  ignore(cursor.u32_le())
  ignore(cursor.u32_le())
  let offset = cursor.u32_le()
  let info_size = cursor.u32_le()
  let info = read_info(cursor, info_size, offset, bytes)
  limits.check(info.width, info.height)
  let format = format_of(info)
  match info.compression {
    0 | 3 | 6 => read_uncompressed(bytes, info, format)
    1 | 2 => read_run_length(bytes, info, format)
    _ => raise @raster.Unsupported(at=30, got="compression \{info.compression}")
  }
}

///|
fn read_info(
  cursor : @wire.Cursor,
  info_size : Int32,
  offset : Int32,
  bytes : BytesView,
) -> Info raise @raster.Refused {
  if info_size == 12 {
    let width = cursor.u16_le()
    let height = cursor.u16_le()
    ignore(cursor.u16_le())
    let bits = cursor.u16_le()
    return {
      width,
      height,
      top_down: false,
      bits,
      compression: 0,
      offset,
      header_size: 12,
      palette_entry: 3,
      palette_count: 0,
      red_mask: 0x7C00U,
      green_mask: 0x03E0U,
      blue_mask: 0x001FU,
      alpha_mask: 0U,
    }
  }
  if info_size < 40 {
    raise @raster.Unsupported(at=14, got="a header of \{info_size} bytes")
  }
  if bytes.length() < 14 + info_size {
    raise @raster.Truncated(
      at=bytes.length(),
      want=14 + info_size - bytes.length(),
    )
  }
  let width = cursor.i32_le()
  let height = cursor.i32_le()
  ignore(cursor.u16_le())
  let bits = cursor.u16_le()
  let compression = cursor.u32_le()
  ignore(cursor.u32_le())
  ignore(cursor.u32_le())
  ignore(cursor.u32_le())
  let used = cursor.u32_le()
  ignore(cursor.u32_le())
  let mut red_mask = 0U
  let mut green_mask = 0U
  let mut blue_mask = 0U
  let mut alpha_mask = 0U
  if info_size >= 52 {
    red_mask = cursor.bits_le()
    green_mask = cursor.bits_le()
    blue_mask = cursor.bits_le()
    if info_size >= 56 {
      alpha_mask = cursor.bits_le()
    }
  } else if compression == 3 || compression == 6 {
    // The masks follow a forty-byte header when the format is bit fields, and
    // the alpha one is there only for the variant that says so.
    red_mask = cursor.bits_le()
    green_mask = cursor.bits_le()
    blue_mask = cursor.bits_le()
    if compression == 6 {
      alpha_mask = cursor.bits_le()
    }
  }
  if bits == 16 && red_mask == 0U {
    red_mask = 0x7C00U
    green_mask = 0x03E0U
    blue_mask = 0x001FU
  }
  if bits == 32 && red_mask == 0U {
    red_mask = 0x00FF0000U
    green_mask = 0x0000FF00U
    blue_mask = 0x000000FFU
  }
  let palette_entry = if info_size == 12 { 3 } else { 4 }
  let palette_count = if used != 0 {
    used
  } else if bits <= 8 {
    1 << bits
  } else {
    0
  }
  {
    width,
    height: if height < 0 {
      -height
    } else {
      height
    },
    top_down: height < 0,
    bits,
    compression,
    offset,
    header_size: info_size,
    palette_entry,
    palette_count,
    red_mask,
    green_mask,
    blue_mask,
    alpha_mask,
  }
}

///|
/// What the pixels become.
///
/// A thirty-two-bit file is taken to carry alpha even when its header says
/// nothing about it, because half of them do; whether the fourth byte means
/// anything is decided afterwards, by looking at it.
fn format_of(info : Info) -> @raster.PixelFormat {
  if info.bits == 32 {
    @raster.PixelFormat::Rgba8
  } else {
    @raster.PixelFormat::Rgb8
  }
}

///|
/// The palette, as three bytes per entry regardless of how the file stored it.
fn read_palette(
  bytes : BytesView,
  info : Info,
) -> Array[(Int32, Int32, Int32)] raise @raster.Refused {
  let entries : Array[(Int32, Int32, Int32)] = []
  let start = 14 + info.header_size
  let mut index = 0
  while index < info.palette_count {
    let at = start + index * info.palette_entry
    if at + info.palette_entry > bytes.length() {
      raise @raster.Truncated(at~, want=info.palette_entry)
    }
    entries.push(
      (bytes[at + 2].to_int(), bytes[at + 1].to_int(), bytes[at].to_int()),
    )
    index = index + 1
  }
  entries
}

///|
/// Rows as stored, no run lengths: one bit per pixel, four, eight, sixteen,
/// twenty-four or thirty-two.
fn read_uncompressed(
  bytes : BytesView,
  info : Info,
  format : @raster.PixelFormat,
) -> @raster.Image raise @raster.Refused {
  let palette = if info.bits <= 8 { read_palette(bytes, info) } else { [] }
  let stride = info.width * format.bytes()
  let out : FixedArray[Byte] = FixedArray::make(stride * info.height, b'\x00')
  let row_bytes = (info.width * info.bits + 31) / 32 * 4
  let mut row = 0
  while row < info.height {
    let source_row = if info.top_down {
      info.offset + row * row_bytes
    } else {
      info.offset + (info.height - 1 - row) * row_bytes
    }
    if source_row + row_bytes > bytes.length() {
      raise @raster.Truncated(
        at=source_row,
        want=source_row + row_bytes - bytes.length(),
      )
    }
    let target = row * stride
    let mut column = 0
    while column < info.width {
      let (r, g, b, a) = pixel_at(bytes, source_row, column, info, palette)
      let to = target + column * format.bytes()
      out[to] = r.to_byte()
      out[to + 1] = g.to_byte()
      out[to + 2] = b.to_byte()
      if format.bytes() > 3 {
        out[to + 3] = a.to_byte()
      }
      column = column + 1
    }
    row = row + 1
  }
  assemble_image(info, format, out)
}

///|
/// One pixel of an uncompressed row, as four bytes.
fn pixel_at(
  bytes : BytesView,
  row : Int32,
  column : Int32,
  info : Info,
  palette : Array[(Int32, Int32, Int32)],
) -> (Int32, Int32, Int32, Int32) {
  match info.bits {
    1 => {
      let byte = bytes[row + column / 8].to_int()
      let bit = (byte >> (7 - column % 8)) & 1
      palette_entry(palette, bit)
    }
    4 => {
      let byte = bytes[row + column / 2].to_int()
      let index = if column % 2 == 0 { byte >> 4 } else { byte & 0xF }
      palette_entry(palette, index)
    }
    8 => palette_entry(palette, bytes[row + column].to_int())
    16 => {
      let value = bytes[row + column * 2].to_int() +
        bytes[row + column * 2 + 1].to_int() * 256
      let red = channel(value, info.red_mask)
      let green = channel(value, info.green_mask)
      let blue = channel(value, info.blue_mask)
      let alpha = if info.alpha_mask == 0U {
        255
      } else {
        channel(value, info.alpha_mask)
      }
      (red, green, blue, alpha)
    }
    24 => {
      let at = row + column * 3
      (bytes[at + 2].to_int(), bytes[at + 1].to_int(), bytes[at].to_int(), 255)
    }
    _ => {
      let at = row + column * 4
      (
        bytes[at + 2].to_int(),
        bytes[at + 1].to_int(),
        bytes[at].to_int(),
        bytes[at + 3].to_int(),
      )
    }
  }
}

///|
fn palette_entry(
  palette : Array[(Int32, Int32, Int32)],
  index : Int32,
) -> (Int32, Int32, Int32, Int32) {
  if index < palette.length() {
    let (r, g, b) = palette[index]
    (r, g, b, 255)
  } else {
    (0, 0, 0, 255)
  }
}

///|
/// One channel of a bit-field pixel, widened to eight bits by taking the top of
/// its range rather than its low byte: a five-bit channel of 31 is white.
fn channel(value : Int32, mask : UInt32) -> Int32 {
  if mask == 0U {
    return 255
  }
  let bits = mask.reinterpret_as_int()
  let mut shift = 0
  while shift < 32 && ((bits >> shift) & 1) == 0 {
    shift = shift + 1
  }
  let mut width = 0
  while width < 32 && ((bits >> (shift + width)) & 1) == 1 {
    width = width + 1
  }
  let extracted = (value >> shift) & ((1 << width) - 1)
  let top = (1 << width) - 1
  (extracted * 255 + top / 2) / top
}

///|
/// Run-length coded rows, which BMP calls BI_RLE8 and BI_RLE4.
///
/// The codes alternate between a run of one index repeated and a block of
/// indices written out, with three escapes: end of line, end of bitmap, and a
/// delta that moves the cursor without writing anything.
fn read_run_length(
  bytes : BytesView,
  info : Info,
  format : @raster.PixelFormat,
) -> @raster.Image raise @raster.Refused {
  let palette = read_palette(bytes, info)
  let indices : FixedArray[Byte] = FixedArray::make(
    info.width * info.height,
    b'\x00',
  )
  let cursor = @wire.Cursor::new(bytes)
  cursor.seek(info.offset)
  let mut x = 0
  let mut y = info.height - 1
  let mut running = true
  while running && y >= 0 && !cursor.is_empty() {
    let count = cursor.u8()
    if count > 0 {
      let value = cursor.u8()
      for step in 0..<count {
        let index = if info.bits == 8 {
          value
        } else if step % 2 == 0 {
          value >> 4
        } else {
          value & 0xF
        }
        put_index(indices, info.width, info.height, x, y, index)
        x = x + 1
      }
    } else {
      let escape = cursor.u8()
      match escape {
        0 => {
          x = 0
          y = y - 1
        }
        1 => running = false
        2 => {
          x = x + cursor.u8()
          y = y - cursor.u8()
        }
        _ => {
          // An absolute block: `escape` indices, packed two to a byte when the
          // pixels are four bits, and padded to a word.
          let at = cursor.at()
          let mut step = 0
          if info.bits == 8 {
            while step < escape {
              let value = cursor.u8()
              put_index(indices, info.width, info.height, x, y, value)
              x = x + 1
              step = step + 1
            }
            let used = cursor.at() - at
            if used % 2 == 1 && !cursor.is_empty() {
              cursor.skip(1)
            }
          } else {
            while step < escape {
              let value = cursor.u8()
              put_index(indices, info.width, info.height, x, y, value >> 4)
              x = x + 1
              step = step + 1
              if step < escape {
                put_index(indices, info.width, info.height, x, y, value & 0xF)
                x = x + 1
                step = step + 1
              }
            }
            let used = cursor.at() - at
            if used % 2 == 1 && !cursor.is_empty() {
              cursor.skip(1)
            }
          }
        }
      }
    }
  }
  let stride = info.width * format.bytes()
  let out : FixedArray[Byte] = FixedArray::make(stride * info.height, b'\x00')
  for row in 0..<info.height {
    for column in 0..<info.width {
      let (r, g, b, _) = palette_entry(
        palette,
        indices[row * info.width + column].to_int(),
      )
      let to = row * stride + column * format.bytes()
      out[to] = r.to_byte()
      out[to + 1] = g.to_byte()
      out[to + 2] = b.to_byte()
      if format.bytes() > 3 {
        out[to + 3] = (255).to_byte()
      }
    }
  }
  assemble_image(info, format, out)
}

///|
fn put_index(
  indices : FixedArray[Byte],
  width : Int32,
  height : Int32,
  x : Int32,
  y : Int32,
  value : Int32,
) -> Unit {
  if x >= 0 && x < width && y >= 0 && y < height {
    indices[y * width + x] = (value & 0xFF).to_byte()
  }
}

///|
fn assemble_image(
  info : Info,
  format : @raster.PixelFormat,
  pixels : FixedArray[Byte],
) -> @raster.Image {
  {
    width: info.width,
    height: info.height,
    format,
    stride: info.width * format.bytes(),
    pixels: Bytes::from_array(pixels.clamped_view()),
    premultiplied: false,
    metadata: @raster.Metadata::default(),
  }
}
