// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Reading GIF.
//
// A header, a logical screen, an optional global colour table, then a stream of
// blocks: extensions that carry timing and looping, and images that carry a
// rectangle, an optional colour table of their own, and LZW-compressed indices.
//
// LZW is the part that bites. The code width grows as the dictionary fills, the
// dictionary resets on a clear code, and a code may refer to the entry that is
// about to be created — the one case a decoder written from the description
// usually misses.

///|
/// What the file says before the frames.
priv struct Screen {
  palette : Array[(Int32, Int32, Int32)]
}

///|
/// The first frame of a GIF.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let animation = parse(bytes, limits.unwrap_or(@raster.Limits::default()))
  animation.frames[0].image
}

///|
/// Every frame of a GIF, with the rectangle, delay, disposal and transparency
/// each frame declares.
pub fn decode_animation(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Animation raise @raster.Refused {
  parse(bytes, limits.unwrap_or(@raster.Limits::default()))
}

///|
fn parse(
  bytes : BytesView,
  limits : @raster.Limits,
) -> @raster.Animation raise @raster.Refused {
  if bytes.length() < 13 {
    raise @raster.Truncated(at=bytes.length(), want=13 - bytes.length())
  }
  let signature = bytes[0:6]
  if !signature.equal_to_bytes(b"GIF87a") &&
    !signature.equal_to_bytes(b"GIF89a") {
    raise @raster.Unknown(at=0, got=@raster.hex(bytes, 0, 6))
  }
  let cursor = @wire.Cursor::new(bytes)
  cursor.seek(6)
  let width = cursor.u16_le()
  let height = cursor.u16_le()
  let packed = cursor.u8()
  ignore(cursor.u8())
  ignore(cursor.u8())
  if width == 0 || height == 0 {
    raise @raster.Unexpected(
      at=6,
      got="a screen with no pixels",
      want="a width and a height above zero",
    )
  }
  limits.check(width, height)
  let global = if (packed & 0x80) != 0 {
    read_palette(cursor, 2 << (packed & 0x07))
  } else {
    []
  }
  let screen = { palette: global, }
  let frames : Array[@raster.Frame] = []
  let mut loop_count = 0
  let mut delay = 0
  let mut dispose = 0
  let mut transparent = -1
  while !cursor.is_empty() {
    let marker = cursor.u8()
    match marker {
      0x3B => break
      0x21 => {
        let label = cursor.u8()
        match label {
          0xF9 => {
            // A graphic control extension: four bytes of it, then a terminator.
            let size = cursor.u8()
            if size < 4 {
              raise @raster.Truncated(at=cursor.at(), want=4 - size)
            }
            let flags = cursor.u8()
            delay = cursor.u16_le() * 10
            let index = cursor.u8()
            ignore(cursor.u8())
            dispose = (flags >> 2) & 0x07
            transparent = if (flags & 0x01) != 0 { index } else { -1 }
          }
          0xFF => {
            let size = cursor.u8()
            let name = cursor.bytes(size)
            let data = read_sub_blocks(cursor)
            if name.length() >= 11 && name[0:11].equal_to_bytes(b"NETSCAPE2.0") {
              if data.length() >= 3 && data[0].to_int() == 1 {
                loop_count = data[1].to_int() + data[2].to_int() * 256
              }
            }
          }
          _ => ignore(read_sub_blocks(cursor))
        }
      }
      0x2C => {
        frames.push(
          read_frame(cursor, screen, limits, delay, dispose, transparent),
        )
        // A graphic control extension applies to the frame that follows it and
        // to nothing else.
        delay = 0
        dispose = 0
        transparent = -1
      }
      _ =>
        raise @raster.Unexpected(
          at=cursor.at() - 1,
          got="block \{marker}",
          want="an extension or an image",
        )
    }
  }
  if frames.is_empty() {
    raise @raster.Unexpected(
      at=0,
      got="no image blocks",
      want="at least one frame",
    )
  }
  @raster.Animation::new(width, height, frames, loops=loop_count)
}

///|
fn dispose_of(code : Int32) -> @raster.Dispose {
  match code {
    2 => @raster.Dispose::Background
    3 => @raster.Dispose::Previous
    _ => @raster.Dispose::Keep
  }
}

///|
/// A colour table of `count` entries, three bytes each.
fn read_palette(
  cursor : @wire.Cursor,
  count : Int32,
) -> Array[(Int32, Int32, Int32)] raise @raster.Refused {
  let entries : Array[(Int32, Int32, Int32)] = []
  for _ in 0..<count {
    let red = cursor.u8()
    let green = cursor.u8()
    let blue = cursor.u8()
    entries.push((red, green, blue))
  }
  entries
}

///|
/// The bytes of a series of sub-blocks, joined: GIF splits everything longer than
/// 255 bytes this way.
fn read_sub_blocks(cursor : @wire.Cursor) -> Bytes raise @raster.Refused {
  let builder = @buffer.Buffer::Buffer()
  while true {
    let size = cursor.u8()
    if size == 0 {
      break
    }
    builder.write_bytesview(cursor.bytes(size))
  }
  builder.to_bytes()
}

///|
/// One image descriptor and its data.
fn read_frame(
  cursor : @wire.Cursor,
  screen : Screen,
  limits : @raster.Limits,
  delay : Int32,
  dispose : Int32,
  transparent : Int32,
) -> @raster.Frame raise @raster.Refused {
  let x = cursor.u16_le()
  let y = cursor.u16_le()
  let width = cursor.u16_le()
  let height = cursor.u16_le()
  let packed = cursor.u8()
  if width == 0 || height == 0 {
    raise @raster.Unexpected(
      at=cursor.at() - 5,
      got="a frame with no pixels",
      want="a width and a height above zero",
    )
  }
  limits.check(width, height)
  let table = if (packed & 0x80) != 0 {
    read_palette(cursor, 2 << (packed & 0x07))
  } else {
    screen.palette
  }
  if table.is_empty() {
    raise @raster.Unexpected(
      at=cursor.at(),
      got="a frame with no colour table",
      want="a global or local palette",
    )
  }
  let minimum = cursor.u8()
  if minimum < 2 || minimum > 8 {
    raise @raster.Unexpected(
      at=cursor.at() - 1,
      got="a code size of \{minimum}",
      want="two to eight",
    )
  }
  let data = read_sub_blocks(cursor)
  let indices = unlzw(data, minimum, width * height)
  let interlaced = (packed & 0x40) != 0
  let pixels : FixedArray[Byte] = FixedArray::make(width * height * 4, b'\x00')
  for row in 0..<height {
    let source_row = if interlaced { interlaced_row(row, height) } else { row }
    for column in 0..<width {
      let index = indices[source_row * width + column].to_int()
      let (red, green, blue) = if index < table.length() {
        table[index]
      } else {
        (0, 0, 0)
      }
      let at = (row * width + column) * 4
      pixels[at] = red.to_byte()
      pixels[at + 1] = green.to_byte()
      pixels[at + 2] = blue.to_byte()
      pixels[at + 3] = (if index == transparent { 0 } else { 255 }).to_byte()
    }
  }
  @raster.Frame::new(
    {
      width,
      height,
      format: @raster.PixelFormat::Rgba8,
      stride: width * 4,
      pixels: Bytes::from_array(pixels.clamped_view()),
      premultiplied: false,
      metadata: @raster.Metadata::default(),
    },
    x~,
    y~,
    delay~,
    dispose=dispose_of(dispose),
    blend=@raster.Blend::Over,
  )
}

///|
/// Which stored row holds a given image row.
///
/// GIF writes an interlaced image in four passes: every eighth row from zero,
/// then every eighth from four, then every fourth from two, then every second
/// from one. The passes come one after another in the file, so the stored row is
/// the pass's starting offset plus how far into the pass this row is.
fn interlaced_row(row : Int32, height : Int32) -> Int32 {
  let starts = [0, 4, 2, 1]
  let steps = [8, 8, 4, 2]
  let mut offset = 0
  for pass in 0..<4 {
    let start = starts[pass]
    let step = steps[pass]
    if row >= start && (row - start) % step == 0 {
      return offset + (row - start) / step
    }
    if height > start {
      offset = offset + (height - start + step - 1) / step
    }
  }
  row
}

///|
/// LZW, as GIF speaks it: codes of a growing width, least significant bit first,
/// a clear code that resets the dictionary and an end code that stops it.
fn unlzw(
  data : BytesView,
  minimum : Int32,
  expected : Int32,
) -> FixedArray[Byte] raise @raster.Refused {
  let clear = 1 << minimum
  let end = clear + 1
  let prefix : FixedArray[Int32] = FixedArray::make(4096, 0)
  let suffix : FixedArray[Int32] = FixedArray::make(4096, 0)
  let first : FixedArray[Int32] = FixedArray::make(4096, 0)
  for index in 0..<clear {
    suffix[index] = index
    first[index] = index
  }
  let stack : FixedArray[Int32] = FixedArray::make(4096, 0)
  let out : FixedArray[Byte] = FixedArray::make(expected, b'\x00')
  let mut written = 0
  let bits = BitReader::new(data)
  let mut width = minimum + 1
  let mut next = end + 1
  let mut previous = -1
  while true {
    let code = bits.read(width)
    if code < 0 {
      break
    }
    if code == clear {
      width = minimum + 1
      next = end + 1
      previous = -1
      continue
    }
    if code == end {
      break
    }
    if code > next {
      raise @raster.Unexpected(
        at=bits.at(),
        got="a code of \{code}",
        want="a code below \{next}",
      )
    }
    let mut depth = 0
    let mut current = code
    if code == next {
      // The code that is about to be defined: the previous string plus its own
      // first symbol, which is the case a decoder must special-case.
      if previous < 0 {
        raise @raster.Unexpected(
          at=bits.at(),
          got="a code with nothing behind it",
          want="a string",
        )
      }
      stack[depth] = first[previous]
      depth = depth + 1
      current = previous
    }
    while current >= clear {
      if depth >= 4096 {
        raise @raster.Unexpected(
          at=bits.at(),
          got="a string that does not start",
          want="a prefix",
        )
      }
      stack[depth] = suffix[current]
      depth = depth + 1
      current = prefix[current]
    }
    stack[depth] = current
    depth = depth + 1
    while depth > 0 {
      depth = depth - 1
      if written < expected {
        out[written] = stack[depth].to_byte()
        written = written + 1
      }
    }
    if previous >= 0 && next < 4096 {
      prefix[next] = previous
      suffix[next] = current
      first[next] = first[previous]
      next = next + 1
      // The width grows the moment the next free code no longer fits: the
      // encoder adds the same entry at the same point, so both sides widen on
      // the same code.
      if next == 1 << width && width < 12 {
        width = width + 1
      }
    }
    previous = code
  }
  if written < expected {
    // A file that ends early leaves the rest of the rectangle as the palette's
    // first colour, which is what every viewer shows.
    let padding = out[0]
    let _ = padding
  }
  out
}

///|
/// A reader of codes packed least significant bit first.
priv struct BitReader {
  data : BytesView
  mut position : Int32
}

///|
fn BitReader::new(data : BytesView) -> BitReader {
  { data, position: 0, }
}

///|
fn BitReader::at(self : BitReader) -> Int32 {
  self.position / 8
}

///|
/// The next `width` bits, or -1 when the data has run out.
fn BitReader::read(self : BitReader, width : Int32) -> Int32 {
  if self.position + width > self.data.length() * 8 {
    return -1
  }
  let mut value = 0
  for bit in 0..<width {
    let at = self.position + bit
    let byte = self.data[at / 8].to_int()
    if ((byte >> (at % 8)) & 1) == 1 {
      value = value | (1 << bit)
    }
  }
  self.position = self.position + width
  value
}
