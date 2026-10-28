// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing a lossless WebP.
//
// The encoder is deliberately plain. It applies the subtract-green transform,
// because red and blue are usually close to green and the differences repeat
// across a picture; it finds repeats with a hash of the pixel value, which is
// what makes a flat area cost one copy rather than a thousand literals; and it
// writes one prefix code group for the whole image.
//
// What it does not do: the predictor transform, the colour transform, the
// palette, and the colour cache. Each of those would buy a few per cent on a
// photograph and cost a search that belongs in a different commit — and a
// decoder is the half of the codec that has to be exactly right, while a writer
// only has to produce something a reader accepts.
//
// The trees are written the long way, with a code-length code and repeats, so
// that `dwebp` and this library's own reader both accept the result.

///|
/// A writer of bits, least significant bit of each byte first, which is the
/// order VP8L reads them in.
priv struct BitWriter {
  buffer : @buffer.Buffer
  mut bits : UInt32
  mut held : Int32
}

///|
fn BitWriter::new() -> BitWriter {
  { buffer: @buffer.Buffer::Buffer(), bits: 0U, held: 0, }
}

///|
fn BitWriter::put(self : BitWriter, value : Int32, count : Int32) -> Unit {
  if count == 0 {
    return
  }
  self.bits = self.bits | (value.reinterpret_as_uint() << self.held)
  self.held = self.held + count
  while self.held >= 8 {
    self.buffer.write_byte((self.bits & 0xFFU).reinterpret_as_int().to_byte())
    self.bits = self.bits >> 8
    self.held = self.held - 8
  }
}

///|
/// A prefix code, written most significant bit first.
fn BitWriter::code(self : BitWriter, code : Int32, length : Int32) -> Unit {
  for index in 0..<length {
    self.put((code >> (length - 1 - index)) & 1, 1)
  }
}

///|
fn BitWriter::to_bytes(self : BitWriter) -> Bytes {
  if self.held > 0 {
    self.buffer.write_byte((self.bits & 0xFFU).reinterpret_as_int().to_byte())
    self.bits = 0U
    self.held = 0
  }
  self.buffer.to_bytes()
}

///|
/// A prefix code as the stream carries it: the length of each symbol's code, and
/// the code itself, which is the canonical assignment.
priv struct PrefixCode {
  lengths : FixedArray[Int32]
  codes : FixedArray[Int32]
  alphabet : Int32
  /// Whether the tree has one leaf. Such a tree is marked with a length of one
  /// and occupies no bits at all in the stream: the symbol is not read, it is
  /// the only thing the region can be.
  single : Bool
}

///|
/// The canonical codes for a set of code lengths: symbols of the same length in
/// increasing order, each length starting where the previous one left off.
fn PrefixCode::from_lengths(
  lengths : FixedArray[Int32],
  alphabet : Int32,
) -> PrefixCode {
  let codes : FixedArray[Int32] = FixedArray::make(alphabet, 0)
  let counts : FixedArray[Int32] = FixedArray::make(16, 0)
  for symbol in 0..<alphabet {
    let length = lengths[symbol]
    if length > 0 {
      counts[length] = counts[length] + 1
    }
  }
  let next : FixedArray[Int32] = FixedArray::make(16, 0)
  let mut code = 0
  for length in 1..<=15 {
    code = (code + counts[length - 1]) << 1
    next[length] = code
  }
  for symbol in 0..<alphabet {
    let length = lengths[symbol]
    if length > 0 {
      codes[symbol] = next[length]
      next[length] = next[length] + 1
    }
  }
  let mut used = 0
  for symbol in 0..<alphabet {
    if lengths[symbol] > 0 {
      used = used + 1
    }
  }
  { lengths, codes, alphabet, single: used == 1, }
}

///|
/// One symbol of a tree, in the stream.
fn PrefixCode::emit(
  self : PrefixCode,
  writer : BitWriter,
  symbol : Int32,
) -> Unit {
  if self.single {
    return
  }
  writer.code(self.codes[symbol], self.lengths[symbol])
}

///|
/// Code lengths for a set of symbol frequencies, none longer than `limit` bits.
///
/// A Huffman tree is the shortest a prefix code can be, but its deepest leaf can
/// be longer than a bit stream may name, which happens when the frequencies are
/// as skewed as Fibonacci numbers. When that happens the code is thrown away and
/// replaced by the flattest complete code there is, which is never more than a
/// bit per symbol worse and always fits.
fn code_lengths(
  frequencies : FixedArray[Int32],
  alphabet : Int32,
  limit : Int32,
) -> FixedArray[Int32] {
  let lengths : FixedArray[Int32] = FixedArray::make(alphabet, 0)
  let used : Array[Int32] = []
  for symbol in 0..<alphabet {
    if frequencies[symbol] > 0 {
      used.push(symbol)
    }
  }
  if used.is_empty() {
    // A tree with no symbols cannot be written; one symbol that never appears
    // can, and costs nothing.
    lengths[0] = 1
    return lengths
  }
  if used.length() == 1 {
    lengths[used[0]] = 1
    return lengths
  }
  // The tree, as two arrays: a weight per node, and the node above it.
  let size = used.length() * 2
  let weights : FixedArray[Int64] = FixedArray::make(size, 0L)
  let parent : FixedArray[Int32] = FixedArray::make(size, -1)
  let active : FixedArray[Bool] = FixedArray::make(size, false)
  let mut nodes = 0
  for symbol in used {
    weights[nodes] = frequencies[symbol].to_int64()
    active[nodes] = true
    nodes = nodes + 1
  }
  let leaves = nodes
  let mut remaining = leaves
  while remaining > 1 {
    let mut first = -1
    let mut second = -1
    for node in 0..<nodes {
      if active[node] {
        if first < 0 || weights[node] < weights[first] {
          second = first
          first = node
        } else if second < 0 || weights[node] < weights[second] {
          second = node
        }
      }
    }
    if second < 0 {
      break
    }
    weights[nodes] = weights[first] + weights[second]
    active[nodes] = true
    parent[first] = nodes
    parent[second] = nodes
    active[first] = false
    active[second] = false
    nodes = nodes + 1
    remaining = remaining - 1
  }
  let mut deepest = 0
  for leaf in 0..<leaves {
    let mut depth = 0
    let mut node = leaf
    while parent[node] >= 0 {
      node = parent[node]
      depth = depth + 1
    }
    if depth > deepest {
      deepest = depth
    }
    lengths[used[leaf]] = depth
  }
  if deepest <= limit {
    return lengths
  }
  balanced_lengths(frequencies, used, limit)
}

///|
/// The flattest complete code over `symbols`: lengths that differ by at most one,
/// with the more frequent symbols getting the shorter of the two.
fn balanced_lengths(
  frequencies : FixedArray[Int32],
  symbols : Array[Int32],
  limit : Int32,
) -> FixedArray[Int32] {
  let alphabet = frequencies.length()
  let lengths : FixedArray[Int32] = FixedArray::make(alphabet, 0)
  let count = symbols.length()
  let mut width = 1
  while 1 << width < count {
    width = width + 1
  }
  if width > limit {
    width = limit
  }
  let shorter = (1 << width) - count
  // The most frequent first, so that they take the shorter codes.
  let order = symbols.copy()
  for index in 1..<count {
    let symbol = order[index]
    let mut at = index
    while at > 0 && frequencies[order[at - 1]] < frequencies[symbol] {
      order[at] = order[at - 1]
      at = at - 1
    }
    order[at] = symbol
  }
  for index in 0..<count {
    lengths[order[index]] = if index < shorter { width - 1 } else { width }
  }
  lengths
}

///|
/// The 19 code-length symbols, as the stream orders them.
fn code_length_order() -> Array[Int32] {
  [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
}

///|
/// One step of the encoded code lengths: a symbol, and the extra bits it carries.
priv struct LengthStep {
  symbol : Int32
  extra : Int32
  extra_bits : Int32
}

///|
/// A run of code lengths as the length symbols describe it: literal lengths,
/// repeats of the previous length, and runs of zeros.
fn length_steps(
  lengths : FixedArray[Int32],
  alphabet : Int32,
) -> Array[LengthStep] {
  let steps : Array[LengthStep] = []
  let mut symbol = 0
  while symbol < alphabet {
    let length = lengths[symbol]
    let mut run = 1
    while symbol + run < alphabet && lengths[symbol + run] == length {
      run = run + 1
    }
    if length == 0 {
      // Zeros have two symbols of their own, one for a short run and one for a
      // long one, and both are cheaper than a zero a symbol.
      let mut left = run
      while left >= 11 {
        let count = if left > 138 { 138 } else { left }
        steps.push({ symbol: 18, extra: count - 11, extra_bits: 7, })
        left = left - count
      }
      if left >= 3 {
        steps.push({ symbol: 17, extra: left - 3, extra_bits: 3, })
        left = 0
      }
      for _ in 0..<left {
        steps.push({ symbol: 0, extra: 0, extra_bits: 0, })
      }
    } else {
      steps.push({ symbol: length, extra: 0, extra_bits: 0, })
      let mut left = run - 1
      while left >= 3 {
        let count = if left > 6 { 6 } else { left }
        steps.push({ symbol: 16, extra: count - 3, extra_bits: 2, })
        left = left - count
      }
      for _ in 0..<left {
        steps.push({ symbol: length, extra: 0, extra_bits: 0, })
      }
    }
    symbol = symbol + run
  }
  steps
}

///|
/// One prefix code, written: its lengths as a code-length code, then the lengths
/// themselves.
fn write_code(writer : BitWriter, code : PrefixCode) -> Unit {
  let steps = length_steps(code.lengths, code.alphabet)
  let frequencies : FixedArray[Int32] = FixedArray::make(19, 0)
  for step in steps {
    frequencies[step.symbol] = frequencies[step.symbol] + 1
  }
  let lengths = code_lengths(frequencies, 19, 7)
  let table = PrefixCode::from_lengths(lengths, 19)
  writer.put(0, 1)
  // Only the code-length symbols up to the last one used need a length, and the
  // alphabet of that list is at least four.
  let order = code_length_order()
  let mut count = 19
  while count > 4 && lengths[order[count - 1]] == 0 {
    count = count - 1
  }
  writer.put(count - 4, 4)
  for index in 0..<count {
    writer.put(lengths[order[index]], 3)
  }
  // The full alphabet: the alternative is a bound on the number of symbols,
  // which saves a few bits on a sparse tree and costs a branch here.
  writer.put(0, 1)
  for step in steps {
    table.emit(writer, step.symbol)
    if step.extra_bits > 0 {
      writer.put(step.extra, step.extra_bits)
    }
  }
}

///|
/// The prefix code for a length or a distance: which code names it, and the
/// extra bits that finish it.
fn code_for(value : Int32) -> (Int32, Int32, Int32) {
  if value <= 4 {
    return (value - 1, 0, 0)
  }
  for code in 4..<40 {
    let extra = (code - 2) >> 1
    let offset = (2 + (code & 1)) << extra
    if value - 1 >= offset && value - 1 < offset + (1 << extra) {
      return (code, value - 1 - offset, extra)
    }
  }
  (39, 0, 0)
}

///|
/// The distance code for a distance, preferring the two-dimensional places,
/// which cost fewer bits than the number they stand for.
fn distance_code(distance : Int32, width : Int32) -> Int32 {
  let places = distance_places()
  for index in 0..<places.length() {
    let place = places[index]
    if place.0 + place.1 * width == distance {
      return index + 1
    }
  }
  distance + 120
}

///|
/// One thing to encode: a literal pixel, or a run copied from behind.
priv enum Op {
  Literal(UInt32)
  Copy(Int32, Int32)
}

///|
/// The ops for a picture, with repeats found by a hash of the pixel value.
fn ops_of(pixels : FixedArray[UInt32]) -> Array[Op] {
  let ops : Array[Op] = []
  let table = @hashmap.HashMap::HashMap([], capacity=4096)
  let total = pixels.length()
  let mut position = 0
  while position < total {
    let key = pixels[position]
    let mut best = 0
    let mut best_at = -1
    match table.get(key) {
      Some(at) =>
        if position - at > 0 {
          let mut run = 0
          while position + run < total &&
                run < 4096 &&
                pixels[at + run] == pixels[position + run] {
            run = run + 1
          }
          // A copy of two is no shorter than two literals, and a copy of three
          // pays for itself.
          if run >= 3 {
            best = run
            best_at = at
          }
        }
      None => ()
    }
    if best_at >= 0 && best >= 3 {
      ops.push(Copy(best, position - best_at))
      // Remember the start of the run so a later repeat can find it.
      table.set(pixels[position], position)
      position = position + best
    } else {
      ops.push(Literal(key))
      table.set(key, position)
      position = position + 1
    }
  }
  ops
}

///|
/// The image as a VP8L payload.
pub fn encode_lossless(image : @raster.Image) -> Bytes {
  let source = image.convert(@raster.PixelFormat::Rgba8)
  let width = source.width
  let height = source.height
  let total = width * height
  let pixels : FixedArray[UInt32] = FixedArray::make(total, 0U)
  let mut uses_alpha = false
  for index in 0..<total {
    let at = index * 4
    let alpha = source.pixels[at + 3].to_int()
    if alpha != 255 {
      uses_alpha = true
    }
    pixels[index] = (alpha.reinterpret_as_uint() << 24) |
      (source.pixels[at].to_int().reinterpret_as_uint() << 16) |
      (source.pixels[at + 1].to_int().reinterpret_as_uint() << 8) |
      source.pixels[at + 2].to_int().reinterpret_as_uint()
  }
  let writer = BitWriter::new()
  writer.put(0x2F, 8)
  writer.put(width - 1, 14)
  writer.put(height - 1, 14)
  writer.put(if uses_alpha { 1 } else { 0 }, 1)
  writer.put(0, 3)
  encode_stream(writer, pixels, width, height, true)
  writer.to_bytes()
}

///|
/// One entropy-coded image, which is the whole file when it is the outermost
/// one and a transform's own data when it is not.
fn encode_stream(
  writer : BitWriter,
  pixels : FixedArray[UInt32],
  width : Int32,
  height : Int32,
  level0 : Bool,
) -> Unit {
  let mut data = pixels
  if level0 {
    // A block is four pixels on a small picture and sixteen on a large one: the
    // predictor is only worth a mode of its own where there is room for one.
    let bits = if width >= 128 && height >= 128 {
      5
    } else if width >= 64 && height >= 64 {
      4
    } else if width >= 32 && height >= 32 {
      3
    } else {
      2
    }
    let block_width = subsample(width, bits)
    let block_height = subsample(height, bits)
    let modes = choose_modes(
      pixels, width, height, bits, block_width, block_height,
    )
    data = residuals(pixels, width, height, bits, block_width, modes)
    writer.put(1, 1)
    writer.put(0, 2)
    writer.put(bits - 2, 3)
    encode_stream(writer, modes, block_width, block_height, false)
    // The loop that reads transforms ends on a zero bit.
    writer.put(0, 1)
  }
  // No colour cache.
  writer.put(0, 1)
  if level0 {
    // One prefix code group for the whole picture.
    writer.put(0, 1)
  }
  write_image(writer, data, width)
}

///|
fn smaller(left : Int32, right : Int32) -> Int32 {
  if left < right {
    left
  } else {
    right
  }
}

///|
/// The modes the predictor transform may use. Opaque black is left out: a block
/// that predicts itself black is a block that should not have a predictor.
fn candidate_modes() -> Array[Int32] {
  [1, 2, 4, 7, 8, 11, 12, 13]
}

///|
/// The mode for each block: whichever one leaves the smallest residuals.
fn choose_modes(
  pixels : FixedArray[UInt32],
  width : Int32,
  height : Int32,
  bits : Int32,
  block_width : Int32,
  block_height : Int32,
) -> FixedArray[UInt32] {
  let modes : FixedArray[UInt32] = FixedArray::make(
    block_width * block_height,
    0U,
  )
  for block_y in 0..<block_height {
    for block_x in 0..<block_width {
      let x0 = block_x << bits
      let y0 = block_y << bits
      let x1 = smaller(x0 + (1 << bits), width)
      let y1 = smaller(y0 + (1 << bits), height)
      let mut best_mode = 1
      let mut best_cost = 1 << 30
      for mode in candidate_modes() {
        let mut cost = 0
        for y in y0..<y1 {
          for x in x0..<x1 {
            let prediction = predict_at(pixels, width, height, x, y, mode)
            cost = cost + residual_cost(pixels[y * width + x], prediction)
            if cost >= best_cost {
              // No need to look further in this block.
              break
            }
          }
          if cost >= best_cost {
            break
          }
        }
        if cost < best_cost {
          best_cost = cost
          best_mode = mode
        }
      }
      modes[block_y * block_width + block_x] = 0xFF000000U |
        (best_mode.reinterpret_as_uint() << 8)
    }
  }
  modes
}

///|
/// How far a pixel is from its prediction, summed over the four channels.
fn residual_cost(pixel : UInt32, prediction : UInt32) -> Int32 {
  let mut cost = 0
  for shift in [0, 8, 16, 24] {
    let difference = (
        ((pixel >> shift) & 0xFFU) + 256U - ((prediction >> shift) & 0xFFU)
      ) &
      0xFFU
    let steps = difference.reinterpret_as_int()
    cost = cost + smaller(steps, 256 - steps)
  }
  cost
}

///|
/// The prediction the decoder will make for a pixel, from the pixels around it.
fn predict_at(
  pixels : FixedArray[UInt32],
  width : Int32,
  height : Int32,
  x : Int32,
  y : Int32,
  mode : Int32,
) -> UInt32 {
  if x == 0 && y == 0 {
    return 0xFF000000U
  }
  let left = if x > 0 { pixels[y * width + x - 1] } else { 0U }
  if y == 0 {
    return left
  }
  let top = pixels[(y - 1) * width + x]
  if x == 0 {
    return top
  }
  let top_left = pixels[(y - 1) * width + x - 1]
  let top_right = if x + 1 < width {
    pixels[(y - 1) * width + x + 1]
  } else {
    pixels[(y - 1) * width]
  }
  ignore(height)
  predict_one(mode, left, top, top_left, top_right)
}

///|
/// The image with each pixel replaced by what its block's prediction missed by.
fn residuals(
  pixels : FixedArray[UInt32],
  width : Int32,
  height : Int32,
  bits : Int32,
  block_width : Int32,
  modes : FixedArray[UInt32],
) -> FixedArray[UInt32] {
  let out : FixedArray[UInt32] = FixedArray::make(width * height, 0U)
  for y in 0..<height {
    for x in 0..<width {
      let block = (y >> bits) * block_width + (x >> bits)
      let mode = ((modes[block] >> 8) & 0xFFU).reinterpret_as_int()
      let prediction = predict_at(pixels, width, height, x, y, mode)
      out[y * width + x] = subtract_pixels(pixels[y * width + x], prediction)
    }
  }
  out
}

///|
/// A pixel minus a pixel, channel by channel, without a borrow between them.
fn subtract_pixels(pixel : UInt32, prediction : UInt32) -> UInt32 {
  let a = (((pixel >> 24) & 0xFFU) + 256U - ((prediction >> 24) & 0xFFU)) &
    0xFFU
  let r = (((pixel >> 16) & 0xFFU) + 256U - ((prediction >> 16) & 0xFFU)) &
    0xFFU
  let g = (((pixel >> 8) & 0xFFU) + 256U - ((prediction >> 8) & 0xFFU)) & 0xFFU
  let b = ((pixel & 0xFFU) + 256U - (prediction & 0xFFU)) & 0xFFU
  (a << 24) | (r << 16) | (g << 8) | b
}

///|
/// One image's op list, trees and symbols, written into the stream.
fn write_image(
  writer : BitWriter,
  pixels : FixedArray[UInt32],
  width : Int32,
) -> Unit {
  let ops = ops_of(pixels)
  let green_frequencies : FixedArray[Int32] = FixedArray::make(256 + 24, 0)
  let red_frequencies : FixedArray[Int32] = FixedArray::make(256, 0)
  let blue_frequencies : FixedArray[Int32] = FixedArray::make(256, 0)
  let alpha_frequencies : FixedArray[Int32] = FixedArray::make(256, 0)
  let distance_frequencies : FixedArray[Int32] = FixedArray::make(40, 0)
  for op in ops {
    match op {
      Literal(pixel) => {
        let green = ((pixel >> 8) & 0xFFU).reinterpret_as_int()
        green_frequencies[green] = green_frequencies[green] + 1
        let red = ((pixel >> 16) & 0xFFU).reinterpret_as_int()
        red_frequencies[red] = red_frequencies[red] + 1
        let blue = (pixel & 0xFFU).reinterpret_as_int()
        blue_frequencies[blue] = blue_frequencies[blue] + 1
        let alpha = ((pixel >> 24) & 0xFFU).reinterpret_as_int()
        alpha_frequencies[alpha] = alpha_frequencies[alpha] + 1
      }
      Copy(length, gap) => {
        let (length_code, _, _) = code_for(length)
        green_frequencies[256 + length_code] = green_frequencies[256 +
          length_code] +
          1
        let (distance_symbol, _, _) = code_for(distance_code(gap, width))
        distance_frequencies[distance_symbol] = distance_frequencies[distance_symbol] +
          1
      }
    }
  }
  let green = PrefixCode::from_lengths(
    code_lengths(green_frequencies, 280, 15),
    280,
  )
  let red = PrefixCode::from_lengths(
    code_lengths(red_frequencies, 256, 15),
    256,
  )
  let blue = PrefixCode::from_lengths(
    code_lengths(blue_frequencies, 256, 15),
    256,
  )
  let alpha = PrefixCode::from_lengths(
    code_lengths(alpha_frequencies, 256, 15),
    256,
  )
  let distance = PrefixCode::from_lengths(
    code_lengths(distance_frequencies, 40, 15),
    40,
  )
  write_code(writer, green)
  write_code(writer, red)
  write_code(writer, blue)
  write_code(writer, alpha)
  write_code(writer, distance)
  for op in ops {
    match op {
      Literal(pixel) => {
        green.emit(writer, ((pixel >> 8) & 0xFFU).reinterpret_as_int())
        red.emit(writer, ((pixel >> 16) & 0xFFU).reinterpret_as_int())
        blue.emit(writer, (pixel & 0xFFU).reinterpret_as_int())
        alpha.emit(writer, ((pixel >> 24) & 0xFFU).reinterpret_as_int())
      }
      Copy(length, gap) => {
        let (length_code, length_extra, length_bits) = code_for(length)
        green.emit(writer, 256 + length_code)
        writer.put(length_extra, length_bits)
        let (distance_symbol, distance_extra, distance_bits) = code_for(
          distance_code(gap, width),
        )
        distance.emit(writer, distance_symbol)
        writer.put(distance_extra, distance_bits)
      }
    }
  }
}
