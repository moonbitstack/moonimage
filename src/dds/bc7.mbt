// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// BC7: sixteen bytes that are one four-by-four square of colour.
//
// A block names a mode in unary — a run of zeroes closed by a one, so mode six
// costs seven bits and mode nought one. The mode is what says how many regions
// the square is cut into, how many bits an endpoint has, whether there is alpha
// at all, and how many bits an index has. Everything after it is read in the
// order the mode dictates.
//
// Endpoints are stored narrower than eight bits and widened by repeating their
// most significant bits into the ones left empty, which is what makes a five-bit
// endpoint reach nought and two hundred and fifty-five exactly rather than
// stopping at two hundred and forty-seven. A pixel is then a weight between its
// region's two endpoints, and the weight tables are not fractions of sixty-four
// but the fractions sixty-four can name, which is why they are tabulated.

///|
/// How many bits an endpoint's colour has, per mode.
let bc7_colour_bits : FixedArray[Int32] = [4, 6, 5, 7, 5, 7, 7, 5]

///|
/// How many bits an endpoint's alpha has, per mode. Nought means the mode has no
/// alpha field and every pixel is opaque.
let bc7_alpha_bits : FixedArray[Int32] = [0, 0, 0, 0, 6, 8, 7, 5]

///|
/// The modes whose endpoints carry a parity bit, one bit of a sample that does
/// not fit in the field it was given.
let bc7_parity_modes : Int32 = 0b11001011

///|
/// One block of BC7, sixteen bytes wide, as sixty-four bytes of RGBA.
fn decode_bc7(bytes : BytesView, at : Int32) -> FixedArray[Byte] {
  let pixels : FixedArray[Byte] = FixedArray::make(64, b'\x00')
  let bits = Bits::at(bytes, at)
  let mut mode = 0
  while mode < 8 {
    if bits.read(1) != 0 {
      break
    }
    mode = mode + 1
  }
  if mode >= 8 {
    // Eight zeroes is not a mode; the hardware hands back transparent black and
    // so does this.
    return pixels
  }
  let mut regions = 1
  if mode == 0 || mode == 2 {
    regions = 3
  } else if mode == 1 || mode == 3 || mode == 7 {
    regions = 2
  }
  let mut shape = 0
  if regions > 1 {
    // A three-region block has sixteen shapes and a two-region one sixty-four,
    // which is why this field is four bits and not six.
    shape = bits.read(if mode == 0 { 4 } else { 6 })
  }
  let mut rotation = 0
  let mut select_alpha = 0
  if mode == 4 || mode == 5 {
    // Two bits that rotate which channel alpha travels in: a block whose alpha
    // is nearly constant packs better in the channel that is not alpha.
    rotation = bits.read(2)
    if mode == 4 {
      select_alpha = bits.read(1)
    }
  }
  let endpoints_count = regions * 2
  let endpoints : FixedArray[Int32] = FixedArray::make(24, 0)
  let colour_bits = bc7_colour_bits[mode]
  let alpha_bits = bc7_alpha_bits[mode]
  for component in 0..<3 {
    for endpoint in 0..<endpoints_count {
      endpoints[endpoint * 4 + component] = bits.read(colour_bits)
    }
  }
  if alpha_bits > 0 {
    for endpoint in 0..<endpoints_count {
      endpoints[endpoint * 4 + 3] = bits.read(alpha_bits)
    }
  }
  if mode == 0 || mode == 1 || mode == 3 || mode == 6 || mode == 7 {
    // The parity bit is one sample wide, shared by all four components of an
    // endpoint, so every component is shifted to make room for it.
    for endpoint in 0..<endpoints_count {
      for component in 0..<4 {
        endpoints[endpoint * 4 + component] = endpoints[endpoint * 4 + component] <<
          1
      }
    }
    if mode == 1 {
      let first = bits.read(1)
      let second = bits.read(1)
      for component in 0..<3 {
        endpoints[component] = endpoints[component] | first
        endpoints[4 + component] = endpoints[4 + component] | first
        endpoints[8 + component] = endpoints[8 + component] | second
        endpoints[12 + component] = endpoints[12 + component] | second
      }
    } else if ((bc7_parity_modes >> mode) & 1) == 1 {
      for endpoint in 0..<endpoints_count {
        let parity = bits.read(1)
        for component in 0..<4 {
          endpoints[endpoint * 4 + component] = endpoints[endpoint * 4 +
            component] |
            parity
        }
      }
    }
  }
  for endpoint in 0..<endpoints_count {
    let width = colour_bits + ((bc7_parity_modes >> mode) & 1)
    for component in 0..<3 {
      let value = endpoints[endpoint * 4 + component] << (8 - width)
      endpoints[endpoint * 4 + component] = value | (value >> width)
    }
    let alpha_width = alpha_bits + ((bc7_parity_modes >> mode) & 1)
    let alpha = endpoints[endpoint * 4 + 3] << (8 - alpha_width)
    endpoints[endpoint * 4 + 3] = alpha | (alpha >> alpha_width)
  }
  if alpha_bits == 0 {
    for endpoint in 0..<endpoints_count {
      endpoints[endpoint * 4 + 3] = 0xFF
    }
  }
  let index_bits = if mode == 0 || mode == 1 {
    3
  } else if mode == 6 {
    4
  } else {
    2
  }
  let alpha_index_bits = if mode == 4 { 3 } else if mode == 5 { 2 } else { 0 }
  // Indices are not interleaved with the endpoints: every colour index in the
  // block comes before every alpha index, so they are read in two passes.
  let indices : FixedArray[Int32] = FixedArray::make(16, 0)
  for row in 0..<4 {
    for column in 0..<4 {
      let cell = if regions == 1 {
        if row == 0 && column == 0 {
          128
        } else {
          0
        }
      } else {
        bc7_partitions[(regions - 2) * 1024 + shape * 16 + row * 4 + column].to_int()
      }
      // The first pixel of a region always has index nought, so its index is
      // written one bit narrower.
      let width = if (cell & 0x80) != 0 { index_bits - 1 } else { index_bits }
      indices[row * 4 + column] = bits.read(width)
    }
  }
  for row in 0..<4 {
    for column in 0..<4 {
      let cell = if regions == 1 {
        if row == 0 && column == 0 {
          128
        } else {
          0
        }
      } else {
        bc7_partitions[(regions - 2) * 1024 + shape * 16 + row * 4 + column].to_int()
      }
      let region = cell & 0x03
      let index = indices[row * 4 + column]
      let mut red = 0
      let mut green = 0
      let mut blue = 0
      let mut alpha = 0
      if alpha_index_bits == 0 {
        red = bc7_interpolate(endpoints, region, 0, index, index_bits)
        green = bc7_interpolate(endpoints, region, 1, index, index_bits)
        blue = bc7_interpolate(endpoints, region, 2, index, index_bits)
        alpha = bc7_interpolate(endpoints, region, 3, index, index_bits)
      } else {
        let second = bits.read(
          if row == 0 && column == 0 {
            alpha_index_bits - 1
          } else {
            alpha_index_bits
          },
        )
        // Which of the two index sets drives colour and which drives alpha:
        // mode four lets the block choose, mode five does not.
        if select_alpha == 0 {
          red = bc7_interpolate(endpoints, region, 0, index, index_bits)
          green = bc7_interpolate(endpoints, region, 1, index, index_bits)
          blue = bc7_interpolate(endpoints, region, 2, index, index_bits)
          alpha = bc7_interpolate(
            endpoints, region, 3, second, alpha_index_bits,
          )
        } else {
          red = bc7_interpolate(endpoints, region, 0, second, alpha_index_bits)
          green = bc7_interpolate(
            endpoints, region, 1, second, alpha_index_bits,
          )
          blue = bc7_interpolate(endpoints, region, 2, second, alpha_index_bits)
          alpha = bc7_interpolate(endpoints, region, 3, index, index_bits)
        }
      }
      // The rotation moves the alpha samples into whichever channel the block
      // found cheapest to code, so undoing it swaps them back.
      let mut first = red
      let mut second = green
      let mut third = blue
      let mut last = alpha
      if rotation == 1 {
        let held = first
        first = last
        last = held
      } else if rotation == 2 {
        let held = second
        second = last
        last = held
      } else if rotation == 3 {
        let held = third
        third = last
        last = held
      }
      let at_pixel = (row * 4 + column) * 4
      pixels[at_pixel] = first.to_byte()
      pixels[at_pixel + 1] = second.to_byte()
      pixels[at_pixel + 2] = third.to_byte()
      pixels[at_pixel + 3] = last.to_byte()
    }
  }
  pixels
}

///|
/// One component of one pixel, between the two endpoints of its region.
fn bc7_interpolate(
  endpoints : FixedArray[Int32],
  region : Int32,
  component : Int32,
  index : Int32,
  index_bits : Int32,
) -> Int32 {
  let weights = bc7_weights(index_bits)
  let low = endpoints[region * 8 + component]
  let high = endpoints[region * 8 + 4 + component]
  (low * (64 - weights[index]) + high * weights[index] + 32) >> 6
}

///|
/// The weights an index of this width stands for.
fn bc7_weights(index_bits : Int32) -> FixedArray[Int32] {
  match index_bits {
    2 => weights_two
    3 => weights_three
    _ => weights_four
  }
}
