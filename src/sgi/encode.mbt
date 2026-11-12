// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing an SGI: the header every writer of the format agrees about, then the
// channels stored plain, one after another.
//
// Plain rather than run-length coded, and marked with both the magic that says
// runs are allowed and the storage byte that says this file has none, because
// that is the pair Pillow writes and the pair every reader of the format has
// been tested against for thirty years. The runs would save space on a picture
// with flat colour and cost a table per channel on one that is a photograph.

///|
/// One channel of the picture, as the samples the format stores.
fn channel_of(
  pixels : BytesView,
  width : Int32,
  height : Int32,
  channel : Int32,
) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(width * height, b'\x00')
  for y in 0..<height {
    // The format counts rows from the bottom, so the last row of the picture is
    // the first one in the file.
    let stored = height - 1 - y
    for x in 0..<width {
      out[stored * width + x] = pixels[(y * width + x) * 4 + channel]
    }
  }
  Bytes::from_array(out.clamped_view())
}

///|
/// The image as SGI bytes.
pub fn encode(image : @raster.Image) -> Bytes {
  let rgba = image.convert(@raster.PixelFormat::Rgba8)
  let width = rgba.width
  let height = rgba.height
  let pixels = rgba.pixels
  let mut channels = 3
  for i in 0..<(width * height) {
    if pixels[i * 4 + 3] != b'\xFF' {
      channels = 4
      break
    }
  }
  let writer = @wire.Writer::new()
  writer.u16_be(474)
  writer.u8(0)
  writer.u8(1)
  writer.u16_be(3)
  writer.u16_be(width)
  writer.u16_be(height)
  writer.u16_be(channels)
  writer.u32_be(0)
  writer.u32_be(255)
  writer.u32_be(0)
  // The name is eighty bytes and the rest of the header four hundred and four;
  // neither is read by anything, and zeroes are what a writer with no opinion
  // puts there.
  writer.zeros(80)
  writer.u32_be(0)
  writer.zeros(404)
  for channel in 0..<channels {
    writer.bytes(channel_of(pixels, width, height, channel))
  }
  writer.to_bytes()
}
