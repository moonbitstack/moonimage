// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing a VP8 key frame.
//
// A key frame is one picture and nothing before it: every macroblock is
// predicted from the ones above and to the left of it in the same frame, so a
// decoder needs no state to start. That is what makes an intra frame writer a
// page of arithmetic rather than a codec — there is no motion to search for and
// nothing to choose between but four predictors.
//
// What the frame is made of: a header of probabilities and quantiser steps, a
// partition of modes, and a partition of coefficients. Both partitions are
// arithmetic-coded at the probabilities the header declares, which is why the
// writer below has a boolean coder of its own.
//
// The encoder reconstructs as it goes, because the next macroblock predicts from
// this one: the residual is transformed, quantised, dequantised and added back
// to the prediction, and it is the added-back picture — not the original — that
// the macroblock to the right predicts from.

// ---------------------------------------------------------------------------
// The boolean coder

///|
/// The arithmetic coder the partitions are written with.
///
/// `low` holds the value so far, `range` the width of the interval, and `count`
/// how many bits of the value are not written yet: negative while the value is
/// still being assembled, which is what lets a carry reach back into bytes
/// already in the output.
priv struct BoolWriter {
  out : Array[Byte]
  mut low : UInt32
  mut range : UInt32
  mut count : Int32
}

///|
fn BoolWriter::new() -> BoolWriter {
  { out: [], low: 0, range: 255, count: -24, }
}

///|
/// How far a range has to be shifted to bring it back above one hundred and
/// twenty-eight.
fn shift_for(range : Int32) -> Int32 {
  let mut value = range
  let mut shift = 0
  while value < 128 {
    value = value << 1
    shift = shift + 1
  }
  shift
}

///|
/// One bit at `probability/256` of being zero, which is the same arithmetic the
/// reader runs backwards.
fn BoolWriter::put(self : BoolWriter, bit : Int32, probability : Int32) -> Unit {
  let mut range = self.range
  let mut low = self.low
  let mut count = self.count
  let split = 1U + (((range - 1U) * probability.reinterpret_as_uint()) >> 8)
  range = split
  if bit != 0 {
    low = low + split
    range = self.range - split
  }
  let mut shift = shift_for(range.reinterpret_as_int())
  range = range << shift
  count = count + shift
  if count >= 0 {
    let offset = shift - count
    if offset > 0 && ((low << (offset - 1)) & 0x80000000U) != 0 {
      // The value ran past the byte that was being assembled: the carry goes
      // back through the bytes already written, turning each 0xFF into a zero
      // until it finds one it can add to.
      let mut at = self.out.length() - 1
      while at >= 0 && self.out[at] == b'\xFF' {
        self.out[at] = b'\x00'
        at = at - 1
      }
      if at >= 0 {
        self.out[at] = (self.out[at].to_int() + 1).to_byte()
      }
    }
    let byte = ((low >> (24 - offset)) & 0xFFU).reinterpret_as_int()
    self.out.push(byte.to_byte())
    low = low << offset
    shift = count
    low = low & 0xFFFFFFU
    count = count - 8
  }
  low = low << shift
  self.low = low
  self.range = range
  self.count = count
}

///|
/// The bits still held in the coder: thirty-two zeroes at even odds, which is
/// what flushes the window.
fn BoolWriter::finish(self : BoolWriter) -> Bytes {
  for _ in 0..<32 {
    self.put(0, 128)
  }
  Bytes::from_array(self.out[:])
}

// ---------------------------------------------------------------------------
// The transforms, forwards

///|
/// The four-point transform one axis at a time, which is the transpose of the
/// inverse the reader runs: the same butterflies with the coefficients in the
/// other order, and a halving at the end because two passes of four points are
/// twice the scale the inverse expects.
fn forward_row(
  x : FixedArray[Int32],
  at : Int32,
  out : FixedArray[Int32],
  to : Int32,
) -> Unit {
  let a = x[at]
  let b = x[at + 1]
  let c = x[at + 2]
  let d = x[at + 3]
  out[to] = a + b + c + d
  out[to + 1] = mul1(a) + mul2(b) - mul2(c) - mul1(d)
  out[to + 2] = a - b - c + d
  out[to + 3] = mul2(a) - mul1(b) + mul1(c) - mul2(d)
}

///|
/// The forward four-by-four transform of a residual, down the columns and then
/// across the rows.
fn forward4x4(
  residual : FixedArray[Int32],
  out : FixedArray[Int32],
  to : Int32,
) -> Unit {
  let column : FixedArray[Int32] = FixedArray::make(4, 0)
  let result : FixedArray[Int32] = FixedArray::make(4, 0)
  let tmp : FixedArray[Int32] = FixedArray::make(16, 0)
  for c in 0..<4 {
    column[0] = residual[c]
    column[1] = residual[4 + c]
    column[2] = residual[8 + c]
    column[3] = residual[12 + c]
    forward_row(column, 0, result, 0)
    for r in 0..<4 {
      tmp[4 * r + c] = result[r]
    }
  }
  for r in 0..<4 {
    forward_row(tmp, 4 * r, result, 0)
    for i in 0..<4 {
      // Two passes of four points are four times the scale of one, and the
      // inverse divides by eight; the halving here is the difference.
      out[to + 4 * r + i] = (result[i] + 1) >> 1
    }
  }
}

///|
/// The forward Walsh-Hadamard of the sixteen averages of a macroblock, which is
/// the inverse of what the reader applies to place them.
fn forward_wht(dc : FixedArray[Int32]) -> Unit {
  let tmp : FixedArray[Int32] = FixedArray::make(16, 0)
  let out : FixedArray[Int32] = FixedArray::make(16, 0)
  for i in 0..<4 {
    let a = dc[i]
    let b = dc[4 + i]
    let c = dc[8 + i]
    let d = dc[12 + i]
    tmp[i] = a + b + c + d
    tmp[4 + i] = a + b - c - d
    tmp[8 + i] = a - b - c + d
    tmp[12 + i] = a - b + c - d
  }
  for i in 0..<4 {
    let a = tmp[4 * i]
    let b = tmp[4 * i + 1]
    let c = tmp[4 * i + 2]
    let d = tmp[4 * i + 3]
    out[4 * i] = (a + b + c + d + 1) >> 1
    out[4 * i + 1] = (a + b - c - d + 1) >> 1
    out[4 * i + 2] = (a - b - c + d + 1) >> 1
    out[4 * i + 3] = (a - b + c - d + 1) >> 1
  }
  for i in 0..<16 {
    dc[i] = out[i]
  }
}

// ---------------------------------------------------------------------------
// Quantisation

///|
/// A coefficient as the level the entropy coder carries: the nearest step, with
/// the sign kept apart.
fn quantise(value : Int32, step : Int32) -> Int32 {
  let magnitude = value.abs()
  let level = (magnitude + (step >> 1)) / step
  if value < 0 {
    -level
  } else {
    level
  }
}

// ---------------------------------------------------------------------------
// The frame

///|
/// The picture as a lossy WebP.
///
/// `quality` runs from nought, which is a mosaic of the picture's largest
/// shapes, to a hundred, which keeps every coefficient; seventy-five is what the
/// format's own tools call the default. A picture with alpha is written as a
/// lossy colour plane and a lossless alpha plane, which is how the container
/// carries the two: the alpha of a lossy WebP is never lossy.
pub fn encode_lossy(image : @raster.Image, quality? : Int32) -> Bytes {
  let quality = clamp(quality.unwrap_or(75), 0, 100)
  // The quantiser index runs the other way: nought is every coefficient.
  let qi = clamp((100 - quality) * 127 / 100, 0, 127)
  let header = BoolWriter::new()
  let tokens = BoolWriter::new()
  let frame = Frame::new(image.width, image.height)
  frame.y1dc[0] = dc_quant[qi]
  frame.y1ac[0] = ac_quant[qi]
  frame.y2dc[0] = dc_quant[qi] * 2
  let y2ac = (ac_quant[qi] * 101581) >> 16
  frame.y2ac[0] = if y2ac < 8 { 8 } else { y2ac }
  frame.uvdc[0] = dc_quant[clamp(qi, 0, 117)]
  frame.uvac[0] = ac_quant[qi]
  for i in 1..<4 {
    frame.y1dc[i] = frame.y1dc[0]
    frame.y1ac[i] = frame.y1ac[0]
    frame.y2dc[i] = frame.y2dc[0]
    frame.y2ac[i] = frame.y2ac[0]
    frame.uvdc[i] = frame.uvdc[0]
    frame.uvac[i] = frame.uvac[0]
  }
  for i in 0..<(4 * 8 * 3 * 11) {
    frame.probs[i] = default_coeff_probs[i]
  }
  write_header(header, qi)
  encode_macroblocks(image, frame, header, tokens)
  let first = header.finish()
  let second = tokens.finish()
  let file = @wire.Writer::new()
  // The frame tag: a key frame, profile nought, for display, and the length of
  // the partition that holds the header and the modes.
  let tag = (first.length() << 5) | 0x10
  file.u8(tag & 0xFF)
  file.u8((tag >> 8) & 0xFF)
  file.u8((tag >> 16) & 0xFF)
  file.bytes(b"\x9D\x01\x2A")
  file.u16_le(image.width)
  file.u16_le(image.height)
  file.bytes(first)
  file.bytes(second)
  let payload = file.to_bytes()
  let chunks : Array[(String, Bytes)] = []
  if image.format.has_alpha() {
    let extended = @wire.Writer::new()
    extended.u8(0x10)
    extended.zeros(3)
    extended.u24_le(image.width - 1)
    extended.u24_le(image.height - 1)
    chunks.push(("VP8X", extended.to_bytes()))
    // The alpha plane as it came: one byte a pixel, which is the one shape of
    // the chunk every reader takes.
    let alpha = @wire.Writer::new()
    alpha.u8(0)
    let rgba = image.convert(@raster.PixelFormat::Rgba8)
    for i in 0..<(image.width * image.height) {
      alpha.u8(rgba.pixels[i * 4 + 3].to_int())
    }
    chunks.push(("ALPH", alpha.to_bytes()))
  }
  chunks.push(("VP8 ", payload))
  write_riff(chunks)
}

///|
/// The frame header: no segmentation, no loop filter, one token partition, the
/// quantiser index, and the default coefficient probabilities.
fn write_header(header : BoolWriter, qi : Int32) -> Unit {
  header.put(0, 128) // the colour space, which is BT.601
  header.put(0, 128) // clamping, which no decoder has to honour
  header.put(0, 128) // segmentation off
  header.put(0, 128) // the normal loop filter
  write_literal(header, 0, 6)
  write_literal(header, 0, 3)
  header.put(0, 128) // no per-reference filter adjustment
  write_literal(header, 0, 2) // one token partition
  write_literal(header, qi, 7)
  for _ in 0..<5 {
    header.put(0, 128) // no quantiser deltas
  }
  header.put(1, 128) // refresh the probabilities, which a key frame always does
  for i in 0..<(4 * 8 * 3 * 11) {
    header.put(0, coeff_update[i])
  }
  header.put(0, 128) // no skip flag, so every macroblock carries its residue
}

///|
fn write_literal(writer : BoolWriter, value : Int32, bits : Int32) -> Unit {
  for i in 0..<bits {
    writer.put((value >> (bits - 1 - i)) & 1, 128)
  }
}

///|
/// Every macroblock, in the order the reader takes them: the modes into the
/// header's partition and the coefficients into the token partition.
fn encode_macroblocks(
  image : @raster.Image,
  frame : Frame,
  header : BoolWriter,
  tokens : BoolWriter,
) -> Unit {
  let mb_w = frame.mb_w
  let mb_h = frame.mb_h
  let sy = mb_w * 16 + 16
  let sc = mb_w * 8 + 16
  let py = FixedArray::make((mb_h * 16 + 2) * sy, 0)
  let pu = FixedArray::make((mb_h * 8 + 2) * sc, 0)
  let pv = FixedArray::make((mb_h * 8 + 2) * sc, 0)
  fill_border(py, sy, mb_w * 16, mb_h * 16)
  fill_border(pu, sc, mb_w * 8, mb_h * 8)
  fill_border(pv, sc, mb_w * 8, mb_h * 8)
  let planes : Planes = { y: py, u: pu, v: pv, sy, sc, }
  let (source_y, source_u, source_v) = source_planes(image, mb_w, mb_h)
  let modes = FixedArray::make(20, 0)
  let coeffs = FixedArray::make(384, 0)
  let nz_top = FixedArray::make(mb_w, 0)
  let nz_dc_top = FixedArray::make(mb_w, 0)
  let nz_left = FixedArray::make(2, 0)
  for mb_y in 0..<mb_h {
    for i in 0..<2 {
      nz_left[i] = 0
    }
    for mb_x in 0..<mb_w {
      let px = mb_x * 16
      let py_at = mb_y * 16
      let base = at(sy, px, py_at)
      let luma_mode = choose_16(
        source_y,
        mb_w * 16,
        planes.y,
        base,
        sy,
        mb_x,
        mb_y,
      )
      predict16(corner_mode(mb_x, mb_y, luma_mode), planes.y, base, sy)
      let chroma_mode = choose_8(
        source_u,
        mb_w * 8,
        planes.u,
        at(sc, mb_x * 8, mb_y * 8),
        sc,
        mb_x,
        mb_y,
      )
      write_modes(header, luma_mode, chroma_mode)
      modes[16] = luma_mode
      modes[17] = chroma_mode
      encode_residual(
        frame, planes, source_y, source_u, source_v, coeffs, modes, tokens, nz_top,
        nz_dc_top, nz_left, mb_x, mb_y,
      )
    }
  }
}

///|
/// The modes of one macroblock, which is the whole-block form: no subblock modes
/// at all, because a sixteen-by-sixteen prediction costs four bits and the
/// subblock forms cost more to send than they win back on a photograph.
fn write_modes(header : BoolWriter, luma : Int32, chroma : Int32) -> Unit {
  header.put(1, 145) // a sixteen-by-sixteen block
  if luma == 1 {
    header.put(1, 156)
    header.put(1, 128)
  } else if luma == 3 {
    header.put(1, 156)
    header.put(0, 128)
  } else if luma == 2 {
    header.put(0, 156)
    header.put(1, 163)
  } else {
    header.put(0, 156)
    header.put(0, 163)
  }
  if chroma == 0 {
    header.put(0, 142)
  } else if chroma == 2 {
    header.put(1, 142)
    header.put(0, 114)
  } else if chroma == 1 {
    header.put(1, 142)
    header.put(1, 114)
    header.put(1, 183)
  } else {
    header.put(1, 142)
    header.put(1, 114)
    header.put(0, 183)
  }
}

///|
/// The picture as three planes of samples, padded out to whole macroblocks by
/// repeating the last row and column: a partial macroblock predicts from what is
/// there, and what is there is the edge.
fn source_planes(
  image : @raster.Image,
  mb_w : Int32,
  mb_h : Int32,
) -> (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]) {
  let rgba = image.convert(@raster.PixelFormat::Rgba8)
  let width = image.width
  let height = image.height
  let wide = mb_w * 16
  let tall = mb_h * 16
  let y : FixedArray[Int32] = FixedArray::make(wide * tall, 0)
  let u : FixedArray[Int32] = FixedArray::make(mb_w * 8 * (mb_h * 8), 0)
  let v : FixedArray[Int32] = FixedArray::make(mb_w * 8 * (mb_h * 8), 0)
  for row in 0..<tall {
    let sy = if row >= height { height - 1 } else { row }
    for column in 0..<wide {
      let sx = if column >= width { width - 1 } else { column }
      let at = (sy * width + sx) * 4
      let r = rgba.pixels[at].to_int()
      let g = rgba.pixels[at + 1].to_int()
      let b = rgba.pixels[at + 2].to_int()
      y[row * wide + column] = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16
    }
  }
  let cw = mb_w * 8
  let ch = mb_h * 8
  for row in 0..<ch {
    for column in 0..<cw {
      // The chroma of a pixel is the average of the two by two it stands for.
      let mut r = 0
      let mut g = 0
      let mut b = 0
      for dy in 0..<2 {
        for dx in 0..<2 {
          let mut sy = row * 2 + dy
          let mut sx = column * 2 + dx
          if sy >= height {
            sy = height - 1
          }
          if sx >= width {
            sx = width - 1
          }
          let at = (sy * width + sx) * 4
          r = r + rgba.pixels[at].to_int()
          g = g + rgba.pixels[at + 1].to_int()
          b = b + rgba.pixels[at + 2].to_int()
        }
      }
      r = (r + 2) >> 2
      g = (g + 2) >> 2
      b = (b + 2) >> 2
      u[row * cw + column] = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128
      v[row * cw + column] = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128
    }
  }
  (y, u, v)
}

///|
/// Which of the four sixteen-by-sixteen predictions is closest to the picture,
/// by the sum of the differences rather than their squares: what the eye finds
/// wrong at a block edge is the step, and a step is a difference.
fn choose_16(
  source : FixedArray[Int32],
  wide : Int32,
  plane : FixedArray[Int32],
  base : Int32,
  stride : Int32,
  mb_x : Int32,
  mb_y : Int32,
) -> Int32 {
  let mut best = 0
  let mut closest = -1
  for mode in 0..<4 {
    predict16(corner_mode(mb_x, mb_y, mode), plane, base, stride)
    let mut total = 0
    for row in 0..<16 {
      for column in 0..<16 {
        total = total +
          (source[(mb_y * 16 + row) * wide + mb_x * 16 + column] -
          plane[base + row * stride + column]).abs()
      }
    }
    if closest < 0 || total < closest {
      closest = total
      best = mode
    }
  }
  best
}

///|
fn choose_8(
  source : FixedArray[Int32],
  wide : Int32,
  plane : FixedArray[Int32],
  base : Int32,
  stride : Int32,
  mb_x : Int32,
  mb_y : Int32,
) -> Int32 {
  let mut best = 0
  let mut closest = -1
  for mode in 0..<4 {
    predict8(corner_mode(mb_x, mb_y, mode), plane, base, stride)
    let mut total = 0
    for row in 0..<8 {
      for column in 0..<8 {
        total = total +
          (source[(mb_y * 8 + row) * wide + mb_x * 8 + column] -
          plane[base + row * stride + column]).abs()
      }
    }
    if closest < 0 || total < closest {
      closest = total
      best = mode
    }
  }
  best
}

// ---------------------------------------------------------------------------
// Coefficients

///|
/// A magnitude above one, in the four lengths the format gives them: two to
/// four, five to six, seven to ten, and then a category whose width says how
/// many more bits there are.
fn write_large(
  tokens : BoolWriter,
  probs : FixedArray[Int32],
  base : Int32,
  value : Int32,
) -> Unit {
  if value <= 4 {
    tokens.put(0, probs[base + 3])
    if value == 2 {
      tokens.put(0, probs[base + 4])
    } else {
      tokens.put(1, probs[base + 4])
      tokens.put(value - 3, probs[base + 5])
    }
  } else if value <= 6 {
    tokens.put(1, probs[base + 3])
    tokens.put(0, probs[base + 6])
    tokens.put(0, probs[base + 7])
    tokens.put(value - 5, 159)
  } else if value <= 10 {
    tokens.put(1, probs[base + 3])
    tokens.put(0, probs[base + 6])
    tokens.put(1, probs[base + 7])
    let offset = value - 7
    tokens.put(offset >> 1, 165)
    tokens.put(offset & 1, 145)
  } else {
    tokens.put(1, probs[base + 3])
    tokens.put(1, probs[base + 6])
    let category = if value <= 18 {
      0
    } else if value <= 34 {
      1
    } else if value <= 66 {
      2
    } else {
      3
    }
    let high = category >> 1
    tokens.put(high, probs[base + 8])
    tokens.put(category & 1, probs[base + 9 + high])
    let table = if category == 0 {
      cat3
    } else if category == 1 {
      cat4
    } else if category == 2 {
      cat5
    } else {
      cat6
    }
    let mut magnitude = value - 3 - (8 << category)
    let bits = table.length()
    for i in 0..<bits {
      let bit = (magnitude >> (bits - 1 - i)) & 1
      tokens.put(bit, table[i])
    }
    magnitude = 0
    let _ = magnitude
  }
}

///|
/// One block of levels in the scan order, from `first` on, and the position the
/// reader will stop at.
fn write_coefficients(
  tokens : BoolWriter,
  frame : Frame,
  kind : Int32,
  context : Int32,
  levels : FixedArray[Int32],
  offset : Int32,
  first : Int32,
) -> Int32 {
  let mut last = -1
  for n in first..<16 {
    if levels[offset + zigzag[n]] != 0 {
      last = n
    }
  }
  let mut n = first
  let mut base = probability_base(kind, bands[n], context)
  while n < 16 {
    if n > last {
      tokens.put(0, frame.probs[base])
      return n
    }
    tokens.put(1, frame.probs[base])
    // The run of zeroes before the next coefficient: a nought for each, and a
    // one on the coefficient itself, which is why a non-zero one still costs a
    // bit here.
    while n <= last && levels[offset + zigzag[n]] == 0 {
      tokens.put(0, frame.probs[base + 1])
      n = n + 1
      if n == 16 {
        return 16
      }
      base = probability_base(kind, bands[n], 0)
    }
    tokens.put(1, frame.probs[base + 1])
    let value = levels[offset + zigzag[n]]
    let magnitude = value.abs()
    let next = probability_base(kind, bands[n + 1], 0)
    if magnitude == 1 {
      tokens.put(0, frame.probs[base + 2])
      base = next + 11
    } else {
      tokens.put(1, frame.probs[base + 2])
      write_large(tokens, frame.probs, base, magnitude)
      base = next + 22
    }
    tokens.put(if value < 0 { 1 } else { 0 }, 128)
    n = n + 1
  }
  n
}

///|
/// One macroblock's residue: transformed, quantised, and then written both to
/// the token partition and back into the picture the next macroblock predicts
/// from.
fn encode_residual(
  frame : Frame,
  planes : Planes,
  source_y : FixedArray[Int32],
  source_u : FixedArray[Int32],
  source_v : FixedArray[Int32],
  coeffs : FixedArray[Int32],
  modes : FixedArray[Int32],
  tokens : BoolWriter,
  nz_top : FixedArray[Int32],
  nz_dc_top : FixedArray[Int32],
  nz_left : FixedArray[Int32],
  mb_x : Int32,
  mb_y : Int32,
) -> Unit {
  let sy = planes.sy
  let sc = planes.sc
  let px = mb_x * 16
  let py = mb_y * 16
  let wide = frame.mb_w * 16
  let narrow = frame.mb_w * 8
  for i in 0..<384 {
    coeffs[i] = 0
  }
  let residual : FixedArray[Int32] = FixedArray::make(16, 0)
  let transformed : FixedArray[Int32] = FixedArray::make(256, 0)
  for n in 0..<16 {
    let bx = px + (n & 3) * 4
    let by = py + (n >> 2) * 4
    let here = at(sy, bx, by)
    for row in 0..<4 {
      for column in 0..<4 {
        residual[row * 4 + column] = source_y[(by + row) * wide + bx + column] -
          planes.y[here + row * sy + column]
      }
    }
    forward4x4(residual, transformed, 16 * n)
  }
  // The sixteen averages, which travel as a block of their own at a coarser
  // step: a picture whose light changes slowly has almost nothing in them.
  let dc : FixedArray[Int32] = FixedArray::make(16, 0)
  for n in 0..<16 {
    dc[n] = transformed[16 * n]
  }
  forward_wht(dc)
  let dc_levels : FixedArray[Int32] = FixedArray::make(16, 0)
  let dc_values : FixedArray[Int32] = FixedArray::make(16, 0)
  for i in 0..<16 {
    let step = if i == 0 { frame.y2dc[0] } else { frame.y2ac[0] }
    dc_levels[i] = quantise(dc[i], step)
    dc_values[i] = dc_levels[i] * step
  }
  let context = nz_dc_top[mb_x] + nz_left[1]
  let nz_dc = write_coefficients(tokens, frame, 1, context, dc_levels, 0, 0)
  let non_zero_dc = if nz_dc > 0 { 1 } else { 0 }
  nz_dc_top[mb_x] = non_zero_dc
  nz_left[1] = non_zero_dc
  if nz_dc > 1 {
    transform_wht(dc_values, coeffs)
  } else {
    let flat = (dc_values[0] + 3) >> 3
    for i in 0..<16 {
      coeffs[16 * i] = flat
    }
  }
  // The sixteen luma blocks, whose DC came from the block above.
  let old = nz_top[mb_x]
  let mut tnz = old & 0x0F
  let mut lnz = nz_left[0] & 0x0F
  let mut non_zero_y = 0
  let levels : FixedArray[Int32] = FixedArray::make(16, 0)
  for y in 0..<4 {
    let mut l = lnz & 1
    let mut bits = 0
    for x in 0..<4 {
      let block = 4 * y + x
      for k in 0..<16 {
        levels[k] = 0
      }
      for k in 1..<16 {
        let level = quantise(transformed[16 * block + k], frame.y1ac[0])
        levels[k] = level
        coeffs[16 * block + k] = level * frame.y1ac[0]
      }
      let nz = write_coefficients(tokens, frame, 0, l + (tnz & 1), levels, 0, 1)
      l = if nz > 1 { 1 } else { 0 }
      tnz = (tnz >> 1) | (l << 7)
      bits = (bits << 2) |
        (if nz > 3 {
          3
        } else if nz > 1 {
          2
        } else if coeffs[16 * block] != 0 {
          1
        } else {
          0
        })
    }
    tnz = tnz >> 4
    lnz = (lnz >> 1) | (l << 7)
    non_zero_y = (non_zero_y << 8) | bits
  }
  let mut top_out = tnz
  let mut left_out = lnz >> 4
  // The two chroma planes, four blocks each, coded from their own averages.
  let mut non_zero_uv = 0
  for plane_index in 0..<2 {
    let plane = if plane_index == 0 { planes.u } else { planes.v }
    let source = if plane_index == 0 { source_u } else { source_v }
    let base = at(sc, mb_x * 8, mb_y * 8)
    predict8(corner_mode(mb_x, mb_y, modes[17]), plane, base, sc)
    let mut ctnz = (old >> (4 + 2 * plane_index)) & 3
    let mut clnz = (nz_left[0] >> (4 + 2 * plane_index)) & 3
    let mut bits = 0
    for y in 0..<2 {
      let mut l = clnz & 1
      for x in 0..<2 {
        let block = 2 * y + x
        let offset = 256 + 64 * plane_index + 16 * block
        let here = at(sc, mb_x * 8 + x * 4, mb_y * 8 + y * 4)
        for row in 0..<4 {
          for column in 0..<4 {
            residual[row * 4 + column] = source[(mb_y * 8 + y * 4 + row) *
              narrow +
              mb_x * 8 +
              x * 4 +
              column] -
              plane[here + row * sc + column]
          }
        }
        forward4x4(residual, transformed, 0)
        for k in 0..<16 {
          levels[k] = 0
        }
        for k in 0..<16 {
          let step = if k == 0 { frame.uvdc[0] } else { frame.uvac[0] }
          let level = quantise(transformed[k], step)
          levels[k] = level
          coeffs[offset + k] = level * step
        }
        let nz = write_coefficients(
          tokens,
          frame,
          2,
          l + (ctnz & 1),
          levels,
          0,
          0,
        )
        l = if nz > 0 { 1 } else { 0 }
        ctnz = (ctnz >> 1) | (l << 3)
        bits = (bits << 2) |
          (if nz > 3 {
            3
          } else if nz > 1 {
            2
          } else if coeffs[offset] != 0 {
            1
          } else {
            0
          })
      }
      ctnz = ctnz >> 2
      clnz = (clnz >> 1) | (l << 5)
    }
    non_zero_uv = non_zero_uv | (bits << (8 * plane_index))
    // The four bits of this plane's context live above the luma's four in the
    // same two words, which is how the reader carries them from one macroblock
    // to the next.
    top_out = top_out | (ctnz << 4 << (2 * plane_index))
    left_out = left_out | ((clnz & 0xF0) << (2 * plane_index))
  }
  nz_top[mb_x] = top_out
  nz_left[0] = left_out
  reconstruct(frame, planes, coeffs, modes, non_zero_y, non_zero_uv, mb_x, mb_y)
}
