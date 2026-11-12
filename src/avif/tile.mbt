// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The tile: the partition tree, the block syntax under it, and the samples the
// blocks end up holding.
//
// A tile is decoded as a tree of partitions. Each superblock is asked how it
// divides — in half across, in half down, into four, into ten — and each of the
// pieces is asked the same question until the pieces are small enough or it says
// no. Only then is a block's own syntax read: whether it has coefficients at
// all, how it is predicted, which transform it uses, and what those coefficients
// are.
//
// The neighbours are what most of that syntax is conditioned on, so they are
// kept the way the reference keeps them: one set of arrays for the row above and
// one for the column to the left, indexed by the position within the current
// hundred and twenty-eight pixels, and reset at the start of every superblock
// row on the left and every frame on the top.
//
// A prediction may read a neighbour only if that neighbour has already been
// reconstructed, and "already" is not a property of the frame but of the decode
// order: the block above and to the right of a block in the same superblock is
// decoded after it, so it is not an edge. The reference carries that around in a
// tree of edge flags threaded through the partition recursion; here it is kept
// as one bit per four-pixel square, set as each transform block is written, which
// is the same information and cannot get out of step with the samples.

///|
/// The neighbour state along one edge of the block being decoded.
pub(all) struct Ctx {
  mode : FixedArray[Int32]
  lcoef : FixedArray[Int32]
  ccoef0 : FixedArray[Int32]
  ccoef1 : FixedArray[Int32]
  seg_pred : FixedArray[Int32]
  skip : FixedArray[Int32]
  skip_mode : FixedArray[Int32]
  intra : FixedArray[Int32]
  tx_intra : FixedArray[Int32]
  tx : FixedArray[Int32]
  uvmode : FixedArray[Int32]
  pal_sz : FixedArray[Int32]
  partition : FixedArray[Int32]
}

///|
fn Ctx::new() -> Ctx {
  {
    mode: FixedArray::make(32, 0),
    lcoef: FixedArray::make(32, 0x40),
    ccoef0: FixedArray::make(32, 0x40),
    ccoef1: FixedArray::make(32, 0x40),
    seg_pred: FixedArray::make(32, 0),
    skip: FixedArray::make(32, 0),
    skip_mode: FixedArray::make(32, 0),
    intra: FixedArray::make(32, 1),
    tx_intra: FixedArray::make(32, -1),
    tx: FixedArray::make(32, 4),
    uvmode: FixedArray::make(32, 0),
    pal_sz: FixedArray::make(32, 0),
    partition: FixedArray::make(16, 0),
  }
}

///|
fn Ctx::reset(self : Ctx) -> Unit {
  for i in 0..<32 {
    self.mode[i] = 0
    self.lcoef[i] = 0x40
    self.ccoef0[i] = 0x40
    self.ccoef1[i] = 0x40
    self.seg_pred[i] = 0
    self.skip[i] = 0
    self.skip_mode[i] = 0
    self.intra[i] = 1
    self.tx_intra[i] = -1
    self.tx[i] = 4
    self.uvmode[i] = 0
    self.pal_sz[i] = 0
  }
  for i in 0..<16 {
    self.partition[i] = 0
  }
}

///|
/// Everything one tile's decoding needs: the bit reader, the frame's copy of the
/// probability tables, the samples, and the state of the block being read.
pub(all) struct Tile {
  msac : Msac
  cdf : FixedArray[Int32]
  fb : FrameBuffer
  seq : Sequence
  frame : Frame
  bw : Int32
  bh : Int32
  mut bx : Int32
  mut by : Int32
  above : Array[Ctx]
  left : Ctx
  decoded_y : FixedArray[Int32]
  decoded_uv : FixedArray[Int32]
  cf : FixedArray[Int32]
  levels : FixedArray[Int32]
  edges : FixedArray[Byte]
  block : FixedArray[Byte]
  ac : FixedArray[Int32]
  dq : FixedArray[Int32]
  txw_map : FixedArray[Int32]
  txh_map : FixedArray[Int32]
  uv_txw_map : FixedArray[Int32]
  uv_txh_map : FixedArray[Int32]
  cdef_map : FixedArray[Int32]
  skip_map : FixedArray[Int32]
  lf_v_map : FixedArray[Int32]
  lf_h_map : FixedArray[Int32]
  lf_u_map : FixedArray[Int32]
  lf_w_map : FixedArray[Int32]
  mut last_qidx : Int32
  last_delta_lf : FixedArray[Int32]
  lf : FixedArray[Int32]
  mut skip : Bool
  mut y_mode : Int32
  mut y_angle : Int32
  mut uv_mode : Int32
  mut uv_angle : Int32
  mut tx : Int32
  mut uvtx : Int32
  mut cfl_alpha : FixedArray[Int32]
  mut seg_pred : Int32
  mut pal_sz_y : Int32
  mut pal_sz_uv : Int32
  mut cdef_idx : FixedArray[Int32]
  mut cdef_at : Int32
}

///|
fn Tile::new(
  data : BytesView,
  fb : FrameBuffer,
  seq : Sequence,
  frame : Frame,
  cdf : FixedArray[Int32],
  allow_update : Bool,
) -> Tile {
  let bw = (fb.width + 3) >> 2
  let bh = (fb.height + 3) >> 2
  let across = ((bw + 31) >> 5) + 1
  let above : Array[Ctx] = []
  for _ in 0..<across {
    above.push(Ctx::new())
  }
  let uv_bw = ((bw + fb.ss_hor) >> fb.ss_hor) + 1
  let uv_bh = ((bh + fb.ss_ver) >> fb.ss_ver) + 1
  {
    msac: Msac::new(data, allow_update~),
    cdf,
    fb,
    seq,
    frame,
    bw,
    bh,
    bx: 0,
    by: 0,
    above,
    left: Ctx::new(),
    decoded_y: FixedArray::make(bw * bh + 64, 0),
    decoded_uv: FixedArray::make(uv_bw * uv_bh + 64, 0),
    cf: FixedArray::make(1024, 0),
    levels: FixedArray::make(32 * 34, 0),
    edges: FixedArray::make(2 * edge_corner + 8, b'\x00'),
    block: FixedArray::make(64 * 64, b'\x00'),
    ac: FixedArray::make(32 * 32, 0),
    dq: quantiser(seq, frame),
    txw_map: FixedArray::make(bw * bh + 64, 0),
    txh_map: FixedArray::make(bw * bh + 64, 0),
    uv_txw_map: FixedArray::make(uv_bw * uv_bh + 64, 0),
    uv_txh_map: FixedArray::make(uv_bw * uv_bh + 64, 0),
    cdef_map: FixedArray::make(bw * bh + 64, 0),
    skip_map: FixedArray::make(bw * bh + 64, 1),
    lf_v_map: FixedArray::make(bw * bh + 64, 0),
    lf_h_map: FixedArray::make(bw * bh + 64, 0),
    lf_u_map: FixedArray::make(bw * bh + 64, 0),
    lf_w_map: FixedArray::make(bw * bh + 64, 0),
    last_qidx: frame.yac,
    last_delta_lf: FixedArray::make(4, 0),
    lf: FixedArray::from_array([
      frame.lf_y0,
      frame.lf_y1,
      frame.lf_u,
      frame.lf_v,
    ]),
    skip: false,
    y_mode: 0,
    y_angle: 0,
    uv_mode: 0,
    uv_angle: 0,
    tx: 0,
    uvtx: 0,
    cfl_alpha: FixedArray::make(2, 0),
    seg_pred: 0,
    pal_sz_y: 0,
    pal_sz_uv: 0,
    cdef_idx: FixedArray::make(4, -1),
    cdef_at: 0,
  }
}

///|
/// The quantiser's two values for each plane, at the frame's quantiser index.
fn quantiser(seq : Sequence, frame : Frame) -> FixedArray[Int32] {
  quantiser_at(seq, frame, frame.yac)
}

///|
/// The same at one superblock's index, which a frame with deltas may move.
fn quantiser_at(
  seq : Sequence,
  frame : Frame,
  index : Int32,
) -> FixedArray[Int32] {
  let hbd = if seq.hbd != 0 { 1 } else { 0 }
  let yac = index
  let ydc = clip_q(yac + frame.ydc_delta)
  let udc = clip_q(yac + frame.udc_delta)
  let uac = clip_q(yac + frame.uac_delta)
  let vdc = clip_q(yac + frame.vdc_delta)
  let vac = clip_q(yac + frame.vac_delta)
  let base = hbd * 512
  FixedArray::from_array([
    dq_tbl[base + ydc * 2],
    dq_tbl[base + yac * 2 + 1],
    dq_tbl[base + udc * 2],
    dq_tbl[base + uac * 2 + 1],
    dq_tbl[base + vdc * 2],
    dq_tbl[base + vac * 2 + 1],
  ])
}

///|
/// One filter level after a superblock's delta.
fn filter_level(base : Int32, delta : Int32) -> Int32 {
  let value = base + delta
  if value < 0 {
    0
  } else if value > 63 {
    63
  } else {
    value
  }
}

///|
fn clip_q(value : Int32) -> Int32 {
  if value < 0 {
    0
  } else if value > 255 {
    255
  } else {
    value
  }
}

///|
/// Where the matrix of a plane's transform begins, or -1 when the frame does
/// not weight it.
fn qm_offset(frame : Frame, plane : Int32, tx : Int32) -> Int32 {
  let level = if plane == 0 {
    frame.qm_y
  } else if plane == 1 {
    frame.qm_u
  } else {
    frame.qm_v
  }
  if level == 0 {
    return -1
  }
  let variant = if plane == 0 { 0 } else { 1 }
  qm_index[(level * 2 + variant) * 19 + tx]
}

///|
/// The symbol of one syntax element, from the row its context names.
fn sym(t : Tile, element : Int32, context : Int32, n : Int32) -> Int32 {
  let at = cdf_row(t.cdf, element, context)
  if at < 0 || at + n >= t.cdf.length() || context < 0 {
    abort("cdf row out of range: element \{element} context \{context}")
  }
  t.msac.symbol(t.cdf, at, n)
}

///|
fn bit_sym(t : Tile, element : Int32, context : Int32) -> Int32 {
  t.msac.bool_adapt(t.cdf, cdf_row(t.cdf, element, context))
}

///|
/// The neighbour state above the column the block starts at.
fn above_of(t : Tile, bx : Int32) -> Ctx {
  t.above[bx >> 5]
}

///|
fn min_i32(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn max_i32(a : Int32, b : Int32) -> Int32 {
  if a > b {
    a
  } else {
    b
  }
}

///|
/// Whether the given four-pixel square of a plane has been reconstructed.
fn marked(
  bitmap : FixedArray[Int32],
  across : Int32,
  x : Int32,
  y : Int32,
) -> Bool {
  if x < 0 || y < 0 || x >= across {
    return false
  }
  let at = y * across + x
  if at < 0 || at >= bitmap.length() {
    return false
  }
  bitmap[at] != 0
}

///|
fn mark(
  bitmap : FixedArray[Int32],
  across : Int32,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
) -> Unit {
  for yy in 0..<h {
    for xx in 0..<w {
      let at = (y + yy) * across + x + xx
      if at >= 0 && at < bitmap.length() {
        bitmap[at] = 1
      }
    }
  }
}

///|
/// The context a partition's neighbours put it in.
fn partition_ctx(t : Tile, bl : Int32) -> Int32 {
  let bx8 = (t.bx & 31) >> 1
  let by8 = (t.by & 31) >> 1
  let above = above_of(t, t.bx).partition[bx8]
  let left = t.left.partition[by8]
  ((above >> (4 - bl)) & 1) + (((left >> (4 - bl)) & 1) << 1)
}

///|
/// The probability that a block with only one way to split takes it, gathered
/// from the entries of the partition distribution that describe the halves: the
/// three that separate the two together from the rest, and the one that
/// separates the four-way split.
fn gather_top_prob(t : Tile, bl : Int32) -> Int32 {
  let at = cdf_row(t.cdf, CDF_M_PARTITION, bl * 4 + partition_ctx(t, bl))
  let cdf = t.cdf
  // The block is cut across when it takes the horizontal partition, the split
  // or one of the two T shapes that put two halves on top; the entries of a
  // cumulative distribution make that the difference between the first of those
  // and the one past the last.
  let mut out = cdf[at + 1] - cdf[at + 5]
  out = out + cdf[at + 5]
  if bl != 0 {
    out = out + cdf[at + 8] - cdf[at + 7]
  }
  out
}

///|
fn gather_left_prob(t : Tile, bl : Int32) -> Int32 {
  let at = cdf_row(t.cdf, CDF_M_PARTITION, bl * 4 + partition_ctx(t, bl))
  let cdf = t.cdf
  let mut out = cdf[at] - cdf[at + 1]
  out = out + cdf[at + 2] - cdf[at + 6]
  if bl != 0 {
    out = out + cdf[at + 8] - cdf[at + 9]
  }
  out
}

///|
/// Read one partition and everything under it.
fn decode_sb(t : Tile, bl : Int32) -> Unit raise @raster.Refused {
  let hsz = 16 >> bl
  let have_h_split = t.bw > t.bx + hsz
  let have_v_split = t.bh > t.by + hsz
  if !have_h_split && !have_v_split {
    decode_sb(t, bl + 1)
    return
  }

  let mut bp = 0
  if have_h_split && have_v_split {
    bp = sym(
      t,
      CDF_M_PARTITION,
      bl * 4 + partition_ctx(t, bl),
      partition_type_count[bl],
    )
  } else if have_h_split {
    // Only a cut across is possible, so the stream carries one bit: whether the
    // block splits into two superblocks side by side or is one block.
    let split = t.msac.bool(gather_top_prob(t, bl))
    bp = if split == 1 { 3 } else { 1 }
  } else {
    let split = t.msac.bool(gather_left_prob(t, bl))
    bp = if split == 1 { 3 } else { 2 }
  }

  let bs = block_sizes[(bl * 10 + bp) * 2]
  if bp == 0 {
    decode_b(t, bs, bp)
  } else if bp == 1 {
    decode_b(t, bs, bp)
    t.by = t.by + hsz
    decode_b(t, bs, bp)
    t.by = t.by - hsz
  } else if bp == 2 {
    decode_b(t, bs, bp)
    t.bx = t.bx + hsz
    decode_b(t, bs, bp)
    t.bx = t.bx - hsz
  } else if bp == 3 {
    if bl == 4 {
      decode_b(t, bs, bp)
      t.bx = t.bx + 1
      decode_b(t, bs, bp)
      t.bx = t.bx - 1
      t.by = t.by + 1
      decode_b(t, bs, bp)
      t.bx = t.bx + 1
      decode_b(t, bs, bp)
      t.bx = t.bx - 1
      t.by = t.by - 1
    } else {
      decode_sb(t, bl + 1)
      t.bx = t.bx + hsz
      decode_sb(t, bl + 1)
      t.bx = t.bx - hsz
      t.by = t.by + hsz
      decode_sb(t, bl + 1)
      t.bx = t.bx + hsz
      decode_sb(t, bl + 1)
      t.bx = t.bx - hsz
      t.by = t.by - hsz
    }
  } else if bp == 4 {
    // Two blocks across the top, one under them.
    let upper = block_sizes[bl * 10 * 2]
    decode_b(t, upper, bp)
    t.bx = t.bx + hsz
    decode_b(t, upper, bp)
    t.bx = t.bx - hsz
    t.by = t.by + hsz
    decode_b(t, block_sizes[(bl * 10 + 1) * 2], bp)
    t.by = t.by - hsz
  } else if bp == 5 {
    decode_b(t, block_sizes[(bl * 10 + 1) * 2], bp)
    t.by = t.by + hsz
    let lower = block_sizes[bl * 10 * 2]
    decode_b(t, lower, bp)
    t.bx = t.bx + hsz
    decode_b(t, lower, bp)
    t.bx = t.bx - hsz
    t.by = t.by - hsz
  } else if bp == 6 {
    let side = block_sizes[(bl * 10 + 2) * 2]
    decode_b(t, side, bp)
    t.by = t.by + hsz
    decode_b(t, side, bp)
    t.by = t.by - hsz
    t.bx = t.bx + hsz
    decode_b(t, block_sizes[(bl * 10 + 2) * 2], bp)
    t.bx = t.bx - hsz
  } else if bp == 7 {
    decode_b(t, block_sizes[(bl * 10 + 2) * 2], bp)
    t.bx = t.bx + hsz
    let side = block_sizes[(bl * 10 + 2) * 2]
    decode_b(t, side, bp)
    t.by = t.by + hsz
    decode_b(t, side, bp)
    t.by = t.by - hsz
    t.bx = t.bx - hsz
  } else if bp == 8 {
    let quarter = hsz >> 1
    for i in 0..<4 {
      t.by = t.by + quarter * i
      if t.by < t.bh {
        decode_b(t, bs, bp)
      }
      t.by = t.by - quarter * i
    }
  } else if bp == 9 {
    let quarter = hsz >> 1
    for i in 0..<4 {
      t.bx = t.bx + quarter * i
      if t.bx < t.bw {
        decode_b(t, bs, bp)
      }
      t.bx = t.bx - quarter * i
    }
  }
  if bp != 3 || bl == 4 {
    let slot_above = al_part_ctx[bl * 10 + bp]
    let slot_left = al_part_ctx[50 + bl * 10 + bp]
    let bx8 = (t.bx & 31) >> 1
    let by8 = (t.by & 31) >> 1
    for i in 0..<hsz {
      if bx8 + i < 16 && slot_above >= 0 {
        above_of(t, t.bx).partition[bx8 + i] = slot_above
      }
      if by8 + i < 16 && slot_left >= 0 {
        t.left.partition[by8 + i] = slot_left
      }
    }
  }
}

///|
/// The transform type of a luma block, as the reference names it when it maps a
/// filter-intra index back to a mode.
fn filter_mode_of(index : Int32) -> Int32 {
  filter_mode_to_y_mode[index & 7]
}

///|
/// Decode one block: its syntax, its samples, and its neighbours' record of it.
fn decode_b(t : Tile, bs : Int32, bp : Int32) -> Unit raise @raster.Refused {
  ignore(bp)
  let bw4 = block_dimensions[bs * 4]
  let bh4 = block_dimensions[bs * 4 + 1]
  let w4 = min_i32(bw4, t.bw - t.bx)
  let h4 = min_i32(bh4, t.bh - t.by)
  let ss_hor = t.fb.ss_hor
  let ss_ver = t.fb.ss_ver
  let bx4 = t.bx & 31
  let by4 = t.by & 31
  let cbx4 = bx4 >> ss_hor
  let cby4 = by4 >> ss_ver
  let cbw4 = (bw4 + ss_hor) >> ss_hor
  let cbh4 = (bh4 + ss_ver) >> ss_ver
  let has_chroma = !t.fb.monochrome &&
    (bw4 > ss_hor || (t.bx & 1) != 0) &&
    (bh4 > ss_ver || (t.by & 1) != 0)

  // Whether the block has any coefficients.
  let sctx = above_of(t, t.bx).skip[bx4] + t.left.skip[by4]
  t.skip = bit_sym(t, CDF_M_SKIP, sctx) == 1

  // The strength index CDEF filters this part of the superblock with, read once
  // per sixty-four pixel square of it.
  if !t.skip {
    let index = if t.seq.sb128 {
      ((t.bx & 16) >> 4) + ((t.by & 16) >> 3)
    } else {
      0
    }
    if t.cdef_idx[index] == -1 {
      let value = t.msac.bools(t.frame.cdef_bits)
      t.cdef_idx[index] = value
      if bw4 > 16 {
        t.cdef_idx[index + 1] = value
      }
      if bh4 > 16 {
        t.cdef_idx[index + 2] = value
      }
      if bw4 == 32 && bh4 == 32 {
        t.cdef_idx[index + 3] = value
      }
    }
    let value = t.cdef_idx[index]
    mark_value(t.cdef_map, t.bw, t.bx, t.by, w4, h4, value)
    mark_value(t.skip_map, t.bw, t.bx, t.by, w4, h4, 0)
  }

  // A superblock may carry its own quantiser and filter levels, read once at its
  // first block and applied to everything in it.
  if ((t.bx | t.by) & (31 >> (if t.seq.sb128 { 0 } else { 1 }))) == 0 {
    let sb_size = if t.seq.sb128 { 1 } else { 3 }
    let have_delta = t.frame.delta_q_present && (bs != sb_size || !t.skip)
    if have_delta {
      let mut delta_q = sym(t, CDF_M_DELTA_Q, 0, 3)
      if delta_q == 3 {
        let n_bits = 1 + t.msac.bools(3)
        delta_q = t.msac.bools(n_bits) + 1 + (1 << n_bits)
      }
      if delta_q != 0 {
        if t.msac.bool_equi() == 1 {
          delta_q = -delta_q
        }
        delta_q = delta_q * (1 << t.frame.delta_q_res)
      }
      t.last_qidx = clip_q(t.last_qidx + delta_q)
      if t.last_qidx < 1 {
        t.last_qidx = 1
      }
      if t.frame.delta_lf_present {
        let count = if t.frame.delta_lf_multi {
          if t.fb.monochrome {
            2
          } else {
            4
          }
        } else {
          1
        }
        let offset = if t.frame.delta_lf_multi { 1 } else { 0 }
        for i in 0..<count {
          let mut delta = sym(t, CDF_M_DELTA_LF, i + offset, 3)
          if delta == 3 {
            let n_bits = 1 + t.msac.bools(3)
            delta = t.msac.bools(n_bits) + 1 + (1 << n_bits)
          }
          if delta != 0 {
            if t.msac.bool_equi() == 1 {
              delta = -delta
            }
            delta = delta * (1 << t.frame.delta_lf_res)
          }
          let mut value = t.last_delta_lf[i] + delta
          if value < -63 {
            value = -63
          } else if value > 63 {
            value = 63
          }
          t.last_delta_lf[i] = value
        }
      }
      if t.last_qidx != t.frame.yac {
        let dq = quantiser_at(t.seq, t.frame, t.last_qidx)
        for i in 0..<6 {
          t.dq[i] = dq[i]
        }
      } else {
        let dq = quantiser(t.seq, t.frame)
        for i in 0..<6 {
          t.dq[i] = dq[i]
        }
      }
    }
    // The filter levels of this superblock: the frame's, shifted by whatever
    // deltas the superblock carried.
    let multi = t.frame.delta_lf_multi
    t.lf[0] = filter_level(t.frame.lf_y0, t.last_delta_lf[0])
    t.lf[1] = filter_level(
      t.frame.lf_y1,
      t.last_delta_lf[if multi { 1 } else { 0 }],
    )
    t.lf[2] = filter_level(
      t.frame.lf_u,
      t.last_delta_lf[if multi { 2 } else { 0 }],
    )
    t.lf[3] = filter_level(
      t.frame.lf_v,
      t.last_delta_lf[if multi { 3 } else { 0 }],
    )
  }
  mark_value(t.lf_v_map, t.bw, t.bx, t.by, w4, h4, t.lf[0])
  mark_value(t.lf_h_map, t.bw, t.bx, t.by, w4, h4, t.lf[1])
  mark_value(t.lf_u_map, t.bw, t.bx, t.by, w4, h4, t.lf[2])
  mark_value(t.lf_w_map, t.bw, t.bx, t.by, w4, h4, t.lf[3])
  if t.frame.mode_ref_delta_enabled {
    raise @raster.Unsupported(
      at=0,
      got="a frame with mode and reference filter deltas",
    )
  }
  // The block's mode.
  let ymode_ctx = intra_mode_context[above_of(t, t.bx).mode[bx4]] * 5 +
    intra_mode_context[t.left.mode[by4]]
  t.y_mode = sym(t, CDF_KFYM, ymode_ctx, 12)
  t.y_angle = 0
  if block_dimensions[bs * 4 + 2] + block_dimensions[bs * 4 + 3] >= 2 &&
    t.y_mode >= 1 &&
    t.y_mode <= 8 {
    t.y_angle = sym(t, CDF_M_ANGLE_DELTA, t.y_mode - 1, 6) - 3
  }
  t.uv_mode = 0
  t.uv_angle = 0
  t.cfl_alpha[0] = 0
  t.cfl_alpha[1] = 0
  if has_chroma {
    let cfl_allowed = if t.frame.all_lossless {
      cbw4 == 1 && cbh4 == 1
    } else {
      ((cfl_allowed_mask >> bs) & 1) != 0
    }
    let cfl_bit = if cfl_allowed { 1 } else { 0 }
    t.uv_mode = sym(t, CDF_M_UV_MODE, cfl_bit * 13 + t.y_mode, 12 + cfl_bit)
    if t.uv_mode == 13 {
      let sign = sym(t, CDF_M_CFL_SIGN, 0, 7) + 1
      let sign_u = (sign * 0x56) >> 8
      let sign_v = sign - sign_u * 3
      if sign_u != 0 {
        let ctx = (if sign_u == 2 { 3 } else { 0 }) + sign_v
        let alpha = sym(t, CDF_M_CFL_ALPHA, ctx, 15) + 1
        t.cfl_alpha[0] = if sign_u == 1 { -alpha } else { alpha }
      }
      if sign_v != 0 {
        let ctx = (if sign_v == 2 { 3 } else { 0 }) + sign_u
        let alpha = sym(t, CDF_M_CFL_ALPHA, ctx, 15) + 1
        t.cfl_alpha[1] = if sign_v == 1 { -alpha } else { alpha }
      }
    } else if block_dimensions[bs * 4 + 2] + block_dimensions[bs * 4 + 3] >= 2 &&
      t.uv_mode >= 1 &&
      t.uv_mode <= 8 {
      t.uv_angle = sym(t, CDF_M_ANGLE_DELTA, t.uv_mode - 1, 6) - 3
    }
  }

  // A palette is a screen-content tool: the mode is refused by name rather than
  // decoded into a picture that would be missing its colours.
  t.pal_sz_y = 0
  t.pal_sz_uv = 0
  if t.frame.allow_screen_content && max_i32(bw4, bh4) <= 16 && bw4 + bh4 >= 4 {
    let sz_ctx = block_dimensions[bs * 4 + 2] + block_dimensions[bs * 4 + 3] - 2
    if t.y_mode == 0 {
      let pal_ctx = (if above_of(t, t.bx).pal_sz[bx4] > 0 { 1 } else { 0 }) +
        (if t.left.pal_sz[by4] > 0 { 1 } else { 0 })
      if bit_sym(t, CDF_M_PAL_Y, sz_ctx * 3 + pal_ctx) == 1 {
        raise @raster.Unsupported(at=0, got="a block with a luma palette")
      }
    }
    if has_chroma && t.uv_mode == 0 {
      if bit_sym(t, CDF_M_PAL_UV, 0) == 1 {
        raise @raster.Unsupported(at=0, got="a block with a chroma palette")
      }
    }
  }
  // Filter intra, which replaces the DC prediction on a small block.
  if t.y_mode == 0 &&
    max_i32(block_dimensions[bs * 4 + 2], block_dimensions[bs * 4 + 3]) <= 3 &&
    t.seq.filter_intra {
    if bit_sym(t, CDF_M_USE_FILTER_INTRA, bs) == 1 {
      t.y_mode = 13
      t.y_angle = sym(t, CDF_M_FILTER_INTRA, 0, 4)
    }
  }

  // The transform size. A block is covered by one grid of transforms, not a
  // tree: what the symbol chooses is how far below the block's largest
  // transform the grid goes.
  if t.frame.all_lossless {
    t.tx = 0
    t.uvtx = 0
  } else {
    t.tx = max_txfm_size_for_bs[bs * 4]
    t.uvtx = max_txfm_size_for_bs[bs * 4 + 1]
    if t.frame.txfm_mode == 2 && txfm_max[t.tx] > 0 {
      let ctx = (if t.left.tx_intra[by4] >= txfm_lh[t.tx] { 1 } else { 0 }) +
        (if above_of(t, t.bx).tx_intra[bx4] >= txfm_lw[t.tx] { 1 } else { 0 })
      let limit = min_i32(txfm_max[t.tx], 2)
      let mut depth = sym(t, CDF_M_TXSZ, (txfm_max[t.tx] - 1) * 3 + ctx, limit)
      while depth > 0 {
        t.tx = txfm_sub[t.tx]
        depth = depth - 1
      }
    }
  }
  reconstruct_luma(t, bs, w4, h4)
  if has_chroma {
    reconstruct_chroma(t, bs, w4, h4)
  }

  // The neighbours now know what this block was.
  let y_mode_nofilt = if t.y_mode == 13 {
    filter_mode_of(t.y_angle)
  } else {
    t.y_mode
  }
  let above = above_of(t, t.bx)
  for i in 0..<w4 {
    above.tx_intra[bx4 + i] = txfm_lw[t.tx]
    above.tx[bx4 + i] = txfm_lw[t.tx]
    above.mode[bx4 + i] = y_mode_nofilt
    above.pal_sz[bx4 + i] = t.pal_sz_y
    above.skip_mode[bx4 + i] = 0
    above.intra[bx4 + i] = 1
    above.skip[bx4 + i] = if t.skip { 1 } else { 0 }
    above.seg_pred[bx4 + i] = t.seg_pred
  }
  for i in 0..<h4 {
    t.left.tx_intra[by4 + i] = txfm_lh[t.tx]
    t.left.tx[by4 + i] = txfm_lh[t.tx]
    t.left.mode[by4 + i] = y_mode_nofilt
    t.left.pal_sz[by4 + i] = t.pal_sz_y
    t.left.skip_mode[by4 + i] = 0
    t.left.intra[by4 + i] = 1
    t.left.skip[by4 + i] = if t.skip { 1 } else { 0 }
    t.left.seg_pred[by4 + i] = t.seg_pred
  }
  if has_chroma {
    let above2 = above_of(t, t.bx)
    for i in 0..<cbw4 {
      above2.uvmode[cbx4 + i] = t.uv_mode
    }
    for i in 0..<cbh4 {
      t.left.uvmode[cby4 + i] = t.uv_mode
    }
  }
}

///|
fn mark_value(
  map : FixedArray[Int32],
  across : Int32,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
  value : Int32,
) -> Unit {
  for yy in 0..<h {
    for xx in 0..<w {
      let at = (y + yy) * across + x + xx
      if at >= 0 && at < map.length() {
        map[at] = value
      }
    }
  }
}

///|
/// Predict and reconstruct the luma of a block, transform by transform.
fn reconstruct_luma(t : Tile, bs : Int32, w4 : Int32, h4 : Int32) -> Unit {
  let txw = txfm_w[t.tx]
  let txh = txfm_h[t.tx]
  let bx = t.bx
  let by = t.by
  let mut y = 0
  while y < h4 {
    let mut x = 0
    while x < w4 {
      let px = (bx + x) << 2
      let py = (by + y) << 2
      let lw = min_i32(2, txfm_lw[t.tx])
      let lh = min_i32(2, txfm_lh[t.tx])
      mark_value(t.txw_map, t.bw, bx + x, by + y, txw, txh, lw)
      mark_value(t.txh_map, t.bw, bx + x, by + y, txw, txh, lh)
      reconstruct_one(
        t,
        0,
        px,
        py,
        x,
        y,
        txw,
        txh,
        t.y_mode,
        t.y_angle,
        t.tx,
        bs,
        t.bw,
        t.decoded_y,
      )
      x = x + txw
    }
    y = y + txh
  }
}

///|
/// One transform block of one plane: predict it, then add what the coefficients
/// say.
fn reconstruct_one(
  t : Tile,
  plane_index : Int32,
  px : Int32,
  py : Int32,
  x_off : Int32,
  y_off : Int32,
  tw4 : Int32,
  th4 : Int32,
  mode : Int32,
  angle : Int32,
  tx : Int32,
  bs : Int32,
  across : Int32,
  bitmap : FixedArray[Int32],
) -> Unit {
  let plane = plane_of(t, plane_index)
  let tw = tw4 << 2
  let th = th4 << 2
  let bx4 = (px >> 2) + tw4
  let by4 = (py >> 2) + th4
  let have_top = py > 0
  let have_left = px > 0
  let have_topright = marked(bitmap, across, bx4, (py >> 2) - 1)
  let have_bottomleft = marked(bitmap, across, (px >> 2) - 1, by4)
  let above = above_of(t, t.bx)
  let sm = if plane_index == 0 {
    (if smooth_mode(above, (px >> 2) & 31) { 512 } else { 0 }) |
    (if smooth_mode(t.left, (py >> 2) & 31) { 512 } else { 0 })
  } else {
    (if smooth_uv(above, (px >> t.fb.ss_hor) & 31) { 512 } else { 0 }) |
    (if smooth_uv(t.left, (py >> t.fb.ss_ver) & 31) { 512 } else { 0 })
  }
  let filter_flag = if t.seq.intra_edge_filter { 1024 } else { 0 }
  let (resolved, angle_out) = prepare_edges(
    plane,
    px,
    py,
    plane.width,
    plane.height,
    tw,
    th,
    mode,
    angle,
    have_top,
    have_left,
    have_topright,
    have_bottomleft,
    t.seq.intra_edge_filter,
    t.edges,
  )
  predict(
    t.block,
    tw,
    t.edges,
    edge_corner,
    tw,
    th,
    resolved,
    angle_out | sm | filter_flag,
  )
  if plane_index != 0 {

  }
  for yy in 0..<th {
    for xx in 0..<tw {
      plane.set(px + xx, py + yy, t.block[yy * tw + xx].to_int())
    }
  }
  let ctx_at = if plane_index == 0 {
    (t.bx + x_off) & 31
  } else {
    ((t.bx + x_off) >> t.fb.ss_hor) & 31
  }
  let ctx_at_l = if plane_index == 0 {
    (t.by + y_off) & 31
  } else {
    ((t.by + y_off) >> t.fb.ss_ver) & 31
  }
  let above_coef = if plane_index == 0 {
    above.lcoef
  } else if plane_index == 1 {
    above.ccoef0
  } else {
    above.ccoef1
  }
  let left_coef = if plane_index == 0 {
    t.left.lcoef
  } else if plane_index == 1 {
    t.left.ccoef0
  } else {
    t.left.ccoef1
  }
  let ctx_w = if plane_index == 0 { tw4 } else { tw4 }
  if t.skip {
    for i in 0..<ctx_w {
      above_coef[ctx_at + i] = 0x40
    }
    for i in 0..<th4 {
      left_coef[ctx_at_l + i] = 0x40
    }
  } else {
    let result = decode_coefs(
      t.msac,
      t.cdf,
      above_coef,
      ctx_at,
      left_coef,
      ctx_at_l,
      tx,
      bs,
      plane_index,
      true,
      t.y_mode,
      t.y_angle,
      t.uv_mode,
      t.frame.reduced_txtp_set,
      t.frame.all_lossless,
      clip_q(t.frame.yac),
      t.dq[plane_index * 2],
      t.dq[plane_index * 2 + 1],
      t.cf,
      t.levels,
      t.fb.ss_hor,
      t.fb.ss_ver,
      qm_offset(t.frame, plane_index, tx),
    )
    for i in 0..<ctx_w {
      above_coef[ctx_at + i] = result.ctx
    }
    for i in 0..<th4 {
      left_coef[ctx_at_l + i] = result.ctx
    }
    if result.eob >= 0 {
      inv_txfm_add(
        plane.data,
        plane.at(px, py),
        plane.stride,
        t.cf,
        result.eob,
        tx,
        result.txtp,
      )
    }
  }
  mark(bitmap, across, px >> 2, py >> 2, tw4, th4)
}

///|
fn plane_of(t : Tile, index : Int32) -> Plane {
  if index == 0 {
    t.fb.y
  } else if index == 1 {
    t.fb.u
  } else {
    t.fb.v
  }
}

///|
fn smooth_mode(ctx : Ctx, at : Int32) -> Bool {
  if ctx.intra[at] == 0 {
    return false
  }
  let mode = ctx.mode[at]
  mode == 9 || mode == 10 || mode == 11
}

///|
fn smooth_uv(ctx : Ctx, at : Int32) -> Bool {
  let mode = ctx.uvmode[at]
  mode == 9 || mode == 10 || mode == 11
}

///|
/// The chroma of a block: predicted from luma, or from its own edges, then given
/// what its coefficients say.
fn reconstruct_chroma(t : Tile, bs : Int32, w4 : Int32, h4 : Int32) -> Unit {
  let ss_hor = t.fb.ss_hor
  let ss_ver = t.fb.ss_ver
  let cw4 = (w4 + ss_hor) >> ss_hor
  let ch4 = (h4 + ss_ver) >> ss_ver
  let cbw4 = (block_dimensions[bs * 4] + ss_hor) >> ss_hor
  let cbh4 = (block_dimensions[bs * 4 + 1] + ss_ver) >> ss_ver
  let uvtx = t.uvtx
  let tw4 = txfm_w[uvtx]
  let th4 = txfm_h[uvtx]
  let px0 = t.bx >> ss_hor << 2
  let py0 = t.by >> ss_ver << 2
  let uv_across = ((t.bw + ss_hor) >> ss_hor) + 1
  // The deblocking filter needs to know how large the chroma transforms are, to
  // tell a transform edge from a boundary inside one.
  mark_value(
    t.uv_txw_map,
    uv_across,
    t.bx >> ss_hor,
    t.by >> ss_ver,
    cw4,
    ch4,
    min_i32(2, txfm_lw[uvtx]),
  )
  mark_value(
    t.uv_txh_map,
    uv_across,
    t.bx >> ss_hor,
    t.by >> ss_ver,
    cw4,
    ch4,
    min_i32(2, txfm_lh[uvtx]),
  )

  let cfl = t.uv_mode == 13
  if cfl {
    // The AC of the luma under the block, averaged down to the chroma grid.
    let luma_x = t.bx >> ss_hor << ss_hor << 2
    let luma_y = t.by >> ss_ver << ss_ver << 2
    let furthest_r = ((cw4 << ss_hor) + txfm_w[t.tx] - 1) /
      txfm_w[t.tx] *
      txfm_w[t.tx]
    let furthest_b = ((ch4 << ss_ver) + txfm_h[t.tx] - 1) /
      txfm_h[t.tx] *
      txfm_h[t.tx]
    let w_pad = cbw4 - (furthest_r >> ss_hor)
    let h_pad = cbh4 - (furthest_b >> ss_ver)
    cfl_ac(
      t.ac,
      t.fb.y,
      luma_x,
      luma_y,
      cbw4 << 2,
      cbh4 << 2,
      w_pad << 2,
      h_pad << 2,
      ss_hor,
      ss_ver,
    )
    for pl in 0..<2 {
      if t.cfl_alpha[pl] == 0 {
        continue
      }
      let plane = plane_of(t, pl + 1)
      let (resolved, _) = prepare_edges(
        plane,
        px0,
        py0,
        plane.width,
        plane.height,
        tw4 << 2,
        th4 << 2,
        0,
        0,
        py0 > 0,
        px0 > 0,
        false,
        false,
        false,
        t.edges,
      )
      let dc = cfl_dc(t.edges, edge_corner, cbw4 << 2, cbh4 << 2, resolved)
      cfl_predict(
        plane,
        px0,
        py0,
        cbw4 << 2,
        cbh4 << 2,
        dc,
        t.ac,
        t.cfl_alpha[pl],
      )
    }
  }

  for pl in 0..<2 {
    let mut y = 0
    while y < ch4 {
      let mut x = 0
      while x < cw4 {
        let px = px0 + (x << 2)
        let py = py0 + (y << 2)
        let skip_predict = cfl
        reconstruct_one_chroma(
          t,
          pl,
          px,
          py,
          x << ss_hor,
          y << ss_ver,
          tw4,
          th4,
          uvtx,
          bs,
          uv_across,
          skip_predict,
        )
        x = x + tw4
      }
      y = y + th4
    }
  }
}

///|
fn reconstruct_one_chroma(
  t : Tile,
  pl : Int32,
  px : Int32,
  py : Int32,
  x_off : Int32,
  y_off : Int32,
  tw4 : Int32,
  th4 : Int32,
  uvtx : Int32,
  bs : Int32,
  uv_across : Int32,
  skip_predict : Bool,
) -> Unit {
  reconstruct_one_core(
    t,
    pl + 1,
    px,
    py,
    x_off,
    y_off,
    tw4,
    th4,
    t.uv_mode,
    t.uv_angle,
    uvtx,
    bs,
    uv_across,
    t.decoded_uv,
    skip_predict,
  )
}

///|
/// One transform block of a plane, optionally without the prediction: chroma
/// predicted from luma has already been written.
fn reconstruct_one_core(
  t : Tile,
  plane_index : Int32,
  px : Int32,
  py : Int32,
  x_off : Int32,
  y_off : Int32,
  tw4 : Int32,
  th4 : Int32,
  mode : Int32,
  angle : Int32,
  tx : Int32,
  bs : Int32,
  across : Int32,
  bitmap : FixedArray[Int32],
  skip_predict : Bool,
) -> Unit {
  if !skip_predict {
    reconstruct_one(
      t, plane_index, px, py, x_off, y_off, tw4, th4, mode, angle, tx, bs, across,
      bitmap,
    )
    return
  }
  // No prediction: only the coefficients, and the record that the samples are
  // now final.
  let plane = plane_of(t, plane_index)
  let above = above_of(t, t.bx)
  let above_coef = if plane_index == 1 { above.ccoef0 } else { above.ccoef1 }
  let left_coef = if plane_index == 1 { t.left.ccoef0 } else { t.left.ccoef1 }
  let ctx_at = ((t.bx + x_off) >> t.fb.ss_hor) & 31
  let ctx_at_l = ((t.by + y_off) >> t.fb.ss_ver) & 31
  if t.skip {
    for i in 0..<tw4 {
      above_coef[ctx_at + i] = 0x40
    }
    for i in 0..<th4 {
      left_coef[ctx_at_l + i] = 0x40
    }
    mark(bitmap, across, px >> 2, py >> 2, tw4, th4)
    return
  }
  let result = decode_coefs(
    t.msac,
    t.cdf,
    above_coef,
    ctx_at,
    left_coef,
    ctx_at_l,
    tx,
    bs,
    plane_index,
    true,
    t.y_mode,
    t.y_angle,
    t.uv_mode,
    t.frame.reduced_txtp_set,
    t.frame.all_lossless,
    clip_q(t.frame.yac),
    t.dq[plane_index * 2],
    t.dq[plane_index * 2 + 1],
    t.cf,
    t.levels,
    t.fb.ss_hor,
    t.fb.ss_ver,
    qm_offset(t.frame, plane_index, tx),
  )
  for i in 0..<tw4 {
    above_coef[ctx_at + i] = result.ctx
  }
  for i in 0..<th4 {
    left_coef[ctx_at_l + i] = result.ctx
  }
  if result.eob >= 0 {
    inv_txfm_add(
      plane.data,
      plane.at(px, py),
      plane.stride,
      t.cf,
      result.eob,
      tx,
      result.txtp,
    )
  }
  mark(bitmap, across, px >> 2, py >> 2, tw4, th4)
}

///|
/// The DC a chroma-from-luma prediction starts from, for the mode the edges
/// resolved to.
fn cfl_dc(
  edges : FixedArray[Byte],
  corner : Int32,
  w : Int32,
  h : Int32,
  mode : Int32,
) -> Int32 {
  if mode == 14 {
    return 128
  }
  if mode == 15 {
    let mut sum = w / 2
    for i in 0..<w {
      sum = sum + edges[corner + 1 + i].to_int()
    }
    return sum >> w.ctz()
  }
  if mode == 16 {
    let mut sum = h / 2
    for i in 0..<h {
      sum = sum + edges[corner - 1 - i].to_int()
    }
    return sum >> h.ctz()
  }
  dc_value(edges, corner, w, h)
}
