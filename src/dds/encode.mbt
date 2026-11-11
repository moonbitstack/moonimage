// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing a DirectDraw surface.
//
// A texture is a header and a grid of blocks. The header says how the blocks are
// divided — which is what a reader needs before it can do anything — and each
// block holds a four-by-four square of pixels as two endpoints and an index a
// pixel.
//
// Choosing the two endpoints is a search, and the search here is the simple one:
// the smallest and the largest value of each channel in the block, which is the
// box the block's colours sit in. A better encoder would try more pairs and keep
// the one whose sixteen pixels come back closest; the difference shows on a
// block that holds two colours far apart and nothing between them, and hardly at
// all on the photographs and gradients a texture is made of.
//
// A block of one value has no box to speak of, and the endpoints of such a block
// are made a step apart rather than equal: a colour block whose first endpoint is
// not above its second is a block in the three-colour mode, which is not what an
// opaque texture means.

///|
/// The picture as a DDS.
///
/// Without a block the surface is thirty-two bits a pixel and uncompressed,
/// which is what every reader of the format opens and what loses nothing. With
/// one, the picture is cut into four-by-four blocks; the blocks at the right and
/// the bottom reach past the picture, and the pixels there repeat the ones at the
/// edge, so that the box a block is fitted to is not stretched by a colour that
/// is not in the picture.
///
/// BC1 to BC5 are written, and so are BC6H and BC7: a block of one of those
/// takes its colour from two endpoints along a line, which is a line fitted here
/// by least squares, and the mode chosen is the one with the finest weights —
/// the sixth of BC7 and the third of BC6H. The other modes spend their bits on
/// partitions of the square instead, and a search over the sixty-four shapes is
/// the difference between a good encoder and a great one rather than between a
/// picture and a refusal.
pub fn encode(
  image : @raster.Image,
  block? : Block,
) -> Bytes raise @raster.Refused {
  match block {
    None => encode_plain(image)
    Some(kind) => encode_blocks(image, kind)
  }
}

///|
/// The four-character code that names a block format.
fn fourcc_of(block : Block) -> Bytes {
  match block {
    Bc1 | Bc1Opaque => b"DXT1"
    Bc2 => b"DXT3"
    Bc3 => b"DXT5"
    Bc4 => b"ATI1"
    Bc5 => b"ATI2"
    // The two block formats the format had no code of its own for: an extension
    // header names them by number instead.
    Bc6h | Bc6hSigned | Bc7 => b"DX10"
  }
}

///|
/// The number that names a block format in the extension header, or nought for
/// one that had a code of its own.
fn dxgi_of(block : Block) -> Int32 {
  match block {
    Bc6h => 95
    Bc6hSigned => 96
    Bc7 => 98
    _ => 0
  }
}

///|
/// The header of a surface, without its pixels.
fn header(
  width : Int32,
  height : Int32,
  fourcc : Bytes?,
  step : Int32,
  dxgi : Int32,
) -> Bytes {
  let writer = @wire.Writer::new()
  writer.bytes(b"DDS ")
  writer.u32_le(124)
  let linear = fourcc is Some(_)
  // Caps, height, width, pixel format, and either the pitch of a row of pixels
  // or the size of a row of blocks.
  writer.u32_le(0x1 | 0x2 | 0x4 | 0x8 | (if linear { 0x80000 } else { 0x1000 }))
  writer.u32_le(height)
  writer.u32_le(width)
  writer.u32_le(if linear { (width + 3) / 4 * step } else { width * step })
  writer.u32_le(0)
  writer.u32_le(0)
  for _ in 0..<11 {
    writer.u32_le(0)
  }
  writer.u32_le(32)
  match fourcc {
    Some(code) => {
      writer.u32_le(0x4)
      writer.bytes(code)
      writer.u32_le(0)
      for _ in 0..<4 {
        writer.u32_le(0)
      }
    }
    None => {
      writer.u32_le(0x41)
      writer.u32_le(0)
      writer.u32_le(32)
      writer.u32_le(0x00FF0000)
      writer.u32_le(0x0000FF00)
      writer.u32_le(0x000000FF)
      writer.u32_le(0xFF000000)
    }
  }
  writer.u32_le(0x1000)
  for _ in 0..<4 {
    writer.u32_le(0)
  }
  if dxgi > 0 {
    // The extension header: the format by number, a two-dimensional texture, no
    // cube face, one surface, and no sRGB note of its own.
    writer.u32_le(dxgi)
    writer.u32_le(3)
    writer.u32_le(0)
    writer.u32_le(1)
    writer.u32_le(0)
  }
  writer.to_bytes()
}

///|
/// A surface of thirty-two bits a pixel, blue first, which is the order the
/// masks in the header name.
fn encode_plain(image : @raster.Image) -> Bytes {
  let source = image.convert(@raster.PixelFormat::Rgba8)
  let writer = @wire.Writer::new()
  writer.bytes(header(source.width, source.height, None, 4, 0))
  for y in 0..<source.height {
    for x in 0..<source.width {
      let at = y * source.stride + x * 4
      writer.u8(source.pixels[at + 2].to_int())
      writer.u8(source.pixels[at + 1].to_int())
      writer.u8(source.pixels[at].to_int())
      writer.u8(source.pixels[at + 3].to_int())
    }
  }
  writer.to_bytes()
}

///|
/// A surface of blocks.
fn encode_blocks(
  image : @raster.Image,
  block : Block,
) -> Bytes raise @raster.Refused {
  let code = fourcc_of(block)
  if block == Bc6h && has_negative(image) {
    // The unsigned half of the format cannot name a sample below nought —
    // there is no sign in it — and a picture of one written here would come back
    // brighter than it went in. The signed half of the format is the one for a
    // difference between two exposures.
    raise @raster.Unsupported(
      at=0,
      got="a negative sample in a block that has no sign",
    )
  }
  let step = block_size(block)
  let across = (image.width + 3) / 4
  let down = (image.height + 3) / 4
  let writer = @wire.Writer::new()
  writer.bytes(
    header(image.width, image.height, Some(code), step, dxgi_of(block)),
  )
  let bpp = pixel_bytes(block)
  let pixels = block_pixels(image, block)
  for by in 0..<down {
    for bx in 0..<across {
      let square = square_of(pixels, image.width, image.height, bx, by, bpp)
      match block {
        Bc1 | Bc1Opaque => write_block(writer, colour_bytes(square))
        Bc2 => {
          write_block(writer, raw_alpha_block(square))
          write_block(writer, colour_bytes(square))
        }
        Bc3 => {
          write_block(writer, single_block(square, 3))
          write_block(writer, colour_bytes(square))
        }
        Bc4 => write_block(writer, single_block(square, 0))
        Bc7 => write_wide(writer, bc7_pack(square))
        Bc6h | Bc6hSigned =>
          write_wide(
            writer,
            bc6h_pack(half_square(image, bx, by), block == Bc6hSigned),
          )
        Bc5 => {
          // The two channels of a BC5 block are the red and the green of the
          // picture: a normal map is stored that way, and the reader puts them
          // back where they were.
          write_block(writer, single_block(square, 0))
          write_block(writer, single_block(square, 1))
        }
      }
    }
  }
  writer.to_bytes()
}

///|
fn write_block(writer : @wire.Writer, body : FixedArray[Byte]) -> Unit {
  for i in 0..<8 {
    writer.u8(body[i].to_int())
  }
}

///|
/// A block of sixteen bytes, which is what a format named by an extension header
/// is.
fn write_wide(writer : @wire.Writer, body : FixedArray[Byte]) -> Unit {
  for i in 0..<16 {
    writer.u8(body[i].to_int())
  }
}

///|
/// Whether any sample of the picture is below nought.
fn has_negative(image : @raster.Image) -> Bool {
  let floats = image.convert(@raster.PixelFormat::RgbaF32)
  for i in 0..<(floats.width * floats.height) {
    for c in 0..<3 {
      if @raster.float_at(floats.pixels, i * 16 + c * 4) < 0.0F {
        return true
      }
    }
  }
  false
}

///|
/// The sixteen pixels of a block as the bit patterns of halves, which is what
/// BC6H stores: the samples of the picture, in the order red, green and blue.
fn half_square(
  image : @raster.Image,
  bx : Int32,
  by : Int32,
) -> FixedArray[Int32] {
  let floats = image.convert(@raster.PixelFormat::RgbaF32)
  let out : FixedArray[Int32] = FixedArray::make(48, 0)
  for y in 0..<4 {
    let mut py = by * 4 + y
    if py >= floats.height {
      py = floats.height - 1
    }
    for x in 0..<4 {
      let mut px = bx * 4 + x
      if px >= floats.width {
        px = floats.width - 1
      }
      let at = py * floats.stride + px * 16
      for c in 0..<3 {
        out[(y * 4 + x) * 3 + c] = @raster.float_to_half(
          @raster.float_at(floats.pixels, at + c * 4),
        )
      }
    }
  }
  out
}

///|
/// The picture in the layout its blocks speak.
fn block_pixels(image : @raster.Image, block : Block) -> Bytes {
  match block {
    Bc4 => image.convert(@raster.PixelFormat::Gray8).pixels
    Bc5 => image.convert(@raster.PixelFormat::Rgb8).pixels
    Bc6h | Bc6hSigned => image.convert(@raster.PixelFormat::RgbaF32).pixels
    _ => image.convert(@raster.PixelFormat::Rgba8).pixels
  }
}

///|
/// How many bytes a pixel of that layout takes.
fn pixel_bytes(block : Block) -> Int32 {
  match block {
    Bc4 => 1
    Bc5 => 3
    Bc6h | Bc6hSigned => 16
    _ => 4
  }
}

///|
/// Sixteen pixels of one block, four rows of four, as red, green, blue and
/// alpha; the pixels outside the picture repeat the ones at the edge.
fn square_of(
  pixels : Bytes,
  width : Int32,
  height : Int32,
  bx : Int32,
  by : Int32,
  bpp : Int32,
) -> FixedArray[Byte] {
  let stride = width * bpp
  let out : FixedArray[Byte] = FixedArray::make(64, b'\x00')
  for y in 0..<4 {
    let mut py = by * 4 + y
    if py >= height {
      py = height - 1
    }
    for x in 0..<4 {
      let mut px = bx * 4 + x
      if px >= width {
        px = width - 1
      }
      let from = py * stride + px * bpp
      let to = (y * 4 + x) * 4
      if bpp == 1 {
        out[to] = pixels[from]
        out[to + 1] = pixels[from]
        out[to + 2] = pixels[from]
        out[to + 3] = b'\xFF'
      } else if bpp == 3 {
        out[to] = pixels[from]
        out[to + 1] = pixels[from + 1]
        out[to + 2] = pixels[from + 2]
        out[to + 3] = b'\xFF'
      } else {
        for k in 0..<4 {
          out[to + k] = pixels[from + k]
        }
      }
    }
  }
  out
}

///|
/// A colour block: two endpoints of five, six and five bits, and two bits a
/// pixel choosing between the two and the two thirds of the way along.
fn colour_bytes(square : FixedArray[Byte]) -> FixedArray[Byte] {
  // The two colours of the block that are furthest apart, which is a better pair
  // to fit a line to than the corners of the box: the box has two of them for
  // one colour, and a block of red on black sits in a corner of it.
  let mut far_a = 0
  let mut far_b = 0
  let mut furthest = -1
  for i in 0..<16 {
    for j in (i + 1)..<16 {
      let dr = square[i * 4].to_int() - square[j * 4].to_int()
      let dg = square[i * 4 + 1].to_int() - square[j * 4 + 1].to_int()
      let db = square[i * 4 + 2].to_int() - square[j * 4 + 2].to_int()
      let distance = dr * dr + dg * dg + db * db
      if distance > furthest {
        furthest = distance
        far_a = i
        far_b = j
      }
    }
  }
  let mut first = pack565(
    square[far_a * 4].to_int(),
    square[far_a * 4 + 1].to_int(),
    square[far_a * 4 + 2].to_int(),
  )
  let mut second = pack565(
    square[far_b * 4].to_int(),
    square[far_b * 4 + 1].to_int(),
    square[far_b * 4 + 2].to_int(),
  )
  if first < second {
    let swap = first
    first = second
    second = swap
  }
  if first == second {
    // A block of one colour: the second endpoint steps down so that the block
    // stays in the four-colour mode, where every index means a colour.
    if first == 0xFFFF {
      second = 0
    } else {
      first = first + 1
    }
  }
  let palette = colour_palette(first, second)
  let out : FixedArray[Byte] = FixedArray::make(8, b'\x00')
  out[0] = (first & 0xFF).to_byte()
  out[1] = ((first >> 8) & 0xFF).to_byte()
  out[2] = (second & 0xFF).to_byte()
  out[3] = ((second >> 8) & 0xFF).to_byte()
  let mut bits = 0
  for i in 0..<16 {
    let red = square[i * 4].to_int()
    let green = square[i * 4 + 1].to_int()
    let blue = square[i * 4 + 2].to_int()
    let mut best = 0
    let mut closest = 1 << 30
    for index in 0..<4 {
      let dr = red - palette[index * 3]
      let dg = green - palette[index * 3 + 1]
      let db = blue - palette[index * 3 + 2]
      let distance = dr * dr + dg * dg + db * db
      if distance < closest {
        closest = distance
        best = index
      }
    }
    bits = bits | (best << (i * 2))
  }
  out[4] = (bits & 0xFF).to_byte()
  out[5] = ((bits >> 8) & 0xFF).to_byte()
  out[6] = ((bits >> 16) & 0xFF).to_byte()
  out[7] = ((bits >> 24) & 0xFF).to_byte()
  out
}

///|
/// A colour of eight bits a channel as five, six and five.
fn pack565(red : Int32, green : Int32, blue : Int32) -> Int32 {
  (red >> 3 << 11) | (green >> 2 << 5) | (blue >> 3)
}

///|
/// The four colours a block of two endpoints stands for, each as three bytes.
fn colour_palette(first : Int32, second : Int32) -> FixedArray[Int32] {
  let out : FixedArray[Int32] = FixedArray::make(12, 0)
  let r0 = (first >> 11) & 0x1F
  let g0 = (first >> 5) & 0x3F
  let b0 = first & 0x1F
  let r1 = (second >> 11) & 0x1F
  let g1 = (second >> 5) & 0x3F
  let b1 = second & 0x1F
  out[0] = (r0 << 3) | (r0 >> 2)
  out[1] = (g0 << 2) | (g0 >> 4)
  out[2] = (b0 << 3) | (b0 >> 2)
  out[3] = (r1 << 3) | (r1 >> 2)
  out[4] = (g1 << 2) | (g1 >> 4)
  out[5] = (b1 << 3) | (b1 >> 2)
  for channel in 0..<3 {
    out[6 + channel] = (2 * out[channel] + out[3 + channel]) / 3
    out[9 + channel] = (out[channel] + 2 * out[3 + channel]) / 3
  }
  out
}

///|
/// A block of one channel: two endpoints and three bits a pixel, over the six
/// values between them.
fn single_block(square : FixedArray[Byte], channel : Int32) -> FixedArray[Byte] {
  let mut high = 0
  let mut low = 255
  for i in 0..<16 {
    let value = square[i * 4 + channel].to_int()
    if value > high {
      high = value
    }
    if value < low {
      low = value
    }
  }
  if high == low {
    if high == 255 {
      low = 0
    } else {
      high = high + 1
    }
  }
  let palette : FixedArray[Int32] = FixedArray::make(8, 0)
  palette[0] = high
  palette[1] = low
  for i in 2..<8 {
    palette[i] = ((8 - i) * high + (i - 1) * low) / 7
  }
  let out : FixedArray[Byte] = FixedArray::make(8, b'\x00')
  out[0] = high.to_byte()
  out[1] = low.to_byte()
  // Sixteen indices of three bits are forty-eight bits, which is more than a
  // thirty-two-bit word holds: they are packed in a sixty-four-bit one.
  let mut bits = 0L
  for i in 0..<16 {
    let value = square[i * 4 + channel].to_int()
    let mut best = 0
    let mut closest = 1 << 30
    for index in 0..<8 {
      let distance = (value - palette[index]).abs()
      if distance < closest {
        closest = distance
        best = index
      }
    }
    bits = bits | (best.to_int64() << (i * 3))
  }
  for at in 2..<8 {
    let shift = (at - 2) * 8
    out[at] = ((bits >> shift) & 0xFFL).to_int().to_byte()
  }
  out
}

///|
/// The alpha of a BC2 block: four bits a pixel, straight through, without an
/// endpoint to interpolate between.
fn raw_alpha_block(square : FixedArray[Byte]) -> FixedArray[Byte] {
  let out : FixedArray[Byte] = FixedArray::make(8, b'\x00')
  for i in 0..<8 {
    let first = square[i * 2 * 4 + 3].to_int() >> 4
    let second = square[(i * 2 + 1) * 4 + 3].to_int() >> 4
    out[i] = (first | (second << 4)).to_byte()
  }
  out
}
