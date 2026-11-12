// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Constrained directional enhancement: a filter that walks along the edges in a
// picture rather than across them, and refuses to move a sample further than the
// quantiser says its error can be.
//
// There is nothing in the bitstream that says which direction to walk in. The
// decoder finds it, from the same samples it is about to filter: eight
// directions are scored by how much of the block's variance they explain, and
// the one that explains the most wins. That is why the search and the filter
// both have to see the picture as it was before filtering, which is why the
// whole plane is copied before any of it is touched.
//
// Only blocks that carry coefficients are filtered — an eight-by-eight that was
// predicted and then skipped is the predictor's answer, not the quantiser's, and
// there is no quantisation error in it to remove.

///|
/// constrain: how much of a neighbour's difference the filter is allowed to act
/// on, tapering to nothing as the difference grows past the strength.
fn constrain(diff : Int32, threshold : Int32, shift : Int32) -> Int32 {
  let magnitude = if diff < 0 { -diff } else { diff }
  let mut limit = threshold - (magnitude >> shift)
  if limit < 0 {
    limit = 0
  }
  let value = if magnitude < limit { magnitude } else { limit }
  if diff < 0 {
    -value
  } else {
    value
  }
}

///|
/// A copy of a plane, for the filter to read while it writes the original.
fn copy_plane(plane : Plane) -> Plane {
  let copy = Plane::allocate(plane.width, plane.height)
  for i in 0..<plane.data.length() {
    copy.data[i] = plane.data[i]
  }
  copy
}

///|
/// The direction an eight-by-eight block runs in, and how much of its variance
/// that direction accounts for.
///
/// The eight sums are of the samples along each direction; a direction that
/// lines up with the block's edges concentrates its sum and scores high, and one
/// that cuts across them cancels itself out.
fn find_direction(plane : Plane, px : Int32, py : Int32) -> (Int32, Int32) {
  let hv : FixedArray[Int32] = FixedArray::make(16, 0)
  let diag : FixedArray[Int32] = FixedArray::make(30, 0)
  let alt : FixedArray[Int32] = FixedArray::make(44, 0)
  for y in 0..<8 {
    for x in 0..<8 {
      let value = plane.get(px + x, py + y) - 128
      diag[0 + y + x] = diag[0 + y + x] + value
      alt[0 + y + (x >> 1)] = alt[0 + y + (x >> 1)] + value
      hv[0 + y] = hv[0 + y] + value
      alt[11 + 3 + y - (x >> 1)] = alt[11 + 3 + y - (x >> 1)] + value
      diag[15 + 7 + y - x] = diag[15 + 7 + y - x] + value
      alt[22 + 3 - (y >> 1) + x] = alt[22 + 3 - (y >> 1) + x] + value
      hv[8 + x] = hv[8 + x] + value
      alt[33 + (y >> 1) + x] = alt[33 + (y >> 1) + x] + value
    }
  }
  let cost : FixedArray[Int32] = FixedArray::make(8, 0)
  for n in 0..<8 {
    cost[2] = cost[2] + hv[n] * hv[n]
    cost[6] = cost[6] + hv[8 + n] * hv[8 + n]
  }
  cost[2] = cost[2] * 105
  cost[6] = cost[6] * 105
  let div : FixedArray[Int32] = [840, 420, 280, 210, 168, 140, 120]
  for n in 0..<7 {
    let d = div[n]
    cost[0] = cost[0] + (diag[n] * diag[n] + diag[14 - n] * diag[14 - n]) * d
    cost[4] = cost[4] +
      (diag[15 + n] * diag[15 + n] + diag[15 + 14 - n] * diag[15 + 14 - n]) * d
  }
  cost[0] = cost[0] + diag[7] * diag[7] * 105
  cost[4] = cost[4] + diag[15 + 7] * diag[15 + 7] * 105
  for n in 0..<4 {
    let base = n * 11
    let mut sum = 0
    for m in 0..<5 {
      sum = sum + alt[base + 3 + m] * alt[base + 3 + m]
    }
    cost[n * 2 + 1] = cost[n * 2 + 1] + sum * 105
    for m in 0..<3 {
      let d = div[2 * m + 1]
      cost[n * 2 + 1] = cost[n * 2 + 1] +
        (
          alt[base + m] * alt[base + m] +
          alt[base + 10 - m] * alt[base + 10 - m]
        ) *
        d
    }
  }
  let mut best_dir = 0
  let mut best_cost = cost[0]
  for n in 1..<8 {
    if cost[n] > best_cost {
      best_cost = cost[n]
      best_dir = n
    }
  }
  let variance = (best_cost - cost[best_dir ^ 4]) >> 10
  (best_dir, variance)
}

///|
/// How much of a strength survives the block's variance: a flat block gets all
/// of it, a busy one less.
fn adjust_strength(strength : Int32, variance : Int32) -> Int32 {
  if variance == 0 {
    return 0
  }
  let shifted = variance >> 6
  let mut i = 0
  if shifted != 0 {
    i = floor_log2(shifted)
    if i > 12 {
      i = 12
    }
  }
  (strength * (4 + i) + 8) >> 4
}

///|
/// Where one tap of a direction lands: a step along x and a step along y.
///
/// The reference packs the two into one number against a scratch buffer it
/// filters in, twelve samples wide; there is no such buffer here, so the table
/// is dumped with the steps apart.
fn cdef_step(row : Int32, k : Int32) -> (Int32, Int32) {
  let at = (row * 2 + k) * 2
  (cdef_directions[at + 1], cdef_directions[at])
}

///|
/// Add one neighbour's contribution to a sample: its constrained difference, and
/// its part in the range the result is held to.
///
/// A neighbour outside the picture contributes nothing at all. The reference
/// fills those cells of its scratch buffer with a value that is out of range in
/// both directions — nought when the difference is taken, never the smallest or
/// the largest when the range is — which is the same as not reading them.
fn add_tap(
  acc : FixedArray[Int32],
  src : Plane,
  hx : Int32,
  hy : Int32,
  dx : Int32,
  dy : Int32,
  weight : Int32,
  threshold : Int32,
  shift : Int32,
) -> Unit {
  let x = hx + dx
  let y = hy + dy
  if x >= 0 && x < src.width && y >= 0 && y < src.height {
    let centre = acc[3]
    let value = src.get(x, y)
    acc[0] = acc[0] + weight * constrain(value - centre, threshold, shift)
    if value < acc[1] {
      acc[1] = value
    }
    if value > acc[2] {
      acc[2] = value
    }
  }
}

///|
/// Filter one block: the primary taps along the direction, the secondary ones
/// either side of it.
fn cdef_block(
  dst : Plane,
  src : Plane,
  px : Int32,
  py : Int32,
  w : Int32,
  h : Int32,
  dir : Int32,
  pri : Int32,
  sec : Int32,
  damping : Int32,
) -> Unit {
  let pri_shift = if damping - floor_log2(pri) > 0 {
    damping - floor_log2(pri)
  } else {
    0
  }
  let sec_shift = damping - floor_log2(sec)
  let pri_tap = 4 - (pri & 1)
  let acc : FixedArray[Int32] = FixedArray::make(4, 0)
  for y in 0..<h {
    for x in 0..<w {
      let hx = px + x
      let hy = py + y
      let centre = src.get(hx, hy)
      acc[0] = 0
      acc[1] = centre
      acc[2] = centre
      acc[3] = centre
      // Along the direction, the two taps at four and at two samples out; then
      // either side of it, at two and at one.
      for k in 0..<2 {
        let (dx, dy) = cdef_step(dir + 2, k)
        let weight = if k == 0 { pri_tap } else { (pri_tap & 3) | 2 }
        add_tap(acc, src, hx, hy, dx, dy, weight, pri, pri_shift)
        add_tap(acc, src, hx, hy, -dx, -dy, weight, pri, pri_shift)
        let sec_weight = 2 - k
        let (sx, sy) = cdef_step(dir + 4, k)
        add_tap(acc, src, hx, hy, sx, sy, sec_weight, sec, sec_shift)
        add_tap(acc, src, hx, hy, -sx, -sy, sec_weight, sec, sec_shift)
        let (tx, ty) = cdef_step(dir, k)
        add_tap(acc, src, hx, hy, tx, ty, sec_weight, sec, sec_shift)
        add_tap(acc, src, hx, hy, -tx, -ty, sec_weight, sec, sec_shift)
      }
      let sum = acc[0]
      let value = centre + ((sum - (if sum < 0 { 1 } else { 0 }) + 8) >> 4)
      let clipped = if value < acc[1] {
        acc[1]
      } else if value > acc[2] {
        acc[2]
      } else {
        value
      }
      dst.set(hx, hy, clipped)
    }
  }
}

///|
/// The whole picture, eight by eight at a time.
fn cdef_filter(t : Tile) -> Unit {
  let frame = t.frame
  if !t.seq.cdef || frame.all_lossless {
    return
  }
  let mut any = false
  for i in 0..<(1 << frame.cdef_bits) {
    if frame.cdef_y[i] != 0 || frame.cdef_uv[i] != 0 {
      any = true
    }
  }
  if !any {
    return
  }
  let y_src = copy_plane(t.fb.y)
  let u_src = copy_plane(t.fb.u)
  let v_src = copy_plane(t.fb.v)
  let damping = frame.cdef_damping
  let mut by = 0
  while by < t.bh {
    let mut bx = 0
    while bx < t.bw {
      let at = by * t.bw + bx
      if at < t.cdef_map.length() {
        let index = t.cdef_map[at]
        let y_level = frame.cdef_y[index]
        let uv_level = frame.cdef_uv[index]
        let mut coded = false
        for dy in 0..<2 {
          for dx in 0..<2 {
            let spot = (by + dy) * t.bw + bx + dx
            if spot < t.skip_map.length() && t.skip_map[spot] == 0 {
              coded = true
            }
          }
        }
        if coded && (y_level != 0 || uv_level != 0) {
          let mut dir = 0
          let mut variance = 0
          let (found, spread) = find_direction(y_src, bx << 2, by << 2)
          dir = found
          variance = spread
          if y_level != 0 {
            let pri = y_level >> 2
            let mut sec = y_level & 3
            if sec == 3 {
              sec = 4
            }
            let adjusted = adjust_strength(pri, variance)
            if adjusted != 0 || sec != 0 {
              cdef_block(
                t.fb.y,
                y_src,
                bx << 2,
                by << 2,
                8,
                8,
                dir,
                adjusted,
                sec,
                damping,
              )
            }
          }
          if uv_level != 0 {
            let pri = uv_level >> 2
            let mut sec = uv_level & 3
            if sec == 3 {
              sec = 4
            }
            let adjusted = adjust_strength(pri, variance)
            if adjusted != 0 || sec != 0 {
              // An eight-by-eight of luma is a four-by-four of chroma when the
              // colour is subsampled, and the chroma filter runs one step
              // gentler: the difference it is undoing was halved with it.
              let cw = 8 >> t.fb.ss_hor
              let ch = 8 >> t.fb.ss_ver
              cdef_block(
                t.fb.u,
                u_src,
                bx << 2 >> t.fb.ss_hor,
                by << 2 >> t.fb.ss_ver,
                cw,
                ch,
                if pri != 0 {
                  dir
                } else {
                  0
                },
                adjusted,
                sec,
                damping - 1,
              )
              cdef_block(
                t.fb.v,
                v_src,
                bx << 2 >> t.fb.ss_hor,
                by << 2 >> t.fb.ss_ver,
                cw,
                ch,
                if pri != 0 {
                  dir
                } else {
                  0
                },
                adjusted,
                sec,
                damping - 1,
              )
            }
          }
        }
      }
      bx = bx + 2
    }
    by = by + 2
  }
}
