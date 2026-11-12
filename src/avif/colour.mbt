// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// From the planes to colour.
//
// AV1 codes a picture in a luma plane and two colour differences, with a matrix
// that says how they add back up. The container names the matrix, so it is read
// from there rather than assumed; what is assumed is the arithmetic, which is
// the integer form of the definition in BT.601 for the matrices this library is
// likely to meet.

///|
/// The four multipliers of a matrix, in twelve-bit fixed point: how much of the
/// red difference goes to red, how much of each difference is taken away from
/// green, and how much of the blue difference goes to blue.
fn colour_matrix(matrix : Int32) -> FixedArray[Int32] {
  // Kr and Kb of the three matrices that appear in practice, in ten-thousandths
  // the way the format states them: 0.299 and 0.114 for BT.601, 0.2126 and
  // 0.0722 for BT.709, 0.2627 and 0.0593 for BT.2020.
  let (kr, kb) = if matrix == 1 {
    (2126, 722) // BT.709
  } else if matrix == 9 {
    (2627, 593) // BT.2020
  } else {
    (2990, 1140) // BT.601, which is also what an unlabelled file means
  }
  let kg = 10000 - kr - kb
  // Each multiplier is 2ab/10000c in twelve-bit fixed point, and the product of
  // the middle terms runs past what a thirty-two bit integer holds — a thousand
  // times nine thousand times four thousand is thirty-six thousand million — so
  // it is computed sixty-four bits wide and narrowed once.
  fn scaled(a : Int32, b : Int32, c : Int32) -> Int32 {
    (2L * a.to_int64() * b.to_int64() * 4096L / (10000L * c.to_int64())).to_int()
  }
  FixedArray::from_array([
    scaled(10000 - kr, 10000, 10000),
    scaled(kb, 10000 - kb, kg),
    scaled(kr, 10000 - kr, kg),
    scaled(10000 - kb, 10000, 10000),
  ])
}

///|
/// One pixel of colour from its luma and two differences.
fn to_rgb(
  luma : Int32,
  u : Int32,
  v : Int32,
  coefficients : FixedArray[Int32],
  full_range : Bool,
) -> (Int32, Int32, Int32) {
  let y = if full_range { luma } else { (luma - 16) * 255 / 219 }
  let cb = if full_range { u - 128 } else { (u - 128) * 255 / 224 }
  let cr = if full_range { v - 128 } else { (v - 128) * 255 / 224 }
  let r = y + coefficients[0] * cr / 4096
  let g = y - (coefficients[1] * cb + coefficients[2] * cr) / 4096
  let b = y + coefficients[3] * cb / 4096
  (clip8(r), clip8(g), clip8(b))
}

///|
fn clip8(value : Int32) -> Int32 {
  if value < 0 {
    0
  } else if value > 255 {
    255
  } else {
    value
  }
}
