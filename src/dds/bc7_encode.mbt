// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing a BC7 block.
//
// Mode six: one region, two endpoints of eight bits a channel, and sixteen
// weights of four. It is the mode with the finest indices of the eight, and the
// only one that spends the same number of bits on alpha as on colour, which is
// what a texture with a soft edge needs.
//
// The two endpoints are fitted rather than guessed: the pair furthest apart
// gives a line to start from, the pixels are assigned the weight nearest it, and
// the line is then moved to the least-squares fit of those assignments. Three
// rounds of that settle on a line the block's colours actually lie along, and
// the pair of corner colours the box gives is tried beside it, because a block
// of two colours has no line of its own.
//
// One bit of the block is not what it seems: the parity of an endpoint is
// written once and applies to all four of its channels, so an endpoint can only
// name colours that share a parity. Both parities of both endpoints are tried
// and the combination that reconstructs the block closest is kept, which costs a
// step of a sample on the channels that had to move.

///|
/// Sixteen bytes that are one four-by-four square of colour, sixteen pixels of
/// red, green, blue and alpha.
fn bc7_pack(square : FixedArray[Byte]) -> FixedArray[Byte] {
  let targets : FixedArray[Double] = FixedArray::make(64, 0.0)
  for i in 0..<64 {
    targets[i] = square[i].to_int().to_double()
  }
  let first : FixedArray[Double] = FixedArray::make(4, 0.0)
  let second : FixedArray[Double] = FixedArray::make(4, 0.0)
  bc7_furthest(targets, first, second)
  let (a, b, indices, error) = bc7_fit(targets, first, second)
  bc7_corners(targets, first, second)
  let (other_a, other_b, other_indices, other_error) = bc7_fit(
    targets, first, second,
  )
  let (low, high, chosen) = if error <= other_error {
    (a, b, indices)
  } else {
    (other_a, other_b, other_indices)
  }
  bc7_write(low, high, chosen)
}

///|
/// The two colours of the square that lie furthest apart, which is a pair a line
/// can be fitted through even when the block holds two colours and nothing else.
fn bc7_furthest(
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
      for c in 0..<4 {
        let difference = targets[i * 4 + c] - targets[j * 4 + c]
        distance = distance + difference * difference
      }
      if distance > furthest {
        furthest = distance
        far_a = i
        far_b = j
      }
    }
  }
  for c in 0..<4 {
    first[c] = targets[far_a * 4 + c]
    second[c] = targets[far_b * 4 + c]
  }
}

///|
/// The two corners of the box the square's colours sit in.
fn bc7_corners(
  targets : FixedArray[Double],
  first : FixedArray[Double],
  second : FixedArray[Double],
) -> Unit {
  for c in 0..<4 {
    let mut low = targets[c]
    let mut high = targets[c]
    for i in 1..<16 {
      let value = targets[i * 4 + c]
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
/// A line through the block's colours, fitted to the weights the pixels are
/// given, and the endpoints rounded to what the block can name.
fn bc7_fit(
  targets : FixedArray[Double],
  first : FixedArray[Double],
  second : FixedArray[Double],
) -> (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32], Double) {
  let a : FixedArray[Double] = FixedArray::make(4, 0.0)
  let b : FixedArray[Double] = FixedArray::make(4, 0.0)
  for c in 0..<4 {
    a[c] = first[c]
    b[c] = second[c]
  }
  let weights : FixedArray[Double] = FixedArray::make(16, 0.0)
  for index in 0..<16 {
    weights[index] = weights_four[index].to_double() / 64.0
  }
  let assignment : FixedArray[Int32] = FixedArray::make(16, 0)
  // The box the block's colours sit in, which every round ends by putting the
  // ends of the line back inside: a line fitted by least squares is free to run
  // past the points it was fitted to, and three rounds of refitting can walk it
  // a long way from the picture.
  let lowest : FixedArray[Double] = FixedArray::make(4, 0.0)
  let highest : FixedArray[Double] = FixedArray::make(4, 0.0)
  for c in 0..<4 {
    lowest[c] = targets[c]
    highest[c] = targets[c]
    for i in 1..<16 {
      let value = targets[i * 4 + c]
      if value < lowest[c] {
        lowest[c] = value
      }
      if value > highest[c] {
        highest[c] = value
      }
    }
  }
  for _ in 0..<3 {
    bc7_assign(targets, a, b, weights, assignment)
    bc7_least_squares(targets, assignment, a, b, weights)
    for c in 0..<4 {
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
  // Both parities of both endpoints, and the combination that lands closest.
  let mut best_low : FixedArray[Int32] = FixedArray::make(4, 0)
  let mut best_high : FixedArray[Int32] = FixedArray::make(4, 0)
  let mut best_indices : FixedArray[Int32] = FixedArray::make(16, 0)
  let mut best_error = -1.0
  for parity_low in 0..<2 {
    for parity_high in 0..<2 {
      let low : FixedArray[Int32] = FixedArray::make(4, 0)
      let high : FixedArray[Int32] = FixedArray::make(4, 0)
      for c in 0..<4 {
        low[c] = bc7_with_parity(a[c], parity_low)
        high[c] = bc7_with_parity(b[c], parity_high)
      }
      let indices : FixedArray[Int32] = FixedArray::make(16, 0)
      let error = bc7_score(targets, low, high, indices)
      if best_error < 0.0 || error < best_error {
        best_error = error
        best_low = low
        best_high = high
        best_indices = indices
      }
    }
  }
  (best_low, best_high, best_indices, best_error)
}

///|
/// The weight nearest a pixel for each pixel, in doubles, which is where the fit
/// starts; the second pass is the same arithmetic on the rounded endpoints.
fn bc7_assign(
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
      for c in 0..<4 {
        let value = low[c] * (1.0 - weight) + high[c] * weight
        let difference = targets[p * 4 + c] - value
        distance = distance + difference * difference
      }
      if closest < 0.0 || distance < closest {
        closest = distance
        best = index
      }
    }
    indices[p] = best
  }
  // The first pixel's weight is written without its top bit, so it has to be one
  // of the first eight; turning the line around does that without moving it.
  if indices[0] >= 8 {
    for c in 0..<4 {
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
/// The endpoints of each channel that minimise the error of the weights just
/// assigned, which is a line fitted by least squares through sixteen points.
fn bc7_least_squares(
  targets : FixedArray[Double],
  indices : FixedArray[Int32],
  low : FixedArray[Double],
  high : FixedArray[Double],
  weights : FixedArray[Double],
) -> Unit {
  for c in 0..<4 {
    let mut count = 0.0
    let mut sum_weight = 0.0
    let mut sum_square = 0.0
    let mut sum_value = 0.0
    let mut sum_product = 0.0
    for p in 0..<16 {
      let weight = weights[indices[p]]
      let value = targets[p * 4 + c]
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
      // Every pixel took the same weight, so the line has no direction to fit:
      // both ends sit on the mean and the next round starts from there.
      let mean = sum_value / count
      low[c] = mean
      high[c] = mean
    }
  }
}

///|
/// A number rounded to the nearest sample of the given parity, which is the only
/// kind of sample an endpoint can name.
fn bc7_with_parity(value : Double, parity : Int32) -> Int32 {
  let lowest = parity.to_double()
  let highest = (254 + parity).to_double()
  let mut lower = ((value - lowest) / 2.0).floor() * 2.0 + lowest
  if lower < lowest {
    lower = lowest
  }
  if lower > highest {
    lower = highest
  }
  let upper = lower + 2.0
  if upper <= highest && upper - value < value - lower {
    upper.to_int()
  } else {
    lower.to_int()
  }
}

///|
/// How far the rounded endpoints and the weights nearest them are from the
/// block, and the weights themselves.
fn bc7_score(
  targets : FixedArray[Double],
  low : FixedArray[Int32],
  high : FixedArray[Int32],
  indices : FixedArray[Int32],
) -> Double {
  for p in 0..<16 {
    let mut best = 0
    let mut closest = -1.0
    for index in 0..<16 {
      let weight = weights_four[index]
      let mut distance = 0.0
      for c in 0..<4 {
        let value = (low[c] * (64 - weight) + high[c] * weight + 32) >> 6
        let difference = targets[p * 4 + c] - value.to_double()
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
    for c in 0..<4 {
      let held = low[c]
      low[c] = high[c]
      high[c] = held
    }
    for p in 0..<16 {
      indices[p] = 15 - indices[p]
    }
  }
  let mut error = 0.0
  for p in 0..<16 {
    let weight = weights_four[indices[p]]
    for c in 0..<4 {
      let value = (low[c] * (64 - weight) + high[c] * weight + 32) >> 6
      let difference = targets[p * 4 + c] - value.to_double()
      error = error + difference * difference
    }
  }
  error
}

///|
/// The block, as the fields of mode six: a run of six zeroes closed by a one,
/// the endpoints of the two colours interleaved by channel, their parities, and
/// the sixteen weights.
fn bc7_write(
  low : FixedArray[Int32],
  high : FixedArray[Int32],
  indices : FixedArray[Int32],
) -> FixedArray[Byte] {
  let bits = BlockBits::new()
  // Six zeroes then a one, which is how the mode is named.
  bits.put(64, 7)
  for c in 0..<3 {
    bits.put(low[c] >> 1, 7)
    bits.put(high[c] >> 1, 7)
  }
  bits.put(low[3] >> 1, 7)
  bits.put(high[3] >> 1, 7)
  bits.put(low[0] & 1, 1)
  bits.put(high[0] & 1, 1)
  bits.put(indices[0], 3)
  for p in 1..<16 {
    bits.put(indices[p], 4)
  }
  bits.to_bytes()
}
