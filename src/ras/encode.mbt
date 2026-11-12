// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing a Sun raster: the header, no colour map, and three or four bytes a
// pixel in the order a Sun framebuffer held them.
//
// Twenty-four bits when the picture is opaque, thirty-two when it is not. The
// format has no alpha channel: the fourth byte of a thirty-two bit raster is
// padding as far as every other reader is concerned. This library writes the
// picture's alpha there anyway — a reader that ignores the byte sees the colour
// it expects, and this library gets the picture back exactly.

///|
/// The width of a row in bytes, padded to the sixteen-bit boundary the format
/// keeps every row on.
fn stride_of(width : Int32, depth : Int32) -> Int32 {
  (width * depth + 15) / 16 * 2
}

///|
/// The image as Sun raster bytes.
pub fn encode(image : @raster.Image) -> Bytes {
  let rgba = image.convert(@raster.PixelFormat::Rgba8)
  let width = rgba.width
  let height = rgba.height
  let pixels = rgba.pixels
  let mut depth = 24
  for i in 0..<(width * height) {
    if pixels[i * 4 + 3] != b'\xFF' {
      depth = 32
      break
    }
  }
  let bytes_a_pixel = depth / 8
  let stride = stride_of(width, depth)
  let writer = @wire.Writer::new()
  writer.u8(0x59)
  writer.u8(0xA6)
  writer.u8(0x6A)
  writer.u8(0x95)
  writer.u32_be(width)
  writer.u32_be(height)
  writer.u32_be(depth)
  writer.u32_be(stride * height)
  // Type one, the standard flavour: no runs, blue first.
  writer.u32_be(1)
  writer.u32_be(0)
  writer.u32_be(0)
  for y in 0..<height {
    for x in 0..<width {
      let p = (y * width + x) * 4
      writer.u8(pixels[p + 2].to_int())
      writer.u8(pixels[p + 1].to_int())
      writer.u8(pixels[p].to_int())
      if bytes_a_pixel == 4 {
        writer.u8(pixels[p + 3].to_int())
      }
    }
    for _ in 0..<(stride - width * bytes_a_pixel) {
      writer.u8(0)
    }
  }
  writer.to_bytes()
}
