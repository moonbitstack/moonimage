// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing TGA.
//
// True colour, twenty-four or thirty-two bits, with runs when the caller wants
// them. The run coder is the format's own: a packet either repeats one pixel up
// to a hundred and twenty-eight times or carries that many pixels as they are,
// and the high bit of the packet header says which.
//
// A run of two is worth coding and a run of one is not, but the packets have a
// header byte either way, so a raw packet only wins when it holds more than one
// pixel.

///|
/// The image as a TGA file.
pub fn encode(image : @raster.Image, options? : EncodeOptions) -> Bytes {
  let options = options.unwrap_or(EncodeOptions::default())
  let bits = match options.depth {
    Bits24 => 24
    Bits32 => 32
  }
  let format = if bits == 32 {
    @raster.PixelFormat::Rgba8
  } else {
    @raster.PixelFormat::Rgb8
  }
  let source = image.convert(format)
  let writer = @wire.Writer::new()
  writer.u8(0)
  writer.u8(0)
  writer.u8(if options.rle { 10 } else { 2 })
  writer.u16_le(0)
  writer.u16_le(0)
  writer.u8(0)
  writer.u16_le(0)
  writer.u16_le(0)
  writer.u16_le(source.width)
  writer.u16_le(source.height)
  writer.u8(bits)
  // The alpha bits are what tells a reader that the fourth byte means
  // something; the top-down bit is what tells it which row comes first.
  let alpha_bits = if bits == 32 { 8 } else { 0 }
  let orientation = if options.top_down { 0x20 } else { 0 }
  writer.u8(alpha_bits | orientation)
  let rows : Array[Bytes] = []
  for row in 0..<source.height {
    let y = if options.top_down { row } else { source.height - 1 - row }
    let start = y * source.stride
    let line = @wire.Writer::new()
    for x in 0..<source.width {
      let at = start + x * format.bytes()
      line.u8(source.pixels[at + 2].to_int())
      line.u8(source.pixels[at + 1].to_int())
      line.u8(source.pixels[at].to_int())
      if bits == 32 {
        line.u8(source.pixels[at + 3].to_int())
      }
    }
    rows.push(line.to_bytes())
  }
  let body = concat(rows)
  if options.rle {
    for packet in run_packets(body, format.bytes()) {
      writer.bytes(packet)
    }
  } else {
    writer.bytes(body)
  }
  writer.to_bytes()
}

///|
fn concat(parts : Array[Bytes]) -> Bytes {
  let builder = @buffer.Buffer::Buffer()
  for part in parts {
    builder.write_bytesview(part)
  }
  builder.to_bytes()
}

///|
/// The pixels as TGA packets: a run of one repeated pixel, or a block of pixels
/// written out.
fn run_packets(pixels : Bytes, pixel : Int32) -> Array[Bytes] {
  let packets : Array[Bytes] = []
  let total = pixels.length() / pixel
  let mut index = 0
  while index < total {
    let run = run_length(pixels, pixel, index, total)
    if run >= 2 {
      let packet = @wire.Writer::new()
      packet.u8(0x80 | (run - 1))
      packet.bytes(
        pixels.clamped_view(start=index * pixel, end=(index + 1) * pixel),
      )
      packets.push(packet.to_bytes())
      index = index + run
    } else {
      // A raw packet, up to the point where a run of three begins: a run of two
      // is not worth the header a packet costs, so it stays in the raw block.
      let start = index
      let mut count = 0
      while index < total && count < 128 {
        if run_length(pixels, pixel, index, total) >= 3 {
          break
        }
        index = index + 1
        count = count + 1
      }
      let packet = @wire.Writer::new()
      packet.u8(count - 1)
      packet.bytes(
        pixels.clamped_view(start=start * pixel, end=(start + count) * pixel),
      )
      packets.push(packet.to_bytes())
    }
  }
  packets
}

///|
/// How many times the pixel at `index` repeats, up to the end of the image and up
/// to the hundred and twenty-eight a packet can hold.
fn run_length(
  pixels : Bytes,
  pixel : Int32,
  index : Int32,
  total : Int32,
) -> Int32 {
  let mut run = 1
  while index + run < total &&
        run < 128 &&
        same_pixel(pixels, pixel, index, index + run) {
    run = run + 1
  }
  run
}

///|
fn same_pixel(pixels : Bytes, pixel : Int32, a : Int32, b : Int32) -> Bool {
  let mut index = 0
  while index < pixel {
    if pixels[a * pixel + index] != pixels[b * pixel + index] {
      return false
    }
    index = index + 1
  }
  true
}
