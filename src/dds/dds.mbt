// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// DirectDraw surfaces, read for the block-compressed pictures in them.
//
// A DDS is a texture: a header, an optional second header that names the
// format, and then the blocks. Compression here is not a stream but a grid: a
// four-by-four square of pixels becomes one block of eight or sixteen bytes,
// and the square is rebuilt from two endpoints and an index a pixel.
//
// Reading is all this library does with the format. Writing a block-compressed
// texture means choosing the endpoints and the indices, which is a search with
// a quality knob — a different job from coding a picture, and one whose result
// nobody can check by eye.
//
// A BC4 block is one channel, so it comes back as a grey picture and every
// operation the library has for grey pictures applies to it. A BC5 block is two,
// and they come back as red and green with blue at nought, which is what a
// normal map is. The three colour formats come back as RGBA.
//
// BC6H is a picture of light: its samples are halves and it has no alpha, so it
// comes back as four floats a pixel with alpha at one. BC7 is the newest of the
// eight-bit formats and the only one that carries a mode number, which is what
// says how its sixteen bytes are divided between endpoints and indices. Both are
// read; neither is written, for the reason above.

///|
/// Which block format a texture is in.
#derive(Eq, Debug)
pub(all) enum Block {
  /// BC1: two colours and two thirds of the way between them, with a
  /// transparent entry in the three-colour form.
  Bc1
  /// BC1 with alpha treated as opaque, which is how a normal map is stored.
  Bc1Opaque
  /// BC2: four bits of alpha a pixel, then a BC1 colour block.
  Bc2
  /// BC3: interpolated alpha, then a BC1 colour block.
  Bc3
  /// BC4: one channel, interpolated from two endpoints.
  Bc4
  /// BC5: two channels, each a BC4 block.
  Bc5
  /// BC6H: three channels of half-precision light, unsigned.
  Bc6h
  /// BC6H with signed samples, which is what a difference between two exposures
  /// is stored in.
  Bc6hSigned
  /// BC7: eight bits a channel, with a mode number that says how the block is
  /// divided.
  Bc7
}

///|
pub extend Block with Eq::{equal, not_equal}

///|
pub extend Block with Debug::{to_repr}

///|
/// How many bytes a block of this format takes.
fn block_size(block : Block) -> Int32 {
  match block {
    Bc1 | Bc1Opaque | Bc4 => 8
    _ => 16
  }
}

///|
/// The picture in these bytes.
///
/// A texture usually carries a chain of mipmaps after the first surface; this
/// reads the first, which is the only one a caller that wants "the picture"
/// means.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  if bytes.length() < 128 || !bytes.has_prefix(b"DDS ") {
    raise @raster.Unknown(at=0, got=@raster.hex(bytes, 0, 8))
  }
  let height = le32(bytes, 12)
  let width = le32(bytes, 16)
  if width <= 0 || height <= 0 {
    raise @raster.Unexpected(
      at=12,
      got="a surface with no pixels",
      want="a width and a height above zero",
    )
  }
  limits.check(width, height)
  let fourcc = bytes[84:88]
  let flags = le32(bytes, 80)
  let mut at = 128
  let block = if fourcc.equal_to_bytes(b"DX10") {
    if bytes.length() < 148 {
      raise @raster.Truncated(at=128, want=20)
    }
    let dxgi = le32(bytes, 128)
    at = 148
    match dxgi {
      70 | 71 => Bc1
      72 | 73 => Bc1
      74 | 75 => Bc2
      76 | 77 => Bc3
      79 | 80 => Bc4
      82 | 83 => Bc5
      95 => Bc6h
      96 => Bc6hSigned
      97 | 98 => Bc7
      _ => raise @raster.Unsupported(at=128, got="a DXGI format of \{dxgi}")
    }
  } else if fourcc.equal_to_bytes(b"DXT1") {
    Bc1
  } else if fourcc.equal_to_bytes(b"DXT3") {
    Bc2
  } else if fourcc.equal_to_bytes(b"DXT5") {
    Bc3
  } else if fourcc.equal_to_bytes(b"ATI1") || fourcc.equal_to_bytes(b"BC4U") {
    Bc4
  } else if fourcc.equal_to_bytes(b"ATI2") || fourcc.equal_to_bytes(b"BC5U") {
    Bc5
  } else if (flags & 0x40) != 0 || ((flags & 0x1) != 0 && le32(bytes, 88) > 0) {
    // An uncompressed surface: the masks say how the bits of a pixel are
    // divided, which is how a texture with an unusual channel order is stored.
    return decode_plain(bytes, width, height, at, limits)
  } else {
    raise @raster.Unsupported(
      at=84,
      got="a pixel format this library does not read",
    )
  }
  decode_blocks(bytes, width, height, at, block, limits)
}

///|
/// The picture in these bytes, in the layout the caller needs rather than the one
/// the block is.
///
/// A block format says what a block holds, not what a picture is drawn with: BC4
/// is one channel and BC5 is two, and a caller that is about to upload a texture
/// or paint a canvas wants neither. This is that call.
///
/// The formats that mean RGBA already — BC1, BC2, BC3, BC7 — cost nothing here:
/// the decode lands in the layout asked for and no second buffer is made. A BC4
/// or a BC5 is widened, and a BC6H, which is light rather than colour, is scaled
/// down to eight bits with the rest of the picture; those two are a decode
/// followed by a conversion, so a caller that wants both the native sampling and
/// the display one may prefer to call `decode` and convert the result itself.
pub fn decode_as(
  bytes : BytesView,
  format : @raster.PixelFormat,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  decode(bytes, limits?).convert(format)
}

///|
/// The textures that are stored as plain samples, which is what a DDS of a
/// mask or a height field usually is.
fn decode_plain(
  bytes : BytesView,
  width : Int32,
  height : Int32,
  at : Int32,
  limits : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let bits = le32(bytes, 88)
  let red = le32(bytes, 92)
  let green = le32(bytes, 96)
  let blue = le32(bytes, 100)
  let alpha = le32(bytes, 108)
  if bits != 32 && bits != 24 {
    raise @raster.Unsupported(at=88, got="\{bits} bits a pixel uncompressed")
  }
  let step = bits / 8
  limits.check_bytes(width * height * step)
  if at.to_int64() + width.to_int64() * height.to_int64() * step.to_int64() >
    bytes.length().to_int64() {
    raise @raster.Truncated(at~, want=width * height * step)
  }
  let out : FixedArray[Byte] = FixedArray::make(width * height * 4, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let from = at + (y * width + x) * step
      let value = le32(bytes, from)
      let to = (y * width + x) * 4
      out[to] = mask_value(value, red)
      out[to + 1] = mask_value(value, green)
      out[to + 2] = mask_value(value, blue)
      out[to + 3] = if alpha == 0 { b'\xFF' } else { mask_value(value, alpha) }
    }
  }
  @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(out.clamped_view()),
  )
}

///|
/// The bits a mask covers, moved down and widened to a byte.
fn mask_value(value : Int32, mask : Int32) -> Byte {
  if mask == 0 {
    return b'\x00'
  }
  let mut shift = 0
  while shift < 32 && ((mask >> shift) & 1) == 0 {
    shift = shift + 1
  }
  let mut width = 0
  while width < 32 && ((mask >> (shift + width)) & 1) == 1 {
    width = width + 1
  }
  let raw = (value >> shift) & ((1 << width) - 1)
  let top = (1 << width) - 1
  ((raw * 255 + top / 2) / top).to_byte()
}

///|
/// The block grid, row of blocks by row of blocks.
fn decode_blocks(
  bytes : BytesView,
  width : Int32,
  height : Int32,
  at : Int32,
  block : Block,
  limits : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let across = (width + 3) / 4
  let down = (height + 3) / 4
  let step = block_size(block)
  let needed = across.to_int64() * down.to_int64() * step.to_int64()
  if at.to_int64() + needed > bytes.length().to_int64() {
    raise @raster.Truncated(at~, want=needed.to_int())
  }
  limits.check_bytes(needed.to_int())
  let format = block_format(block)
  let out : FixedArray[Byte] = FixedArray::make(
    width * height * format.bytes(),
    b'\x00',
  )
  let mut from = at
  for by in 0..<down {
    for bx in 0..<across {
      decode_block(bytes, from, block, out, width, height, bx * 4, by * 4)
      from = from + step
    }
  }
  @raster.Image::of(
    width,
    height,
    format,
    Bytes::from_array(out.clamped_view()),
  )
}

///|
/// What a block of this format is a picture of.
///
/// One channel is grey; two are red and green, which is what the format was
/// invented for; three and four are a picture with alpha in it.
fn block_format(block : Block) -> @raster.PixelFormat {
  match block {
    Bc4 => @raster.PixelFormat::Gray8
    Bc5 => @raster.PixelFormat::Rgb8
    Bc6h | Bc6hSigned => @raster.PixelFormat::RgbaF32
    _ => @raster.PixelFormat::Rgba8
  }
}

///|
/// One four-by-four square.
fn decode_block(
  bytes : BytesView,
  at : Int32,
  block : Block,
  out : FixedArray[Byte],
  width : Int32,
  height : Int32,
  left : Int32,
  top : Int32,
) -> Unit {
  let colour_at = match block {
    Bc2 | Bc3 => at + 8
    _ => at
  }
  let alpha_at = match block {
    Bc2 | Bc3 => at
    _ => at
  }
  let pixel = block_format(block).bytes()
  if block == Bc7 {
    let colours = decode_bc7(bytes, at)
    for y in 0..<4 {
      for x in 0..<4 {
        let px = left + x
        let py = top + y
        if px < width && py < height {
          let to = (py * width + px) * pixel
          let from = (y * 4 + x) * 4
          out[to] = colours[from]
          out[to + 1] = colours[from + 1]
          out[to + 2] = colours[from + 2]
          out[to + 3] = colours[from + 3]
        }
      }
    }
    return
  }
  if block == Bc6h || block == Bc6hSigned {
    let halves = decode_bc6h(bytes, at, block == Bc6hSigned)
    for y in 0..<4 {
      for x in 0..<4 {
        let px = left + x
        let py = top + y
        if px < width && py < height {
          let to = (py * width + px) * pixel
          let from = (y * 4 + x) * 3
          for channel in 0..<3 {
            @raster.put_float(
              out,
              to + channel * 4,
              @raster.half_to_float(halves[from + channel]),
            )
          }
          // The format has no alpha, so a pixel is as opaque as one can be.
          @raster.put_float(out, to + 12, 1.0)
        }
      }
    }
    return
  }
  if block == Bc4 || block == Bc5 {
    let red = channel_block(bytes, alpha_at)
    let green = if block == Bc5 {
      channel_block(bytes, alpha_at + 8)
    } else {
      red
    }
    for y in 0..<4 {
      for x in 0..<4 {
        let px = left + x
        let py = top + y
        if px < width && py < height {
          let to = (py * width + px) * pixel
          out[to] = red[y * 4 + x]
          if block == Bc5 {
            out[to + 1] = green[y * 4 + x]
            out[to + 2] = b'\x00'
          }
        }
      }
    }
    return
  }
  // Only BC1 has the three-colour form with a transparent entry: a BC2 or BC3
  // colour block is four colours whatever its endpoints are, because the alpha
  // is in the block beside it.
  let colours = colour_block(bytes, colour_at, block == Bc1)
  let alpha = if block == Bc3 {
    channel_block(bytes, alpha_at)
  } else {
    FixedArray::make(16, b'\xFF')
  }
  for y in 0..<4 {
    for x in 0..<4 {
      let px = left + x
      let py = top + y
      if px < width && py < height {
        let (r, g, b, a) = colours[y * 4 + x]
        let to = (py * width + px) * 4
        out[to] = r
        out[to + 1] = g
        out[to + 2] = b
        out[to + 3] = match block {
          Bc2 => alpha_four_bits(bytes, alpha_at, x, y)
          Bc3 => alpha[y * 4 + x]
          _ => a
        }
      }
    }
  }
}

///|
/// The colours of a BC1 block and the two bits a pixel that pick one.
///
/// The two forms differ in what the third and fourth entries are: more colour
/// when the first endpoint is the larger, and in the other form the average
/// plus a transparent black, which is how a cut-out sprite is stored.
fn colour_block(
  bytes : BytesView,
  at : Int32,
  punch_through : Bool,
) -> FixedArray[(Byte, Byte, Byte, Byte)] {
  let first = be16(bytes, at)
  let second = be16(bytes, at + 2)
  let c0 = (
    expand5((first >> 11) & 0x1F),
    expand6((first >> 5) & 0x3F),
    expand5(first & 0x1F),
  )
  let c1 = (
    expand5((second >> 11) & 0x1F),
    expand6((second >> 5) & 0x3F),
    expand5(second & 0x1F),
  )
  let base : FixedArray[(Byte, Byte, Byte, Byte)] = FixedArray::make(
    4,
    (b'\x00', b'\x00', b'\x00', b'\xFF'),
  )
  base[0] = (c0.0, c0.1, c0.2, b'\xFF')
  base[1] = (c1.0, c1.1, c1.2, b'\xFF')
  if first > second || !punch_through {
    base[2] = (
      ((c0.0.to_int() * 2 + c1.0.to_int()) / 3).to_byte(),
      ((c0.1.to_int() * 2 + c1.1.to_int()) / 3).to_byte(),
      ((c0.2.to_int() * 2 + c1.2.to_int()) / 3).to_byte(),
      b'\xFF',
    )
    base[3] = (
      ((c0.0.to_int() + c1.0.to_int() * 2) / 3).to_byte(),
      ((c0.1.to_int() + c1.1.to_int() * 2) / 3).to_byte(),
      ((c0.2.to_int() + c1.2.to_int() * 2) / 3).to_byte(),
      b'\xFF',
    )
  } else {
    base[2] = (
      ((c0.0.to_int() + c1.0.to_int()) / 2).to_byte(),
      ((c0.1.to_int() + c1.1.to_int()) / 2).to_byte(),
      ((c0.2.to_int() + c1.2.to_int()) / 2).to_byte(),
      b'\xFF',
    )
    base[3] = (b'\x00', b'\x00', b'\x00', b'\x00')
  }
  let picks = le32(bytes, at + 4)
  let pixels : FixedArray[(Byte, Byte, Byte, Byte)] = FixedArray::make(
    16,
    (b'\x00', b'\x00', b'\x00', b'\xFF'),
  )
  for y in 0..<4 {
    for x in 0..<4 {
      pixels[y * 4 + x] = base[(picks >> ((y * 4 + x) * 2)) & 0x3]
    }
  }
  pixels
}

///|
/// The two endpoints of a channel block and the three bits a sample that pick
/// between them, which is how BC3's alpha and all of BC4 is stored.
fn channel_block(bytes : BytesView, at : Int32) -> FixedArray[Byte] {
  let a0 = bytes[at].to_int()
  let a1 = bytes[at + 1].to_int()
  let steps : FixedArray[Int32] = FixedArray::make(8, 0)
  steps[0] = a0
  steps[1] = a1
  if a0 > a1 {
    for i in 0..<6 {
      steps[2 + i] = ((6 - i) * a0 + (1 + i) * a1) / 7
    }
  } else {
    for i in 0..<4 {
      steps[2 + i] = ((4 - i) * a0 + (1 + i) * a1) / 5
    }
    steps[6] = 0
    steps[7] = 255
  }
  let out : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  // Sixteen three-bit indices in six bytes, little endian.
  let mut packed : Int64 = 0L
  for i in 0..<6 {
    packed = packed | (bytes[at + 2 + i].to_int64() << (8 * i))
  }
  for i in 0..<16 {
    let index = ((packed >> (i * 3)) & 7L).to_int()
    out[i] = steps[index].to_byte()
  }
  out
}

///|
fn alpha_four_bits(bytes : BytesView, at : Int32, x : Int32, y : Int32) -> Byte {
  let row = y * 2 + x / 2
  let value = bytes[at + row].to_int()
  let nibble = if x % 2 == 0 { value & 0xF } else { value >> 4 }
  (nibble * 17).to_byte()
}

///|
fn expand5(value : Int32) -> Byte {
  ((value << 3) | (value >> 2)).to_byte()
}

///|
fn expand6(value : Int32) -> Byte {
  ((value << 2) | (value >> 4)).to_byte()
}

///|
fn be16(bytes : BytesView, at : Int32) -> Int32 {
  bytes[at].to_int() | (bytes[at + 1].to_int() << 8)
}

///|
fn le32(bytes : BytesView, at : Int32) -> Int32 {
  bytes[at].to_int() |
  (bytes[at + 1].to_int() << 8) |
  (bytes[at + 2].to_int() << 16) |
  (bytes[at + 3].to_int() << 24)
}
