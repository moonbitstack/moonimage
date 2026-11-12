// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The colour behind the planes: three multipliers per matrix, in twelve-bit
// fixed point, and the one place a well-meant constant can be out by ten.

///|
test "a full-range BT.601 triple comes back as the colour it stands for" {
  // YUV (122, 149, 109) is what libavif writes for the flat sample's RGB
  // (96, 128, 160); the arithmetic has to land within a step of it.
  assert_eq(to_rgb(122, 149, 109, colour_matrix(6), true), (96, 128, 159))
}

///|
test "grey stays grey in every matrix and both ranges" {
  for matrix in [1, 6, 9] {
    let coefficients = colour_matrix(matrix)
    assert_eq(to_rgb(128, 128, 128, coefficients, true), (128, 128, 128))
    // Limited range puts 128 at sixteen and 235: the mid-point is 126.
    assert_eq(to_rgb(126, 128, 128, coefficients, false), (128, 128, 128))
  }
}
