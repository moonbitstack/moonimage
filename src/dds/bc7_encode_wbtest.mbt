// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The block writer against the block reader, one square at a time.

///|
test "a block whose first pixel sits at the far end of its colours" {
  // The first pixel of a block is written without the top bit of its weight, so
  // a block whose first pixel is the bright end of the line has a weight above
  // seven — the one weight that would not fit. A writer that did not turn the
  // line around would put that pixel somewhere in the middle, which no bound on
  // a gradient would notice and this test does.
  let square : FixedArray[Byte] = FixedArray::make(64, b'\x00')
  for i in 0..<16 {
    let value = if i == 0 { 250 } else { i * 6 }
    square[i * 4] = value.to_byte()
    square[i * 4 + 1] = value.to_byte()
    square[i * 4 + 2] = value.to_byte()
    square[i * 4 + 3] = b'\xFF'
  }
  let block = bc7_pack(square)
  let back = decode_bc7(Bytes::from_array(block), 0)
  let first = back[0].to_int()
  if (first - 250).abs() > 4 {
    abort("the first pixel came back at \{first} rather than near 250")
  }
  for i in 1..<16 {
    let want = i * 6
    if (back[i * 4].to_int() - want).abs() > 24 {
      abort("pixel \{i}: \{back[i * 4].to_int()} rather than \{want}")
    }
  }
}

///|
test "a block of one colour comes back as that colour" {
  let square : FixedArray[Byte] = FixedArray::make(64, b'\x00')
  for i in 0..<16 {
    square[i * 4] = b'\x33'
    square[i * 4 + 1] = b'\x99'
    square[i * 4 + 2] = b'\xCC'
    square[i * 4 + 3] = b'\xFF'
  }
  let block = bc7_pack(square)
  let back = decode_bc7(Bytes::from_array(block), 0)
  // One step, not none: the four channels of an endpoint share a parity bit, and
  // the blue of this colour is the one of the four that has to move for the
  // other three to land on their own values.
  let wanted : FixedArray[Int32] = [0x33, 0x99, 0xCC, 0xFF]
  for i in 0..<16 {
    for c in 0..<4 {
      if (back[i * 4 + c].to_int() - wanted[c]).abs() > 1 {
        abort("pixel \{i} channel \{c}: \{back[i * 4 + c].to_int()}")
      }
    }
  }
}
