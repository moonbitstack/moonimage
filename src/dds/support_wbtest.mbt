// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The one helper the white-box tests need: the digest the reference decoder's
// output was reduced to. It is the same function as the one the sample tests use,
// and it is here rather than there because a white-box test is compiled into the
// package and a black-box one is not.

///|
/// FNV-1a over bytes, which is how every comparison in this package is made.
fn digest_bytes(bytes : Bytes) -> String {
  let mut value : UInt64 = 0xCBF29CE484222325UL
  for i in 0..<bytes.length() {
    let byte = bytes[i].to_int() & 0xFF
    value = (value ^ byte.to_uint64()) * 0x100000001B3UL
  }
  hex_of(value)
}

///|
fn hex_of(value : UInt64) -> String {
  let digits = "0123456789abcdef"
  let mut out = ""
  for place in 0..<16 {
    let shift = (15 - place) * 4
    let nibble = ((value >> shift) & 0xFUL).to_int()
    out = out + digits[nibble:nibble + 1].to_owned()
  }
  out
}
