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
  // Kr and Kb of the three matrices that appear in practice.
  let (kr, kb) = if matrix == 1 {
    (2126, 722) // BT.709
  } else if matrix == 9 {
    (2627, 593) // BT.2020
  } else {
    (299, 114) // BT.601, which is also what an unlabelled file means
  }
  let kg = 10000 - kr - kb
  let scale = 4096
  FixedArray::from_array([
    2 * (10000 - kr) * scale / 10000,
    2 * kb * (10000 - kb) * scale / (10000 * kg),
    2 * kr * (10000 - kr) * scale / (10000 * kg),
    2 * (10000 - kb) * scale / 10000,
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
