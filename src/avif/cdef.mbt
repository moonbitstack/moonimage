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
  for y in 0..<h {
    for x in 0..<w {
      let here_x = px + x
      let here_y = py + y
      let centre = src.get(here_x, here_y)
      let mut sum = 0
      let mut lowest = centre
      let mut highest = centre
      let mut tap = pri_tap
      for k in 0..<2 {
        let primary = cdef_directions[(dir + 2) * 2 + k]
        let p0 = src.get(
          clamp_x(src, here_x + primary),
          clamp_y(src, here_y + primary),
        )
        let p1 = src.get(
          clamp_x(src, here_x - primary),
          clamp_y(src, here_y - primary),
        )
        sum = sum + tap * constrain(p0 - centre, pri, pri_shift)
        sum = sum + tap * constrain(p1 - centre, pri, pri_shift)
        tap = (tap & 3) | 2
        lowest = min_i32(min_i32(p0, p1), lowest)
        highest = max_i32(max_i32(p0, p1), highest)
        let second = cdef_directions[(dir + 4) * 2 + k]
        let third = cdef_directions[dir * 2 + k]
        let s0 = src.get(
          clamp_x(src, here_x + second),
          clamp_y(src, here_y + second),
        )
        let s1 = src.get(
          clamp_x(src, here_x - second),
          clamp_y(src, here_y - second),
        )
        let s2 = src.get(
          clamp_x(src, here_x + third),
          clamp_y(src, here_y + third),
        )
        let s3 = src.get(
          clamp_x(src, here_x - third),
          clamp_y(src, here_y - third),
        )
        let sec_tap = 2 - k
        sum = sum + sec_tap * constrain(s0 - centre, sec, sec_shift)
        sum = sum + sec_tap * constrain(s1 - centre, sec, sec_shift)
        sum = sum + sec_tap * constrain(s2 - centre, sec, sec_shift)
        sum = sum + sec_tap * constrain(s3 - centre, sec, sec_shift)
        lowest = min_i32(min_i32(min_i32(s0, s1), min_i32(s2, s3)), lowest)
        highest = max_i32(max_i32(max_i32(s0, s1), max_i32(s2, s3)), highest)
      }
      let value = centre + ((sum - (if sum < 0 { 1 } else { 0 }) + 8) >> 4)
      let clipped = if value < lowest {
        lowest
      } else if value > highest {
        highest
      } else {
        value
      }
      dst.set(here_x, here_y, clipped)
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
              let cw = 4 >> t.fb.ss_hor
              let ch = 4 >> t.fb.ss_ver
              cdef_block(
                t.fb.u,
                u_src,
                bx << 2 >> t.fb.ss_hor,
                by << 2 >> t.fb.ss_ver,
                cw,
                ch,
                dir,
                adjusted,
                sec,
                damping,
              )
              cdef_block(
                t.fb.v,
                v_src,
                bx << 2 >> t.fb.ss_hor,
                by << 2 >> t.fb.ss_ver,
                cw,
                ch,
                dir,
                adjusted,
                sec,
                damping,
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
