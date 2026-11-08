// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The helpers the sample tests in this package share: the digest the generator
// computed on the reference side, and a way to read a pixel without handling a
// refusal that cannot happen.

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

///|
/// FNV-1a over the float samples of an image, which is what a picture of light
/// is compared by: rounding it to eight bits first would throw away the range
/// the format exists for.
fn float_digest_of(image : @raster.Image) -> String {
  digest_bytes(image.convert(@raster.PixelFormat::RgbaF32).pixels)
}
