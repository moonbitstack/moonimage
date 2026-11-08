// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// BC6H against another decoder.
//
// Fourteen modes, each with its own order of fields, and the difference between
// them is where a sample's bits live — which is exactly the kind of thing that is
// read correctly eleven times and wrong three. So the blocks below were decoded
// by `bcdec` and the digest of its halves is what these are held to; both the
// signed and the unsigned reading are checked, because they differ in three
// places and one of them is the sign of every endpoint.

///|
/// The halves of a block as the bytes they are, little-endian, so that a digest
/// of them can be compared with the one the reference decoder's output has.
fn halves_bytes(halves : FixedArray[Int32]) -> Bytes {
  let bytes : FixedArray[Byte] = FixedArray::make(halves.length() * 2, b'\x00')
  for index in 0..<halves.length() {
    bytes[index * 2] = (halves[index] & 0xFF).to_byte()
    bytes[index * 2 + 1] = ((halves[index] >> 8) & 0xFF).to_byte()
  }
  Bytes::from_array(bytes.clamped_view())
}

///|
test "every block of BC6H decodes to the halves the reference decoder made" {
  let count = bc6h_blocks.length() / 16
  assert_eq(bc6h_signed_expected.length(), count)
  assert_eq(bc6h_unsigned_expected.length(), count)
  for index in 0..<count {
    let block = bc6h_blocks.clamped_view(start=index * 16, end=index * 16 + 16)
    let signed = digest_bytes(halves_bytes(decode_bc6h(block, 0, true)))
    if signed != bc6h_signed_expected[index] {
      abort(
        "block \{index} signed decodes to \{signed}, want \{bc6h_signed_expected[index]}",
      )
    }
    let unsigned = digest_bytes(halves_bytes(decode_bc6h(block, 0, false)))
    if unsigned != bc6h_unsigned_expected[index] {
      abort(
        "block \{index} unsigned decodes to \{unsigned}, want \{bc6h_unsigned_expected[index]}",
      )
    }
  }
}

///|
test "a reserved mode is black rather than an error" {
  // 0b11111 is reserved: three bits of one after a two-bit mode of three.
  let block : FixedArray[Byte] = FixedArray::make(16, b'\xFF')
  let halves = decode_bc6h(Bytes::from_array(block.clamped_view()), 0, false)
  for index in 0..<48 {
    assert_eq(halves[index], 0)
  }
}
