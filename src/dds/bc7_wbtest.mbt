// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// BC7 against another decoder.
//
// The format is a mode number and five tables of shapes, and a mode is decided
// by reading a run of bits nothing else describes. A test that only round-tripped
// would prove nothing: there is no BC7 encoder here, and a table typed one row
// out of place decodes into a picture that still looks plausible. So each block
// below was decoded by `bcdec`, a reference decoder written outside this
// repository, and the digest of what it made is what this is held to.

///|
test "every block of BC7 decodes to the pixels the reference decoder made" {
  let count = bc7_blocks.length() / 16
  assert_eq(bc7_expected.length(), count)
  for index in 0..<count {
    let pixels = decode_bc7(bc7_blocks, index * 16)
    let actual = digest_bytes(Bytes::from_array(pixels.clamped_view()))
    if actual != bc7_expected[index] {
      abort("block \{index} decodes to \{actual}, want \{bc7_expected[index]}")
    }
  }
}

///|
test "a block of eight noughts is not a mode, and is transparent black" {
  let zero : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  let pixels = decode_bc7(Bytes::from_array(zero.clamped_view()), 0)
  for index in 0..<16 {
    let at = index * 4
    assert_eq(pixels[at], b'\x00')
    assert_eq(pixels[at + 3], b'\x00')
  }
}

///|
test "a block with every endpoint at nought is black and opaque" {
  // Mode three, which is three noughts and then a one: the mode is read from the
  // low bit, so the one is at bit three. Everything after it is nought, so both
  // endpoints of both regions are nought and every weight lands on the same
  // colour — and the mode has no alpha field, so that colour is opaque.
  let block : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  block[0] = b'\x08'
  let pixels = decode_bc7(Bytes::from_array(block.clamped_view()), 0)
  for index in 0..<16 {
    let at = index * 4
    assert_eq(pixels[at], b'\x00')
    assert_eq(pixels[at + 3], b'\xFF')
  }
}
