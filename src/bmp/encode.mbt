// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing BMP.
//
// Two shapes, both of which every reader in existence understands: twenty-four
// bits per pixel in the oldest header there is, and thirty-two bits in the fourth
// version of the header, which is the first one that can say where the alpha
// channel is. Twenty-four bits is the safe choice; thirty-two is the lossless
// one.
//
// Rows are stored bottom first because that is what the format says, unless the
// caller asks for the other order, which the format also allows by writing a
// negative height.

///|
/// The image as a BMP file.
pub fn encode(image : @raster.Image, options? : EncodeOptions) -> Bytes {
  let options = options.unwrap_or(EncodeOptions::default())
  let depth = match options.depth {
    Bits24 => 24
    Bits32 => 32
  }
  let format = if depth == 32 {
    @raster.PixelFormat::Rgba8
  } else {
    @raster.PixelFormat::Rgb8
  }
  let source = image.convert(format)
  let pixel = format.bytes()
  let row_bytes = (source.width * depth + 31) / 32 * 4
  let pixel_bytes = row_bytes * source.height
  let header_size = if depth == 32 { 108 } else { 40 }
  let offset = 14 + header_size
  let writer = @wire.Writer::new()
  writer.u8(0x42)
  writer.u8(0x4D)
  writer.u32_le(offset + pixel_bytes)
  writer.u32_le(0)
  writer.u32_le(offset)
  writer.u32_le(header_size)
  writer.i32_le(source.width)
  writer.i32_le(if options.top_down { -source.height } else { source.height })
  writer.u16_le(1)
  writer.u16_le(depth)
  writer.u32_le(if depth == 32 { 3 } else { 0 })
  writer.u32_le(pixel_bytes)
  writer.u32_le(2_835)
  writer.u32_le(2_835)
  writer.u32_le(0)
  writer.u32_le(0)
  if depth == 32 {
    writer.u32_le(0x00FF_0000)
    writer.u32_le(0x0000_FF00)
    writer.u32_le(0x0000_00FF)
    writer.u32_le(0xFF00_0000)
    // The colour space: sRGB, then no endpoints and no gamma, which is what a
    // file that has not been colour managed says.
    writer.u32_le(0x7352_4742)
    // Endpoints and gamma that say nothing, which is what an sRGB file leaves
    // out, and the rest of the header as zeros.
    writer.zeros(36)
    writer.zeros(12)
  }
  for row in 0..<source.height {
    let y = if options.top_down { row } else { source.height - 1 - row }
    let start = y * source.stride
    for x in 0..<source.width {
      let at = start + x * pixel
      if depth == 32 {
        writer.u8(source.pixels[at + 2].to_int())
        writer.u8(source.pixels[at + 1].to_int())
        writer.u8(source.pixels[at].to_int())
        writer.u8(source.pixels[at + 3].to_int())
      } else {
        writer.u8(source.pixels[at + 2].to_int())
        writer.u8(source.pixels[at + 1].to_int())
        writer.u8(source.pixels[at].to_int())
      }
    }
    for _ in 0..<(row_bytes - source.width * (depth / 8)) {
      writer.u8(0)
    }
  }
  writer.to_bytes()
}
