// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The bit reader a block format is decoded with.
//
// A block of BC7 or BC6H is one hundred and twenty-eight bits of fields with no
// byte boundaries anywhere: a mode of five bits, then endpoints of seven, then
// indices of two, each field starting where the one before it stopped. The whole
// block is loaded into a pair of words and read a field at a time, beginning at
// the least significant bit, which is the order the formats write them.

///|
/// Sixteen bytes as a bit stream, least significant bit first.
priv struct Bits {
  mut low : UInt64
  mut high : UInt64
}

///|
/// Load sixteen bytes, the ones beginning at `at`.
fn Bits::at(bytes : BytesView, at : Int32) -> Bits {
  let mut low = 0UL
  let mut high = 0UL
  let mut i = 0
  while i < 8 {
    low = low | (bytes[at + i].to_int().to_uint64() << (i * 8))
    high = high | (bytes[at + 8 + i].to_int().to_uint64() << (i * 8))
    i = i + 1
  }
  { low, high, }
}

///|
/// The next `count` bits, and the stream moved past them.
fn Bits::read(self : Bits, count : Int32) -> Int32 {
  if count <= 0 {
    return 0
  }
  let width = count
  let mask = (1UL << width) - 1UL
  let taken = self.low & mask
  // What is left of the low word is what the high word has not given up yet,
  // which is the whole point of carrying two: a field may straddle them.
  self.low = (self.low >> width) | ((self.high & mask) << (64 - width))
  self.high = self.high >> width
  taken.to_int()
}

///|
/// The next `count` bits in the other order, which is how a BC6H sample wider
/// than ten bits is written: the low part first, the high part in a field of its
/// own somewhere else, and this is the piece that has to be turned around.
fn Bits::read_reversed(self : Bits, count : Int32) -> Int32 {
  let bits = self.read(count)
  let mut result = 0
  let mut left = count
  let mut value = bits
  while left > 0 {
    result = (result << 1) | (value & 1)
    value = value >> 1
    left = left - 1
  }
  result
}
