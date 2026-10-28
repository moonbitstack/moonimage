// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing JPEG.
//
// Baseline, Huffman-coded, no restart markers: the shape every decoder reads.
// The image is transformed eight by eight, quantised by a table scaled from the
// standard's example by the quality the caller asked for, and the coefficients
// are run-length and Huffman coded.
//
// Quality is not a property of the file; it is a number from one to a hundred
// that scales the quantisation table, which is what every encoder does and
// therefore what a comparison against one means.

///|
/// The image as a baseline JPEG.
pub fn encode(image : @raster.Image, options? : EncodeOptions) -> Bytes {
  let options = options.unwrap_or(EncodeOptions::default())
  let quality = if options.quality < 1 {
    1
  } else if options.quality > 100 {
    100
  } else {
    options.quality
  }
  let scale = if quality < 50 { 5000 / quality } else { 200 - quality * 2 }
  let luma = scaled_table(luminance_table, scale)
  let chroma = scaled_table(chrominance_table, scale)
  let grey = image.format.is_gray()
  let source = if grey {
    image.convert(@raster.PixelFormat::Gray8)
  } else {
    image.convert(@raster.PixelFormat::Rgb8)
  }
  let (hs, vs) = match options.subsampling {
    Yuv444 => (1, 1)
    Yuv422 => (2, 1)
    Yuv420 => (2, 2)
  }
  let width = source.width
  let height = source.height
  let mcu_w = if grey { 8 } else { 8 * hs }
  let mcu_h = if grey { 8 } else { 8 * vs }
  let across = (width + mcu_w - 1) / mcu_w
  let down = (height + mcu_h - 1) / mcu_h
  let writer = @wire.Writer::new()
  writer.u8(0xFF)
  writer.u8(0xD8)
  write_app0(writer)
  write_quantisation(writer, luma, chroma)
  write_frame(writer, width, height, grey, hs, vs)
  write_huffman_tables(writer)
  write_scan_header(writer, grey)
  let bits = JpegBits::new()
  let dc_luma = codes_of(luminance_dc_counts, luminance_dc_symbols)
  let ac_luma = codes_of(luminance_ac_counts, luminance_ac_symbols)
  let dc_chroma = codes_of(chrominance_dc_counts, chrominance_dc_symbols)
  let ac_chroma = codes_of(chrominance_ac_counts, chrominance_ac_symbols)
  let previous = [0, 0, 0]
  let block : FixedArray[Double] = FixedArray::make(64, 0.0)
  let samples : FixedArray[Double] = FixedArray::make(64, 0.0)
  for mcu_y in 0..<down {
    for mcu_x in 0..<across {
      if grey {
        gather_grey(source, mcu_x * 8, mcu_y * 8, samples)
        previous[0] = encode_block(
          bits,
          block,
          samples,
          luma,
          dc_luma,
          ac_luma,
          previous[0],
        )
      } else {
        // Component by component, and within a component row by row: that is the
        // order the scan declares and the order the decoder reads.
        for v in 0..<vs {
          for h in 0..<hs {
            gather_plane(
              source,
              mcu_x * 8 * hs + h * 8,
              mcu_y * 8 * vs + v * 8,
              0,
              8,
              1,
              1,
              samples,
            )
            previous[0] = encode_block(
              bits,
              block,
              samples,
              luma,
              dc_luma,
              ac_luma,
              previous[0],
            )
          }
        }
        // One chroma block per MCU per component: the chroma planes are
        // subsampled, so their block already covers the whole MCU.
        for channel in [1, 2] {
          gather_plane(
            source,
            mcu_x * 8 * hs,
            mcu_y * 8 * vs,
            channel,
            8,
            hs,
            vs,
            samples,
          )
          if channel == 1 {
            previous[1] = encode_block(
              bits,
              block,
              samples,
              chroma,
              dc_chroma,
              ac_chroma,
              previous[1],
            )
          } else {
            previous[2] = encode_block(
              bits,
              block,
              samples,
              chroma,
              dc_chroma,
              ac_chroma,
              previous[2],
            )
          }
        }
      }
    }
  }
  writer.bytes(bits.to_bytes())
  writer.u8(0xFF)
  writer.u8(0xD9)
  writer.to_bytes()
}

///|
/// The standard's example luminance table.
let luminance_table : Array[Int32] = [
  16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24,
  40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77,
  24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95,
  98, 112, 100, 103, 99,
]

///|
/// The standard's example chrominance table.
let chrominance_table : Array[Int32] = [
  17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99,
  99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99,
]

///|
/// A table scaled by a quality, which is what the number on the dial means.
fn scaled_table(base : Array[Int32], scale : Int32) -> Array[Int32] {
  let out : Array[Int32] = []
  for value in base {
    let scaled = (value * scale + 50) / 100
    out.push(if scaled < 1 { 1 } else if scaled > 255 { 255 } else { scaled })
  }
  out
}

///|
fn write_app0(writer : @wire.Writer) -> Unit {
  writer.u8(0xFF)
  writer.u8(0xE0)
  writer.u16_be(16)
  writer.bytes(b"JFIF\x00")
  writer.u8(1)
  writer.u8(1)
  writer.u8(0)
  writer.u16_be(1)
  writer.u16_be(1)
  writer.u8(0)
  writer.u8(0)
}

///|
fn write_quantisation(
  writer : @wire.Writer,
  luma : Array[Int32],
  chroma : Array[Int32],
) -> Unit {
  for pair in [(0, luma), (1, chroma)] {
    let (index, table) = pair
    writer.u8(0xFF)
    writer.u8(0xDB)
    writer.u16_be(2 + 65)
    writer.u8(index)
    for k in 0..<64 {
      writer.u8(table[zigzag_order[k]])
    }
  }
}

///|
fn write_frame(
  writer : @wire.Writer,
  width : Int32,
  height : Int32,
  grey : Bool,
  hs : Int32,
  vs : Int32,
) -> Unit {
  let components = if grey { 1 } else { 3 }
  writer.u8(0xFF)
  writer.u8(0xC0)
  writer.u16_be(8 + components * 3)
  writer.u8(8)
  writer.u16_be(height)
  writer.u16_be(width)
  writer.u8(components)
  writer.u8(1)
  writer.u8(if grey { 0x11 } else { (hs << 4) | vs })
  writer.u8(0)
  if !grey {
    writer.u8(2)
    writer.u8(0x11)
    writer.u8(1)
    writer.u8(3)
    writer.u8(0x11)
    writer.u8(1)
  }
}

///|
fn write_huffman_tables(writer : @wire.Writer) -> Unit {
  let tables = [
    (0x00, luminance_dc_counts, luminance_dc_symbols),
    (0x10, luminance_ac_counts, luminance_ac_symbols),
    (0x01, chrominance_dc_counts, chrominance_dc_symbols),
    (0x11, chrominance_ac_counts, chrominance_ac_symbols),
  ]
  for entry in tables {
    let (id, counts, symbols) = entry
    writer.u8(0xFF)
    writer.u8(0xC4)
    writer.u16_be(2 + 1 + 16 + symbols.length())
    writer.u8(id)
    for value in counts {
      writer.u8(value)
    }
    for value in symbols {
      writer.u8(value)
    }
  }
}

///|
fn write_scan_header(writer : @wire.Writer, grey : Bool) -> Unit {
  let components = if grey { 1 } else { 3 }
  writer.u8(0xFF)
  writer.u8(0xDA)
  writer.u16_be(6 + components * 2)
  writer.u8(components)
  writer.u8(1)
  writer.u8(0x00)
  if !grey {
    writer.u8(2)
    writer.u8(0x11)
    writer.u8(3)
    writer.u8(0x11)
  }
  writer.u8(0)
  writer.u8(63)
  writer.u8(0)
}

///|
/// The eight by eight samples of a grey image, with the edges replicated.
fn gather_grey(
  source : @raster.Image,
  x0 : Int32,
  y0 : Int32,
  samples : FixedArray[Double],
) -> Unit {
  for y in 0..<8 {
    let sy = clamp_index(y0 + y, source.height)
    for x in 0..<8 {
      let sx = clamp_index(x0 + x, source.width)
      samples[y * 8 + x] = source.pixels[sy * source.stride + sx]
        .to_int()
        .to_double() -
        128.0
    }
  }
}

///|
/// One component's block: the component's samples, averaged over the area each
/// covers when the component is subsampled.
fn gather_plane(
  source : @raster.Image,
  x0 : Int32,
  y0 : Int32,
  channel : Int32,
  size : Int32,
  hx : Int32,
  vy : Int32,
  samples : FixedArray[Double],
) -> Unit {
  for y in 0..<size {
    for x in 0..<size {
      let mut total = 0
      let mut count = 0
      for sy in 0..<vy {
        for sx in 0..<hx {
          let px = clamp_index(x0 * 1 + x * hx + sx, source.width)
          let py = clamp_index(y0 * 1 + y * vy + sy, source.height)
          let at = py * source.stride + px * 3
          total = total + sample_channel(source, at, channel)
          count = count + 1
        }
      }
      samples[y * size + x] = total.to_double() / count.to_double() - 128.0
    }
  }
}

///|
fn sample_channel(source : @raster.Image, at : Int32, channel : Int32) -> Int32 {
  let red = source.pixels[at].to_int()
  let green = source.pixels[at + 1].to_int()
  let blue = source.pixels[at + 2].to_int()
  match channel {
    0 => (77 * red + 150 * green + 29 * blue) >> 8
    1 => ((-43 * red - 85 * green + 128 * blue) >> 8) + 128
    _ => ((128 * red - 107 * green - 21 * blue) >> 8) + 128
  }
}

///|
/// One block: transform, quantise, and write the coefficients.
fn encode_block(
  bits : JpegBits,
  block : FixedArray[Double],
  samples : FixedArray[Double],
  quant : Array[Int32],
  dc : Codes,
  ac : Codes,
  previous : Int32,
) -> Int32 {
  for index in 0..<64 {
    block[index] = samples[index]
  }
  forward_dct(block)
  let quantised : FixedArray[Int32] = FixedArray::make(64, 0)
  for k in 0..<64 {
    let at = zigzag_order[k]
    let scaled = block[at] / quant[at].to_double()
    quantised[k] = if scaled < 0.0 {
      (scaled - 0.5).to_int()
    } else {
      (scaled + 0.5).to_int()
    }
  }
  // A baseline file has codes for magnitudes up to ten bits and a DC difference
  // of eleven; a value beyond that has no code at all, so it is clamped rather
  // than written as a symbol the table does not have.
  for k in 1..<64 {
    if quantised[k] > 1023 {
      quantised[k] = 1023
    } else if quantised[k] < -1023 {
      quantised[k] = -1023
    }
  }
  let mut difference = quantised[0] - previous
  if difference > 2047 {
    difference = 2047
  } else if difference < -2047 {
    difference = -2047
  }
  quantised[0] = previous + difference
  let size = magnitude(difference)
  write_code(bits, dc, size)
  if size > 0 {
    bits.write(if difference < 0 { difference - 1 } else { difference }, size)
  }
  let mut run = 0
  for k in 1..<64 {
    let value = quantised[k]
    if value == 0 {
      run = run + 1
      continue
    }
    while run > 15 {
      write_code(bits, ac, 0xF0)
      run = run - 16
    }
    let length = magnitude(value)
    write_code(bits, ac, (run << 4) | length)
    bits.write(if value < 0 { value - 1 } else { value }, length)
    run = 0
  }
  if run > 0 {
    write_code(bits, ac, 0x00)
  }
  quantised[0]
}

///|
/// How many bits the magnitude of a value needs.
fn magnitude(value : Int32) -> Int32 {
  let mut magnitude = if value < 0 { -value } else { value }
  let mut size = 0
  while magnitude > 0 {
    magnitude = magnitude >> 1
    size = size + 1
  }
  size
}

///|
/// A Huffman table as codes, so that writing a symbol is a lookup.
priv struct Codes {
  values : FixedArray[Int32]
  lengths : FixedArray[Int32]
}

///|
fn codes_of(counts : Array[Int32], symbols : Array[Int32]) -> Codes {
  let values : FixedArray[Int32] = FixedArray::make(256, 0)
  let lengths : FixedArray[Int32] = FixedArray::make(256, 0)
  let mut code = 0
  let mut index = 0
  for length in 1..<=16 {
    for _ in 0..<counts[length - 1] {
      if index < symbols.length() {
        values[symbols[index]] = code
        lengths[symbols[index]] = length
      }
      index = index + 1
      code = code + 1
    }
    code = code << 1
  }
  { values, lengths, }
}

///|
fn write_code(bits : JpegBits, table : Codes, symbol : Int32) -> Unit {
  let length = table.lengths[symbol]
  if length > 0 {
    bits.write(table.values[symbol], length)
  }
}

///|
/// Bits, written the way JPEG wants them: most significant first, with a zero
/// byte after every 0xFF so that the stream cannot look like a marker.
priv struct JpegBits {
  buffer : @buffer.Buffer
  mut bits : Int32
  mut count : Int32
}

///|
fn JpegBits::new() -> JpegBits {
  { buffer: @buffer.Buffer::Buffer(), bits: 0, count: 0, }
}

///|
fn JpegBits::write(self : JpegBits, value : Int32, size : Int32) -> Unit {
  if size <= 0 {
    return
  }
  let mut index = size - 1
  while index >= 0 {
    self.bits = (self.bits << 1) | ((value >> index) & 1)
    self.count = self.count + 1
    if self.count == 8 {
      self.flush()
    }
    index = index - 1
  }
}

///|
fn JpegBits::flush(self : JpegBits) -> Unit {
  let byte = self.bits & 0xFF
  self.buffer.write_byte(byte.to_byte())
  if byte == 0xFF {
    self.buffer.write_byte(b'\x00')
  }
  self.bits = 0
  self.count = 0
}

///|
fn JpegBits::to_bytes(self : JpegBits) -> Bytes {
  if self.count > 0 {
    self.bits = self.bits << (8 - self.count)
    self.flush()
  }
  self.buffer.to_bytes()
}

///|
/// The forward cosine transform, separable and in floating point.
fn forward_dct(block : FixedArray[Double]) -> Unit {
  let temp : FixedArray[Double] = FixedArray::make(64, 0.0)
  for y in 0..<8 {
    for u in 0..<8 {
      let mut total = 0.0
      for x in 0..<8 {
        total = total + block[y * 8 + x] * cosine(x, u)
      }
      temp[y * 8 + u] = total * scale(u) * 0.5
    }
  }
  for u in 0..<8 {
    for v in 0..<8 {
      let mut total = 0.0
      for y in 0..<8 {
        total = total + temp[y * 8 + u] * cosine(y, v)
      }
      block[v * 8 + u] = total * scale(v) * 0.5
    }
  }
}
