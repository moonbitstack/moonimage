// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing a PCX: the header a version-five paint program wrote, one plane a
// channel, and every row run-length coded.
//
// Eight bits a channel is the only depth written, because it is the only one
// every reader of the format agrees about: one, two and four bit pictures are
// read here, and were written by programs that had a sixteen-colour palette in
// a card and nothing else. A picture with transparency goes out as four planes
// — the format has no alpha channel of its own, and four planes is what every
// writer since Windows 95 has meant by a thirty-two bit PCX.

///|
/// How long the runs the encoder writes may be: six bits of count.
const MAX_RUN : Int32 = 0x3F

///|
/// The image as PCX bytes.
pub fn encode(image : @raster.Image) -> Bytes {
  let rgba = image.convert(@raster.PixelFormat::Rgba8)
  let width = rgba.width
  let height = rgba.height
  let pixels = rgba.pixels
  // Four planes when any pixel is not opaque: a picture that is opaque gains
  // nothing from a fourth plane, and every reader of the era treated one as a
  // mask rather than as alpha.
  let mut planes = 3
  for i in 0..<(width * height) {
    if pixels[i * 4 + 3] != b'\xFF' {
      planes = 4
      break
    }
  }
  // A row is an even number of bytes in every file the format's own tools
  // wrote; the two bytes past an odd width are padding the reader skips.
  let stride = width + width % 2
  let writer = @wire.Writer::new()
  writer.u8(0x0A)
  writer.u8(5)
  writer.u8(1)
  writer.u8(8)
  writer.u16_le(0)
  writer.u16_le(0)
  writer.u16_le(width - 1)
  writer.u16_le(height - 1)
  writer.u16_le(72)
  writer.u16_le(72)
  // The header's sixteen colours: a grey ramp, which is what a reader that
  // ignores the planes shows and what the format's own tools put there.
  for i in 0..<16 {
    let level = (i * 17).to_byte()
    writer.u8(level.to_int())
    writer.u8(level.to_int())
    writer.u8(level.to_int())
  }
  writer.u8(0)
  writer.u8(planes)
  writer.u16_le(stride)
  writer.u16_le(0)
  writer.u16_le(0)
  writer.u16_le(0)
  writer.zeros(54)
  for y in 0..<height {
    for plane in 0..<planes {
      let row : FixedArray[Byte] = FixedArray::make(stride, b'\x00')
      for x in 0..<width {
        row[x] = pixels[(y * width + x) * 4 + plane]
      }
      write_run(writer, row)
    }
  }
  writer.to_bytes()
}

///|
/// One scanline, run-length coded: a byte of two hundred or more is a count of
/// one to sixty-three and the byte after it is the value, and a run of one byte
/// below two hundred is written as itself, because the escape costs a byte.
fn write_run(writer : @wire.Writer, row : FixedArray[Byte]) -> Unit {
  let length = row.length()
  let mut at = 0
  while at < length {
    let value = row[at]
    let mut run = 1
    while at + run < length && row[at + run] == value && run < MAX_RUN {
      run = run + 1
    }
    if run > 1 || value.to_int() >= 0xC0 {
      writer.u8(0xC0 | run)
      writer.u8(value.to_int())
    } else {
      writer.u8(value.to_int())
    }
    at = at + run
  }
}
