// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Putting a block of coefficients back into a picture.
//
// The one-dimensional transforms live beside this file and were translated
// from the reference decoder; the two-dimensional combination here follows
// its `inv_txfm_add_c` step for step. A transform is a separable pair of
// one-dimensional passes, so the work is: gather the coefficients into rows in
// the order the scan table names, run the horizontal pass, round and clip,
// run the vertical pass, add the residual to the prediction. The two unusual
// cases are a lone DC coefficient (a closed form, no butterflies needed) and
// the lossless Walsh-Hadamard transform, which has its own rounding.
//
// Everything here is integer arithmetic with the reference decoder's clip
// bounds, because a difference of one in an intermediate becomes a visible
// difference in the picture.

///|
fn clip_pixel(value : Int32) -> Int32 {
  if value < 0 {
    0
  } else if value > 255 {
    255
  } else {
    value
  }
}

///|
/// One one-dimensional inverse transform. `size` is the log2 of the width
/// divided by four (0 is four coefficients, 4 is sixty-four); `kind` is the
/// reference decoder's Tx1dType: DCT, ADST, identity, flipADST.
pub fn itx_1d(
  kind : Int32,
  size : Int32,
  c : FixedArray[Int32],
  at : Int32,
  stride : Int32,
  min : Int32,
  max : Int32,
) -> Unit {
  match kind {
    0 =>
      match size {
        0 => dct4(c, at, stride, min, max, false)
        1 => dct8(c, at, stride, min, max, false)
        2 => dct16(c, at, stride, min, max, false)
        3 => dct32(c, at, stride, min, max, false)
        4 => dct64(c, at, stride, min, max)
        _ => ()
      }
    1 =>
      // ADST writes its outputs from the same end it read its inputs.
      match size {
        0 => adst4(c, at, stride, at, stride)
        1 => adst8(c, at, stride, at, stride, min, max)
        2 => adst16(c, at, stride, at, stride, min, max)
        _ => ()
      }
    2 =>
      match size {
        0 => identity4(c, at, stride)
        1 => identity8(c, at, stride)
        2 => identity16(c, at, stride)
        3 => identity32(c, at, stride)
        _ => ()
      }
    3 =>
      // FLIPADST is ADST with the outputs written back-to-front.
      match size {
        0 => adst4(c, at, stride, at + 3 * stride, -stride)
        1 => adst8(c, at, stride, at + 7 * stride, -stride, min, max)
        2 => adst16(c, at, stride, at + 15 * stride, -stride, min, max)
        _ => ()
      }
    _ => ()
  }
}

///|
/// The lossless 4x4 Walsh-Hadamard transform, which is not separable in the
/// same way: its coefficients are shifted by two before the first pass and
/// its residual is added without the final four-bit rounding.
fn itx_wht_wht(
  dst : FixedArray[Int32],
  dst_at : Int32,
  dst_stride : Int32,
  coeff : FixedArray[Int32],
) -> Unit {
  let tmp : FixedArray[Int32] = FixedArray::make(16, 0)
  for y in 0..<4 {
    for x in 0..<4 {
      tmp[y * 4 + x] = coeff[y + x * 4] >> 2
    }
    wht4(tmp, y * 4, 1)
  }
  for x in 0..<4 {
    wht4(tmp, x, 4)
  }
  for y in 0..<4 {
    for x in 0..<4 {
      let p = dst_at + y * dst_stride + x
      dst[p] = clip_pixel(dst[p] + tmp[y * 4 + x])
    }
  }
}

///|
/// Add the inverse-transformed residual to `dst`. `coeff` holds the levels at
/// the positions the scan table names; `eob` is the last non-zero position.
pub fn inv_txfm_add(
  dst : FixedArray[Int32],
  dst_at : Int32,
  dst_stride : Int32,
  coeff : FixedArray[Int32],
  eob : Int32,
  tx : Int32,
  txtp : Int32,
) -> Unit {
  if txtp == 16 {
    itx_wht_wht(dst, dst_at, dst_stride, coeff)
    return
  }
  // Five numbers a size — the index, the two sides, the two logarithms — so a
  // row is five wide whatever the size is.
  let w = itx_dims[tx * 5 + 1]
  let h = itx_dims[tx * 5 + 2]
  let lw = itx_dims[tx * 5 + 3]
  let lh = itx_dims[tx * 5 + 4]
  let shift = itx_shift[tx]
  let is_rect2 = w * 2 == h || h * 2 == w
  let rnd = 1 << shift >> 1
  let row_min = -32768
  let row_max = 32767
  let col_min = -32768
  let col_max = 32767

  // A single DC coefficient has a closed form, and it is the most common
  // block in a still picture.
  if eob == 0 && txtp == 0 {
    let mut dc = coeff[0]
    if is_rect2 {
      dc = (dc * 181 + 128) >> 8
    }
    dc = (dc * 181 + 128) >> 8
    dc = (dc + rnd) >> shift
    dc = (dc * 181 + 128 + 2048) >> 12
    for y in 0..<h {
      for x in 0..<w {
        let p = dst_at + y * dst_stride + x
        dst[p] = clip_pixel(dst[p] + dc)
      }
    }
    return
  }

  // The pair is applied the other way round from the order it is written in:
  // the run the scan walks inside a coefficient column spans the block's width,
  // so it takes the second of the pair, and the pass down the columns takes the
  // first. The vectors are what say so — the arrangement that reads the pair in
  // order produced the transpose of every picture that was not DCT_DCT, and a
  // transpose of a square block is not a thing a rounding difference can
  // explain.
  let second = itx_1d_types[txtp * 2]
  let first = itx_1d_types[txtp * 2 + 1]
  let sh = min_of(h, 32)
  let sw = min_of(w, 32)
  let last_col = if second == 2 && first != 2 {
    min_of(sh - 1, eob)
  } else if first == 2 && second != 2 {
    eob >> (lw + 2)
  } else {
    itx_last_nonzero_col(tx, eob)
  }
  let tmp : FixedArray[Int32] = FixedArray::make(64 * 64, 0)
  let mut y = 0
  while y <= last_col {
    let row = y * w
    for x in 0..<sw {
      tmp[row + x] = if is_rect2 {
        (coeff[y + x * sh] * 181 + 128) >> 8
      } else {
        coeff[y + x * sh]
      }
    }
    itx_1d(first, lw, tmp, row, 1, row_min, row_max)
    y = y + 1
  }
  for i in 0..<(w * sh) {
    tmp[i] = clip((tmp[i] + rnd) >> shift, col_min, col_max)
  }
  for x in 0..<w {
    itx_1d(second, lh, tmp, x, w, col_min, col_max)
  }
  for y in 0..<h {
    for x in 0..<w {
      let p = dst_at + y * dst_stride + x
      dst[p] = clip_pixel(dst[p] + ((tmp[y * w + x] + 8) >> 4))
    }
  }
}
