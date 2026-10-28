// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// VP8, the lossy codec inside a WebP.
//
// https://datatracker.ietf.org/doc/html/rfc6386
//
// VP8 is the intra frame of a video codec, so the picture is built out of
// prediction and residue rather than transmitted whole:
//
//   * a boolean arithmetic coder that narrows an interval rather than packing
//     bits, one decision at a time, each at its own probability;
//   * ten predictors for four-by-four blocks and four for sixteen-by-sixteen
//     ones, all of which copy or average the row above and the column to the
//     left — which is why the picture is rebuilt from the top left and cannot
//     be decoded in parallel by block;
//   * a residual coded as quantised transform coefficients, in a run-length
//     code that says "no more", "zero", "one" or "large", with five probability
//     contexts per frequency band;
//   * a loop filter along every macroblock and transform edge, which is what
//     keeps the blockiness out of the visible picture; it runs after the whole
//     frame is reconstructed, because prediction uses unfiltered samples.
//
// Samples are held on planes of whole macroblocks — sixteen by sixteen, with
// one row and one column of border — because prediction reads one sample above
// and one to the left, and the last macroblock is rarely the last row of the
// picture. Colour is 4:2:0: luma at full size, two chroma planes at half, and
// the conversion back to RGB interpolates chroma between the two rows it sits
// between, which is what the reference decoder does and what a browser shows.

// ---------------------------------------------------------------------------
// The arithmetic coder

///|
/// The boolean decoder: a range that narrows with every bit, and a window of
/// input bits held in `value`.
///
/// Every decision in VP8 goes through `bit`, so this is where a stream either
/// stays in step or does not. The invariant that keeps it exact is
/// `value < range << 8`: a zero keeps the left part of the interval and a one
/// takes the right, and the range is renormalised back above 128 each time.
priv struct Coder {
  data : BytesView
  end : Int
  mut at : Int
  mut range : Int
  mut value : Int
  mut count : Int
}

///|
/// A decoder over `data[at..<end]`, primed with the first two bytes.
fn Coder::new(data : BytesView, at : Int, end : Int) -> Coder {
  let mut value = 0
  let mut cursor = at
  if cursor < end {
    value = data[cursor].to_int()
    cursor = cursor + 1
  }
  value = value << 8
  if cursor < end {
    value = value | data[cursor].to_int()
    cursor = cursor + 1
  }
  { data, end, at: cursor, range: 255, value, count: 0 }
}

///|
/// One bit, coded at a `prob/256` probability of being zero.
///
/// Past the end of the partition the input reads as zero and decoding carries
/// on. That is not a concession: the coder holds a window of bits rather than
/// consuming them, so a frame read to its last macroblock always asks for a
/// byte or two that the encoder had no reason to write.
fn Coder::bit(self : Coder, prob : Int) -> Int {
  let split = 1 + (((self.range - 1) * prob) >> 8)
  let big = split << 8
  let mut answer = 0
  if self.value >= big {
    answer = 1
    self.range = self.range - split
    self.value = self.value - big
  } else {
    self.range = split
  }
  while self.range < 128 {
    self.value = self.value << 1
    self.range = self.range << 1
    let count = self.count + 1
    if count == 8 {
      self.count = 0
      if self.at < self.end {
        self.value = self.value | self.data[self.at].to_int()
        self.at = self.at + 1
      }
    } else {
      self.count = count
    }
  }
  answer
}

///|
/// One bit at even odds.
fn Coder::flag(self : Coder) -> Int {
  self.bit(128)
}

///|
/// An unsigned literal of `bits` bits, most significant first.
fn Coder::literal(self : Coder, bits : Int) -> Int {
  let mut value = 0
  for _ in 0..<bits {
    value = (value << 1) | self.flag()
  }
  value
}

///|
/// A literal that a trailing flag can turn negative: `bits` of magnitude, then
/// the sign.
fn Coder::signed_literal(self : Coder, bits : Int) -> Int {
  let magnitude = self.literal(bits)
  if self.flag() == 1 {
    -magnitude
  } else {
    magnitude
  }
}

// ---------------------------------------------------------------------------
// The frame header

///|
/// Everything the frame header says, which is everything the frame needs: how
/// big it is, how hard it was quantised, how strongly its edges are filtered,
/// and the probabilities its coefficients are coded at.
priv struct Frame {
  mb_w : Int
  mb_h : Int
  // Segmentation: four quadrants with their own quantiser and filter strength.
  mut use_segment : Bool
  mut update_map : Bool
  mut absolute_delta : Bool
  segment_quant : FixedArray[Int]
  segment_filter : FixedArray[Int]
  segment_probs : FixedArray[Int]
  // The loop filter.
  mut filter_simple : Bool
  mut filter_level : Int
  mut sharpness : Int
  mut use_lf_delta : Bool
  ref_lf_delta : FixedArray[Int]
  mode_lf_delta : FixedArray[Int]
  mut filter_type : Int
  // Quantiser steps per segment: luma DC and AC, the second-order luma block
  // that holds sixteen DCs, and chroma.
  y1dc : FixedArray[Int]
  y1ac : FixedArray[Int]
  y2dc : FixedArray[Int]
  y2ac : FixedArray[Int]
  uvdc : FixedArray[Int]
  uvac : FixedArray[Int]
  // [block type][band][context][token], flattened.
  probs : FixedArray[Int]
  mut use_skip : Bool
  mut skip_prob : Int
}

///|
fn Frame::new(width : Int, height : Int) -> Frame {
  {
    mb_w: (width + 15) >> 4,
    mb_h: (height + 15) >> 4,
    use_segment: false,
    update_map: false,
    absolute_delta: true,
    segment_quant: FixedArray::make(4, 0),
    segment_filter: FixedArray::make(4, 0),
    segment_probs: FixedArray::make(3, 255),
    filter_simple: false,
    filter_level: 0,
    sharpness: 0,
    use_lf_delta: false,
    ref_lf_delta: FixedArray::make(4, 0),
    mode_lf_delta: FixedArray::make(4, 0),
    filter_type: 0,
    y1dc: FixedArray::make(4, 0),
    y1ac: FixedArray::make(4, 0),
    y2dc: FixedArray::make(4, 0),
    y2ac: FixedArray::make(4, 0),
    uvdc: FixedArray::make(4, 0),
    uvac: FixedArray::make(4, 0),
    probs: FixedArray::make(4 * 8 * 3 * 11, 128),
    use_skip: false,
    skip_prob: 0,
  }
}

///|
fn clamp(value : Int, low : Int, high : Int) -> Int {
  if value < low {
    low
  } else if value > high {
    high
  } else {
    value
  }
}

///|
/// The segment header: whether quadrants carry their own quantiser and filter
/// strength, and the probabilities the map itself is coded at.
fn read_segment_header(coder : Coder, frame : Frame) -> Unit {
  frame.use_segment = coder.flag() == 1
  if frame.use_segment {
    frame.update_map = coder.flag() == 1
    if coder.flag() == 1 {
      frame.absolute_delta = coder.flag() == 1
      for s in 0..<4 {
        frame.segment_quant[s] = if coder.flag() == 1 {
          coder.signed_literal(7)
        } else {
          0
        }
      }
      for s in 0..<4 {
        frame.segment_filter[s] = if coder.flag() == 1 {
          coder.signed_literal(6)
        } else {
          0
        }
      }
    }
    if frame.update_map {
      for s in 0..<3 {
        frame.segment_probs[s] = if coder.flag() == 1 {
          coder.literal(8)
        } else {
          255
        }
      }
    }
  }
}

///|
/// The loop filter's header: how strong, how sharp, and whether the strength is
/// adjusted per reference frame and per block size.
fn read_filter_header(coder : Coder, frame : Frame) -> Unit {
  frame.filter_simple = coder.flag() == 1
  frame.filter_level = coder.literal(6)
  frame.sharpness = coder.literal(3)
  frame.use_lf_delta = coder.flag() == 1
  if frame.use_lf_delta {
    if coder.flag() == 1 {
      for i in 0..<4 {
        if coder.flag() == 1 {
          frame.ref_lf_delta[i] = coder.signed_literal(6)
        }
      }
      for i in 0..<4 {
        if coder.flag() == 1 {
          frame.mode_lf_delta[i] = coder.signed_literal(6)
        }
      }
    }
  }
  frame.filter_type = if frame.filter_level == 0 {
    0
  } else if frame.filter_simple {
    1
  } else {
    2
  }
}

///|
/// The six quantiser indices, and the steps they imply for all four segments.
///
/// The chroma DC step is indexed up to 117 rather than 127: the tail of that
/// table is for luminance, and a chroma block is a quarter of the area. The
/// second-order AC step is scaled by 155/100, computed as a multiply and a shift
/// so that it matches the reference to the bit.
fn read_quant(coder : Coder, frame : Frame) -> Unit {
  let base = coder.literal(7)
  let dy1dc = if coder.flag() == 1 { coder.signed_literal(4) } else { 0 }
  let dy2dc = if coder.flag() == 1 { coder.signed_literal(4) } else { 0 }
  let dy2ac = if coder.flag() == 1 { coder.signed_literal(4) } else { 0 }
  let duvdc = if coder.flag() == 1 { coder.signed_literal(4) } else { 0 }
  let duvac = if coder.flag() == 1 { coder.signed_literal(4) } else { 0 }
  for i in 0..<4 {
    let q = if !frame.use_segment {
      base
    } else if frame.absolute_delta {
      frame.segment_quant[i]
    } else {
      frame.segment_quant[i] + base
    }
    frame.y1dc[i] = dc_quant[clamp(q + dy1dc, 0, 127)]
    frame.y1ac[i] = ac_quant[clamp(q, 0, 127)]
    frame.y2dc[i] = dc_quant[clamp(q + dy2dc, 0, 127)] * 2
    let y2ac = (ac_quant[clamp(q + dy2ac, 0, 127)] * 101581) >> 16
    frame.y2ac[i] = if y2ac < 8 { 8 } else { y2ac }
    frame.uvdc[i] = dc_quant[clamp(q + duvdc, 0, 117)]
    frame.uvac[i] = ac_quant[clamp(q + duvac, 0, 127)]
  }
  if !frame.use_segment {
    for i in 1..<4 {
      frame.y1dc[i] = frame.y1dc[0]
      frame.y1ac[i] = frame.y1ac[0]
      frame.y2dc[i] = frame.y2dc[0]
      frame.y2ac[i] = frame.y2ac[0]
      frame.uvdc[i] = frame.uvdc[0]
      frame.uvac[i] = frame.uvac[0]
    }
  }
}

///|
/// The coefficient probabilities: whether the frame updates each of the
/// thousand defaults, then the skip flag's own probability.
fn read_coefficient_probs(coder : Coder, frame : Frame) -> Unit {
  for i in 0..<(4 * 8 * 3 * 11) {
    frame.probs[i] = if coder.bit(coeff_update[i]) == 1 {
      coder.literal(8)
    } else {
      default_coeff_probs[i]
    }
  }
  frame.use_skip = coder.flag() == 1
  if frame.use_skip {
    frame.skip_prob = coder.literal(8)
  }
}

// ---------------------------------------------------------------------------
// Intra prediction modes

///|
/// The band each coefficient belongs to. The first four get their own — DC, the
/// first AC, and the two either side of it — and everything past the sixth
/// shares the last, because their statistics differ little.
let bands : Array[Int] = [0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0]

///|
/// The subblock mode tree as libwebp numbers it: a negative entry is a leaf
/// holding minus the mode, a positive one the node to descend to.
let mode_tree : Array[Int] = [
  0, 1, -1, 2, -2, 3, 4, 6, -3, 5, -4, -5, -6, 7, -7, 8, -8, -9,
]

///|
/// Walk the mode tree, one bit per interior node.
fn read_submode(coder : Coder, probs : Array[Int], base : Int) -> Int {
  let mut node = mode_tree[coder.bit(probs[base])]
  while node > 0 {
    node = mode_tree[2 * node + coder.bit(probs[base + node])]
  }
  -node
}

///|
/// A macroblock's modes: its segment, whether it is coded as sixteen four-by-four
/// blocks, the sixteen modes for those or the one for the whole, and the chroma
/// mode.
///
/// The two contexts are arrays because a mode's neighbours are modes: `top`
/// holds four per macroblock column and is rewritten as each row of subblocks is
/// read, so the second row is predicted from the first and not from the
/// macroblock above; `left` holds four and is rewritten as the row of
/// macroblocks advances. Getting that wrong decodes the first row of subblocks
/// correctly and the rest of them as noise, which is what the comments here are
/// for.
fn read_modes(
  coder : Coder,
  frame : Frame,
  top : FixedArray[Int],
  left : FixedArray[Int],
  mb_x : Int,
  modes : FixedArray[Int],
) -> Unit {
  let mut segment = 0
  if frame.use_segment && frame.update_map {
    segment = if coder.bit(frame.segment_probs[0]) == 0 {
      coder.bit(frame.segment_probs[1])
    } else {
      coder.bit(frame.segment_probs[2]) + 2
    }
  }
  let skip = if frame.use_skip { coder.bit(frame.skip_prob) } else { 0 }
  if coder.bit(145) == 0 {
    for y in 0..<4 {
      let mut mode = left[y]
      for x in 0..<4 {
        mode = read_submode(coder, bmode_probs, (top[4 * mb_x + x] * 10 + mode) * 9)
        top[4 * mb_x + x] = mode
        modes[4 * y + x] = mode
      }
      left[y] = mode
    }
    modes[16] = -1 // not a sixteen-by-sixteen block
  } else {
    let mode = if coder.bit(156) == 1 {
      if coder.bit(128) == 1 {
        1
      } else {
        3
      }
    } else if coder.bit(163) == 1 {
      2
    } else {
      0
    }
    for x in 0..<4 {
      top[4 * mb_x + x] = mode
    }
    for y in 0..<4 {
      left[y] = mode
    }
    modes[16] = mode
  }
  modes[17] = if coder.bit(142) == 0 {
    0
  } else if coder.bit(114) == 0 {
    2
  } else if coder.bit(183) == 1 {
    1
  } else {
    3
  }
  modes[18] = skip
  modes[19] = segment
}

// ---------------------------------------------------------------------------
// Coefficients

///|
/// The scan order: where each step of the run-length code lands in the block.
let zigzag : Array[Int] = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15]

///|
/// The probabilities of the category bits, one table per category.
let cat3 : Array[Int] = [173, 148, 140]
let cat4 : Array[Int] = [176, 155, 140, 135]
let cat5 : Array[Int] = [180, 157, 141, 134, 130]
let cat6 : Array[Int] = [254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129]

///|
/// A coefficient larger than one, whose magnitude is coded in one of four
/// lengths: two to four, five to six, seven to ten, then a run of category bits.
fn read_large(coder : Coder, probs : FixedArray[Int], base : Int) -> Int {
  if coder.bit(probs[base + 3]) == 0 {
    if coder.bit(probs[base + 4]) == 0 {
      2
    } else {
      3 + coder.bit(probs[base + 5])
    }
  } else if coder.bit(probs[base + 6]) == 0 {
    if coder.bit(probs[base + 7]) == 0 {
      5 + coder.bit(159)
    } else {
      7 + 2 * coder.bit(165) + coder.bit(145)
    }
  } else {
    let high = coder.bit(probs[base + 8])
    let low = coder.bit(probs[base + 9 + high])
    let category = 2 * high + low
    let table = if category == 0 {
      cat3
    } else if category == 1 {
      cat4
    } else if category == 2 {
      cat5
    } else {
      cat6
    }
    let mut value = 0
    for probability in table {
      value = value + value + coder.bit(probability)
    }
    value + 3 + (8 << category)
  }
}

///|
/// Where one block's coefficient probabilities start: by block type, band and
/// context, eleven tokens each.
fn probability_base(kind : Int, band : Int, context : Int) -> Int {
  ((kind * 8 + band) * 3 + context) * 11
}

///|
/// Read one four-by-four block's coefficients from scan position `first`, and
/// answer the position after the last non-zero one.
///
/// The stream is a run-length code over the scan: a bit says whether another
/// coefficient follows, another says whether this one is zero, and the rest says
/// how big it is and with what sign. The context for the first bit is 0, 1 or 2
/// — was the previous coefficient zero, one, or larger — and it follows the
/// stream into the next band.
fn read_coefficients(
  coder : Coder,
  frame : Frame,
  kind : Int,
  context : Int,
  dc : Int,
  ac : Int,
  first : Int,
  out : FixedArray[Int],
  base : Int,
) -> Int {
  let mut n = first
  let mut offset = probability_base(kind, bands[n], context)
  while n < 16 {
    if coder.bit(frame.probs[offset]) == 0 {
      return n
    }
    while coder.bit(frame.probs[offset + 1]) == 0 {
      n = n + 1
      if n == 16 {
        return 16
      }
      offset = probability_base(kind, bands[n], 0)
    }
    let next = probability_base(kind, bands[n + 1], 0)
    let mut value = 1
    if coder.bit(frame.probs[offset + 2]) == 1 {
      value = read_large(coder, frame.probs, offset)
      offset = next + 22 // context two: the previous coefficient was large
    } else {
      offset = next + 11 // context one: the previous coefficient was one
    }
    if coder.flag() == 1 {
      value = -value
    }
    out[base + zigzag[n]] = value * (if n > 0 { ac } else { dc })
    n = n + 1
  }
  16
}

// ---------------------------------------------------------------------------
// Transforms

///|
/// The two constants of VP8's transform in 16.16 — half, and √3/2 — with the
/// rounding of the reference folded into the first, which is why it adds its
/// argument back.
fn mul1(value : Int) -> Int {
  value + ((value * 20091) >> 16)
}

///|
fn mul2(value : Int) -> Int {
  (value * 35468) >> 16
}

///|
/// Add a residual to one sample, clamped to a byte.
fn store(
  plane : FixedArray[Int],
  base : Int,
  stride : Int,
  x : Int,
  y : Int,
  delta : Int,
) -> Unit {
  let at = base + y * stride + x
  plane[at] = clamp(plane[at] + delta, 0, 255)
}

///|
/// The inverse four-by-four transform: a butterfly down the columns, then one
/// across the rows, with the rounder of the last pass folded into the DC.
fn transform_one(
  coeffs : FixedArray[Int],
  at : Int,
  plane : FixedArray[Int],
  base : Int,
  stride : Int,
  tmp : FixedArray[Int],
) -> Unit {
  for i in 0..<4 {
    let a = coeffs[at + i] + coeffs[at + 8 + i]
    let b = coeffs[at + i] - coeffs[at + 8 + i]
    let c = mul2(coeffs[at + 4 + i]) - mul1(coeffs[at + 12 + i])
    let d = mul1(coeffs[at + 4 + i]) + mul2(coeffs[at + 12 + i])
    tmp[4 * i] = a + d
    tmp[4 * i + 1] = b + c
    tmp[4 * i + 2] = b - c
    tmp[4 * i + 3] = a - d
  }
  for i in 0..<4 {
    let dc = tmp[i] + 4
    let a = dc + tmp[8 + i]
    let b = dc - tmp[8 + i]
    let c = mul2(tmp[4 + i]) - mul1(tmp[12 + i])
    let d = mul1(tmp[4 + i]) + mul2(tmp[12 + i])
    store(plane, base, stride, 0, i, (a + d) >> 3)
    store(plane, base, stride, 1, i, (b + c) >> 3)
    store(plane, base, stride, 2, i, (b - c) >> 3)
    store(plane, base, stride, 3, i, (a - d) >> 3)
  }
}

///|
/// The transform of a block whose only non-zero coefficients are the DC, the
/// first horizontal and the first vertical: the common case, and worth not
/// running the whole butterfly for.
fn transform_ac3(
  coeffs : FixedArray[Int],
  at : Int,
  plane : FixedArray[Int],
  base : Int,
  stride : Int,
) -> Unit {
  let dc = coeffs[at] + 4
  let c4 = mul2(coeffs[at + 4])
  let d4 = mul1(coeffs[at + 4])
  let c1 = mul2(coeffs[at + 1])
  let d1 = mul1(coeffs[at + 1])
  let r0 = dc + d4
  let r1 = dc + c4
  let r2 = dc - c4
  let r3 = dc - d4
  store(plane, base, stride, 0, 0, (r0 + d1) >> 3)
  store(plane, base, stride, 1, 0, (r0 + c1) >> 3)
  store(plane, base, stride, 2, 0, (r0 - c1) >> 3)
  store(plane, base, stride, 3, 0, (r0 - d1) >> 3)
  store(plane, base, stride, 0, 1, (r1 + d1) >> 3)
  store(plane, base, stride, 1, 1, (r1 + c1) >> 3)
  store(plane, base, stride, 2, 1, (r1 - c1) >> 3)
  store(plane, base, stride, 3, 1, (r1 - d1) >> 3)
  store(plane, base, stride, 0, 2, (r2 + d1) >> 3)
  store(plane, base, stride, 1, 2, (r2 + c1) >> 3)
  store(plane, base, stride, 2, 2, (r2 - c1) >> 3)
  store(plane, base, stride, 3, 2, (r2 - d1) >> 3)
  store(plane, base, stride, 0, 3, (r3 + d1) >> 3)
  store(plane, base, stride, 1, 3, (r3 + c1) >> 3)
  store(plane, base, stride, 2, 3, (r3 - c1) >> 3)
  store(plane, base, stride, 3, 3, (r3 - d1) >> 3)
}

///|
/// A block that is one flat value.
fn transform_dc(
  coeffs : FixedArray[Int],
  at : Int,
  plane : FixedArray[Int],
  base : Int,
  stride : Int,
) -> Unit {
  let dc = (coeffs[at] + 4) >> 3
  for y in 0..<4 {
    for x in 0..<4 {
      store(plane, base, stride, x, y, dc)
    }
  }
}

///|
/// The second-order transform over the sixteen DCs of a sixteen-by-sixteen
/// block: a Walsh-Hadamard, which is what lets those sixteen numbers be coded as
/// a block of their own, at a coarser quantiser, instead of being spread across
/// the sixteen they belong to.
fn transform_wht(dc : FixedArray[Int], coeffs : FixedArray[Int]) -> Unit {
  let tmp : Array[Int] = Array::make(16, 0)
  for i in 0..<4 {
    let a0 = dc[i] + dc[12 + i]
    let a1 = dc[4 + i] + dc[8 + i]
    let a2 = dc[4 + i] - dc[8 + i]
    let a3 = dc[i] - dc[12 + i]
    tmp[i] = a0 + a1
    tmp[8 + i] = a0 - a1
    tmp[4 + i] = a3 + a2
    tmp[12 + i] = a3 - a2
  }
  for i in 0..<4 {
    let zero = tmp[4 * i] + 3
    let a0 = zero + tmp[4 * i + 3]
    let a1 = tmp[4 * i + 1] + tmp[4 * i + 2]
    let a2 = tmp[4 * i + 1] - tmp[4 * i + 2]
    let a3 = zero - tmp[4 * i + 3]
    coeffs[64 * i] = (a0 + a1) >> 3
    coeffs[64 * i + 16] = (a3 + a2) >> 3
    coeffs[64 * i + 32] = (a0 - a1) >> 3
    coeffs[64 * i + 48] = (a3 - a2) >> 3
  }
}

// ---------------------------------------------------------------------------
// Prediction

///|
fn avg3(a : Int, b : Int, c : Int) -> Int {
  (a + 2 * b + c + 2) >> 2
}

///|
fn avg2(a : Int, b : Int) -> Int {
  (a + b + 1) >> 1
}

///|
/// A four-by-four prediction into `out`, row after row, from the eight samples
/// above — `top[0..<4]` over the block and `top[4..<8]` past its right edge —
/// the four to its left, and the corner between them.
///
/// The ten modes are the specification's numbering: DC, true motion, vertical,
/// horizontal, down-right, vertical-right, down-left, vertical-left,
/// horizontal-down, horizontal-up.
fn predict4(
  mode : Int,
  out : FixedArray[Int],
  top : FixedArray[Int],
  left : FixedArray[Int],
  corner : Int,
) -> Unit {
  // The samples are named as the specification names them: `corner` is X, the
  // row above is A B C D and past the edge E F G H, the column to the left is
  // I J K L. A destination is `out[x + 4 * y]`.
  if mode == 0 {
    let dc = (top[0] +
      top[1] +
      top[2] +
      top[3] +
      left[0] +
      left[1] +
      left[2] +
      left[3] +
      4) >>
      3
    for i in 0..<16 {
      out[i] = dc
    }
  } else if mode == 1 {
    for y in 0..<4 {
      for x in 0..<4 {
        out[x + 4 * y] = clamp(left[y] + top[x] - corner, 0, 255)
      }
    }
  } else if mode == 2 {
    let row = [
      avg3(corner, top[0], top[1]),
      avg3(top[0], top[1], top[2]),
      avg3(top[1], top[2], top[3]),
      avg3(top[2], top[3], top[4]),
    ]
    for y in 0..<4 {
      for x in 0..<4 {
        out[x + 4 * y] = row[x]
      }
    }
  } else if mode == 3 {
    let first = avg3(corner, left[0], left[1])
    let second = avg3(left[0], left[1], left[2])
    let third = avg3(left[1], left[2], left[3])
    let fourth = avg3(left[2], left[3], left[3])
    for x in 0..<4 {
      out[x] = first
      out[x + 4] = second
      out[x + 8] = third
      out[x + 12] = fourth
    }
  } else if mode == 4 {
    // Down-right: a diagonal fan around the corner.
    out[12] = avg3(left[1], left[2], left[3])
    let third = avg3(left[0], left[1], left[2])
    out[13] = third
    out[8] = third
    let second = avg3(corner, left[0], left[1])
    out[14] = second
    out[9] = second
    out[4] = second
    let first = avg3(top[0], corner, left[0])
    out[15] = first
    out[10] = first
    out[5] = first
    out[0] = first
    let above = avg3(top[1], top[0], corner)
    out[11] = above
    out[6] = above
    out[1] = above
    let more = avg3(top[2], top[1], top[0])
    out[7] = more
    out[2] = more
    out[3] = avg3(top[3], top[2], top[1])
  } else if mode == 5 {
    // Vertical-right: the top row pushed down and right, the left column
    // pushed up and left.
    out[0] = avg2(corner, top[0])
    out[9] = out[0]
    out[1] = avg2(top[0], top[1])
    out[10] = out[1]
    out[2] = avg2(top[1], top[2])
    out[11] = out[2]
    out[3] = avg2(top[2], top[3])
    out[12] = avg3(left[2], left[1], left[0])
    out[8] = avg3(left[1], left[0], corner)
    out[4] = avg3(left[0], corner, top[0])
    out[13] = out[4]
    out[5] = avg3(corner, top[0], top[1])
    out[14] = out[5]
    out[6] = avg3(top[0], top[1], top[2])
    out[15] = out[6]
    out[7] = avg3(top[1], top[2], top[3])
  } else if mode == 6 {
    // Down-left: everything comes from the row above, sliding right.
    out[0] = avg3(top[0], top[1], top[2])
    out[4] = avg3(top[1], top[2], top[3])
    out[1] = out[4]
    out[8] = avg3(top[2], top[3], top[4])
    out[5] = out[8]
    out[2] = out[8]
    out[12] = avg3(top[3], top[4], top[5])
    out[9] = out[12]
    out[6] = out[12]
    out[3] = out[12]
    out[13] = avg3(top[4], top[5], top[6])
    out[10] = out[13]
    out[7] = out[13]
    out[14] = avg3(top[5], top[6], top[7])
    out[11] = out[14]
    out[15] = avg3(top[6], top[7], top[7])
  } else if mode == 7 {
    // Vertical-left: the same fan as down-left at half the slope.
    out[0] = avg2(top[0], top[1])
    out[8] = avg2(top[1], top[2])
    out[1] = out[8]
    out[9] = avg2(top[2], top[3])
    out[2] = out[9]
    out[10] = avg2(top[3], top[4])
    out[3] = out[10]
    out[4] = avg3(top[0], top[1], top[2])
    out[12] = avg3(top[1], top[2], top[3])
    out[5] = out[12]
    out[13] = avg3(top[2], top[3], top[4])
    out[6] = out[13]
    out[14] = avg3(top[3], top[4], top[5])
    out[7] = out[14]
    out[11] = avg3(top[4], top[5], top[6])
    out[15] = avg3(top[5], top[6], top[7])
  } else if mode == 8 {
    // Horizontal-down: the left column pushed down and right.
    out[0] = avg2(left[0], corner)
    out[6] = out[0]
    out[4] = avg2(left[1], left[0])
    out[10] = out[4]
    out[8] = avg2(left[2], left[1])
    out[14] = out[8]
    out[12] = avg2(left[3], left[2])
    out[3] = avg3(top[0], top[1], top[2])
    out[2] = avg3(corner, top[0], top[1])
    out[1] = avg3(left[0], corner, top[0])
    out[7] = out[1]
    out[5] = avg3(left[1], left[0], corner)
    out[11] = out[5]
    out[9] = avg3(left[2], left[1], left[0])
    out[15] = out[9]
    out[13] = avg3(left[3], left[2], left[1])
  } else {
    // Horizontal-up: the left column slid down, the last sample repeated across
    // the bottom right.
    out[0] = avg2(left[0], left[1])
    out[2] = avg2(left[1], left[2])
    out[4] = out[2]
    out[6] = avg2(left[2], left[3])
    out[8] = out[6]
    out[1] = avg3(left[0], left[1], left[2])
    out[3] = avg3(left[1], left[2], left[3])
    out[5] = out[3]
    out[7] = avg3(left[2], left[3], left[3])
    out[9] = out[7]
    out[10] = left[3]
    out[11] = left[3]
    out[12] = left[3]
    out[13] = left[3]
    out[14] = left[3]
    out[15] = left[3]
  }
}

///|
/// Which of the seven sixteen-by-sixteen or chroma predictors a mode means: the
/// DC one degrades when it has no row above or no column to the left, and which
/// it lacks is a property of the macroblock, not of the block.
fn corner_mode(mb_x : Int, mb_y : Int, mode : Int) -> Int {
  if mode != 0 {
    mode
  } else if mb_x == 0 {
    if mb_y == 0 {
      6
    } else {
      5
    }
  } else if mb_y == 0 {
    4
  } else {
    0
  }
}

///|
/// A sixteen-by-sixteen prediction, written straight into the plane.
fn predict16(
  mode : Int,
  plane : FixedArray[Int],
  base : Int,
  stride : Int,
) -> Unit {
  if mode == 4 {
    // No row above: the DC comes from the column to the left alone.
    let mut dc = 8
    for j in 0..<16 {
      dc = dc + plane[base - 1 + j * stride]
    }
    let value = dc >> 4
    for y in 0..<16 {
      for x in 0..<16 {
        plane[base + y * stride + x] = value
      }
    }
  } else if mode == 5 {
    // No column to the left: the DC comes from the row above alone.
    let mut dc = 8
    for j in 0..<16 {
      dc = dc + plane[base - stride + j]
    }
    let value = dc >> 4
    for y in 0..<16 {
      for x in 0..<16 {
        plane[base + y * stride + x] = value
      }
    }
  } else if mode == 6 {
    for y in 0..<16 {
      for x in 0..<16 {
        plane[base + y * stride + x] = 128
      }
    }
  } else if mode == 0 {
    let mut dc = 16
    for j in 0..<16 {
      dc = dc + plane[base - 1 + j * stride] + plane[base - stride + j]
    }
    let value = dc >> 5
    for y in 0..<16 {
      for x in 0..<16 {
        plane[base + y * stride + x] = value
      }
    }
  } else if mode == 1 {
    for y in 0..<16 {
      let left = plane[base - 1 + y * stride]
      for x in 0..<16 {
        plane[base + y * stride + x] = clamp(
          left + plane[base - stride + x] - plane[base - stride - 1],
          0,
          255,
        )
      }
    }
  } else if mode == 2 {
    for y in 0..<16 {
      for x in 0..<16 {
        plane[base + y * stride + x] = plane[base - stride + x]
      }
    }
  } else {
    for y in 0..<16 {
      let left = plane[base - 1 + y * stride]
      for x in 0..<16 {
        plane[base + y * stride + x] = left
      }
    }
  }
}

///|
/// An eight-by-eight chroma prediction.
fn predict8(
  mode : Int,
  plane : FixedArray[Int],
  base : Int,
  stride : Int,
) -> Unit {
  if mode == 4 {
    // No row above: the DC comes from the column to the left alone.
    let mut dc = 4
    for j in 0..<8 {
      dc = dc + plane[base - 1 + j * stride]
    }
    let value = dc >> 3
    for y in 0..<8 {
      for x in 0..<8 {
        plane[base + y * stride + x] = value
      }
    }
  } else if mode == 5 {
    // No column to the left: the DC comes from the row above alone.
    let mut dc = 4
    for j in 0..<8 {
      dc = dc + plane[base - stride + j]
    }
    let value = dc >> 3
    for y in 0..<8 {
      for x in 0..<8 {
        plane[base + y * stride + x] = value
      }
    }
  } else if mode == 6 {
    for y in 0..<8 {
      for x in 0..<8 {
        plane[base + y * stride + x] = 128
      }
    }
  } else if mode == 0 {
    let mut dc = 8
    for j in 0..<8 {
      dc = dc + plane[base - 1 + j * stride] + plane[base - stride + j]
    }
    let value = dc >> 4
    for y in 0..<8 {
      for x in 0..<8 {
        plane[base + y * stride + x] = value
      }
    }
  } else if mode == 1 {
    for y in 0..<8 {
      let left = plane[base - 1 + y * stride]
      for x in 0..<8 {
        plane[base + y * stride + x] = clamp(
          left + plane[base - stride + x] - plane[base - stride - 1],
          0,
          255,
        )
      }
    }
  } else if mode == 2 {
    for y in 0..<8 {
      for x in 0..<8 {
        plane[base + y * stride + x] = plane[base - stride + x]
      }
    }
  } else {
    for y in 0..<8 {
      let left = plane[base - 1 + y * stride]
      for x in 0..<8 {
        plane[base + y * stride + x] = left
      }
    }
  }
}

// ---------------------------------------------------------------------------
// The loop filter

///|
fn distance(a : Int, b : Int) -> Int {
  let d = a - b
  if d < 0 {
    -d
  } else {
    d
  }
}

///|
fn signed_clip(value : Int) -> Int {
  clamp(value, -16, 15)
}

///|
/// A small correction across an edge: two samples either side moved towards each
/// other by a quarter of their disagreement, limited to sixteen.
fn filter2(plane : FixedArray[Int], at : Int, step : Int) -> Unit {
  let p1 = plane[at - 2 * step]
  let p0 = plane[at - step]
  let q0 = plane[at]
  let q1 = plane[at + step]
  let a = 3 * (q0 - p0) + clamp(p1 - q1, -128, 127)
  let a1 = signed_clip((a + 4) >> 3)
  let a2 = signed_clip((a + 3) >> 3)
  plane[at - step] = clamp(p0 + a2, 0, 255)
  plane[at] = clamp(q0 - a1, 0, 255)
}

///|
/// Four samples either side of an inner edge, where there is no sample beyond
/// the two that are changed.
fn filter4(plane : FixedArray[Int], at : Int, step : Int) -> Unit {
  let p1 = plane[at - 2 * step]
  let p0 = plane[at - step]
  let q0 = plane[at]
  let q1 = plane[at + step]
  let a = 3 * (q0 - p0)
  let a1 = signed_clip((a + 4) >> 3)
  let a2 = signed_clip((a + 3) >> 3)
  let a3 = (a1 + 1) >> 1
  plane[at - 2 * step] = clamp(p1 + a3, 0, 255)
  plane[at - step] = clamp(p0 + a2, 0, 255)
  plane[at] = clamp(q0 - a1, 0, 255)
  plane[at + step] = clamp(q1 - a3, 0, 255)
}

///|
/// Six samples either side of a macroblock edge, where there is room for the
/// full filter.
fn filter6(plane : FixedArray[Int], at : Int, step : Int) -> Unit {
  let p2 = plane[at - 3 * step]
  let p1 = plane[at - 2 * step]
  let p0 = plane[at - step]
  let q0 = plane[at]
  let q1 = plane[at + step]
  let q2 = plane[at + 2 * step]
  let a = clamp(3 * (q0 - p0) + clamp(p1 - q1, -128, 127), -128, 127)
  let a1 = (27 * a + 63) >> 7
  let a2 = (18 * a + 63) >> 7
  let a3 = (9 * a + 63) >> 7
  plane[at - 3 * step] = clamp(p2 + a3, 0, 255)
  plane[at - 2 * step] = clamp(p1 + a2, 0, 255)
  plane[at - step] = clamp(p0 + a1, 0, 255)
  plane[at] = clamp(q0 - a1, 0, 255)
  plane[at + step] = clamp(q1 - a2, 0, 255)
  plane[at + 2 * step] = clamp(q2 - a3, 0, 255)
}

///|
/// Whether the edge is worth touching at all: is there a step across it, and is
/// the neighbourhood smooth enough that the step is a quantisation artefact
/// rather than a real edge? A real edge is left alone, which is the whole point
/// of the filter being conditional.
fn needs_filter(plane : FixedArray[Int], at : Int, step : Int, t : Int) -> Bool {
  let p1 = plane[at - 2 * step]
  let p0 = plane[at - step]
  let q0 = plane[at]
  let q1 = plane[at + step]
  4 * distance(p0, q0) + distance(p1, q1) <= t
}

///|
fn needs_filter2(
  plane : FixedArray[Int],
  at : Int,
  step : Int,
  t : Int,
  it : Int,
) -> Bool {
  let p3 = plane[at - 4 * step]
  let p2 = plane[at - 3 * step]
  let p1 = plane[at - 2 * step]
  let p0 = plane[at - step]
  let q0 = plane[at]
  let q1 = plane[at + step]
  let q2 = plane[at + 2 * step]
  let q3 = plane[at + 3 * step]
  if 4 * distance(p0, q0) + distance(p1, q1) > t {
    return false
  }
  distance(p3, p2) <=
    it &&
  distance(p2, p1) <=
    it &&
  distance(p1, p0) <=
    it &&
  distance(q3, q2) <=
    it &&
  distance(q2, q1) <=
    it &&
  distance(q1, q0) <=
    it
}

///|
/// Whether a high-variance edge runs alongside: if it does, the six-tap filter
/// would smear it and the two-tap one is used instead.
fn high_edge(plane : FixedArray[Int], at : Int, step : Int, thresh : Int) -> Bool {
  let p1 = plane[at - 2 * step]
  let p0 = plane[at - step]
  let q0 = plane[at]
  let q1 = plane[at + step]
  distance(p1, p0) > thresh || distance(q1, q0) > thresh
}

///|
/// Filter `size` samples along one edge, the full six-tap variant.
fn filter_loop6(
  plane : FixedArray[Int],
  at : Int,
  across : Int,
  down : Int,
  size : Int,
  thresh : Int,
  inner : Int,
  hev : Int,
) -> Unit {
  let t = 2 * thresh + 1
  for i in 0..<size {
    let p = at + i * down
    if needs_filter2(plane, p, across, t, inner) {
      if high_edge(plane, p, across, hev) {
        filter2(plane, p, across)
      } else {
        filter6(plane, p, across)
      }
    }
  }
}

///|
/// Filter `size` samples along an inner edge, the four-tap variant.
fn filter_loop4(
  plane : FixedArray[Int],
  at : Int,
  across : Int,
  down : Int,
  size : Int,
  thresh : Int,
  inner : Int,
  hev : Int,
) -> Unit {
  let t = 2 * thresh + 1
  for i in 0..<size {
    let p = at + i * down
    if needs_filter2(plane, p, across, t, inner) {
      if high_edge(plane, p, across, hev) {
        filter2(plane, p, across)
      } else {
        filter4(plane, p, across)
      }
    }
  }
}

///|
/// Filter `size` samples with the simple two-tap filter, which only ever moves
/// the two samples either side of the edge.
fn filter_loop_simple(
  plane : FixedArray[Int],
  at : Int,
  across : Int,
  down : Int,
  size : Int,
  thresh : Int,
) -> Unit {
  let t = 2 * thresh + 1
  for i in 0..<size {
    let p = at + i * down
    if needs_filter(plane, p, across, t) {
      filter2(plane, p, across)
    }
  }
}

// ---------------------------------------------------------------------------
// Reconstruction

///|
/// One macroblock's filter strength, worked out once per segment and block size.
priv struct Strength {
  limit : Int
  ilevel : Int
  hev : Int
}

///|
/// The strength for one segment and one block size, from the header's level, the
/// segment's own adjustment, and the block-size adjustment.
///
/// Sharpness lowers the inner level and caps it at `9 - sharpness`, which is why
/// a sharp setting filters the block edges but barely touches the inner ones.
fn strength_for(frame : Frame, segment : Int, i4x4 : Bool) -> Strength {
  let base = if frame.use_segment {
    if frame.absolute_delta {
      frame.segment_filter[segment]
    } else {
      frame.segment_filter[segment] + frame.filter_level
    }
  } else {
    frame.filter_level
  }
  let mut level = base
  if frame.use_lf_delta {
    level = level + frame.ref_lf_delta[0]
    if i4x4 {
      level = level + frame.mode_lf_delta[0]
    }
  }
  level = clamp(level, 0, 63)
  if level == 0 {
    return { limit: 0, ilevel: 0, hev: 0 }
  }
  let mut ilevel = level
  if frame.sharpness > 0 {
    if frame.sharpness > 4 {
      ilevel = ilevel >> 2
    } else {
      ilevel = ilevel >> 1
    }
    let ceiling = 9 - frame.sharpness
    if ilevel > ceiling {
      ilevel = ceiling
    }
  }
  if ilevel < 1 {
    ilevel = 1
  }
  {
    limit: 2 * level + ilevel,
    ilevel,
    hev: if level >= 40 {
      2
    } else if level >= 15 {
      1
    } else {
      0
    },
  }
}

///|
/// The planes the frame is reconstructed on, each already carrying a row above
/// and a column to the left of border samples.
priv struct Planes {
  y : FixedArray[Int]
  u : FixedArray[Int]
  v : FixedArray[Int]
  sy : Int
  sc : Int
}

///|
/// Where sample `(x, y)` lives, with `(-1, -1)` being the top-left corner of the
/// border.
fn at(stride : Int, x : Int, y : Int) -> Int {
  (y + 1) * stride + (x + 1)
}

///|
/// The border the specification prescribes: 129 down the left, 127 across the
/// top. The two differ because a DC prediction with no neighbours uses 128 and
/// the borders are meant to pull it towards the picture's own average, which is
/// brighter than mid-grey in practice.
fn fill_border(plane : FixedArray[Int], stride : Int, width : Int, height : Int) -> Unit {
  for y in -1..<height {
    plane[at(stride, -1, y)] = 129
  }
  for x in -1..<width {
    plane[at(stride, x, -1)] = 127
  }
}

///|
/// Reconstruct one macroblock: predict, then add whatever residue the entropy
/// stream carried for it.
///
/// The four-by-four path needs one extra thing the others do not. A subblock in
/// the rightmost column has no neighbour above-right inside its own macroblock,
/// and the one above-right belongs to a macroblock that has not been decoded
/// yet; the specification takes those four samples from the row above the
/// macroblock instead, for all four rows of subblocks, so they are gathered once
/// here and reused.
fn reconstruct(
  frame : Frame,
  planes : Planes,
  coeffs : FixedArray[Int],
  modes : FixedArray[Int],
  non_zero_y : Int,
  non_zero_uv : Int,
  mb_x : Int,
  mb_y : Int,
) -> Unit {
  let sy = planes.sy
  let sc = planes.sc
  let px = mb_x * 16
  let py = mb_y * 16
  let base = at(sy, px, py)
  let tmp : FixedArray[Int] = FixedArray::make(16, 0)
  let block : FixedArray[Int] = FixedArray::make(16, 0)
  let top : FixedArray[Int] = FixedArray::make(8, 0)
  let left : FixedArray[Int] = FixedArray::make(4, 0)
  let corner : FixedArray[Int] = FixedArray::make(4, 0)
  for i in 0..<4 {
    corner[i] = if mb_x == frame.mb_w - 1 {
      planes.y[at(sy, px + 15, py - 1)]
    } else {
      planes.y[at(sy, px + 16 + i, py - 1)]
    }
  }
  if modes[16] < 0 {
    for n in 0..<16 {
      let bx = px + (n & 3) * 4
      let by = py + (n >> 2) * 4
      let here = at(sy, bx, by)
      for i in 0..<8 {
        top[i] = if i < 4 || bx < px + 12 {
          planes.y[here - sy + i]
        } else {
          corner[i - 4]
        }
      }
      for i in 0..<4 {
        left[i] = planes.y[here - 1 + i * sy]
      }
      predict4(modes[n], block, top, left, planes.y[here - sy - 1])
      for y in 0..<4 {
        for x in 0..<4 {
          planes.y[here + y * sy + x] = block[4 * y + x]
        }
      }
      let kind = (non_zero_y >> (30 - 2 * n)) & 3
      if kind == 3 {
        transform_one(coeffs, 16 * n, planes.y, here, sy, tmp)
      } else if kind == 2 {
        transform_ac3(coeffs, 16 * n, planes.y, here, sy)
      } else if kind == 1 {
        transform_dc(coeffs, 16 * n, planes.y, here, sy)
      }
    }
  } else {
    predict16(corner_mode(mb_x, mb_y, modes[16]), planes.y, base, sy)
    for n in 0..<16 {
      let kind = (non_zero_y >> (30 - 2 * n)) & 3
      let here = at(sy, px + (n & 3) * 4, py + (n >> 2) * 4)
      if kind == 3 {
        transform_one(coeffs, 16 * n, planes.y, here, sy, tmp)
      } else if kind == 2 {
        transform_ac3(coeffs, 16 * n, planes.y, here, sy)
      } else if kind == 1 {
        transform_dc(coeffs, 16 * n, planes.y, here, sy)
      }
    }
  }
  let chroma_x = mb_x * 8
  let chroma_y = mb_y * 8
  for plane_index in 0..<2 {
    let plane = if plane_index == 0 { planes.u } else { planes.v }
    let cb = at(sc, chroma_x, chroma_y)
    predict8(corner_mode(mb_x, mb_y, modes[17]), plane, cb, sc)
    let bits = (non_zero_uv >> (8 * plane_index)) & 0xFF
    if bits != 0 {
      for n in 0..<4 {
        let here = at(sc, chroma_x + (n & 1) * 4, chroma_y + (n >> 1) * 4)
        let offset = 256 + 64 * plane_index + 16 * n
        let kind = (bits >> (6 - 2 * n)) & 3
        if kind >= 2 {
          transform_one(coeffs, offset, plane, here, sc, tmp)
        } else if kind == 1 {
          if coeffs[offset] != 0 {
            transform_dc(coeffs, offset, plane, here, sc)
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Filtering one macroblock

///|
/// Filter one macroblock's edges.
///
/// The macroblock edge gets the six-tap filter and one step more of limit than
/// an inner edge, because the step there is the one the eye finds. The inner
/// edges are filtered only when the block carries residue: a block that is pure
/// prediction has nothing to smooth, and filtering it would blur the very
/// pattern the predictor just drew.
fn filter_macroblock(
  frame : Frame,
  planes : Planes,
  strength : Strength,
  inner : Bool,
  mb_x : Int,
  mb_y : Int,
) -> Unit {
  if strength.limit == 0 {
    return
  }
  let sy = planes.sy
  let sc = planes.sc
  let base = at(sy, mb_x * 16, mb_y * 16)
  let chroma = at(sc, mb_x * 8, mb_y * 8)
  if frame.filter_type == 1 {
    if mb_x > 0 {
      filter_loop_simple(planes.y, base, 1, sy, 16, strength.limit + 4)
    }
    if inner {
      for k in 1..<4 {
        filter_loop_simple(planes.y, base + 4 * k, 1, sy, 16, strength.limit)
      }
    }
    if mb_y > 0 {
      filter_loop_simple(planes.y, base, sy, 1, 16, strength.limit + 4)
    }
    if inner {
      for k in 1..<4 {
        filter_loop_simple(planes.y, base + 4 * k * sy, sy, 1, 16, strength.limit)
      }
    }
  } else {
    let outer = strength.limit + 4
    if mb_x > 0 {
      filter_loop6(planes.y, base, 1, sy, 16, outer, strength.ilevel, strength.hev)
      filter_loop6(planes.u, chroma, 1, sc, 8, outer, strength.ilevel, strength.hev)
      filter_loop6(planes.v, chroma, 1, sc, 8, outer, strength.ilevel, strength.hev)
    }
    if inner {
      for k in 1..<4 {
        filter_loop4(
          planes.y,
          base + 4 * k,
          1,
          sy,
          16,
          strength.limit,
          strength.ilevel,
          strength.hev,
        )
      }
      // Chroma is eight wide, so it has one inner edge and not three.
      filter_loop4(planes.u, chroma + 4, 1, sc, 8, strength.limit, strength.ilevel, strength.hev)
      filter_loop4(planes.v, chroma + 4, 1, sc, 8, strength.limit, strength.ilevel, strength.hev)
    }
    if mb_y > 0 {
      filter_loop6(planes.y, base, sy, 1, 16, outer, strength.ilevel, strength.hev)
      filter_loop6(planes.u, chroma, sc, 1, 8, outer, strength.ilevel, strength.hev)
      filter_loop6(planes.v, chroma, sc, 1, 8, outer, strength.ilevel, strength.hev)
    }
    if inner {
      for k in 1..<4 {
        filter_loop4(
          planes.y,
          base + 4 * k * sy,
          sy,
          1,
          16,
          strength.limit,
          strength.ilevel,
          strength.hev,
        )
      }
      filter_loop4(
        planes.u,
        chroma + 4 * sc,
        sc,
        1,
        8,
        strength.limit,
        strength.ilevel,
        strength.hev,
      )
      filter_loop4(
        planes.v,
        chroma + 4 * sc,
        sc,
        1,
        8,
        strength.limit,
        strength.ilevel,
        strength.hev,
      )
    }
  }
}

// ---------------------------------------------------------------------------
// Residuals

///|
/// Read one macroblock's residuals into `coeffs`, and answer how many of each
/// block's coefficients are non-zero, two bits per block.
///
/// The prediction context for a block is not its own history but its
/// neighbours': whether the block above and the block to the left had
/// coefficients at all. `nz_top` holds that per macroblock column — the low four
/// bits for luma, the rest for chroma — and `nz_left` the same for the column to
/// the left, reset at the start of each row.
///
/// A sixteen-by-sixteen block is coded twice over: its sixteen DCs are collected
/// into one block of their own and transformed with a Walsh-Hadamard, and the
/// sixteen AC-only blocks are then coded starting at coefficient one, because
/// their DC is already in the other block. That is what `first` means.
fn read_residuals(
  coder : Coder,
  frame : Frame,
  segment : Int,
  i4x4 : Bool,
  mb_x : Int,
  nz_top : FixedArray[Int],
  nz_dc_top : FixedArray[Int],
  nz_left : FixedArray[Int],
  coeffs : FixedArray[Int],
) -> (Int, Int) {
  for i in 0..<384 {
    coeffs[i] = 0
  }
  let mut first = 0
  let mut kind = 3
  if !i4x4 {
    let dc : FixedArray[Int] = FixedArray::make(16, 0)
    let context = nz_dc_top[mb_x] + nz_left[1]
    let nz = read_coefficients(
      coder,
      frame,
      1,
      context,
      frame.y2dc[segment],
      frame.y2ac[segment],
      0,
      dc,
      0,
    )
    nz_dc_top[mb_x] = if nz > 0 { 1 } else { 0 }
    nz_left[1] = nz_dc_top[mb_x]
    if nz > 1 {
      transform_wht(dc, coeffs)
    } else {
      let flat = (dc[0] + 3) >> 3
      for i in 0..<16 {
        coeffs[16 * i] = flat
      }
    }
    first = 1
    kind = 0
  }
  let old = nz_top[mb_x]
  let mut tnz = old & 0x0F
  let mut lnz = nz_left[0] & 0x0F
  let mut non_zero_y = 0
  for y in 0..<4 {
    let mut l = lnz & 1
    let mut bits = 0
    for x in 0..<4 {
      let block = 4 * y + x
      let nz = read_coefficients(
        coder,
        frame,
        kind,
        l + (tnz & 1),
        frame.y1dc[segment],
        frame.y1ac[segment],
        first,
        coeffs,
        16 * block,
      )
      l = if nz > first { 1 } else { 0 }
      tnz = (tnz >> 1) | (l << 7)
      bits = (bits << 2) | (if nz > 3 {
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
  let mut non_zero_uv = 0
  for plane in 0..<2 {
    let mut ctnz = (old >> (4 + 2 * plane)) & 3
    let mut clnz = (nz_left[0] >> (4 + 2 * plane)) & 3
    let mut bits = 0
    for y in 0..<2 {
      let mut l = clnz & 1
      for x in 0..<2 {
        let block = 2 * y + x
        let offset = 256 + 64 * plane + 16 * block
        let nz = read_coefficients(
          coder,
          frame,
          2,
          l + (ctnz & 1),
          frame.uvdc[segment],
          frame.uvac[segment],
          0,
          coeffs,
          offset,
        )
        l = if nz > 0 { 1 } else { 0 }
        ctnz = (ctnz >> 1) | (l << 3)
        bits = (bits << 2) | (if nz > 3 {
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
    non_zero_uv = non_zero_uv | (bits << (8 * plane))
    top_out = top_out | ((ctnz << 4) << (2 * plane))
    left_out = left_out | ((clnz & 0xF0) << (2 * plane))
  }
  nz_top[mb_x] = top_out
  nz_left[0] = left_out
  (non_zero_y, non_zero_uv)
}

// ---------------------------------------------------------------------------
// The partitions

///|
/// The token partitions. The first partition, the one the modes are in, is
/// already open; this opens the rest, whose sizes are three bytes each and whose
/// last one runs to the end of the payload.
fn read_partitions(
  payload : BytesView,
  from : Int,
  count : Int,
) -> FixedArray[Coder] raise @raster.Refused {
  let parts : FixedArray[Coder] = FixedArray::make(count, Coder::new(payload, 0, 0))
  let tail = count - 1
  if from + 3 * tail > payload.length() {
    raise @raster.Truncated(
      at=payload.length(),
      want=from + 3 * tail - payload.length(),
    )
  }
  let mut start = from + 3 * tail
  let mut left = payload.length() - start
  for p in 0..<tail {
    let size = payload[from + 3 * p].to_int() |
      (payload[from + 3 * p + 1].to_int() << 8) |
      (payload[from + 3 * p + 2].to_int() << 16)
    let size = if size > left { left } else { size }
    parts[p] = Coder::new(payload, start, start + size)
    start = start + size
    left = left - size
  }
  parts[tail] = Coder::new(payload, start, payload.length())
  parts
}

// ---------------------------------------------------------------------------
// Colour

///|
/// One sample, clipped the way the reference clips it: the fixed-point value
/// carries six fractional bits, and anything outside the byte range saturates.
fn clip8(value : Int) -> Byte {
  if value < 0 {
    b'\x00'
  } else if value > 16383 {
    b'\xff'
  } else {
    (value >> 6).to_byte()
  }
}

///|
/// Three samples from one luma and two chroma, BT.601 with the coefficients in
/// 16-bit fixed point: 1.164 for luma, 1.596 for red from V, 0.813 and 0.391 for
/// green, 2.018 for blue from U.
fn rgb(out : FixedArray[Byte], at : Int, y : Int, u : Int, v : Int) -> Unit {
  let luma = (y * 19077) >> 8
  out[at] = clip8(luma + ((v * 26149) >> 8) - 14234)
  out[at + 1] = clip8(luma - ((u * 6419) >> 8) - ((v * 13320) >> 8) + 8708)
  out[at + 2] = clip8(luma + ((u * 33050) >> 8) - 17685)
}

///|
/// Write one or two rows of RGB, interpolating the chroma between the two rows
/// it sits between.
///
/// This is the "fancy" upsampling the reference decoder does: a chroma sample
/// covers two luma rows and two columns, and rather than repeat it four times,
/// each output pixel takes a weighted average of the nearest two-by-two block —
/// 9/16 for the sample it belongs to, 3/16 for the two beside it, 1/16 for the
/// diagonal. On a smooth gradient that is the difference between a picture and
/// a mosaic.
///
/// The first row of the picture has no chroma row above it, and the last row of
/// an even-height picture has none below; both are handled by using the one row
/// there is twice, which is what the reference does by mirroring.
fn emit_rows(
  out : FixedArray[Byte],
  width : Int,
  planes : Planes,
  y_top : Int,
  y_bottom : Int,
  c_top : Int,
  c_bottom : Int,
) -> Unit {
  let sy = planes.sy
  let sc = planes.sc
  let row = y_top * width * 3
  let low = if y_bottom >= 0 { y_bottom * width * 3 } else { 0 }
  let mut tl_u = planes.u[at(sc, 0, c_top)]
  let mut tl_v = planes.v[at(sc, 0, c_top)]
  let mut l_u = planes.u[at(sc, 0, c_bottom)]
  let mut l_v = planes.v[at(sc, 0, c_bottom)]
  rgb(
    out,
    row,
    planes.y[at(sy, 0, y_top)],
    (3 * tl_u + l_u + 2) >> 2,
    (3 * tl_v + l_v + 2) >> 2,
  )
  if y_bottom >= 0 {
    rgb(
      out,
      low,
      planes.y[at(sy, 0, y_bottom)],
      (3 * l_u + tl_u + 2) >> 2,
      (3 * l_v + tl_v + 2) >> 2,
    )
  }
  let last = (width - 1) >> 1
  for x in 1..<(last + 1) {
    let t_u = planes.u[at(sc, x, c_top)]
    let t_v = planes.v[at(sc, x, c_top)]
    let here_u = planes.u[at(sc, x, c_bottom)]
    let here_v = planes.v[at(sc, x, c_bottom)]
    let sum_u = tl_u + t_u + l_u + here_u + 8
    let sum_v = tl_v + t_v + l_v + here_v + 8
    let near_u = (sum_u + 2 * (t_u + l_u)) >> 3
    let near_v = (sum_v + 2 * (t_v + l_v)) >> 3
    let far_u = (sum_u + 2 * (tl_u + here_u)) >> 3
    let far_v = (sum_v + 2 * (tl_v + here_v)) >> 3
    rgb(
      out,
      row + (2 * x - 1) * 3,
      planes.y[at(sy, 2 * x - 1, y_top)],
      (near_u + tl_u) >> 1,
      (near_v + tl_v) >> 1,
    )
    rgb(
      out,
      row + 2 * x * 3,
      planes.y[at(sy, 2 * x, y_top)],
      (far_u + t_u) >> 1,
      (far_v + t_v) >> 1,
    )
    if y_bottom >= 0 {
      rgb(
        out,
        low + (2 * x - 1) * 3,
        planes.y[at(sy, 2 * x - 1, y_bottom)],
        (far_u + l_u) >> 1,
        (far_v + l_v) >> 1,
      )
      rgb(
        out,
        low + 2 * x * 3,
        planes.y[at(sy, 2 * x, y_bottom)],
        (near_u + here_u) >> 1,
        (near_v + here_v) >> 1,
      )
    }
    tl_u = t_u
    tl_v = t_v
    l_u = here_u
    l_v = here_v
  }
  if width % 2 == 0 && width > 1 {
    let column = (width - 1) * 3
    let u = (3 * tl_u + l_u + 2) >> 2
    let v = (3 * tl_v + l_v + 2) >> 2
    rgb(out, row + column, planes.y[at(sy, width - 1, y_top)], u, v)
    if y_bottom >= 0 {
      rgb(
        out,
        low + column,
        planes.y[at(sy, width - 1, y_bottom)],
        (3 * l_u + tl_u + 2) >> 2,
        (3 * l_v + tl_v + 2) >> 2,
      )
    }
  }
}

///|
/// The planes as the library's three-byte pixels.
fn to_rgb_image(
  planes : Planes,
  width : Int,
  height : Int,
) -> @raster.Image raise @raster.Refused {
  let out : FixedArray[Byte] = FixedArray::make(width * height * 3, b'\x00')
  emit_rows(out, width, planes, 0, -1, 0, 0)
  let mut pair = 0
  while 2 * pair + 2 < height {
    emit_rows(
      out,
      width,
      planes,
      2 * pair + 1,
      2 * pair + 2,
      pair,
      pair + 1,
    )
    pair = pair + 1
  }
  if height % 2 == 0 && height > 1 {
    emit_rows(out, width, planes, height - 1, -1, height / 2 - 1, height / 2 - 1)
  }
  @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::Rgb8,
    Bytes::from_array(out.clamped_view()),
  )
}

// ---------------------------------------------------------------------------
// The frame

///|
/// The image in a VP8 payload: a frame header, then the compressed frame.
///
/// The header is in the first partition, interleaved with the macroblock modes;
/// the coefficients are spread over up to eight partitions, one per row of
/// macroblocks in rotation, which is what lets a decoder read them in parallel.
pub fn decode_lossy(
  payload : BytesView,
  limits : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  if payload.length() < 10 {
    raise @raster.Truncated(at=payload.length(), want=10 - payload.length())
  }
  let tag = payload[0].to_int() |
    (payload[1].to_int() << 8) |
    (payload[2].to_int() << 16)
  if (tag & 1) == 1 {
    raise @raster.Unsupported(at=0, got="an interframe, which a WebP never holds")
  }
  if ((tag >> 1) & 7) > 3 {
    raise @raster.Unexpected(at=0, got="a profile above three", want="a key frame")
  }
  if ((tag >> 4) & 1) == 0 {
    raise @raster.Unexpected(
      at=0,
      got="a frame that is not for display",
      want="a frame that is",
    )
  }
  let partition_length = tag >> 5
  if payload[3].to_int() != 0x9D ||
    payload[4].to_int() != 0x01 ||
    payload[5].to_int() != 0x2A {
    raise @raster.Unexpected(
      at=3,
      got=@raster.hex(payload, 3, 3),
      want="the 9d 01 2a that starts a key frame",
    )
  }
  let width = ((payload[7].to_int() << 8) | payload[6].to_int()) & 0x3FFF
  let height = ((payload[9].to_int() << 8) | payload[8].to_int()) & 0x3FFF
  if width == 0 || height == 0 {
    raise @raster.Unexpected(
      at=6,
      got="a picture with a zero side",
      want="a picture with a width and a height",
    )
  }
  limits.check(width, height)
  let frame = Frame::new(width, height)
  let first_end = 10 + partition_length
  if first_end > payload.length() {
    raise @raster.Truncated(
      at=payload.length(),
      want=first_end - payload.length(),
    )
  }
  let coder = Coder::new(payload, 10, first_end)
  ignore(coder.flag()) // colour space, which is always BT.601 here
  ignore(coder.flag()) // clamping, which no decoder has to honour
  read_segment_header(coder, frame)
  read_filter_header(coder, frame)
  let parts = read_partitions(payload, first_end, 1 << coder.literal(2))
  read_quant(coder, frame)
  ignore(coder.flag()) // whether the probabilities below are updated
  read_coefficient_probs(coder, frame)

  let mb_w = frame.mb_w
  let mb_h = frame.mb_h
  let sy = mb_w * 16 + 16
  let sc = mb_w * 8 + 16
  let ph = mb_h * 16
  let ch = mb_h * 8
  let py = FixedArray::make((ph + 2) * sy, 0)
  let pu = FixedArray::make((ch + 2) * sc, 0)
  let pv = FixedArray::make((ch + 2) * sc, 0)
  fill_border(py, sy, mb_w * 16, ph)
  fill_border(pu, sc, mb_w * 8, ch)
  fill_border(pv, sc, mb_w * 8, ch)
  let planes : Planes = { y: py, u: pu, v: pv, sy, sc }

  let top = FixedArray::make(4 * mb_w, 0)
  let left = FixedArray::make(4, 0)
  let modes = FixedArray::make(20, 0)
  let coeffs = FixedArray::make(384, 0)
  let nz_top = FixedArray::make(mb_w, 0)
  let nz_dc_top = FixedArray::make(mb_w, 0)
  let nz_left = FixedArray::make(2, 0)
  let segments = FixedArray::make(mb_w * mb_h, 0)
  let small = FixedArray::make(mb_w * mb_h, false)
  let filtered = FixedArray::make(mb_w * mb_h, false)

  for mb_y in 0..<mb_h {
    for i in 0..<4 {
      left[i] = 0
    }
    nz_left[0] = 0
    nz_left[1] = 0
    let tokens = parts[mb_y % parts.length()]
    for mb_x in 0..<mb_w {
      read_modes(coder, frame, top, left, mb_x, modes)
      let i4x4 = modes[16] < 0
      let mut non_zero_y = 0
      let mut non_zero_uv = 0
      if modes[18] == 1 {
        nz_top[mb_x] = 0
        nz_left[0] = 0
        if !i4x4 {
          nz_dc_top[mb_x] = 0
          nz_left[1] = 0
        }
      } else {
        let (y, uv) = read_residuals(
          tokens,
          frame,
          modes[19],
          i4x4,
          mb_x,
          nz_top,
          nz_dc_top,
          nz_left,
          coeffs,
        )
        non_zero_y = y
        non_zero_uv = uv
      }
      reconstruct(
        frame,
        planes,
        coeffs,
        modes,
        non_zero_y,
        non_zero_uv,
        mb_x,
        mb_y,
      )
      let index = mb_y * mb_w + mb_x
      segments[index] = modes[19]
      small[index] = i4x4
      filtered[index] = i4x4 || modes[18] == 0
    }
  }

  // The filter runs over the whole frame once it is reconstructed, in the same
  // order a row-at-a-time decoder would: each edge sees the one above and the
  // one to the left already filtered, and the ones below and to the right not.
  if frame.filter_type > 0 {
    for mb_y in 0..<mb_h {
      for mb_x in 0..<mb_w {
        let index = mb_y * mb_w + mb_x
        filter_macroblock(
          frame,
          planes,
          strength_for(frame, segments[index], small[index]),
          filtered[index],
          mb_x,
          mb_y,
        )
      }
    }
  }
  to_rgb_image(planes, width, height)
}

// ---------------------------------------------------------------------------
// The alpha channel, which VP8 does not have

///|
/// The alpha plane that travels beside a lossy picture.
///
/// VP8 codes no alpha, so a transparent lossy WebP carries a separate `ALPH`
/// chunk: one byte saying how it is stored, then the plane — raw, or compressed
/// with the *lossless* codec, in which case the samples sit in its green channel
/// — then a filter along each row, the same idea as PNG's and undone the same
/// way. The result is one byte per pixel, which is all an alpha channel is.
pub fn decode_alpha(
  payload : BytesView,
  width : Int32,
  height : Int32,
  limits : @raster.Limits,
) -> Bytes raise @raster.Refused {
  if payload.length() < 1 {
    raise @raster.Truncated(at=0, want=1)
  }
  let header = payload[0].to_int()
  let compression = header & 0x03
  let filtering = (header >> 2) & 0x03
  let count = width * height
  let plane : FixedArray[Int] = FixedArray::make(count, 0)
  if compression == 0 {
    if payload.length() < 1 + count {
      raise @raster.Truncated(at=payload.length(), want=1 + count - payload.length())
    }
    for index in 0..<count {
      plane[index] = payload[1 + index].to_int()
    }
  } else if compression == 1 {
    let image = decode_lossless_stream(
      payload.clamped_view(start=1, end=payload.length()),
      width,
      height,
      limits,
    )
    if image.width != width || image.height != height {
      raise @raster.Unexpected(
        at=1,
        got="an alpha plane \{image.width} by \{image.height}",
        want="one the size of the picture, \{width} by \{height}",
      )
    }
    for index in 0..<count {
      plane[index] = image.pixels[index * 4 + 1].to_int()
    }
  } else {
    raise @raster.Unsupported(at=0, got="an alpha compression of \{compression}")
  }
  let stride = width
  for y in 0..<height {
    let base = y * stride
    if filtering == 0 {
      continue
    }
    if y == 0 || filtering == 1 {
      // The first row has no row above it to lean on, so a horizontal filter
      // and the first row of any filter behave alike: a running sum from zero.
      let mut previous = if y == 0 { 0 } else { plane[base - stride] }
      for x in 0..<stride {
        previous = (previous + plane[base + x]) & 0xFF
        plane[base + x] = previous
      }
    } else if filtering == 2 {
      for x in 0..<stride {
        plane[base + x] = (plane[base - stride + x] + plane[base + x]) & 0xFF
      }
    } else {
      let mut above = plane[base - stride]
      let mut corner = above
      let mut left = above
      for x in 0..<stride {
        above = plane[base - stride + x]
        let predicted = clamp(left + above - corner, 0, 255)
        left = (plane[base + x] + predicted) & 0xFF
        corner = above
        plane[base + x] = left
      }
    }
  }
  let out : FixedArray[Byte] = FixedArray::make(count, b'\x00')
  for index in 0..<count {
    out[index] = plane[index].to_byte()
  }
  Bytes::from_array(out.clamped_view())
}

///|
/// A picture and its alpha channel as one image with four samples per pixel.
fn with_alpha(
  image : @raster.Image,
  alpha : Bytes,
) -> @raster.Image raise @raster.Refused {
  let width = image.width
  let height = image.height
  let out : FixedArray[Byte] = FixedArray::make(width * height * 4, b'\xff')
  for y in 0..<height {
    let row = image.row(y).to_owned()
    for x in 0..<width {
      out[(y * width + x) * 4] = row[x * 3]
      out[(y * width + x) * 4 + 1] = row[x * 3 + 1]
      out[(y * width + x) * 4 + 2] = row[x * 3 + 2]
      out[(y * width + x) * 4 + 3] = alpha[y * width + x]
    }
  }
  @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(out.clamped_view()),
  )
}
