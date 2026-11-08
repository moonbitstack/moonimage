// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// BC6H: sixteen bytes that are one four-by-four square of light.
//
// The format stores colour without an alpha channel and without a ceiling: a
// sample is a half float, or a float, and a sun is ten thousand times a wall.
// What it does not store is the exponent of every sample separately. The block
// picks a mode, and the mode says how many bits an endpoint has for its
// exponent-free magnitude and how many for the difference to the other endpoint
// — so a block of one colour spends everything on precision, and a block with a
// bright corner and a dark one spends it on range.
//
// Fourteen modes, each with its fields in its own order, which is why the mode
// switch below is long and dull: it is the format's own table transcribed, one
// read at a time. The reserved modes decode to black, which is what the hardware
// does with them.

///|
/// How many bits of an endpoint each mode gives: the magnitude first, then the
/// difference from it in each of the three channels.
let bc6h_bits : FixedArray[Int32] = [
  10, 7, 11, 11, 11, 9, 8, 8, 8, 6, 10, 11, 12, 16, 5, 6, 5, 4, 4, 5, 6, 5, 5, 6,
  10, 9, 8, 4, 5, 6, 4, 5, 4, 5, 5, 6, 5, 6, 10, 9, 8, 4, 5, 6, 4, 4, 5, 5, 5, 5,
  6, 6, 10, 9, 8, 4,
]

///|
/// How many bits row `row` — the magnitude at nought, the differences after —
/// gives an endpoint of mode `mode`.
fn bc6h_field(row : Int32, mode : Int32) -> Int32 {
  bc6h_bits[row * 14 + mode]
}

///|
/// One block of BC6H as forty-eight half-precision samples, red first.
///
/// The samples are the bit patterns of the halves rather than the numbers they
/// stand for, because that is what the format stores and what two decoders can
/// agree on without either of them rounding.
fn decode_bc6h(
  bytes : BytesView,
  at : Int32,
  signed : Bool,
) -> FixedArray[Int32] {
  let halves : FixedArray[Int32] = FixedArray::make(48, 0)
  let bits = Bits::at(bytes, at)
  let red : FixedArray[Int32] = FixedArray::make(4, 0)
  let green : FixedArray[Int32] = FixedArray::make(4, 0)
  let blue : FixedArray[Int32] = FixedArray::make(4, 0)
  let mut mode = bits.read(2)
  if mode > 1 {
    // Five bits of mode, read as two and then three: the first two are what say
    // whether there are three more.
    mode = mode | (bits.read(3) << 2)
  }
  let mut shape = 0
  // The index into the tables, which is not the mode number: the modes are
  // numbered by their bits and the tables by their order.
  let mut which = -1
  match mode {
    0 => {
      green[2] = green[2] | (bits.read(1) << 4)
      blue[2] = blue[2] | (bits.read(1) << 4)
      blue[3] = blue[3] | (bits.read(1) << 4)
      red[0] = red[0] | bits.read(10)
      green[0] = green[0] | bits.read(10)
      blue[0] = blue[0] | bits.read(10)
      red[1] = red[1] | bits.read(5)
      green[3] = green[3] | (bits.read(1) << 4)
      green[2] = green[2] | bits.read(4)
      green[1] = green[1] | bits.read(5)
      blue[3] = blue[3] | bits.read(1)
      green[3] = green[3] | bits.read(4)
      blue[1] = blue[1] | bits.read(5)
      blue[3] = blue[3] | (bits.read(1) << 1)
      blue[2] = blue[2] | bits.read(4)
      red[2] = red[2] | bits.read(5)
      blue[3] = blue[3] | (bits.read(1) << 2)
      red[3] = red[3] | bits.read(5)
      blue[3] = blue[3] | (bits.read(1) << 3)
      shape = bits.read(5)
      which = 0
    }
    1 => {
      green[2] = green[2] | (bits.read(1) << 5)
      green[3] = green[3] | (bits.read(1) << 4)
      green[3] = green[3] | (bits.read(1) << 5)
      red[0] = red[0] | bits.read(7)
      blue[3] = blue[3] | bits.read(1)
      blue[3] = blue[3] | (bits.read(1) << 1)
      blue[2] = blue[2] | (bits.read(1) << 4)
      green[0] = green[0] | bits.read(7)
      blue[2] = blue[2] | (bits.read(1) << 5)
      blue[3] = blue[3] | (bits.read(1) << 2)
      green[2] = green[2] | (bits.read(1) << 4)
      blue[0] = blue[0] | bits.read(7)
      blue[3] = blue[3] | (bits.read(1) << 3)
      blue[3] = blue[3] | (bits.read(1) << 5)
      blue[3] = blue[3] | (bits.read(1) << 4)
      red[1] = red[1] | bits.read(6)
      green[2] = green[2] | bits.read(4)
      green[1] = green[1] | bits.read(6)
      green[3] = green[3] | bits.read(4)
      blue[1] = blue[1] | bits.read(6)
      blue[2] = blue[2] | bits.read(4)
      red[2] = red[2] | bits.read(6)
      red[3] = red[3] | bits.read(6)
      shape = bits.read(5)
      which = 1
    }
    2 => {
      red[0] = red[0] | bits.read(10)
      green[0] = green[0] | bits.read(10)
      blue[0] = blue[0] | bits.read(10)
      red[1] = red[1] | bits.read(5)
      red[0] = red[0] | (bits.read(1) << 10)
      green[2] = green[2] | bits.read(4)
      green[1] = green[1] | bits.read(4)
      green[0] = green[0] | (bits.read(1) << 10)
      blue[3] = blue[3] | bits.read(1)
      green[3] = green[3] | bits.read(4)
      blue[1] = blue[1] | bits.read(4)
      blue[0] = blue[0] | (bits.read(1) << 10)
      blue[3] = blue[3] | (bits.read(1) << 1)
      blue[2] = blue[2] | bits.read(4)
      red[2] = red[2] | bits.read(5)
      blue[3] = blue[3] | (bits.read(1) << 2)
      red[3] = red[3] | bits.read(5)
      blue[3] = blue[3] | (bits.read(1) << 3)
      shape = bits.read(5)
      which = 2
    }
    6 => {
      red[0] = red[0] | bits.read(10)
      green[0] = green[0] | bits.read(10)
      blue[0] = blue[0] | bits.read(10)
      red[1] = red[1] | bits.read(4)
      red[0] = red[0] | (bits.read(1) << 10)
      green[3] = green[3] | (bits.read(1) << 4)
      green[2] = green[2] | bits.read(4)
      green[1] = green[1] | bits.read(5)
      green[0] = green[0] | (bits.read(1) << 10)
      green[3] = green[3] | bits.read(4)
      blue[1] = blue[1] | bits.read(4)
      blue[0] = blue[0] | (bits.read(1) << 10)
      blue[3] = blue[3] | (bits.read(1) << 1)
      blue[2] = blue[2] | bits.read(4)
      red[2] = red[2] | bits.read(4)
      blue[3] = blue[3] | bits.read(1)
      blue[3] = blue[3] | (bits.read(1) << 2)
      red[3] = red[3] | bits.read(4)
      green[2] = green[2] | (bits.read(1) << 4)
      blue[3] = blue[3] | (bits.read(1) << 3)
      shape = bits.read(5)
      which = 3
    }
    10 => {
      red[0] = red[0] | bits.read(10)
      green[0] = green[0] | bits.read(10)
      blue[0] = blue[0] | bits.read(10)
      red[1] = red[1] | bits.read(4)
      red[0] = red[0] | (bits.read(1) << 10)
      blue[2] = blue[2] | (bits.read(1) << 4)
      green[2] = green[2] | bits.read(4)
      green[1] = green[1] | bits.read(4)
      green[0] = green[0] | (bits.read(1) << 10)
      blue[3] = blue[3] | bits.read(1)
      green[3] = green[3] | bits.read(4)
      blue[1] = blue[1] | bits.read(5)
      blue[0] = blue[0] | (bits.read(1) << 10)
      blue[2] = blue[2] | bits.read(4)
      red[2] = red[2] | bits.read(4)
      blue[3] = blue[3] | (bits.read(1) << 1)
      blue[3] = blue[3] | (bits.read(1) << 2)
      red[3] = red[3] | bits.read(4)
      blue[3] = blue[3] | (bits.read(1) << 4)
      blue[3] = blue[3] | (bits.read(1) << 3)
      shape = bits.read(5)
      which = 4
    }
    14 => {
      red[0] = red[0] | bits.read(9)
      blue[2] = blue[2] | (bits.read(1) << 4)
      green[0] = green[0] | bits.read(9)
      green[2] = green[2] | (bits.read(1) << 4)
      blue[0] = blue[0] | bits.read(9)
      blue[3] = blue[3] | (bits.read(1) << 4)
      red[1] = red[1] | bits.read(5)
      green[3] = green[3] | (bits.read(1) << 4)
      green[2] = green[2] | bits.read(4)
      green[1] = green[1] | bits.read(5)
      blue[3] = blue[3] | bits.read(1)
      green[3] = green[3] | bits.read(4)
      blue[1] = blue[1] | bits.read(5)
      blue[3] = blue[3] | (bits.read(1) << 1)
      blue[2] = blue[2] | bits.read(4)
      red[2] = red[2] | bits.read(5)
      blue[3] = blue[3] | (bits.read(1) << 2)
      red[3] = red[3] | bits.read(5)
      blue[3] = blue[3] | (bits.read(1) << 3)
      shape = bits.read(5)
      which = 5
    }
    18 => {
      red[0] = red[0] | bits.read(8)
      green[3] = green[3] | (bits.read(1) << 4)
      blue[2] = blue[2] | (bits.read(1) << 4)
      green[0] = green[0] | bits.read(8)
      blue[3] = blue[3] | (bits.read(1) << 2)
      green[2] = green[2] | (bits.read(1) << 4)
      blue[0] = blue[0] | bits.read(8)
      blue[3] = blue[3] | (bits.read(1) << 3)
      blue[3] = blue[3] | (bits.read(1) << 4)
      red[1] = red[1] | bits.read(6)
      green[2] = green[2] | bits.read(4)
      green[1] = green[1] | bits.read(5)
      blue[3] = blue[3] | bits.read(1)
      green[3] = green[3] | bits.read(4)
      blue[1] = blue[1] | bits.read(5)
      blue[3] = blue[3] | (bits.read(1) << 1)
      blue[2] = blue[2] | bits.read(4)
      red[2] = red[2] | bits.read(6)
      red[3] = red[3] | bits.read(6)
      shape = bits.read(5)
      which = 6
    }
    22 => {
      red[0] = red[0] | bits.read(8)
      blue[3] = blue[3] | bits.read(1)
      blue[2] = blue[2] | (bits.read(1) << 4)
      green[0] = green[0] | bits.read(8)
      green[2] = green[2] | (bits.read(1) << 5)
      green[2] = green[2] | (bits.read(1) << 4)
      blue[0] = blue[0] | bits.read(8)
      green[3] = green[3] | (bits.read(1) << 5)
      blue[3] = blue[3] | (bits.read(1) << 4)
      red[1] = red[1] | bits.read(5)
      green[3] = green[3] | (bits.read(1) << 4)
      green[2] = green[2] | bits.read(4)
      green[1] = green[1] | bits.read(6)
      green[3] = green[3] | bits.read(4)
      blue[1] = blue[1] | bits.read(5)
      blue[3] = blue[3] | (bits.read(1) << 1)
      blue[2] = blue[2] | bits.read(4)
      red[2] = red[2] | bits.read(5)
      blue[3] = blue[3] | (bits.read(1) << 2)
      red[3] = red[3] | bits.read(5)
      blue[3] = blue[3] | (bits.read(1) << 3)
      shape = bits.read(5)
      which = 7
    }
    26 => {
      red[0] = red[0] | bits.read(8)
      blue[3] = blue[3] | (bits.read(1) << 1)
      blue[2] = blue[2] | (bits.read(1) << 4)
      green[0] = green[0] | bits.read(8)
      blue[2] = blue[2] | (bits.read(1) << 5)
      green[2] = green[2] | (bits.read(1) << 4)
      blue[0] = blue[0] | bits.read(8)
      blue[3] = blue[3] | (bits.read(1) << 5)
      blue[3] = blue[3] | (bits.read(1) << 4)
      red[1] = red[1] | bits.read(5)
      green[3] = green[3] | (bits.read(1) << 4)
      green[2] = green[2] | bits.read(4)
      green[1] = green[1] | bits.read(5)
      blue[3] = blue[3] | bits.read(1)
      green[3] = green[3] | bits.read(4)
      blue[1] = blue[1] | bits.read(6)
      blue[2] = blue[2] | bits.read(4)
      red[2] = red[2] | bits.read(5)
      blue[3] = blue[3] | (bits.read(1) << 2)
      red[3] = red[3] | bits.read(5)
      blue[3] = blue[3] | (bits.read(1) << 3)
      shape = bits.read(5)
      which = 8
    }
    30 => {
      red[0] = red[0] | bits.read(6)
      green[3] = green[3] | (bits.read(1) << 4)
      blue[3] = blue[3] | bits.read(1)
      blue[3] = blue[3] | (bits.read(1) << 1)
      blue[2] = blue[2] | (bits.read(1) << 4)
      green[0] = green[0] | bits.read(6)
      green[2] = green[2] | (bits.read(1) << 5)
      blue[2] = blue[2] | (bits.read(1) << 5)
      blue[3] = blue[3] | (bits.read(1) << 2)
      green[2] = green[2] | (bits.read(1) << 4)
      blue[0] = blue[0] | bits.read(6)
      green[3] = green[3] | (bits.read(1) << 5)
      blue[3] = blue[3] | (bits.read(1) << 3)
      blue[3] = blue[3] | (bits.read(1) << 5)
      blue[3] = blue[3] | (bits.read(1) << 4)
      red[1] = red[1] | bits.read(6)
      green[2] = green[2] | bits.read(4)
      green[1] = green[1] | bits.read(6)
      green[3] = green[3] | bits.read(4)
      blue[1] = blue[1] | bits.read(6)
      blue[2] = blue[2] | bits.read(4)
      red[2] = red[2] | bits.read(6)
      red[3] = red[3] | bits.read(6)
      shape = bits.read(5)
      which = 9
    }
    3 => {
      red[0] = red[0] | bits.read(10)
      green[0] = green[0] | bits.read(10)
      blue[0] = blue[0] | bits.read(10)
      red[1] = red[1] | bits.read(10)
      green[1] = green[1] | bits.read(10)
      blue[1] = blue[1] | bits.read(10)
      which = 10
    }
    7 => {
      red[0] = red[0] | bits.read(10)
      green[0] = green[0] | bits.read(10)
      blue[0] = blue[0] | bits.read(10)
      red[1] = red[1] | bits.read(9)
      red[0] = red[0] | (bits.read(1) << 10)
      green[1] = green[1] | bits.read(9)
      green[0] = green[0] | (bits.read(1) << 10)
      blue[1] = blue[1] | bits.read(9)
      blue[0] = blue[0] | (bits.read(1) << 10)
      which = 11
    }
    11 => {
      red[0] = red[0] | bits.read(10)
      green[0] = green[0] | bits.read(10)
      blue[0] = blue[0] | bits.read(10)
      red[1] = red[1] | bits.read(8)
      red[0] = red[0] | (bits.read_reversed(2) << 10)
      green[1] = green[1] | bits.read(8)
      green[0] = green[0] | (bits.read_reversed(2) << 10)
      blue[1] = blue[1] | bits.read(8)
      blue[0] = blue[0] | (bits.read_reversed(2) << 10)
      which = 12
    }
    15 => {
      red[0] = red[0] | bits.read(10)
      green[0] = green[0] | bits.read(10)
      blue[0] = blue[0] | bits.read(10)
      red[1] = red[1] | bits.read(4)
      red[0] = red[0] | (bits.read_reversed(6) << 10)
      green[1] = green[1] | bits.read(4)
      green[0] = green[0] | (bits.read_reversed(6) << 10)
      blue[1] = blue[1] | bits.read(4)
      blue[0] = blue[0] | (bits.read_reversed(6) << 10)
      which = 13
    }
    _ => ()
  }
  if which < 0 {
    // A reserved mode is black, and this is what the hardware makes of one.
    return halves
  }
  // The last four modes are one region and name both of its endpoints whole; the
  // ten before them cut the square in two and store the second endpoint of each
  // as a difference from the first, one per channel.
  let pairs = if which >= 10 { 1 } else { 2 }
  let value_bits = bc6h_field(0, which)
  if signed {
    red[0] = extend_sign(red[0], value_bits)
    green[0] = extend_sign(green[0], value_bits)
    blue[0] = extend_sign(blue[0], value_bits)
  }
  let endpoints = pairs * 2
  if (which != 9 && which != 10) || signed {
    for i in 1..<endpoints {
      red[i] = extend_sign(red[i], bc6h_field(1, which))
      green[i] = extend_sign(green[i], bc6h_field(2, which))
      blue[i] = extend_sign(blue[i], bc6h_field(3, which))
    }
  }
  if which != 9 && which != 10 {
    for i in 1..<endpoints {
      red[i] = transform_inverse(red[i], red[0], value_bits, signed)
      green[i] = transform_inverse(green[i], green[0], value_bits, signed)
      blue[i] = transform_inverse(blue[i], blue[0], value_bits, signed)
    }
  }
  for i in 0..<endpoints {
    red[i] = unquantize(red[i], value_bits, signed)
    green[i] = unquantize(green[i], value_bits, signed)
    blue[i] = unquantize(blue[i], value_bits, signed)
  }
  let weights = if which >= 10 { weights_four } else { weights_three }
  for row in 0..<4 {
    for column in 0..<4 {
      let cell = if which >= 10 {
        if row == 0 && column == 0 {
          128
        } else {
          0
        }
      } else {
        bc6h_partitions[shape * 16 + row * 4 + column].to_int()
      }
      // Four bits an index in the modes that spend everything on one region,
      // three in the modes that cut the square in two; and the first pixel of a
      // region is written without the bit that would always be nought.
      let width = if (cell & 0x80) != 0 {
        if which >= 10 {
          3
        } else {
          2
        }
      } else if which >= 10 {
        4
      } else {
        3
      }
      let index = bits.read(width)
      let pair = cell & 0x01
      let at_pixel = (row * 4 + column) * 3
      halves[at_pixel] = finish_unquantize(
        interpolate(red[pair * 2], red[pair * 2 + 1], weights, index),
        signed,
      )
      halves[at_pixel + 1] = finish_unquantize(
        interpolate(green[pair * 2], green[pair * 2 + 1], weights, index),
        signed,
      )
      halves[at_pixel + 2] = finish_unquantize(
        interpolate(blue[pair * 2], blue[pair * 2 + 1], weights, index),
        signed,
      )
    }
  }
  halves
}

///|
/// A field of `width` bits as a number that is allowed to be negative: two's
/// complement, done by shifting the sign bit to the top and letting the
/// arithmetic shift bring it back with its copies attached.
fn extend_sign(value : Int32, width : Int32) -> Int32 {
  value << (32 - width) >> (32 - width)
}

///|
/// An endpoint stored as a difference, put back into the magnitude's frame.
fn transform_inverse(
  value : Int32,
  base : Int32,
  width : Int32,
  signed : Bool,
) -> Int32 {
  let folded = (value + base) & ((1 << width) - 1)
  if signed {
    extend_sign(folded, width)
  } else {
    folded
  }
}

///|
/// A magnitude spread over the range a half can hold, which is what the samples
/// are before they are interpolated: nought stays nought, the largest stays the
/// largest, and everything between is scaled.
fn unquantize(value : Int32, width : Int32, signed : Bool) -> Int32 {
  if !signed {
    if width >= 15 {
      value
    } else if value == 0 {
      0
    } else if value == (1 << width) - 1 {
      0xFFFF
    } else {
      ((value << 16) + 0x8000) >> width
    }
  } else if width >= 16 {
    value
  } else {
    let negative = value < 0
    let magnitude = if negative { -value } else { value }
    let scaled = if magnitude == 0 {
      0
    } else if magnitude >= (1 << (width - 1)) - 1 {
      0x7FFF
    } else {
      ((magnitude << 15) + 0x4000) >> (width - 1)
    }
    if negative {
      -scaled
    } else {
      scaled
    }
  }
}

///|
/// An interpolated magnitude as the half-precision sample it is stored as.
fn finish_unquantize(value : Int32, signed : Bool) -> Int32 {
  if !signed {
    // Thirty-one sixty-fourths, which is how a magnitude becomes a half.
    (value * 31) >> 6
  } else {
    // A signed magnitude is scaled by thirty-one thirty-seconds, and the sign
    // goes back into the half's own sign bit rather than into the number.
    let scaled = if value < 0 {
      -((-value * 31) >> 5)
    } else {
      (value * 31) >> 5
    }
    if scaled < 0 {
      0x8000 | -scaled
    } else {
      scaled
    }
  }
}

///|
/// A pixel between the two endpoints of its pair, in the weights of a mode.
fn interpolate(
  low : Int32,
  high : Int32,
  weights : FixedArray[Int32],
  index : Int32,
) -> Int32 {
  (low * (64 - weights[index]) + high * weights[index] + 32) >> 6
}
