// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Building the edges a block is predicted from, and the three predictors that
// need more than one plane: chroma from luma, a palette, and nothing else.
//
// The edges follow the format's rules for a missing neighbour. A block whose
// row above has not been decoded predicts from mid-grey if it has no left
// neighbour either, or from the left column if it has; a block at the left of
// the picture extends its top edge from the leftmost sample it can see. Those
// three cases are why the reference turns a DC prediction into one of four
// predictors before it calls one, and why the caller has to say which of its
// edges exist rather than just handing over a block of pixels.

///|
/// Which parts of the edge a predictor reads.
let needs_top : Int32 = 1

///|
let needs_left : Int32 = 2

///|
let needs_topleft : Int32 = 4

///|
let needs_topright : Int32 = 8

///|
let needs_bottomleft : Int32 = 16

///|
/// Where in the scratch edge buffer the corner sample sits.
let edge_corner : Int32 = 132

///|
/// What each predictor reads, as the flags above.
fn edge_needs(mode : Int32) -> Int32 {
  if mode == 0 {
    needs_top | needs_left
  } else if mode == 1 {
    needs_top
  } else if mode == 2 {
    needs_left
  } else if mode == 16 {
    needs_left
  } else if mode == 15 {
    needs_top
  } else if mode == 14 {
    0
  } else if mode == 6 {
    needs_top | needs_topright | needs_topleft
  } else if mode == 7 {
    needs_left | needs_top | needs_topleft
  } else if mode == 8 {
    needs_left | needs_bottomleft | needs_topleft
  } else if mode == 12 {
    needs_left | needs_top | needs_topleft
  } else if mode == 13 {
    needs_left | needs_top | needs_topleft
  } else {
    // The smooth modes, which read both edges and the two samples beyond them.
    needs_left | needs_top
  }
}

///|
/// The base angle of each directional mode, in the order the format numbers
/// them from vertical.
let mode_angle : FixedArray[Int32] = [90, 180, 45, 135, 113, 157, 203, 67]

///|
/// Fill the edges one transform block is predicted from, and answer which
/// predictor and angle it ends up with.
///
/// `tw` and `th` are the transform's size in pixels; `have_top` and `have_left`
/// say whether the row above and the column to the left hold decoded samples,
/// and `have_topright` and `have_bottomleft` whether the block diagonally past
/// the edge was decoded before this one — which is not the same as existing.
pub fn prepare_edges(
  plane : Plane,
  px : Int32,
  py : Int32,
  frame_w : Int32,
  frame_h : Int32,
  tw : Int32,
  th : Int32,
  mode_in : Int32,
  angle_in : Int32,
  have_top : Bool,
  have_left : Bool,
  have_topright : Bool,
  have_bottomleft : Bool,
  filter_edge : Bool,
  edges : FixedArray[Byte],
) -> (Int32, Int32) {
  let mut mode = mode_in
  let mut angle = angle_in
  if mode >= 1 && mode <= 8 {
    angle = mode_angle[mode - 1] + 3 * angle
    if angle <= 90 {
      mode = if angle < 90 && have_top { 6 } else { 1 }
    } else if angle < 180 {
      mode = 7
    } else {
      mode = if angle > 180 && have_left { 8 } else { 2 }
    }
  } else if mode == 0 || mode == 12 {
    mode = if mode == 0 {
      if have_left {
        if have_top {
          0
        } else {
          16
        }
      } else if have_top {
        15
      } else {
        14
      }
    } else if have_left {
      if have_top {
        12
      } else {
        2
      }
    } else if have_top {
      1
    } else {
      14
    }
  }

  let needs = edge_needs(mode)
  let mut top_value = 0
  if have_top &&
    (
      (needs & (needs_top | needs_topleft)) != 0 ||
      ((needs & needs_left) != 0 && !have_left)
    ) {
    top_value = plane.get(px, py - 1)
  }

  if (needs & needs_left) != 0 {
    let sz = th
    if have_left {
      let available = if frame_h - py < sz { frame_h - py } else { sz }
      for i in 0..<available {
        edges[edge_corner - 1 - i] = plane.get(px - 1, py + i).to_byte()
      }
      for i in available..<sz {
        edges[edge_corner - 1 - i] = edges[edge_corner - available]
      }
    } else {
      let fill = (if have_top { top_value } else { 129 }).to_byte()
      for i in 0..<sz {
        edges[edge_corner - 1 - i] = fill
      }
    }
    if (needs & needs_bottomleft) != 0 {
      let usable = have_left && py + th < frame_h && have_bottomleft
      if usable {
        let available = if frame_h - py - th < sz {
          frame_h - py - th
        } else {
          sz
        }
        for i in 0..<available {
          edges[edge_corner - sz - 1 - i] = plane
            .get(px - 1, py + th + i)
            .to_byte()
        }
        for i in available..<sz {
          edges[edge_corner - sz - 1 - i] = edges[edge_corner - sz - available]
        }
      } else {
        let fill = edges[edge_corner - sz]
        for i in 0..<sz {
          edges[edge_corner - sz - 1 - i] = fill
        }
      }
    }
  }

  if (needs & needs_top) != 0 {
    let sz = tw
    if have_top {
      let available = if frame_w - px < sz { frame_w - px } else { sz }
      for i in 0..<available {
        edges[edge_corner + 1 + i] = plane.get(px + i, py - 1).to_byte()
      }
      for i in available..<sz {
        edges[edge_corner + 1 + i] = edges[edge_corner + available]
      }
    } else {
      let fill = (if have_left { plane.get(px - 1, py) } else { 127 }).to_byte()
      for i in 0..<sz {
        edges[edge_corner + 1 + i] = fill
      }
    }
    if (needs & needs_topright) != 0 {
      let usable = have_top && px + tw < frame_w && have_topright
      if usable {
        let available = if frame_w - px - tw < sz {
          frame_w - px - tw
        } else {
          sz
        }
        for i in 0..<available {
          edges[edge_corner + 1 + sz + i] = plane
            .get(px + tw + i, py - 1)
            .to_byte()
        }
        for i in available..<sz {
          edges[edge_corner + 1 + sz + i] = edges[edge_corner + sz + available]
        }
      } else {
        let fill = edges[edge_corner + sz]
        for i in 0..<sz {
          edges[edge_corner + 1 + sz + i] = fill
        }
      }
    }
  }

  if (needs & needs_topleft) != 0 {
    edges[edge_corner] = if have_left {
      (if have_top { plane.get(px - 1, py - 1) } else { plane.get(px - 1, py) }).to_byte()
    } else if have_top {
      top_value.to_byte()
    } else {
      b'\x80'
    }
    if mode == 7 && tw + th >= 6 && filter_edge {
      edges[edge_corner] = ((
        (edges[edge_corner - 1].to_int() + edges[edge_corner + 1].to_int()) * 5 +
        edges[edge_corner].to_int() * 6 +
        8
      ) >>
      4).to_byte()
    }
  }
  (mode, angle)
}

///|
/// The AC part of a chroma plane predicted from its luma: every luma sample is
/// averaged down to the chroma grid, the mean is taken away, and what is left is
/// the AC the alpha scales.
///
/// `w_pad` and `h_pad` are the columns and rows of the chroma block that no
/// transform reaches — the block is larger than the frame there — and are filled
/// by repeating the last real one, which is what the edge extension does
/// everywhere else.
fn cfl_ac(
  ac : FixedArray[Int32],
  y : Plane,
  px : Int32,
  py : Int32,
  w : Int32,
  h : Int32,
  w_pad : Int32,
  h_pad : Int32,
  ss_hor : Int32,
  ss_ver : Int32,
) -> Unit {
  // A block that sticks out of the picture is covered by whole transforms only
  // as far as the last one that starts inside it, so the padded columns are
  // never more than the block; the clamp says so rather than trusting the
  // arithmetic that produced them.
  let mut real_w = w - w_pad
  let mut real_h = h - h_pad
  if real_w < 4 {
    real_w = w
  }
  if real_h < 4 {
    real_h = h
  }
  if real_w > w {
    real_w = w
  }
  if real_h > h {
    real_h = h
  }
  for yy in 0..<real_h {
    for xx in 0..<real_w {
      let lx = px + (xx << ss_hor)
      let ly = py + (yy << ss_ver)
      let mut sum = y.get(lx, ly)
      if ss_hor != 0 {
        sum = sum + y.get(lx + 1, ly)
      }
      if ss_ver != 0 {
        sum = sum + y.get(lx, ly + 1)
        if ss_hor != 0 {
          sum = sum + y.get(lx + 1, ly + 1)
        }
      }
      ac[yy * w + xx] = sum <<
        (
          1 +
          (if ss_ver != 0 { 0 } else { 1 }) +
          (if ss_hor != 0 { 0 } else { 1 })
        )
    }
    for xx in real_w..<w {
      ac[yy * w + xx] = ac[yy * w + real_w - 1]
    }
  }
  for yy in real_h..<h {
    for xx in 0..<w {
      ac[yy * w + xx] = ac[(real_h - 1) * w + xx]
    }
  }
  let mut log2sz = 0
  let mut side = w
  while side > 1 {
    side = side >> 1
    log2sz = log2sz + 1
  }
  side = h
  while side > 1 {
    side = side >> 1
    log2sz = log2sz + 1
  }
  let mut sum = 1 << log2sz >> 1
  for i in 0..<(w * h) {
    sum = sum + ac[i]
  }
  sum = sum >> log2sz
  for i in 0..<(w * h) {
    ac[i] = ac[i] - sum
  }
}

///|
/// One chroma plane of a block predicted from luma: the DC of its own edges plus
/// the alpha-scaled AC of the luma above.
fn cfl_predict(
  plane : Plane,
  px : Int32,
  py : Int32,
  w : Int32,
  h : Int32,
  dc : Int32,
  ac : FixedArray[Int32],
  alpha : Int32,
) -> Unit {
  for yy in 0..<h {
    for xx in 0..<w {
      let diff = alpha * ac[yy * w + xx]
      let magnitude = ((if diff < 0 { -diff } else { diff }) + 32) >> 6
      let value = dc + (if diff < 0 { -magnitude } else { magnitude })
      plane.set(px + xx, py + yy, clip_sample(value))
    }
  }
}

///|
fn clip_sample(value : Int32) -> Int32 {
  if value < 0 {
    0
  } else if value > 255 {
    255
  } else {
    value
  }
}
