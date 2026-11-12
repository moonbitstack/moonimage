// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Coefficient decoding: which transform a block was coded with, how many of its
// coefficients are not zero, how large they are, and what they become after the
// quantiser is undone.
//
// The syntax is a token stream read in reverse scan order. The end of block is
// read first and says where to stop; the largest coefficient is then read at
// that position, and each position below it is read only if the one above it
// had a token. Two of those tokens are escapes — a base token of three means the
// magnitude is at least four and the "high token" follows, and a high token of
// fifteen means a Golomb code follows that — so a run of coefficients is a chain
// of small symbols and rare large ones.
//
// The context of each token is the sum of the levels of the coefficients above
// and to the left of it in the transform, which is why the levels are kept in an
// array of their own rather than derived from the coefficients: the sum includes
// how many of them were escapes, and that information is gone once a coefficient
// has been dequantised.

///|
/// What the decoder learned about one transform block.
pub(all) struct CoefResult {
  eob : Int32
  txtp : Int32
  ctx : Int32
}

///|
/// Which of the thirteen coefficient tables a set holds.
let coef_eob_bin_16 : Int32 = 0

///|
let coef_eob_bin_32 : Int32 = 1

///|
let coef_eob_bin_64 : Int32 = 2

///|
let coef_eob_bin_128 : Int32 = 3

///|
let coef_eob_bin_256 : Int32 = 4

///|
let coef_eob_bin_512 : Int32 = 5

///|
let coef_eob_bin_1024 : Int32 = 6

///|
let coef_eob_base_tok : Int32 = 7

///|
let coef_base_tok : Int32 = 8

///|
let coef_br_tok : Int32 = 9

///|
let coef_eob_hi_bit : Int32 = 10

///|
let coef_skip : Int32 = 11

///|
let coef_dc_sign : Int32 = 12

///|
/// The three ways a coefficient's neighbours are counted: along both axes,
/// along the row only, or down the column only.
let tx_class_2d : Int32 = 0

///|
let tx_class_h : Int32 = 1

///|
let tx_class_v : Int32 = 2

///|
/// Where the row of a CDF begins: `context` counts rows of `cdf_widths[element]`
/// entries from the element's own offset.
fn cdf_row(cdf : FixedArray[Int32], element : Int32, context : Int32) -> Int32 {
  let at = cdf_offsets[element] + context * cdf_widths[element]
  if at < 0 || at + cdf_widths[element] > cdf.length() {
    abort(
      "cdf row out of range: element \{element} context \{context} at \{at}",
    )
  }
  at
}

///|
/// A run of ones followed by a zero, then the bits below the leading one.
fn read_golomb(msac : Msac) -> Int32 {
  let mut len = 0
  let mut value = 1
  while msac.bool_equi() == 0 && len < 32 {
    len = len + 1
  }
  while len > 0 {
    len = len - 1
    value = (value << 1) + msac.bool_equi()
  }
  value - 1
}

///|
/// The context a coefficient block's neighbours put it in.
///
/// The reference reads the neighbour array a machine word at a time and folds
/// the bytes together; the fold is only a way of asking whether any of them is
/// not the "no coefficient" marker, so it is written out here as the question it
/// answers.
fn get_skip_ctx(
  tx : Int32,
  bs : Int32,
  a : FixedArray[Int32],
  a_at : Int32,
  l : FixedArray[Int32],
  l_at : Int32,
  chroma : Bool,
  ss_hor : Int32,
  ss_ver : Int32,
) -> Int32 {
  let lw = txfm_lw[tx]
  let lh = txfm_lh[tx]
  let bw_log = block_dimensions[bs * 4 + 2]
  let bh_log = block_dimensions[bs * 4 + 3]
  if chroma {
    let across = bw_log - (if bw_log != 0 && ss_hor != 0 { 1 } else { 0 })
    let down = bh_log - (if bh_log != 0 && ss_ver != 0 { 1 } else { 0 })
    let not_one_blk = across > lw || down > lh
    let ca = if any_not_empty(a, a_at, 1 << lw) { 1 } else { 0 }
    let cl = if any_not_empty(l, l_at, 1 << lh) { 1 } else { 0 }
    return 7 + (if not_one_blk { 3 } else { 0 }) + ca + cl
  }
  if bw_log == lw && bh_log == lh {
    return 0
  }
  let la = merged_level(a, a_at, 1 << lw)
  let ll = merged_level(l, l_at, 1 << lh)
  let row = if (la & 0x3F) > 4 { 4 } else { la & 0x3F }
  let column = if (ll & 0x3F) > 4 { 4 } else { ll & 0x3F }
  skip_ctx[row * 5 + column]
}

///|
fn any_not_empty(values : FixedArray[Int32], at : Int32, count : Int32) -> Bool {
  for i in 0..<count {
    if values[at + i] != 0x40 {
      return true
    }
  }
  false
}

///|
/// The bitwise or of a run of neighbour levels.
fn merged_level(values : FixedArray[Int32], at : Int32, count : Int32) -> Int32 {
  let mut merged = 0
  for i in 0..<count {
    merged = merged | values[at + i]
  }
  merged
}

///|
/// The context a coefficient's sign is read in: how many of the neighbours were
/// negative, down the column and along the row.
fn get_dc_sign_ctx(
  tx : Int32,
  a : FixedArray[Int32],
  a_at : Int32,
  l : FixedArray[Int32],
  l_at : Int32,
) -> Int32 {
  let w = txfm_w[tx]
  let h = txfm_h[tx]
  let mut total = 0
  for i in 0..<w {
    total = total + (a[a_at + i] >> 6)
  }
  for i in 0..<h {
    total = total + (l[l_at + i] >> 6)
  }
  let s = total - w - h
  (if s != 0 { 1 } else { 0 }) + (if s > 0 { 1 } else { 0 })
}

///|
/// The context and the magnitude hint of one coefficient, from the levels of the
/// coefficients above and to the left of it.
fn lo_ctx(
  levels : FixedArray[Int32],
  tx_class : Int32,
  x : Int32,
  y : Int32,
  stride : Int32,
  table : Int32,
) -> (Int32, Int32) {
  // `x` counts rows of the level array and `y` counts along them, the way the
  // reference lays the levels out; the two names are the coefficient's own
  // coordinates in the opposite order from the picture's.
  let mut mag = levels[x * stride + y + 1] + levels[(x + 1) * stride + y]
  let mut offset = 0
  if tx_class == tx_class_2d {
    mag = mag + levels[(x + 1) * stride + y + 1]
    let hint = mag
    mag = mag + levels[x * stride + y + 2] + levels[(x + 2) * stride + y]
    let row = if y > 4 { 4 } else { y }
    let column = if x > 4 { 4 } else { x }
    offset = lo_ctx_offsets[table * 25 + row * 5 + column]
    return (offset + (if mag > 512 { 4 } else { (mag + 64) >> 7 }), hint)
  }
  mag = mag + levels[x * stride + y + 2]
  let hint = mag
  mag = mag + levels[x * stride + y + 3] + levels[x * stride + y + 4]
  offset = 26 + (if y > 1 { 10 } else { y * 5 })
  (offset + (if mag > 512 { 4 } else { (mag + 64) >> 7 }), hint)
}

///|
/// The coefficient block of one transform: its transform type, its end of block,
/// and the coefficients themselves in the order the transform reads them.
pub fn decode_coefs(
  msac : Msac,
  cdf : FixedArray[Int32],
  a : FixedArray[Int32],
  a_at : Int32,
  l : FixedArray[Int32],
  l_at : Int32,
  tx : Int32,
  bs : Int32,
  plane : Int32,
  intra : Bool,
  y_mode : Int32,
  y_angle : Int32,
  uv_mode : Int32,
  reduced_txtp : Bool,
  lossless : Bool,
  qidx : Int32,
  dq_dc : Int32,
  dq_ac : Int32,
  cf : FixedArray[Int32],
  levels : FixedArray[Int32],
  ss_hor : Int32,
  ss_ver : Int32,
  qm_at : Int32,
) -> CoefResult {
  let chroma = plane != 0
  // The transform reads a rectangle of coefficients, not the scan: positions the
  // block did not write have to hold nought rather than whatever the last block
  // left there.
  let span = (if txfm_w[tx] > 8 { 8 } else { txfm_w[tx] }) *
    (if txfm_h[tx] > 8 { 8 } else { txfm_h[tx] }) *
    16
  for i in 0..<span {
    cf[i] = 0
  }
  let qcat = (if qidx > 20 { 1 } else { 0 }) +
    (if qidx > 60 { 1 } else { 0 }) +
    (if qidx > 120 { 1 } else { 0 })
  // The thirteen tables of the coefficient set the frame's quantiser selects.
  let base = CDF_COEF0_EOB_BIN_16 + qcat * 13
  let t_dim_ctx = txfm_ctx[tx]
  let t_min = txfm_min[tx]
  let t_max = txfm_max[tx]
  let chroma_bit = if chroma { 1 } else { 0 }

  let sctx = get_skip_ctx(tx, bs, a, a_at, l, l_at, chroma, ss_hor, ss_ver)
  let all_skip = msac.bool_adapt(
    cdf,
    cdf_row(cdf, base + coef_skip, t_dim_ctx * 13 + sctx),
  )
  if all_skip == 1 {
    return { eob: -1, txtp: if lossless { 16 } else { 0 }, ctx: 0x40, }
  }

  let mut txtp = 0
  if lossless {
    txtp = 16
  } else if t_max + (if intra { 1 } else { 0 }) >= 4 {
    txtp = 0
  } else if chroma {
    txtp = if intra { txtp_from_uvmode[uv_mode] } else { 0 }
  } else if qidx == 0 {
    txtp = 0
  } else if intra {
    let mode_nofilt = if y_mode == 13 {
      filter_mode_to_y_mode[y_angle]
    } else {
      y_mode
    }
    if reduced_txtp || t_min == 2 {
      let idx = msac.symbol(
        cdf,
        cdf_row(cdf, CDF_M_TXTP_INTRA2, t_min * 13 + mode_nofilt),
        4,
      )
      txtp = tx_types_per_set[idx]
    } else {
      let idx = msac.symbol(
        cdf,
        cdf_row(cdf, CDF_M_TXTP_INTRA1, t_min * 13 + mode_nofilt),
        6,
      )
      txtp = tx_types_per_set[idx + 5]
    }
  }

  // The end of block, in a bin whose tables are chosen by the size of the block
  // capped at thirty-two and by whether the transform runs along one axis.
  let slw = if txfm_lw[tx] > 3 { 3 } else { txfm_lw[tx] }
  let slh = if txfm_lh[tx] > 3 { 3 } else { txfm_lh[tx] }
  let tx2dszctx = slw + slh
  let tx_class = tx_type_class[txtp]
  let is_1d = if tx_class == tx_class_2d { 0 } else { 1 }
  let mut eob = 0
  if tx2dszctx <= 4 {
    let which = [
        coef_eob_bin_16, coef_eob_bin_32, coef_eob_bin_64, coef_eob_bin_128, coef_eob_bin_256,
      ][tx2dszctx]
    eob = msac.symbol(
      cdf,
      cdf_row(cdf, base + which, chroma_bit * 2 + is_1d),
      4 + tx2dszctx,
    )
  } else if tx2dszctx == 5 {
    eob = msac.symbol(cdf, cdf_row(cdf, base + coef_eob_bin_512, chroma_bit), 9)
  } else {
    eob = msac.symbol(
      cdf,
      cdf_row(cdf, base + coef_eob_bin_1024, chroma_bit),
      10,
    )
  }
  if eob > 1 {
    let eob_bin = eob - 2
    let hi = msac.bool_adapt(
      cdf,
      cdf_row(
        cdf,
        base + coef_eob_hi_bit,
        (t_dim_ctx * 2 + chroma_bit) * 9 + eob_bin,
      ),
    )
    eob = ((hi | 2) << eob_bin) | msac.bools(eob_bin)
  }

  let eob_cdf_row = (t_dim_ctx * 2 + chroma_bit) * 4
  let hi_ctx_count = if t_dim_ctx > 3 { 3 } else { t_dim_ctx }
  let hi_base = (hi_ctx_count * 2 + chroma_bit) * 21
  let lo_base = (t_dim_ctx * 2 + chroma_bit) * 41
  let eob_tok_base = (t_dim_ctx * 2 + chroma_bit) * 4
  let mut dc_tok = 0
  let mut rc = 0

  if eob != 0 {
    let scan_at = itx_scan_offsets[tx]
    let stride = 4 << slh
    let shift = slh + 2
    let mask = (4 << slh) - 1
    let shift2 = if tx_class == tx_class_v { slh + 2 } else { 0 }
    let nonsquare = if tx >= 5 { 1 } else { 0 }
    let table = nonsquare + (tx & nonsquare)
    let clear = if tx_class == tx_class_h {
      stride * ((4 << slh) + 2)
    } else {
      stride * ((4 << slw) + 2)
    }
    for i in 0..<clear {
      levels[i] = 0
    }
    let mut x = 0
    let mut y = 0
    if tx_class == tx_class_2d {
      rc = itx_scans[scan_at + eob]
      x = rc >> shift
      y = rc & mask
    } else if tx_class == tx_class_h {
      x = eob & mask
      y = eob >> shift
      rc = eob
    } else {
      x = eob & mask
      y = eob >> shift
      rc = (x << shift2) | y
    }
    let mut ctx = 1 +
      (if eob > 2 << tx2dszctx { 1 } else { 0 }) +
      (if eob > 4 << tx2dszctx { 1 } else { 0 })
    let mut tok = msac.symbol(
        cdf,
        cdf_row(cdf, base + coef_eob_base_tok, eob_tok_base + ctx),
        2,
      ) +
      1
    let mut level_tok = tok * 0x41
    if tok == 3 {
      ctx = if tx_class == tx_class_2d {
        if (x | y) > 1 {
          14
        } else {
          7
        }
      } else if y != 0 {
        14
      } else {
        7
      }
      tok = msac.hi_tok(cdf, cdf_row(cdf, base + coef_br_tok, hi_base + ctx))
      level_tok = tok + (3 << 6)
    }
    cf[rc] = tok << 11
    let mut level_at = if tx_class == tx_class_2d { rc } else { x * stride + y }
    levels[level_at] = level_tok
    let mut i = eob - 1
    while i > 0 {
      let mut rc_i = 0
      if tx_class == tx_class_2d {
        rc_i = itx_scans[scan_at + i]
        x = rc_i >> shift
        y = rc_i & mask
      } else if tx_class == tx_class_h {
        x = i & mask
        y = i >> shift
        rc_i = i
      } else {
        x = i & mask
        y = i >> shift
        rc_i = (x << shift2) | y
      }
      level_at = if tx_class == tx_class_2d { rc_i } else { x * stride + y }
      let (lo, hint) = lo_ctx(levels, tx_class, x, y, stride, table)
      let indexed_y = if tx_class == tx_class_2d { y | x } else { y }
      tok = msac.symbol(
        cdf,
        cdf_row(cdf, base + coef_base_tok, lo_base + lo),
        3,
      )
      if tok == 3 {
        let mag = hint & 63
        ctx = (if indexed_y > (if tx_class == tx_class_2d { 1 } else { 0 }) {
            14
          } else {
            7
          }) +
          (if mag > 12 { 6 } else { (mag + 1) >> 1 })
        tok = msac.hi_tok(cdf, cdf_row(cdf, base + coef_br_tok, hi_base + ctx))
        levels[level_at] = tok + (3 << 6)
        cf[rc_i] = (tok << 11) | rc
        rc = rc_i
      } else {
        levels[level_at] = tok * 0x41
        if tok != 0 {
          cf[rc_i] = (tok << 11) | rc
          rc = rc_i
        } else {
          cf[rc_i] = 0
        }
      }
      i = i - 1
    }
    // dc
    ctx = if tx_class == tx_class_2d {
      0
    } else {
      let (lo, _) = lo_ctx(levels, tx_class, 0, 0, stride, table)
      lo
    }
    dc_tok = msac.symbol(
      cdf,
      cdf_row(cdf, base + coef_base_tok, lo_base + ctx),
      3,
    )
    if dc_tok == 3 {
      let mut mag = 0
      if tx_class == tx_class_2d {
        mag = levels[1] + levels[stride] + levels[stride + 1]
      }
      mag = mag & 63
      ctx = if mag > 12 { 6 } else { (mag + 1) >> 1 }
      dc_tok = msac.hi_tok(cdf, cdf_row(cdf, base + coef_br_tok, hi_base + ctx))
    }
  } else {
    // The DC-only case reads the first context of this block's group: there is
    // no end of block to place, so the end-of-block token's context is nought.
    let tok_br = msac.symbol(
      cdf,
      cdf_row(cdf, base + coef_eob_base_tok, eob_cdf_row),
      2,
    )
    dc_tok = 1 + tok_br
    if tok_br == 2 {
      dc_tok = msac.hi_tok(cdf, cdf_row(cdf, base + coef_br_tok, hi_base))
    }
  }

  // Residual and sign.
  let dq_shift = if t_dim_ctx > 2 { t_dim_ctx - 2 } else { 0 }
  // The reference's expression is ~(~127 << 8), which at eight bits is the
  // largest positive value a signed sixteen-bit coefficient holds: a
  // coefficient is not clamped to a sample, it is clamped to what the transform
  // will read.
  let cf_max = 32767
  let mut cul_level = 0
  let mut dc_sign_level = 0

  if dc_tok != 0 {
    let dc_sign_ctx = get_dc_sign_ctx(tx, a, a_at, l, l_at)
    let dc_sign = msac.bool_adapt(
      cdf,
      cdf_row(cdf, base + coef_dc_sign, chroma_bit * 3 + dc_sign_ctx),
    )
    dc_sign_level = (dc_sign - 1) & (2 << 6)
    let mut dc_dq = dq_dc
    if qm_at >= 0 {
      dc_dq = (dc_dq * qm_all[qm_at] + 16) >> 5
      if dc_tok == 15 {
        dc_tok = read_golomb(msac) + 15
        dc_tok = dc_tok & 0xFFFFF
        dc_dq = (dc_dq * dc_tok) & 0xFFFFFF
      } else {
        dc_dq = dc_dq * dc_tok
      }
      dc_dq = dc_dq >> dq_shift
      if dc_dq > cf_max + dc_sign {
        dc_dq = cf_max + dc_sign
      }
      cf[0] = if dc_sign == 1 { -dc_dq } else { dc_dq }
    } else {
      if dc_tok == 15 {
        dc_tok = read_golomb(msac) + 15
        dc_tok = dc_tok & 0xFFFFF
        dc_dq = ((dc_dq * dc_tok) & 0xFFFFFF) >> dq_shift
      } else {
        dc_dq = (dc_dq * dc_tok) >> dq_shift
      }
      if dc_dq > cf_max + dc_sign {
        dc_dq = cf_max + dc_sign
      }
      cf[0] = if dc_sign == 1 { -dc_dq } else { dc_dq }
    }
    cul_level = dc_tok
  } else {
    // The DC token was zero, so the coefficient is: the reference leaves the
    // slot alone and relies on the buffer being clear, which is a thing a
    // decoder that shares one buffer between blocks cannot rely on.
    cf[0] = 0
    dc_sign_level = 1 << 6
  }

  // The coefficients that are not zero, walked from the lowest one up: each
  // holds the position of the next one, so the run is followed rather than
  // searched. This runs whether or not there was a DC, because the two are
  // independent tokens.
  while rc != 0 {
    let sign = msac.bool_equi()
    let rc_tok = cf[rc]
    let mut tok = 0
    let mut dq = if qm_at >= 0 {
      (dq_ac * qm_all[qm_at + rc] + 16) >> 5
    } else {
      0
    }
    if qm_at >= 0 {
      if rc_tok >= 15 << 11 {
        tok = read_golomb(msac) + 15
        tok = tok & 0xFFFFF
        dq = (dq * tok) & 0xFFFFFF
      } else {
        tok = rc_tok >> 11
        dq = dq * tok
      }
      dq = dq >> dq_shift
      if dq > cf_max + sign {
        dq = cf_max + sign
      }
    } else if rc_tok >= 15 << 11 {
      tok = read_golomb(msac) + 15
      tok = tok & 0xFFFFF
      dq = ((dq_ac * tok) & 0xFFFFFF) >> dq_shift
      if dq > cf_max + sign {
        dq = cf_max + sign
      }
    } else {
      tok = rc_tok >> 11
      dq = (dq_ac * tok) >> dq_shift
    }
    cul_level = cul_level + tok
    cf[rc] = if sign == 1 { -dq } else { dq }
    rc = rc_tok & 0x3FF
  }
  {
    eob,
    txtp,
    ctx: (if cul_level > 63 { 63 } else { cul_level }) | dc_sign_level,
  }
}
