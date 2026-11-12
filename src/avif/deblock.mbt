// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The deblocking filter: the edges a quantiser left visible, taken down by as
// much as the frame header says.
//
// Every four-pixel boundary is a candidate, but only the ones that fall on a
// transform's edge are filtered, and the width of the filter is capped by the
// smaller of the two transforms it separates — a four-by-four transform on one
// side means four taps and no more. All of the vertical edges are filtered
// before any horizontal one, because the two passes meet at corners and the
// order decides what the second pass reads.
//
// The limits come from the level the frame header gives each direction: the
// largest difference the filter will smooth, how far a sample may move, and the
// threshold above which an edge is called a real one and only its two middle
// samples are touched.

///|
/// The two limits a level implies, computed once per frame the way the
/// specification computes them: sharpness raises the threshold by lowering the
/// limit.
fn lim_lut(sharpness : Int32) -> (FixedArray[Int32], FixedArray[Int32]) {
  let e = FixedArray::make(64, 0)
  let i = FixedArray::make(64, 0)
  for level in 0..<64 {
    let mut limit = level
    if sharpness > 0 {
      limit = limit >> ((sharpness + 3) >> 2)
      if limit > 9 - sharpness {
        limit = 9 - sharpness
      }
    }
    if limit < 1 {
      limit = 1
    }
    i[level] = limit
    e[level] = 2 * (level + 2) + limit
  }
  (e, i)
}

///|
/// One edge, four samples along it.
///
/// `across` filters between columns and `down` between rows; the samples come
/// from the plane's own border, which repeats the nearest sample of the picture,
/// so an edge near the frame's edge reads a window that is defined rather than
/// whatever the allocation happened to hold.
fn deblock_edge(
  plane : Plane,
  x : Int32,
  y : Int32,
  across : Bool,
  wd : Int32,
  em : Int32,
  im : Int32,
  hm : Int32,
) -> Unit {
  let mut lane = 0
  while lane < 4 {
    let bx = if across { x } else { x + lane }
    let by = if across { y + lane } else { y }
    let p : FixedArray[Int32] = FixedArray::make(7, 0)
    let q : FixedArray[Int32] = FixedArray::make(7, 0)
    for k in 0..<7 {
      p[k] = if across {
        plane.get(clamp_x(plane, bx - 1 - k), by)
      } else {
        plane.get(bx, clamp_y(plane, by - 1 - k))
      }
      q[k] = if across {
        plane.get(clamp_x(plane, bx + k), by)
      } else {
        plane.get(bx, clamp_y(plane, by + k))
      }
    }
    let p0 = p[0]
    let p1 = p[1]
    let q0 = q[0]
    let q1 = q[1]
    let mut flat = if abs_i32(p1 - p0) <= im &&
      abs_i32(q1 - q0) <= im &&
      abs_i32(p0 - q0) * 2 + (abs_i32(p1 - q1) >> 1) <= em {
      true
    } else {
      false
    }
    if wd > 4 {
      flat = flat && abs_i32(p[2] - p1) <= im && abs_i32(q[2] - q1) <= im
      if wd > 6 {
        flat = flat && abs_i32(p[3] - p[2]) <= im && abs_i32(q[3] - q[2]) <= im
      }
    }
    if !flat {
      lane = lane + 1
      continue
    }
    let mut flat8out = false
    if wd >= 16 {
      flat8out = abs_i32(p[6] - p0) <= 1 &&
        abs_i32(p[5] - p0) <= 1 &&
        abs_i32(p[4] - p0) <= 1 &&
        abs_i32(q[4] - q0) <= 1 &&
        abs_i32(q[5] - q0) <= 1 &&
        abs_i32(q[6] - q0) <= 1
    }
    let mut flat8in = true
    if wd >= 6 {
      flat8in = abs_i32(p[2] - p0) <= 1 &&
        abs_i32(p1 - p0) <= 1 &&
        abs_i32(q1 - q0) <= 1 &&
        abs_i32(q[2] - q0) <= 1
    }
    if wd >= 8 {
      flat8in = flat8in && abs_i32(p[3] - p0) <= 1 && abs_i32(q[3] - q0) <= 1
    }
    if wd >= 16 && flat8out && flat8in {
      wide_filter(plane, across, bx, by, p, q)
      lane = lane + 1
      continue
    }
    if wd >= 8 && flat8in {
      let out0 = (p[3] + p[3] + p[3] + 2 * p[2] + p1 + p0 + q0 + 4) >> 3
      let out1 = (p[3] + p[3] + p[2] + 2 * p1 + p0 + q0 + q1 + 4) >> 3
      let out2 = (p[3] + p[2] + p1 + 2 * p0 + q0 + q1 + q[2] + 4) >> 3
      let out3 = (p[2] + p1 + p0 + 2 * q0 + q1 + q[2] + q[3] + 4) >> 3
      let out4 = (p1 + p0 + q0 + 2 * q1 + q[2] + q[3] + q[3] + 4) >> 3
      let out5 = (p0 + q0 + q1 + 2 * q[2] + q[3] + q[3] + q[3] + 4) >> 3
      put(plane, across, bx, by, -3, out0)
      put(plane, across, bx, by, -2, out1)
      put(plane, across, bx, by, -1, out2)
      put(plane, across, bx, by, 0, out3)
      put(plane, across, bx, by, 1, out4)
      put(plane, across, bx, by, 2, out5)
      lane = lane + 1
      continue
    }
    if wd == 6 && flat8in {
      let out0 = (p[2] + 2 * p[2] + 2 * p1 + 2 * p0 + q0 + 4) >> 3
      let out1 = (p[2] + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3
      let out2 = (p1 + 2 * p0 + 2 * q0 + 2 * q1 + q[2] + 4) >> 3
      let out3 = (p0 + 2 * q0 + 2 * q1 + 2 * q[2] + q[2] + 4) >> 3
      put(plane, across, bx, by, -2, out0)
      put(plane, across, bx, by, -1, out1)
      put(plane, across, bx, by, 0, out2)
      put(plane, across, bx, by, 1, out3)
      lane = lane + 1
      continue
    }
    let hev = abs_i32(p1 - p0) > hm || abs_i32(q1 - q0) > hm
    let mut f = 0
    if hev {
      f = clip_diff(p1 - q1)
      f = clip_diff(3 * (q0 - p0) + f)
    } else {
      f = clip_diff(3 * (q0 - p0))
    }
    let f1 = min_i32(f + 4, 127) >> 3
    let f2 = min_i32(f + 3, 127) >> 3
    put(plane, across, bx, by, -1, clip8(p0 + f2))
    put(plane, across, bx, by, 0, clip8(q0 - f1))
    if !hev {
      let half = (f1 + 1) >> 1
      put(plane, across, bx, by, -2, clip8(p1 + half))
      put(plane, across, bx, by, 1, clip8(q1 - half))
    }
    lane = lane + 1
  }
}

///|
/// The twelve samples the widest filter writes, each a weighted sum of the
/// seven either side of the edge.
fn wide_filter(
  plane : Plane,
  across : Bool,
  bx : Int32,
  by : Int32,
  p : FixedArray[Int32],
  q : FixedArray[Int32],
) -> Unit {
  let out : FixedArray[Int32] = FixedArray::make(12, 0)
  out[0] = (
      7 * p[6] + 2 * p[5] + 2 * p[4] + p[3] + p[2] + p[1] + p[0] + q[0] + 8
    ) >>
    4
  out[1] = (
      5 * p[6] +
      2 * p[5] +
      2 * p[4] +
      2 * p[3] +
      p[2] +
      p[1] +
      p[0] +
      q[0] +
      q[1] +
      8
    ) >>
    4
  out[2] = (
      4 * p[6] +
      p[5] +
      2 * p[4] +
      2 * p[3] +
      2 * p[2] +
      p[1] +
      p[0] +
      q[0] +
      q[1] +
      q[2] +
      8
    ) >>
    4
  out[3] = (
      3 * p[6] +
      p[5] +
      p[4] +
      2 * p[3] +
      2 * p[2] +
      2 * p[1] +
      p[0] +
      q[0] +
      q[1] +
      q[2] +
      q[3] +
      8
    ) >>
    4
  out[4] = (
      2 * p[6] +
      p[5] +
      p[4] +
      p[3] +
      2 * p[2] +
      2 * p[1] +
      2 * p[0] +
      q[0] +
      q[1] +
      q[2] +
      q[3] +
      q[4] +
      8
    ) >>
    4
  out[5] = (
      p[6] +
      p[5] +
      p[4] +
      p[3] +
      p[2] +
      2 * p[1] +
      2 * p[0] +
      2 * q[0] +
      q[1] +
      q[2] +
      q[3] +
      q[4] +
      q[5] +
      8
    ) >>
    4
  out[6] = (
      p[5] +
      p[4] +
      p[3] +
      p[2] +
      p[1] +
      2 * p[0] +
      2 * q[0] +
      2 * q[1] +
      q[2] +
      q[3] +
      q[4] +
      q[5] +
      q[6] +
      8
    ) >>
    4
  out[7] = (
      p[4] +
      p[3] +
      p[2] +
      p[1] +
      p[0] +
      2 * q[0] +
      2 * q[1] +
      2 * q[2] +
      q[3] +
      q[4] +
      q[5] +
      2 * q[6] +
      8
    ) >>
    4
  out[8] = (
      p[3] +
      p[2] +
      p[1] +
      p[0] +
      q[0] +
      2 * q[1] +
      2 * q[2] +
      2 * q[3] +
      q[4] +
      q[5] +
      3 * q[6] +
      8
    ) >>
    4
  out[9] = (
      p[2] +
      p[1] +
      p[0] +
      q[0] +
      q[1] +
      2 * q[2] +
      2 * q[3] +
      2 * q[4] +
      q[5] +
      4 * q[6] +
      8
    ) >>
    4
  out[10] = (
      p[1] +
      p[0] +
      q[0] +
      q[1] +
      q[2] +
      2 * q[3] +
      2 * q[4] +
      2 * q[5] +
      5 * q[6] +
      8
    ) >>
    4
  out[11] = (
      p[0] +
      q[0] +
      q[1] +
      q[2] +
      q[3] +
      2 * q[4] +
      2 * q[5] +
      2 * q[6] +
      5 * q[6] +
      8
    ) >>
    4
  for k in 0..<12 {
    put(plane, across, bx, by, k - 6, out[k])
  }
}

///|
fn put(
  plane : Plane,
  across : Bool,
  bx : Int32,
  by : Int32,
  offset : Int32,
  value : Int32,
) -> Unit {
  // A sample outside the picture is not written. The reference filters into the
  // padding its planes are allocated with, which no reader ever sees; clamping
  // the write instead would land those samples on the last visible row and
  // change pixels the format says are outside the filter.
  let x = if across { bx + offset } else { bx }
  let y = if across { by } else { by + offset }
  if x >= 0 && x < plane.width && y >= 0 && y < plane.height {
    plane.set(x, y, value)
  }
}

///|
fn abs_i32(value : Int32) -> Int32 {
  if value < 0 {
    -value
  } else {
    value
  }
}

///|
fn clip_diff(value : Int32) -> Int32 {
  if value < -128 {
    -128
  } else if value > 127 {
    127
  } else {
    value
  }
}

///|
/// The whole frame's edges: luma first, then each chroma plane.
fn deblock(t : Tile) -> Unit {
  if t.lf[0] == 0 && t.lf[1] == 0 {
    return
  }
  let (e, i) = lim_lut(t.frame.sharpness)
  deblock_plane(
    t.fb.y,
    t.txw_map,
    t.txh_map,
    t.bw,
    t.bh,
    t.lf_v_map,
    t.lf_h_map,
    t.bw,
    0,
    0,
    t.bw,
    0,
    0,
    e,
    i,
    false,
  )
  if !t.fb.monochrome {
    let cw = (t.bw + t.fb.ss_hor) >> t.fb.ss_hor
    let ch = (t.bh + t.fb.ss_ver) >> t.fb.ss_ver
    // The transform sizes of a chroma plane are kept on the chroma grid and the
    // filter levels on the luma one, so the two maps need two strides.
    deblock_plane(
      t.fb.u,
      t.uv_txw_map,
      t.uv_txh_map,
      cw,
      ch,
      t.lf_u_map,
      t.lf_u_map,
      cw,
      0,
      0,
      t.bw,
      t.fb.ss_hor,
      t.fb.ss_ver,
      e,
      i,
      true,
    )
    deblock_plane(
      t.fb.v,
      t.uv_txw_map,
      t.uv_txh_map,
      cw,
      ch,
      t.lf_w_map,
      t.lf_w_map,
      cw,
      0,
      0,
      t.bw,
      t.fb.ss_hor,
      t.fb.ss_ver,
      e,
      i,
      true,
    )
  }
}

///|
/// Filter the edges of one plane.
///
/// The level comes from a map rather than from one number, because a frame with
/// per-superblock deltas has a different one in each sixty-four pixels and the
/// edge between two of them is filtered by whichever of the two is not zero.
fn deblock_plane(
  plane : Plane,
  txw : FixedArray[Int32],
  txh : FixedArray[Int32],
  w4 : Int32,
  h4 : Int32,
  levels_across : FixedArray[Int32],
  levels_down : FixedArray[Int32],
  tx_stride : Int32,
  tx_ss_hor : Int32,
  tx_ss_ver : Int32,
  lf_stride : Int32,
  lf_ss_hor : Int32,
  lf_ss_ver : Int32,
  e : FixedArray[Int32],
  i : FixedArray[Int32],
  chroma : Bool,
) -> Unit {
  let mut x = 1
  while x < w4 {
    let mut y = 0
    while y < h4 {
      let at = (y << tx_ss_ver) * tx_stride + (x << tx_ss_hor)
      if at < txw.length() && at > 0 {
        let here = txw[at]
        let left = txw[at - (1 << tx_ss_hor)]
        if (x & ((1 << here) - 1)) == 0 || (x & ((1 << left) - 1)) == 0 {
          let idx = min_i32(here, left)
          let wd = if chroma { 4 + 2 * idx } else { 4 << idx }
          let mut level = map_level(
            levels_across, lf_stride, lf_ss_hor, lf_ss_ver, x, y,
          )
          if chroma && idx > 1 {
            level = 0
          }
          if level == 0 {
            level = map_level(
              levels_across,
              lf_stride,
              lf_ss_hor,
              lf_ss_ver,
              x - 1,
              y,
            )
          }
          if level != 0 {
            deblock_edge(
              plane,
              x << 2,
              y << 2,
              true,
              wd,
              e[level],
              i[level],
              level >> 4,
            )
          }
        }
      }
      y = y + 1
    }
    x = x + 1
  }
  let mut y = 1
  while y < h4 {
    let mut x = 0
    while x < w4 {
      let at = (y << tx_ss_ver) * tx_stride + (x << tx_ss_hor)
      if at < txh.length() && at >= tx_stride {
        let here = txh[at]
        let above = txh[at - tx_stride]
        if (y & ((1 << here) - 1)) == 0 || (y & ((1 << above) - 1)) == 0 {
          let idx = min_i32(here, above)
          let wd = if chroma { 4 + 2 * idx } else { 4 << idx }
          let mut level = map_level(
            levels_down, lf_stride, lf_ss_hor, lf_ss_ver, x, y,
          )
          if chroma && idx > 1 {
            level = 0
          }
          if level == 0 {
            level = map_level(
              levels_down,
              lf_stride,
              lf_ss_hor,
              lf_ss_ver,
              x,
              y - 1,
            )
          }
          if level != 0 {
            deblock_edge(
              plane,
              x << 2,
              y << 2,
              false,
              wd,
              e[level],
              i[level],
              level >> 4,
            )
          }
        }
      }
      x = x + 1
    }
    y = y + 1
  }
}

///|
fn map_level(
  levels : FixedArray[Int32],
  stride : Int32,
  ss_hor : Int32,
  ss_ver : Int32,
  x : Int32,
  y : Int32,
) -> Int32 {
  let at = (y << ss_ver) * stride + (x << ss_hor)
  if at < 0 || at >= levels.length() {
    0
  } else {
    levels[at]
  }
}
