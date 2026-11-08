// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Half-precision samples, in and out.
//
// A half is a float with five bits of exponent and ten of mantissa: the same
// shape as a float, narrow enough that a picture of light fits in two bytes a
// sample. OpenEXR stores its pictures this way by default and BC6H stores
// nothing else, so the arithmetic lives beside the pixel formats rather than in
// either of them, and a pixel that is four floats can be built from a block of
// sixteen bytes without a second copy of it.

///|
/// A half-precision sample as a float.
pub fn half_to_float(bits : Int32) -> Float {
  let sign = (bits & 0x8000) << 16
  let exponent = (bits >> 10) & 0x1F
  let mantissa = bits & 0x3FF
  let word = if exponent == 0 {
    if mantissa == 0 {
      sign
    } else {
      let mut m = mantissa
      let mut shift = 0
      while (m & 0x400) == 0 {
        m = m << 1
        shift = shift + 1
      }
      let rest = m & 0x3FF
      sign | ((127 - 14 - shift) << 23) | (rest << 13)
    }
  } else if exponent == 31 {
    sign | 0x7F800000 | (mantissa << 13)
  } else {
    sign | ((exponent - 15 + 127) << 23) | (mantissa << 13)
  }
  Float::reinterpret_from_uint(word.reinterpret_as_uint())
}

///|
/// A float as a half-precision sample, rounded to nearest.
pub fn float_to_half(value : Float) -> Int32 {
  let word = value.reinterpret_as_uint().reinterpret_as_int()
  let sign = (word >> 16) & 0x8000
  let exponent = (word >> 23) & 0xFF
  let mantissa = word & 0x7FFFFF
  if exponent == 0xFF {
    return sign | 0x7C00 | (if mantissa != 0 { 0x200 } else { 0 })
  }
  let shifted = exponent - 127 + 15
  if shifted >= 0x1F {
    return sign | 0x7C00
  }
  if shifted <= 0 {
    if shifted < -10 {
      return sign
    }
    let mant = (mantissa | 0x800000) >> (14 - shifted)
    let rounded = (mant + 1) >> 1
    return sign | rounded
  }
  let mant = (mantissa + 0x1000) >> 13
  if mant >= 0x400 {
    sign | ((shifted + 1) << 10)
  } else {
    sign | (shifted << 10) | mant
  }
}
