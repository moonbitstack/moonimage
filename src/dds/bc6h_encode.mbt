// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing a BC6H block.
//
// Mode three: one region, two endpoints of ten bits a channel, and sixteen
// weights of four. It is the mode that says the most about a single region — the
// mode with two regions spends those bits on a shape instead — and a block of
// light usually holds one gradient rather than two, which is why it is the one
// written here.
//
// The endpoints are fitted in the domain the block interpolates in rather than
// in the halves themselves: a sample is a magnitude of sixteen bits, and the
// block's two ends are that magnitude stretched to ten. Fitting there is what
// makes the arithmetic the decoder will do the arithmetic the fit minimises.

///|
/// Sixteen bytes that are one four-by-four square of light: sixteen pixels of
/// red, green and blue as the bit patterns of halves.
fn bc6h_pack(square : FixedArray[Int32], signed : Bool) -> FixedArray[Byte] {
  let targets : FixedArray[Double] = FixedArray::make(48, 0.0)
  for i in 0..<48 {
    targets[i] = bc6h_target(square[i], signed)
  }
  let first : FixedArray[Double] = FixedArray::make(3, 0.0)
  let second : FixedArray[Double] = FixedArray::make(3, 0.0)
  bc6h_furthest(targets, first, second)
  let (a, b, indices, error) = bc6h_fit(targets, first, second, signed)
  bc6h_corners(targets, first, second)
  let (other_a, other_b, other_indices, other_error) = bc6h_fit(
    targets, first, second, signed,
  )
  let (low, high, chosen) = if error <= other_error {
    (a, b, indices)
  } else {
    (other_a, other_b, other_indices)
  }
  bc6h_write(low, high, chosen)
}

///|
/// The magnitude a sample stands for in the domain the block interpolates in.
///
/// The decoder takes the block's magnitude, stretches it over the halves the
/// format can name, and interpolates there; this is that stretch run backwards,
/// so that a fit in this domain is a fit of the picture.
fn bc6h_target(bits : Int32, signed : Bool) -> Double {
  let magnitude = bits & 0x7FFF
  if signed {
    let value = magnitude.to_double() * 32.0 / 31.0
    if (bits & 0x8000) != 0 {
      -value
    } else {
      value
    }
  } else {
    let clamped = if magnitude > 0x7BFF { 0x7BFF } else { magnitude }
    clamped.to_double() * 64.0 / 31.0
  }
}

///|
/// The two pixels furthest apart, and the box the block's light sits in, as the
/// two places a line through it might run.
fn bc6h_furthest(
  targets : FixedArray[Double],
  first : FixedArray[Double],
  second : FixedArray[Double],
) -> Unit {
  let mut far_a = 0
  let mut far_b = 1
  let mut furthest = -1.0
  for i in 0..<16 {
    for j in (i + 1)..<16 {
      let mut distance = 0.0
      for c in 0..<3 {
        let difference = targets[i * 3 + c] - targets[j * 3 + c]
        distance = distance + difference * difference
      }
      if distance > furthest {
        furthest = distance
        far_a = i
        far_b = j
      }
    }
  }
  for c in 0..<3 {
    first[c] = targets[far_a * 3 + c]
    second[c] = targets[far_b * 3 + c]
  }
}

///|
fn bc6h_corners(
  targets : FixedArray[Double],
  first : FixedArray[Double],
  second : FixedArray[Double],
) -> Unit {
  for c in 0..<3 {
    let mut low = targets[c]
    let mut high = targets[c]
    for i in 1..<16 {
      let value = targets[i * 3 + c]
      if value < low {
        low = value
      }
      if value > high {
        high = value
      }
    }
    first[c] = low
    second[c] = high
  }
}

///|
/// A line through the block's light, fitted to the weights the pixels are given,
/// then rounded to the ten-bit magnitudes the block can name.
fn bc6h_fit(
  targets : FixedArray[Double],
  first : FixedArray[Double],
  second : FixedArray[Double],
  signed : Bool,
) -> (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32], Double) {
  let a : FixedArray[Double] = FixedArray::make(3, 0.0)
  let b : FixedArray[Double] = FixedArray::make(3, 0.0)
  for c in 0..<3 {
    a[c] = first[c]
    b[c] = second[c]
  }
  let weights : FixedArray[Double] = FixedArray::make(16, 0.0)
  for index in 0..<16 {
    weights[index] = weights_four[index].to_double() / 64.0
  }
  let assignment : FixedArray[Int32] = FixedArray::make(16, 0)
  // The box the block's light sits in. A line fitted by least squares is free to
  // run past the points it was fitted to — a block of two colours far apart and
  // nothing else pulls its ends outwards, and three rounds of refitting can walk
  // them a long way — so every round ends by putting them back inside it.
  let lowest : FixedArray[Double] = FixedArray::make(3, 0.0)
  let highest : FixedArray[Double] = FixedArray::make(3, 0.0)
  for c in 0..<3 {
    lowest[c] = targets[c]
    highest[c] = targets[c]
    for i in 1..<16 {
      let value = targets[i * 3 + c]
      if value < lowest[c] {
        lowest[c] = value
      }
      if value > highest[c] {
        highest[c] = value
      }
    }
  }
  for _ in 0..<3 {
    bc6h_assign(targets, a, b, weights, assignment)
    bc6h_least_squares(targets, assignment, a, b, weights)
    for c in 0..<3 {
      if a[c] < lowest[c] {
        a[c] = lowest[c]
      }
      if a[c] > highest[c] {
        a[c] = highest[c]
      }
      if b[c] < lowest[c] {
        b[c] = lowest[c]
      }
      if b[c] > highest[c] {
        b[c] = highest[c]
      }
    }
  }
  let low : FixedArray[Int32] = FixedArray::make(3, 0)
  let high : FixedArray[Int32] = FixedArray::make(3, 0)
  for c in 0..<3 {
    low[c] = bc6h_code(a[c], signed)
    high[c] = bc6h_code(b[c], signed)
  }
  let indices : FixedArray[Int32] = FixedArray::make(16, 0)
  let error = bc6h_score(targets, low, high, indices, signed)
  (low, high, indices, error)
}

///|
fn bc6h_assign(
  targets : FixedArray[Double],
  low : FixedArray[Double],
  high : FixedArray[Double],
  weights : FixedArray[Double],
  indices : FixedArray[Int32],
) -> Unit {
  for p in 0..<16 {
    let mut best = 0
    let mut closest = -1.0
    for index in 0..<16 {
      let weight = weights[index]
      let mut distance = 0.0
      for c in 0..<3 {
        let value = low[c] * (1.0 - weight) + high[c] * weight
        let difference = targets[p * 3 + c] - value
        distance = distance + difference * difference
      }
      if closest < 0.0 || distance < closest {
        closest = distance
        best = index
      }
    }
    indices[p] = best
  }
  // The first pixel of the block is written without the top bit of its weight,
  // so it has to be one of the first eight: turning the line around does that
  // without moving the line.
  if indices[0] >= 8 {
    for c in 0..<3 {
      let held = low[c]
      low[c] = high[c]
      high[c] = held
    }
    for p in 0..<16 {
      indices[p] = 15 - indices[p]
    }
  }
}

///|
fn bc6h_least_squares(
  targets : FixedArray[Double],
  indices : FixedArray[Int32],
  low : FixedArray[Double],
  high : FixedArray[Double],
  weights : FixedArray[Double],
) -> Unit {
  for c in 0..<3 {
    let mut count = 0.0
    let mut sum_weight = 0.0
    let mut sum_square = 0.0
    let mut sum_value = 0.0
    let mut sum_product = 0.0
    for p in 0..<16 {
      let weight = weights[indices[p]]
      let value = targets[p * 3 + c]
      count = count + 1.0
      sum_weight = sum_weight + weight
      sum_square = sum_square + weight * weight
      sum_value = sum_value + value
      sum_product = sum_product + weight * value
    }
    let determinant = count * sum_square - sum_weight * sum_weight
    if determinant > 1.0e-9 {
      let slope = (count * sum_product - sum_weight * sum_value) / determinant
      let base = (sum_value - slope * sum_weight) / count
      low[c] = base
      high[c] = base + slope
    } else {
      let mean = sum_value / count
      low[c] = mean
      high[c] = mean
    }
  }
}

///|
/// A magnitude as the ten bits the block names it with, which is the decoder's
/// stretch undone: nought stays nought, the top of the range stays the top, and
/// everything between is divided by sixty-four.
fn bc6h_code(value : Double, signed : Bool) -> Int32 {
  let limit = if signed { 511.0 } else { 1022.0 }
  let negative = value < 0.0
  let magnitude = if negative { -value } else { value }
  if magnitude <= 0.0 {
    return 0
  }
  let mut code = ((magnitude - 32.0) / 64.0 + 0.5).floor()
  if code < 0.0 {
    code = 0.0
  }
  if code > limit {
    code = limit
  }
  let value = code.to_int()
  if negative {
    -value
  } else {
    value
  }
}

///|
/// A ten-bit magnitude as the number the block interpolates in.
fn bc6h_unquantize(code : Int32, signed : Bool) -> Int32 {
  let negative = code < 0
  let magnitude = if negative { -code } else { code }
  let limit = if signed { 511 } else { 1023 }
  let value = if magnitude == 0 {
    0
  } else if magnitude >= limit {
    if signed {
      0x7FFF
    } else {
      0xFFFF
    }
  } else {
    magnitude * 64 + 32
  }
  if negative {
    -value
  } else {
    value
  }
}

///|
fn bc6h_score(
  targets : FixedArray[Double],
  low : FixedArray[Int32],
  high : FixedArray[Int32],
  indices : FixedArray[Int32],
  signed : Bool,
) -> Double {
  let a : FixedArray[Int32] = FixedArray::make(3, 0)
  let b : FixedArray[Int32] = FixedArray::make(3, 0)
  for c in 0..<3 {
    a[c] = bc6h_unquantize(low[c], signed)
    b[c] = bc6h_unquantize(high[c], signed)
  }
  for p in 0..<16 {
    let mut best = 0
    let mut closest = -1.0
    for index in 0..<16 {
      let weight = weights_four[index]
      let mut distance = 0.0
      for c in 0..<3 {
        let value = (a[c] * (64 - weight) + b[c] * weight + 32) >> 6
        let difference = targets[p * 3 + c] - value.to_double()
        distance = distance + difference * difference
      }
      if closest < 0.0 || distance < closest {
        closest = distance
        best = index
      }
    }
    indices[p] = best
  }
  if indices[0] >= 8 {
    for c in 0..<3 {
      let held = low[c]
      low[c] = high[c]
      high[c] = held
      let held_value = a[c]
      a[c] = b[c]
      b[c] = held_value
    }
    for p in 0..<16 {
      indices[p] = 15 - indices[p]
    }
  }
  let mut error = 0.0
  for p in 0..<16 {
    let weight = weights_four[indices[p]]
    for c in 0..<3 {
      let value = (a[c] * (64 - weight) + b[c] * weight + 32) >> 6
      let difference = targets[p * 3 + c] - value.to_double()
      error = error + difference * difference
    }
  }
  error
}

///|
/// The block as the fields of mode three: five bits of mode, six magnitudes of
/// ten, and sixteen weights of four.
fn bc6h_write(
  low : FixedArray[Int32],
  high : FixedArray[Int32],
  indices : FixedArray[Int32],
) -> FixedArray[Byte] {
  let bits = BlockBits::new()
  // Five bits of mode, read as two and then three: three names the mode, and the
  // three that follow say it is the third and not the twelfth.
  bits.put(3, 2)
  bits.put(0, 3)
  for c in 0..<3 {
    bits.put(low[c] & 0x3FF, 10)
  }
  for c in 0..<3 {
    bits.put(high[c] & 0x3FF, 10)
  }
  bits.put(indices[0], 3)
  for p in 1..<16 {
    bits.put(indices[p], 4)
  }
  bits.to_bytes()
}
