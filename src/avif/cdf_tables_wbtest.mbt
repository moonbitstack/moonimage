// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The generated table against the reference source it came from.

///|
/// FNV-1a over two little-endian bytes of each entry, which is the digest
/// `scripts/fixtures/av1_cdf.py` computed from dav1d's cdf.c before it wrote
/// the table. A hand-edited number, a missing row or a transposed context all
/// change it.
fn cdf_digest(data : FixedArray[Int32]) -> String {
  let mut value : UInt64 = 0xCBF29CE484222325
  for i in 0..<data.length() {
    let word = data[i]
    for shift in [0, 8] {
      let byte = (word >> shift) & 0xFF
      value = (value ^ byte.to_uint64()) * 0x100000001B3
    }
  }
  let digits = "0123456789abcdef"
  let mut out = ""
  for place in 0..<16 {
    let nibble = ((value >> ((15 - place) * 4)) & 0xF).to_int()
    out = out + digits[nibble:nibble + 1].to_owned()
  }
  out
}

///|
test "every default CDF is the one in the reference source" {
  assert_eq(cdf_digest(cdf_all), cdf_reference_digest)
}

///|
test "a fresh table is a copy, not the defaults themselves" {
  let working = cdf_fresh()
  assert_eq(working.length(), cdf_all.length())
  let first = working[0]
  working[0] = 12345
  assert_eq(cdf_all[0], first)
  assert_eq(cdf_fresh()[0], first)
}

///|
test "the offsets walk the tables without a gap" {
  for i in 0..<(cdf_offsets.length() - 1) {
    assert_true(cdf_offsets[i] < cdf_offsets[i + 1])
  }
  assert_true(cdf_offsets[cdf_offsets.length() - 1] < cdf_all.length())
}
