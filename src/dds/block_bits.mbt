// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The bit writer a block format is encoded with.
//
// A block is one hundred and twenty-eight bits of fields with no byte
// boundaries: the format writes the least significant bit of a field first, and
// the field after it begins where it stopped. Sixteen bytes are enough for every
// block this library writes.

///|
/// Sixteen bytes, filled a field at a time.
priv struct BlockBits {
  bytes : FixedArray[Byte]
  mut at : Int32
}

///|
fn BlockBits::new() -> BlockBits {
  { bytes: FixedArray::make(16, b'\x00'), at: 0, }
}

///|
/// The low `count` bits of a value, written in the order the format reads them.
fn BlockBits::put(self : BlockBits, value : Int32, count : Int32) -> Unit {
  for i in 0..<count {
    if ((value >> i) & 1) != 0 {
      let byte = self.at / 8
      let bit = self.at % 8
      self.bytes[byte] = (self.bytes[byte].to_int() | (1 << bit)).to_byte()
    }
    self.at = self.at + 1
  }
}

///|
fn BlockBits::to_bytes(self : BlockBits) -> FixedArray[Byte] {
  self.bytes
}
