// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Intra prediction: the block a neighbour's edges predict, and the arithmetic
// each of the thirteen modes does with them.
//
// The edges follow the reference's layout, which is worth stating because it is
// not the obvious one: `corner` is the sample diagonally above-left, `top(i)` is
// the i-th sample of the row above counting from nought, and `left(i)` is the
// i-th sample of the column to the left. A caller hands in one buffer and the
// index of the corner; the row above runs forward from it, the column to the
// left runs backwards, and both are `width`/`height` long.
//
// The directional modes are the interesting ones. An angle says how far along
// the edge one step across the block travels, through a table of derivatives;
// whether the edge is filtered first, and how strongly, depends on the size of
// the block and how far the angle is from vertical or horizontal, and for the
// shallowest angles the edge is upsampled to twice its length before the walk
// starts. All three of those choices are in the reference's tables rather than
// in this file, because they are the format's decisions rather than ours.

///|
/// Which predictor a mode names, as the format numbers them.
let dc_pred : Int32 = 0

///|
let vert_pred : Int32 = 1

///|
let hor_pred : Int32 = 2

///|
let smooth_pred : Int32 = 9

///|
let smooth_v_pred : Int32 = 10

///|
let smooth_h_pred : Int32 = 11

///|
let paeth_pred : Int32 = 12

///|
fn imin(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn imax(a : Int32, b : Int32) -> Int32 {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn iclip(value : Int32, low : Int32, high : Int32) -> Int32 {
  if value < low {
    low
  } else if value > high {
    high
  } else {
    value
  }
}

///|
/// The average of the row above and the column to the left, rounded as the
/// format rounds it: the sum of both edges, halved, and for a block that is not
/// square scaled by three quarters or a half depending on how far from square
/// it is.
fn dc_value(
  edges : FixedArray[Byte],
  corner : Int32,
  width : Int32,
  height : Int32,
) -> Int32 {
  let mut dc = (width + height) >> 1
  for i in 0..<width {
    dc = dc + edges[corner + 1 + i].to_int()
  }
  for i in 0..<height {
    dc = dc + edges[corner - 1 - i].to_int()
  }
  dc = dc >> (width + height).ctz()
  if width != height {
    dc = if width > height * 2 || height > width * 2 {
      (dc * 0x3334) >> 16
    } else {
      (dc * 0x5556) >> 16
    }
  }
  dc
}

///|
fn splat(
  dst : FixedArray[Byte],
  stride : Int32,
  width : Int32,
  height : Int32,
  value : Int32,
) -> Unit {
  let byte = value.to_byte()
  for y in 0..<height {
    for x in 0..<width {
      dst[y * stride + x] = byte
    }
  }
}

///|
/// How strongly the edge is filtered before a directional walk, if at all.
fn filter_strength(side : Int32, angle : Int32, is_sm : Bool) -> Int32 {
  if is_sm {
    if side <= 8 {
      if angle >= 64 {
        return 2
      }
      if angle >= 40 {
        return 1
      }
    } else if side <= 16 {
      if angle >= 48 {
        return 2
      }
      if angle >= 20 {
        return 1
      }
    } else if side <= 24 {
      if angle >= 4 {
        return 3
      }
    } else {
      return 3
    }
  } else if side <= 8 {
    if angle >= 56 {
      return 1
    }
  } else if side <= 16 {
    if angle >= 40 {
      return 1
    }
  } else if side <= 24 {
    if angle >= 32 {
      return 3
    }
    if angle >= 16 {
      return 2
    }
    if angle >= 8 {
      return 1
    }
  } else if side <= 32 {
    if angle >= 32 {
      return 3
    }
    if angle >= 4 {
      return 2
    }
    return 1
  } else {
    return 3
  }
  0
}

///|
/// The three kernels a filtered edge is convolved with, one per strength.
let edge_kernels : FixedArray[FixedArray[Int32]] = [
  [0, 4, 8, 4, 0],
  [0, 5, 6, 5, 0],
  [2, 4, 4, 4, 2],
]

///|
/// One edge, filtered: the samples within `from..to` are convolved with the
/// kernel of the strength, and the ends are taken as they are.
fn filter_edge(
  out : FixedArray[Byte],
  out_at : Int32,
  size : Int32,
  limit_from : Int32,
  limit_to : Int32,
  source : FixedArray[Byte],
  source_at : Int32,
  from : Int32,
  to : Int32,
  strength : Int32,
) -> Unit {
  let kernel = edge_kernels[strength - 1]
  let mut i = 0
  while i < imin(size, limit_from) {
    out[out_at + i] = source[source_at + iclip(i, from, to - 1)]
    i = i + 1
  }
  while i < imin(limit_to, size) {
    let mut total = 0
    for j in 0..<5 {
      total = total +
        source[source_at + iclip(i - 2 + j, from, to - 1)].to_int() * kernel[j]
    }
    out[out_at + i] = ((total + 8) >> 4).to_byte()
    i = i + 1
  }
  while i < size {
    out[out_at + i] = source[source_at + iclip(i, from, to - 1)]
    i = i + 1
  }
}

///|
/// Whether an edge is doubled before the walk: only the shallowest angles on the
/// smallest blocks, where a step along the edge is less than one sample.
fn upsample(wh : Int32, angle : Int32, is_sm : Bool) -> Bool {
  angle < 40 && wh <= (if is_sm { 8 } else { 16 })
}

///|
/// An edge doubled, each new sample the four-tap interpolation of its
/// neighbours that the format specifies.
fn upsample_edge(
  out : FixedArray[Byte],
  out_at : Int32,
  hsz : Int32,
  source : FixedArray[Byte],
  source_at : Int32,
  from : Int32,
  to : Int32,
) -> Unit {
  let kernel : FixedArray[Int32] = [-1, 9, 9, -1]
  let mut i = 0
  while i < hsz - 1 {
    out[out_at + i * 2] = source[source_at + iclip(i, from, to - 1)]
    let mut total = 0
    for j in 0..<4 {
      total = total +
        source[source_at + iclip(i + j - 1, from, to - 1)].to_int() * kernel[j]
    }
    out[out_at + i * 2 + 1] = clip_pixel((total + 8) >> 4).to_byte()
    i = i + 1
  }
  out[out_at + i * 2] = source[source_at + iclip(i, from, to - 1)]
}

///|
/// The block predicted from the edges.
///
/// `angle` carries three things in one integer, as the format packs them: the
/// angle itself in the low nine bits, whether the block is small enough for the
/// smoothing strength in bit nine, and whether the edge may be filtered at all
/// in bit ten. The zones are chosen from the angle, the way a caller of the
/// reference picks the predictor: below ninety is the first, between the first
/// and the second, above a hundred and eighty the third.
pub fn predict(
  dst : FixedArray[Byte],
  stride : Int32,
  edges : FixedArray[Byte],
  corner : Int32,
  width : Int32,
  height : Int32,
  mode : Int32,
  angle_in : Int32,
) -> Unit {
  if width <= 0 || height <= 0 {
    return
  }
  let is_sm = ((angle_in >> 9) & 1) == 1
  let may_filter = angle_in >> 10 != 0
  let angle = angle_in & 511
  if mode == dc_pred {
    splat(dst, stride, width, height, dc_value(edges, corner, width, height))
    return
  }
  if mode == vert_pred {
    for y in 0..<height {
      for x in 0..<width {
        dst[y * stride + x] = edges[corner + 1 + x]
      }
    }
    return
  }
  if mode == hor_pred {
    for y in 0..<height {
      for x in 0..<width {
        dst[y * stride + x] = edges[corner - 1 - y]
      }
    }
    return
  }
  if mode == paeth_pred {
    let topleft = edges[corner].to_int()
    for y in 0..<height {
      let left = edges[corner - 1 - y].to_int()
      for x in 0..<width {
        let top = edges[corner + 1 + x].to_int()
        let base = left + top - topleft
        let to_left = if base > left { base - left } else { left - base }
        let to_top = if base > top { base - top } else { top - base }
        let to_corner = if base > topleft {
          base - topleft
        } else {
          topleft - base
        }
        let pick = if to_left <= to_top && to_left <= to_corner {
          left
        } else if to_top <= to_corner {
          top
        } else {
          topleft
        }
        dst[y * stride + x] = pick.to_byte()
      }
    }
    return
  }
  if mode == smooth_pred || mode == smooth_v_pred || mode == smooth_h_pred {
    let right = edges[corner + width].to_int()
    let bottom = edges[corner - height].to_int()
    for y in 0..<height {
      for x in 0..<width {
        let horizontal = smooth_weights[width + x]
        let vertical = smooth_weights[height + y]
        let value = if mode == smooth_pred {
          (
            vertical * edges[corner + 1 + x].to_int() +
            (256 - vertical) * bottom +
            horizontal * edges[corner - 1 - y].to_int() +
            (256 - horizontal) * right +
            256
          ) >>
          9
        } else if mode == smooth_v_pred {
          (
            vertical * edges[corner + 1 + x].to_int() +
            (256 - vertical) * bottom +
            128
          ) >>
          8
        } else {
          (
            horizontal * edges[corner - 1 - y].to_int() +
            (256 - horizontal) * right +
            128
          ) >>
          8
        }
        dst[y * stride + x] = value.to_byte()
      }
    }
    return
  }
  if angle < 90 {
    predict_z1(
      dst, stride, edges, corner, width, height, angle, is_sm, may_filter,
    )
  } else if angle < 180 {
    predict_z2(
      dst, stride, edges, corner, width, height, angle, is_sm, may_filter,
    )
  } else {
    predict_z3(
      dst, stride, edges, corner, width, height, angle, is_sm, may_filter,
    )
  }
}

///|
/// The first quarter: everything is read from the row above, walking right as
/// the block is walked down.
fn predict_z1(
  dst : FixedArray[Byte],
  stride : Int32,
  edges : FixedArray[Byte],
  corner : Int32,
  width : Int32,
  height : Int32,
  angle : Int32,
  is_sm : Bool,
  may_filter : Bool,
) -> Unit {
  let mut dx = dr_derivative[angle >> 1]
  let top : FixedArray[Byte] = FixedArray::make(128, b'\x00')
  let mut max_base_x = width + imin(width, height) - 1
  let use_upsample = may_filter && upsample(width + height, 90 - angle, is_sm)
  if use_upsample {
    // The edge is doubled, starting one sample before the corner so that the
    // first interpolated sample has a neighbour on its left.
    upsample_edge(
      top,
      0,
      width + height,
      edges,
      corner,
      -1,
      width + imin(width, height),
    )
    max_base_x = 2 * (width + height) - 2
    dx = dx << 1
  } else {
    let strength = if may_filter {
      filter_strength(width + height, 90 - angle, is_sm)
    } else {
      0
    }
    if strength != 0 {
      filter_edge(
        top,
        0,
        width + height,
        0,
        width + height,
        edges,
        corner,
        -1,
        width + imin(width, height),
        strength,
      )
      max_base_x = width + height - 1
    } else {
      for i in 0..<(max_base_x + 1) {
        top[i] = edges[corner + 1 + i]
      }
    }
  }
  let base_inc = 1 + (if use_upsample { 1 } else { 0 })
  let mut xpos = dx
  for y in 0..<height {
    let frac = xpos & 0x3E
    let mut base = xpos >> 6
    let mut x = 0
    while x < width {
      if base < max_base_x {
        let v = top[base].to_int() * (64 - frac) + top[base + 1].to_int() * frac
        dst[y * stride + x] = ((v + 32) >> 6).to_byte()
      } else {
        while x < width {
          dst[y * stride + x] = top[max_base_x]
          x = x + 1
        }
        break
      }
      base = base + base_inc
      x = x + 1
    }
    xpos = xpos + dx
  }
}

///|
/// The second quarter: both edges, the one above for the samples that reach
/// past the corner and the one to the left for the rest.
fn predict_z2(
  dst : FixedArray[Byte],
  stride : Int32,
  edges : FixedArray[Byte],
  corner : Int32,
  width : Int32,
  height : Int32,
  angle : Int32,
  is_sm : Bool,
  may_filter : Bool,
) -> Unit {
  let mut dy = dr_derivative[(angle - 90) >> 1]
  let mut dx = dr_derivative[(180 - angle) >> 1]
  let upsample_left = may_filter && upsample(width + height, 180 - angle, is_sm)
  let upsample_above = may_filter && upsample(width + height, angle - 90, is_sm)
  // The corner sits at 64 in the working edge so that the column to the left,
  // which the walk reads backwards, has room, and the row above has room past
  // the corner for the sample the interpolation reads one step beyond the block.
  let edge : FixedArray[Byte] = FixedArray::make(144, b'\x00')
  let at = 72
  if upsample_above {
    upsample_edge(edge, at, width + 1, edges, corner, 0, width + 1)
    dx = dx << 1
  } else {
    let strength = if may_filter {
      filter_strength(width + height, angle - 90, is_sm)
    } else {
      0
    }
    if strength != 0 {
      filter_edge(
        edge,
        at + 1,
        width,
        0,
        width,
        edges,
        corner,
        -1,
        width,
        strength,
      )
    } else {
      for i in 0..<width {
        edge[at + 1 + i] = edges[corner + 1 + i]
      }
    }
  }
  if upsample_left {
    upsample_edge(
      edge,
      at - height * 2,
      height + 1,
      edges,
      corner - height,
      0,
      height + 1,
    )
    dy = dy << 1
  } else {
    let strength = if may_filter {
      filter_strength(width + height, 180 - angle, is_sm)
    } else {
      0
    }
    if strength != 0 {
      filter_edge(
        edge,
        at - height,
        height,
        0,
        height,
        edges,
        corner - height,
        0,
        height + 1,
        strength,
      )
    } else {
      for i in 0..<height {
        edge[at - height + i] = edges[corner - height + i]
      }
    }
  }
  edge[at] = edges[corner]
  let base_inc_x = 1 + (if upsample_above { 1 } else { 0 })
  let left_step = 1 + (if upsample_left { 1 } else { 0 })
  let left = at - left_step
  let mut ypos_row = ((1 + (if upsample_above { 1 } else { 0 })) << 6) - dx
  for y in 0..<height {
    let mut base_x = ypos_row >> 6
    let frac_x = ypos_row & 0x3E
    let mut ypos = (y << (6 + (if upsample_left { 1 } else { 0 }))) - dy
    for x in 0..<width {
      let v = if base_x >= 0 {
        edge[at + base_x].to_int() * (64 - frac_x) +
        edge[at + base_x + 1].to_int() * frac_x
      } else {
        let base_y = ypos >> 6
        let frac_y = ypos & 0x3E
        edge[left - base_y].to_int() * (64 - frac_y) +
        edge[left - (base_y + 1)].to_int() * frac_y
      }
      dst[y * stride + x] = ((v + 32) >> 6).to_byte()
      base_x = base_x + base_inc_x
      ypos = ypos - dy
    }
    ypos_row = ypos_row - dx
  }
}

///|
/// The third quarter: everything is read from the column to the left, walking
/// down as the block is walked across.
fn predict_z3(
  dst : FixedArray[Byte],
  stride : Int32,
  edges : FixedArray[Byte],
  corner : Int32,
  width : Int32,
  height : Int32,
  angle : Int32,
  is_sm : Bool,
  may_filter : Bool,
) -> Unit {
  let mut dy = dr_derivative[(270 - angle) >> 1]
  // The left edge is kept the way it is read: index nought is the sample beside
  // the corner and the walk counts away from it.
  let left : FixedArray[Byte] = FixedArray::make(128, b'\x00')
  let work : FixedArray[Byte] = FixedArray::make(128, b'\x00')
  let mut max_base_y = height + imin(width, height) - 1
  let use_upsample = may_filter && upsample(width + height, angle - 180, is_sm)
  if use_upsample {
    upsample_edge(
      work,
      0,
      width + height,
      edges,
      corner - (width + height),
      imax(width - height, 0),
      width + height + 1,
    )
    max_base_y = 2 * (width + height) - 2
    for i in 0..<(max_base_y + 1) {
      left[i] = work[max_base_y - i]
    }
    dy = dy << 1
  } else {
    let strength = if may_filter {
      filter_strength(width + height, angle - 180, is_sm)
    } else {
      0
    }
    if strength != 0 {
      filter_edge(
        work,
        0,
        width + height,
        0,
        width + height,
        edges,
        corner - (width + height),
        imax(width - height, 0),
        width + height + 1,
        strength,
      )
      max_base_y = width + height - 1
      for i in 0..<(max_base_y + 1) {
        left[i] = work[max_base_y - i]
      }
    } else {
      for i in 0..<(max_base_y + 1) {
        left[i] = edges[corner - 1 - i]
      }
    }
  }
  let base_inc = 1 + (if use_upsample { 1 } else { 0 })
  let mut ypos = dy
  for x in 0..<width {
    let frac = ypos & 0x3E
    let mut base = ypos >> 6
    let mut y = 0
    while y < height {
      if base < max_base_y {
        let v = left[base].to_int() * (64 - frac) +
          left[base + 1].to_int() * frac
        dst[y * stride + x] = ((v + 32) >> 6).to_byte()
      } else {
        while y < height {
          dst[y * stride + x] = left[max_base_y]
          y = y + 1
        }
        break
      }
      base = base + base_inc
      y = y + 1
    }
    ypos = ypos + dy
  }
}
