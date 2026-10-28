// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// VP8L, the lossless codec inside a WebP.
//
// https://developers.google.com/speed/webp/docs/webp_lossless_bitstream_specification
//
// The bitstream is LSB-first, which is the opposite of every other format in
// this library, and that is the least of it. What is inside:
//
//   * four transforms that run before the entropy coder — a predictor, a colour
//     decorrelation, a subtract-green, and a palette that packs indices into
//     bytes — each of which has to be undone in reverse after decoding;
//   * an LZ77 stage whose distances live in a two-dimensional neighbourhood
//     rather than a flat window, so a repeat one row up costs three bits;
//   * five prefix codes per region, chosen per four-by-four block of blocks, so
//     that a photograph can code its sky differently from its grass;
//   * a colour cache, a hash table of recent pixels that a repeat can name in
//     one symbol.
//
// The decoder here follows the specification's own pseudocode. Its output is
// checked against libwebp: a lossless file has exactly one correct decoding, so
// a byte out of place is a failure rather than a tolerance.

///|
/// A cursor over bits, least significant bit of each byte first.
///
/// VP8L is the only format here that is not a whole number of bytes, and it
/// keeps a bit buffer rather than re-reading the byte it is partway through.
priv struct Bits {
  data : BytesView
  mut at : Int32
  mut buffer : UInt32
  mut held : Int32
}

///|
fn Bits::new(data : BytesView, at : Int32) -> Bits {
  { data, at, buffer: 0U, held: 0, }
}

///|
/// Where the reader is, in bytes, for the refusal that says where it stopped.
fn Bits::at(self : Bits) -> Int32 {
  self.at
}

///|
/// The next `count` bits, which are the low `count` bits of the answer.
fn Bits::take(self : Bits, count : Int32) -> Int32 raise @raster.Refused {
  if count == 0 {
    return 0
  }
  while self.held < count {
    if self.at >= self.data.length() {
      raise @raster.Truncated(at=self.at, want=1)
    }
    let byte = self.data[self.at].to_int().reinterpret_as_uint()
    self.buffer = self.buffer | (byte << self.held)
    self.at = self.at + 1
    self.held = self.held + 8
  }
  let mask = (1U << count) - 1U
  let value = self.buffer & mask
  self.buffer = self.buffer >> count
  self.held = self.held - count
  value.reinterpret_as_int()
}

///|
/// One bit.
fn Bits::bit(self : Bits) -> Int32 raise @raster.Refused {
  self.take(1)
}

///|
/// A canonical prefix code: how many codes of each length, and the symbols in
/// the order the canonical assignment gives them.
priv struct Huffman {
  counts : FixedArray[Int32]
  symbols : FixedArray[Int32]
  /// The only symbol, when the tree has one leaf and reads no bits at all.
  single : Int32
}

///|
/// The tree a list of code lengths describes, or a refusal when they do not
/// describe one.
///
/// A complete tree is one where the codes of every length fill the space
/// exactly: one bit of prefix is two codes, two bits are four, and so on. A
/// stream whose lengths leave a gap could not be decoded without guessing, so
/// the gap is where the reader stops.
fn Huffman::from_lengths(
  lengths : FixedArray[Int32],
  alphabet : Int32,
) -> Huffman raise @raster.Refused {
  let counts : FixedArray[Int32] = FixedArray::make(16, 0)
  let mut total = 0
  let mut only = -1
  for symbol in 0..<alphabet {
    let length = lengths[symbol]
    if length > 0 {
      if length > 15 {
        raise @raster.Unexpected(
          at=0,
          got="a code 16 bits long",
          want="a code of at most 15 bits",
        )
      }
      counts[length] = counts[length] + 1
      total = total + 1
      only = symbol
    }
  }
  if total == 0 {
    raise @raster.Unexpected(
      at=0,
      got="a prefix code with no symbols",
      want="at least one",
    )
  }
  let offsets : FixedArray[Int32] = FixedArray::make(16, 0)
  if total == 1 {
    // One leaf: a symbol that costs nothing, which is how a region that uses a
    // single value is written.
    return { counts, symbols: FixedArray::make(1, only), single: only, }
  }
  // Kraft: the space at each depth is twice what the depth above left over.
  let mut space = 1
  for length in 1..<=15 {
    space = space * 2 - counts[length]
    if space < 0 {
      raise @raster.Unexpected(
        at=0,
        got="a prefix code longer than its space",
        want="a complete tree",
      )
    }
  }
  if space != 0 {
    raise @raster.Unexpected(
      at=0,
      got="a prefix code that leaves \{space} codes unused",
      want="a complete tree",
    )
  }
  let mut running = 0
  for length in 1..<=15 {
    offsets[length] = running
    running = running + counts[length]
  }
  let symbols : FixedArray[Int32] = FixedArray::make(total, 0)
  let cursor = offsets.copy()
  for symbol in 0..<alphabet {
    let length = lengths[symbol]
    if length > 0 {
      symbols[cursor[length]] = symbol
      cursor[length] = cursor[length] + 1
    }
  }
  { counts, symbols, single: -1, }
}

///|
/// The next symbol, bit by bit: a prefix code is read from its most significant
/// bit, which is the order the canonical assignment numbers them in.
fn Huffman::symbol(
  self : Huffman,
  reader : Bits,
) -> Int32 raise @raster.Refused {
  if self.single >= 0 {
    return self.single
  }
  let mut code = 0
  let mut first = 0
  let mut index = 0
  for length in 1..<=15 {
    code = (code << 1) | reader.bit()
    let count = self.counts[length]
    if code >= first && code - first < count {
      return self.symbols[index + code - first]
    }
    index = index + count
    first = (first + count) << 1
  }
  raise @raster.Unexpected(
    at=reader.at(),
    got="a code no tree contains",
    want="a shorter code",
  )
}

///|
/// A prefix code, as the stream writes it: either the two-symbol shorthand or a
/// code length code followed by the lengths.
fn read_huffman_code(
  reader : Bits,
  alphabet : Int32,
) -> Huffman raise @raster.Refused {
  let lengths : FixedArray[Int32] = FixedArray::make(alphabet, 0)
  if reader.bit() == 1 {
    // The shorthand: one or two symbols, one bit each.
    let count = reader.bit() + 1
    let wide = reader.bit()
    let first = reader.take(1 + 7 * wide)
    if first >= alphabet {
      raise @raster.Unexpected(
        at=reader.at(),
        got="a symbol outside the alphabet",
        want="a symbol below \{alphabet}",
      )
    }
    lengths[first] = 1
    if count == 2 {
      let second = reader.take(8)
      if second >= alphabet {
        raise @raster.Unexpected(
          at=reader.at(),
          got="a symbol outside the alphabet",
          want="a symbol below \{alphabet}",
        )
      }
      lengths[second] = 1
    }
  } else {
    let order = [
      17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    ]
    let code_lengths : FixedArray[Int32] = FixedArray::make(19, 0)
    let used = 4 + reader.take(4)
    for index in 0..<used {
      code_lengths[order[index]] = reader.take(3)
    }
    let table = Huffman::from_lengths(code_lengths, 19)
    let mut limit = alphabet
    if reader.bit() == 1 {
      let width = 2 + 2 * reader.take(3)
      limit = 2 + reader.take(width)
      if limit > alphabet {
        raise @raster.Unexpected(
          at=reader.at(),
          got="more symbols than the alphabet holds",
          want="at most \{alphabet}",
        )
      }
    }
    let mut symbol = 0
    // `limit` counts the codes that follow, not the symbols they produce: a
    // repeat writes several symbols at the cost of one code, so a tree whose
    // lengths are mostly repeats is written with far fewer codes than it has
    // symbols.
    let mut budget = limit
    // A repeat before any length has been given repeats eight, which is what a
    // run of short codes looks like once the first one has been read.
    let mut previous = 8
    while symbol < alphabet && budget > 0 {
      budget = budget - 1
      let code = table.symbol(reader)
      if code < 16 {
        lengths[symbol] = code
        if code != 0 {
          previous = code
        }
        symbol = symbol + 1
      } else if code == 16 {
        let run = 3 + reader.take(2)
        if symbol + run > alphabet {
          raise @raster.Unexpected(
            at=reader.at(),
            got="a repeat past the last symbol",
            want="a shorter run",
          )
        }
        for _ in 0..<run {
          lengths[symbol] = previous
          symbol = symbol + 1
        }
      } else if code == 17 {
        symbol = symbol + 3 + reader.take(3)
      } else {
        symbol = symbol + 11 + reader.take(7)
      }
    }
  }
  Huffman::from_lengths(lengths, alphabet)
}

///|
/// The value behind a length or distance prefix code.
///
/// Codes below four name one, two, three and four; above that, the low bit says
/// how wide the offset is and the extra bits the rest of it, which gives runs
/// that grow twice as fast as the code that names them.
fn value_of_code(code : Int32, reader : Bits) -> Int32 raise @raster.Refused {
  if code < 4 {
    return code + 1
  }
  let extra = (code - 2) >> 1
  let offset = (2 + (code & 1)) << extra
  offset + reader.take(extra) + 1
}

///|
/// Every distance code below 121 names a place in the pixel's own
/// neighbourhood: up to seven rows above, eight columns either side, and eight
/// places back along the same row. Above that the distances are plain.
fn distance_of(code : Int32, width : Int32) -> Int32 {
  if code > 120 {
    return code - 120
  }
  let place = distance_places()[code - 1]
  let distance = place.0 + place.1 * width
  if distance < 1 {
    1
  } else {
    distance
  }
}

///|
/// One transform, with what it needs to be undone.
priv enum Transform {
  Predictor(Int32, Int32, FixedArray[UInt32])
  Color(Int32, Int32, FixedArray[UInt32])
  SubtractGreen
  Indexing(Int32, Int32, Int32, FixedArray[UInt32])
}

///|
/// A decoded rectangle of ARGB pixels, before the caller turns it into an image.
priv struct Plane {
  width : Int32
  height : Int32
  pixels : FixedArray[UInt32]
}

///|
/// An entropy-coded image, and everything above it.
fn decode_stream(
  reader : Bits,
  width : Int32,
  height : Int32,
  level0 : Bool,
  limits : @raster.Limits,
) -> Plane raise @raster.Refused {
  let mut xsize = width
  let ysize = height
  let transforms : Array[Transform] = []
  if level0 {
    while reader.bit() == 1 {
      match reader.take(2) {
        0 => {
          let bits = reader.take(3) + 2
          let block_width = subsample(xsize, bits)
          let block_height = subsample(ysize, bits)
          let sub = decode_stream(
            reader, block_width, block_height, false, limits,
          )

          transforms.push(Predictor(bits, block_width, sub.pixels))
        }
        1 => {
          let bits = reader.take(3) + 2
          let block_width = subsample(xsize, bits)
          let block_height = subsample(ysize, bits)
          let sub = decode_stream(
            reader, block_width, block_height, false, limits,
          )
          transforms.push(Color(bits, block_width, sub.pixels))
        }
        2 => transforms.push(SubtractGreen)
        _ => {
          let palette_size = reader.take(8) + 1
          let bits = if palette_size > 16 {
            0
          } else if palette_size > 4 {
            1
          } else if palette_size > 2 {
            2
          } else {
            3
          }
          let before = xsize
          xsize = subsample(xsize, bits)
          let sub = decode_stream(reader, palette_size, 1, false, limits)
          // The table is written as differences from the entry before it, so
          // that a ramp of colours costs a byte a step rather than three.
          let palette = sub.pixels.copy()
          for index in 1..<palette_size {
            palette[index] = add_pixels(palette[index], palette[index - 1])
          }
          transforms.push(Indexing(bits, before, palette_size, palette))
        }
      }
    }
  }
  let mut cache_bits = 0
  if reader.bit() == 1 {
    cache_bits = reader.take(4)
    if cache_bits < 1 || cache_bits > 11 {
      raise @raster.Unexpected(
        at=reader.at(),
        got="a colour cache of \{cache_bits} bits",
        want="one of one to eleven",
      )
    }
  }
  let cache_size = if cache_bits == 0 { 0 } else { 1 << cache_bits }
  // The group index travels in the entropy image's red and green channels, so
  // the image can name 65536 regions and is read as a picture like any other.
  let mut entropy : Plane? = None
  let mut prefix_bits = 0
  let mut groups = 1
  if level0 && reader.bit() == 1 {
    prefix_bits = reader.take(3) + 2
    let entropy_width = subsample(xsize, prefix_bits)
    let entropy_height = subsample(ysize, prefix_bits)
    let image = decode_stream(
      reader, entropy_width, entropy_height, false, limits,
    )
    let mut highest = 0
    for index in 0..<image.pixels.length() {
      let group = ((image.pixels[index] >> 8) & 0xFFFFU).reinterpret_as_int()
      if group > highest {
        highest = group
      }
    }
    groups = highest + 1
    entropy = Some(image)
  }
  let green_alphabet = 256 + 24 + cache_size
  let codes : Array[Huffman] = []
  for group in 0..<groups {
    ignore(group)
    codes.push(read_huffman_code(reader, green_alphabet))
    codes.push(read_huffman_code(reader, 256))
    codes.push(read_huffman_code(reader, 256))
    codes.push(read_huffman_code(reader, 256))
    codes.push(read_huffman_code(reader, 40))
  }
  let total = xsize * ysize
  if total < 0 || total > limits.pixels {
    raise @raster.OverLimit(limit=limits.pixels, got=total)
  }
  let pixels : FixedArray[UInt32] = FixedArray::make(total, 0U)
  let cache : FixedArray[UInt32] = FixedArray::make(
    if cache_size == 0 {
      1
    } else {
      cache_size
    },
    0U,
  )
  let mut position = 0
  while position < total {
    let group = if entropy is Some(image) {
      let x = position % xsize
      let y = position / xsize
      let at = (y >> prefix_bits) * image.width + (x >> prefix_bits)
      if at < image.pixels.length() {
        ((image.pixels[at] >> 8) & 0xFFFFU).reinterpret_as_int()
      } else {
        0
      }
    } else {
      0
    }
    let base = group * 5
    let symbol = codes[base].symbol(reader)
    if symbol < 256 {
      let red = codes[base + 1].symbol(reader)
      let blue = codes[base + 2].symbol(reader)
      let alpha = codes[base + 3].symbol(reader)
      if red > 255 || blue > 255 || alpha > 255 {
        raise @raster.Unexpected(
          at=reader.at(),
          got="a colour channel outside a byte",
          want="a byte",
        )
      }
      let argb = (alpha.reinterpret_as_uint() << 24) |
        (red.reinterpret_as_uint() << 16) |
        (symbol.reinterpret_as_uint() << 8) |
        blue.reinterpret_as_uint()
      pixels[position] = argb
      cache_put(cache, cache_bits, argb)
      position = position + 1
    } else if symbol < 280 {
      let length = value_of_code(symbol - 256, reader)
      let distance = distance_of(
        value_of_code(codes[base + 4].symbol(reader), reader),
        xsize,
      )
      if distance < 1 || distance > position {
        raise @raster.Unexpected(
          at=reader.at(),
          got="a copy from \{distance} pixels back",
          want="a copy from inside the picture",
        )
      }
      if position + length > total {
        raise @raster.Unexpected(
          at=reader.at(),
          got="a copy past the end",
          want="a copy that fits",
        )
      }
      for _ in 0..<length {
        let value = pixels[position - distance]
        pixels[position] = value
        cache_put(cache, cache_bits, value)
        position = position + 1
      }
    } else {
      let index = symbol - 280
      if index >= cache_size {
        raise @raster.Unexpected(
          at=reader.at(),
          got="a colour cache of \{cache_size} entries",
          want="an index inside it",
        )
      }
      let value = cache[index]
      pixels[position] = value
      cache_put(cache, cache_bits, value)
      position = position + 1
    }
  }
  let plane : Plane = { width: xsize, height: ysize, pixels, }
  let mut undone = plane
  let mut index = transforms.length() - 1
  while index >= 0 {
    undone = undo(undone, transforms[index])
    index = index - 1
  }
  undone
}

///|
/// Undo one transform, which is where the picture grows back to its real width.
fn undo(plane : Plane, transform : Transform) -> Plane {
  match transform {
    SubtractGreen => {
      for index in 0..<plane.pixels.length() {
        plane.pixels[index] = add_green(plane.pixels[index])
      }
      plane
    }
    Predictor(bits, data_width, data) => {
      predict(plane, bits, data_width, data)
      plane
    }
    Color(bits, data_width, data) => {
      decolour(plane, bits, data_width, data)
      plane
    }
    Indexing(bits, width, palette_size, palette) => {
      let per_byte = 1 << bits
      let index_bits = 8 >> bits
      let mask = (1 << index_bits) - 1
      let packed_width = plane.width
      let pixels : FixedArray[UInt32] = FixedArray::make(
        width * plane.height,
        0U,
      )
      for y in 0..<plane.height {
        for x in 0..<width {
          // Each pixel of the packed image is one byte of indices, in its
          // green channel: the other three are padding.
          let packed = plane.pixels[y * packed_width + x / per_byte]
          let byte = (packed >> 8) & 0xFFU
          let index = ((byte >> (x % per_byte * index_bits)) &
          mask.reinterpret_as_uint()).reinterpret_as_int()
          pixels[y * width + x] = if index < palette_size {
            palette[index]
          } else {
            0U
          }
        }
      }
      { width, height: plane.height, pixels, }
    }
  }
}

///|
/// The predictor: each block names how it expects its pixels to follow from
/// their neighbours, and the stored pixel is what the prediction missed by.
fn predict(
  plane : Plane,
  bits : Int32,
  data_width : Int32,
  data : FixedArray[UInt32],
) -> Unit {
  let width = plane.width
  for y in 0..<plane.height {
    for x in 0..<width {
      let at = y * width + x
      let block = (y >> bits) * data_width + (x >> bits)
      let mode = if block < data.length() {
        ((data[block] >> 8) & 0xFFU).reinterpret_as_int()
      } else {
        0
      }
      let left = if x > 0 { plane.pixels[at - 1] } else { 0U }
      let top = if y > 0 { plane.pixels[at - width] } else { 0U }
      let top_left = if x > 0 && y > 0 {
        plane.pixels[at - width - 1]
      } else {
        0U
      }
      let top_right = if y > 0 {
        if x + 1 < width {
          plane.pixels[at - width + 1]
        } else {
          // The rightmost column looks at the start of its own row, which has
          // already been reconstructed.
          plane.pixels[at - width - x]
        }
      } else {
        0U
      }
      let prediction = if x == 0 && y == 0 {
        0xFF000000U
      } else if y == 0 {
        left
      } else if x == 0 {
        top
      } else {
        predict_one(mode, left, top, top_left, top_right)
      }
      plane.pixels[at] = add_pixels(plane.pixels[at], prediction)
    }
  }
}

///|
/// The fourteen predictors, channel by channel: every one of them is a guess
/// that the next pixel resembles its neighbours, and the stored value is the
/// difference that makes the guess exact.
fn predict_one(
  mode : Int32,
  left : UInt32,
  top : UInt32,
  top_left : UInt32,
  top_right : UInt32,
) -> UInt32 {
  if mode == 0 {
    return 0xFF000000U
  }
  if mode == 1 {
    return left
  }
  if mode == 2 {
    return top
  }
  if mode == 3 {
    return top_right
  }
  if mode == 4 {
    return top_left
  }
  if mode == 11 {
    return select(left, top, top_left)
  }
  let channels : Array[UInt32] = []
  for shift in [0, 8, 16, 24] {
    let a = (left >> shift) & 0xFFU
    let b = (top >> shift) & 0xFFU
    let c = (top_left >> shift) & 0xFFU
    let d = (top_right >> shift) & 0xFFU
    let value = match mode {
      5 => average(average(a, d), b)
      6 => average(a, c)
      7 => average(a, b)
      8 => average(c, b)
      9 => average(b, d)
      10 => average(average(a, c), average(b, d))
      12 => clamp_add(a, b, c)
      13 => clamp_half(average(a, b), c)
      _ => a
    }
    channels.push(value)
  }
  channels[3] * 16_777_216 +
  channels[2] * 65_536 +
  channels[1] * 256 +
  channels[0]
}

///|
fn average(a : UInt32, b : UInt32) -> UInt32 {
  (a + b) / 2U
}

///|
/// The predictor that picks whichever of its two neighbours is closer to what
/// their difference from the diagonal suggests.
///
/// The choice is made once for the whole pixel, over all four channels at
/// once: a neighbour that is close in red and far in blue is still one
/// neighbour, and taking the closer one channel by channel would invent a
/// colour that neither of them has.
fn select(left : UInt32, top : UInt32, top_left : UInt32) -> UInt32 {
  let mut from_left = 0
  let mut from_top = 0
  for shift in [0, 8, 16, 24] {
    let l = ((left >> shift) & 0xFFU).reinterpret_as_int()
    let t = ((top >> shift) & 0xFFU).reinterpret_as_int()
    let c = ((top_left >> shift) & 0xFFU).reinterpret_as_int()
    let estimate = l + t - c
    from_left = from_left + (estimate - l).abs()
    from_top = from_top + (estimate - t).abs()
  }
  if from_left < from_top {
    left
  } else {
    top
  }
}

///|
fn clamp_add(a : UInt32, b : UInt32, c : UInt32) -> UInt32 {
  let sum = a.reinterpret_as_int() +
    b.reinterpret_as_int() -
    c.reinterpret_as_int()
  clamp_byte(sum)
}

///|
fn clamp_half(a : UInt32, b : UInt32) -> UInt32 {
  let value = a.reinterpret_as_int() +
    (a.reinterpret_as_int() - b.reinterpret_as_int()) / 2
  clamp_byte(value)
}

///|
fn clamp_byte(value : Int32) -> UInt32 {
  if value < 0 {
    0U
  } else if value > 255 {
    255U
  } else {
    value.reinterpret_as_uint()
  }
}

///|
/// The colour transform: green was used to predict red and blue, so it is added
/// back into them, in the order the encoder subtracted it.
fn decolour(
  plane : Plane,
  bits : Int32,
  data_width : Int32,
  data : FixedArray[UInt32],
) -> Unit {
  let width = plane.width
  for y in 0..<plane.height {
    for x in 0..<width {
      let at = y * width + x
      let block = (y >> bits) * data_width + (x >> bits)
      let element = if block < data.length() { data[block] } else { 0U }
      let green_to_red = ((element >> 0) & 0xFFU).reinterpret_as_int()
      let green_to_blue = ((element >> 8) & 0xFFU).reinterpret_as_int()
      let red_to_blue = ((element >> 16) & 0xFFU).reinterpret_as_int()
      let pixel = plane.pixels[at]
      let green = ((pixel >> 8) & 0xFFU).reinterpret_as_int()
      let red = ((pixel >> 16) & 0xFFU).reinterpret_as_int()
      let blue = ((pixel >> 0) & 0xFFU).reinterpret_as_int()
      let new_red = (red + colour_delta(green_to_red, green)) & 0xFF
      let new_blue = (
          blue +
          colour_delta(green_to_blue, green) +
          colour_delta(red_to_blue, new_red)
        ) &
        0xFF
      plane.pixels[at] = (pixel & 0xFF00FF00U) |
        (new_red.reinterpret_as_uint() << 16) |
        new_blue.reinterpret_as_uint()
    }
  }
}

///|
/// A signed eight-bit multiply in three and a half bits of fraction, which is
/// what the transform's coefficients are.
fn colour_delta(coefficient : Int32, channel : Int32) -> Int32 {
  (signed_byte(coefficient) * signed_byte(channel)) >> 5
}

///|
fn signed_byte(value : Int32) -> Int32 {
  let low = value & 0xFF
  if low >= 128 {
    low - 256
  } else {
    low
  }
}

///|
/// A pixel plus a pixel, channel by channel, without a carry between channels.
fn add_pixels(left : UInt32, right : UInt32) -> UInt32 {
  let a = ((left >> 24) & 0xFFU) + ((right >> 24) & 0xFFU)
  let r = ((left >> 16) & 0xFFU) + ((right >> 16) & 0xFFU)
  let g = ((left >> 8) & 0xFFU) + ((right >> 8) & 0xFFU)
  let b = (left & 0xFFU) + (right & 0xFFU)
  ((a & 0xFFU) << 24) | ((r & 0xFFU) << 16) | ((g & 0xFFU) << 8) | (b & 0xFFU)
}

///|
fn add_green(pixel : UInt32) -> UInt32 {
  let green = (pixel >> 8) & 0xFFU
  let red = ((pixel >> 16) & 0xFFU) + green
  let blue = (pixel & 0xFFU) + green
  (pixel & 0xFF00FF00U) | ((red & 0xFFU) << 16) | (blue & 0xFFU)
}

///|
/// Remember a pixel in the colour cache, which is a plain hash table: two
/// colours that hash alike replace each other, and the format accepts the loss.
fn cache_put(cache : FixedArray[UInt32], bits : Int32, pixel : UInt32) -> Unit {
  if bits == 0 {
    return
  }
  let slot = hash_pixel(pixel, bits)
  cache[slot] = pixel
}

///|
fn hash_pixel(pixel : UInt32, bits : Int32) -> Int32 {
  ((pixel * 0x1E35A7BDU) >> (32 - bits)).reinterpret_as_int()
}

///|
/// The width after a transform that halves it `bits` times.
fn subsample(size : Int32, bits : Int32) -> Int32 {
  (size + (1 << bits) - 1) >> bits
}

///|
/// The hundred and twenty places a short distance code can name: a pixel's own
/// row behind it, then the rows above, nearest first.
fn distance_places() -> Array[(Int32, Int32)] {
  [
    (0, 1),
    (1, 0),
    (1, 1),
    (-1, 1),
    (0, 2),
    (2, 0),
    (1, 2),
    (-1, 2),
    (2, 1),
    (-2, 1),
    (2, 2),
    (-2, 2),
    (0, 3),
    (3, 0),
    (1, 3),
    (-1, 3),
    (3, 1),
    (-3, 1),
    (2, 3),
    (-2, 3),
    (3, 2),
    (-3, 2),
    (0, 4),
    (4, 0),
    (1, 4),
    (-1, 4),
    (4, 1),
    (-4, 1),
    (3, 3),
    (-3, 3),
    (2, 4),
    (-2, 4),
    (4, 2),
    (-4, 2),
    (0, 5),
    (3, 4),
    (-3, 4),
    (4, 3),
    (-4, 3),
    (5, 0),
    (1, 5),
    (-1, 5),
    (5, 1),
    (-5, 1),
    (2, 5),
    (-2, 5),
    (5, 2),
    (-5, 2),
    (4, 4),
    (-4, 4),
    (3, 5),
    (-3, 5),
    (5, 3),
    (-5, 3),
    (0, 6),
    (6, 0),
    (1, 6),
    (-1, 6),
    (6, 1),
    (-6, 1),
    (2, 6),
    (-2, 6),
    (6, 2),
    (-6, 2),
    (4, 5),
    (-4, 5),
    (5, 4),
    (-5, 4),
    (3, 6),
    (-3, 6),
    (6, 3),
    (-6, 3),
    (0, 7),
    (7, 0),
    (1, 7),
    (-1, 7),
    (5, 5),
    (-5, 5),
    (7, 1),
    (-7, 1),
    (4, 6),
    (-4, 6),
    (6, 4),
    (-6, 4),
    (2, 7),
    (-2, 7),
    (7, 2),
    (-7, 2),
    (3, 7),
    (-3, 7),
    (7, 3),
    (-7, 3),
    (5, 6),
    (-5, 6),
    (6, 5),
    (-6, 5),
    (8, 0),
    (4, 7),
    (-4, 7),
    (7, 4),
    (-7, 4),
    (8, 1),
    (8, 2),
    (6, 6),
    (-6, 6),
    (8, 3),
    (5, 7),
    (-5, 7),
    (7, 5),
    (-7, 5),
    (8, 4),
    (6, 7),
    (-6, 7),
    (7, 6),
    (-7, 6),
    (8, 5),
    (7, 7),
    (-7, 7),
    (8, 6),
    (8, 7),
  ]
}

///|
/// The image in a VP8L payload, whose first byte is the signature.
pub fn decode_lossless(
  payload : BytesView,
  limits : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  if payload.length() < 5 {
    raise @raster.Truncated(at=payload.length(), want=5 - payload.length())
  }
  if payload[0].to_int() != 0x2F {
    raise @raster.Unexpected(
      at=0,
      got=@raster.hex(payload, 0, 1),
      want="the 0x2f that starts a lossless stream",
    )
  }
  let reader = Bits::new(payload, 1)
  let width = reader.take(14) + 1
  let height = reader.take(14) + 1
  ignore(reader.take(1))
  let version = reader.take(3)
  if version != 0 {
    raise @raster.Unexpected(
      at=1,
      got="a lossless stream of version \{version}",
      want="version zero",
    )
  }
  limits.check(width, height)
  let plane = decode_stream(reader, width, height, true, limits)
  if plane.width != width || plane.height != height {
    raise @raster.Unexpected(
      at=reader.at(),
      got="a picture \{plane.width} by \{plane.height}",
      want="\{width} by \{height}",
    )
  }
  to_image(plane)
}

///|
/// The image in a lossless *stream*: the part of a VP8L file that comes after
/// its five-byte header, with the size supplied by the caller.
///
/// A lossy WebP codes its alpha channel this way, in a separate `ALPH` chunk
/// whose size is the picture's own, which is why there is no header to read.
pub fn decode_lossless_stream(
  payload : BytesView,
  width : Int32,
  height : Int32,
  limits : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  limits.check(width, height)
  let plane = decode_stream(Bits::new(payload, 0), width, height, true, limits)
  to_image(plane)
}

///|
/// ARGB words as the library's four-byte pixels.
fn to_image(plane : Plane) -> @raster.Image raise @raster.Refused {
  let buffer : FixedArray[Byte] = FixedArray::make(
    plane.width * plane.height * 4,
    b'\x00',
  )
  for index in 0..<plane.pixels.length() {
    let pixel = plane.pixels[index]
    buffer[index * 4] = ((pixel >> 16) & 0xFFU).reinterpret_as_int().to_byte()
    buffer[index * 4 + 1] = ((pixel >> 8) & 0xFFU)
      .reinterpret_as_int()
      .to_byte()
    buffer[index * 4 + 2] = (pixel & 0xFFU).reinterpret_as_int().to_byte()
    buffer[index * 4 + 3] = ((pixel >> 24) & 0xFFU)
      .reinterpret_as_int()
      .to_byte()
  }
  @raster.Image::of(
    plane.width,
    plane.height,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(buffer.clamped_view()),
  )
}
