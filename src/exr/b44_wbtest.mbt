// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The rounding inside a B44 block, at the values where the rule can be told
// apart from the one beside it.

///|
/// A block keeps fifteen differences of six bits, so the step a value is
/// rounded to is a sixty-fourth of the block's span, and the shift that finds it
/// is chosen per block. The format rounds that division to nearest with ties to
/// even — the same rule as IEEE arithmetic — which is not the same as adding
/// half a step and truncating, and the two agree everywhere except exactly
/// halfway between two steps.
///
/// The numbers here are the definition written out: six divided by four is one
/// and a half, which goes to two; two divided by four is a half, which goes to
/// zero because zero is the even neighbour; ten divided by four is two and a
/// half, which goes to two; and so on through three a step, where the halfway
/// point falls between two odd neighbours and the next even one up is taken.
///
/// A rounding that added half a step and truncated would answer one, one, two
/// and four on those four, so the difference is one step in every tie, and it is
/// the step that a picture with a wide block span is most likely to land on.
test "a B44 shift rounds to nearest, ties to even" {
  // Three halves, seven halves, eleven halves: each is a tie, each goes up to
  // the even number.
  assert_eq(b44_shift_and_round(6, 2), 2)
  assert_eq(b44_shift_and_round(14, 2), 4)
  assert_eq(b44_shift_and_round(22, 2), 6)
  // A half and two and a half: both ties, both already even below.
  assert_eq(b44_shift_and_round(2, 2), 0)
  assert_eq(b44_shift_and_round(10, 2), 2)
  // Not a tie, and both sides of the halfway point.
  assert_eq(b44_shift_and_round(4, 2), 1)
  assert_eq(b44_shift_and_round(5, 2), 1)
  assert_eq(b44_shift_and_round(7, 2), 2)
  // The same rule at a wider shift: three halves and five halves go up, a half
  // goes down, and a value just above one goes to one.
  assert_eq(b44_shift_and_round(12, 3), 2)
  assert_eq(b44_shift_and_round(20, 3), 2)
  assert_eq(b44_shift_and_round(4, 3), 0)
  assert_eq(b44_shift_and_round(9, 3), 1)
  assert_eq(b44_shift_and_round(13, 3), 2)
  // A shift of four, where every fourth step is exact.
  assert_eq(b44_shift_and_round(48, 4), 3)
  assert_eq(b44_shift_and_round(24, 4), 2)
  assert_eq(b44_shift_and_round(40, 4), 2)
}
