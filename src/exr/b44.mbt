// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// B44, the compression of a half-float picture that keeps four bits of every
// sample.
//
// A chunk of thirty-two scanlines is grouped by channel, and each channel into
// blocks of four by four pixels. A block of sixteen halves is thirty-two bytes;
// B44 writes fourteen, of which two are the value of one pixel and twelve are
// six-bit differences from it. The differences are right-shifted by a number
// chosen per block, so a block whose values span a wide range keeps its shape
// and loses only its low bits, and a block of a single value costs three bytes
// in B44A.
//
// The values are compared as sign-magnitude integers rather than as halves: for
// a positive float the bit pattern is already in order, and for a negative one
// complementing every bit puts it in order behind the positives. That is what
// makes "the largest of the sixteen" a number the rest can be subtracted from.
//
// Channels that are not halves — a float render, an integer mask — are copied
// through unmoved. A lossy code that quantized them would change what they mean.
//
// A channel marked `linear` in the header is exponentiated by an eighth before
// the block is packed and logarithmically restored on the way out, which spreads
// the low bits of a dark picture over more steps at the cost of the bright end.
// That is the one part of the format that needs a table of sixty-five thousand
// entries, and the tables are computed rather than stored.
//
// https://openexr.com/en/latest/TechnicalIntroduction.html

///|
/// How many pixels on a side a block of B44 holds.
const B44_BLOCK : Int32 = 4

///|
/// A half as a number in which the order of the bits is the order of the values.
fn b44_to_ordered(bits : Int32) -> Int32 {
  if (bits & 0x7C00) == 0x7C00 {
    // A NaN or an infinity has no place in an order, and a block that held one
    // would have no largest value. Every one of them becomes the same pattern,
    // which is what zero is once the signs are undone below.
    0x8000
  } else if (bits & 0x8000) != 0 {
    (bits ^ 0xFFFF) & 0xFFFF
  } else {
    bits | 0x8000
  }
}

///|
/// The half an ordered value came from: the inverse of `b44_to_ordered`.
fn b44_from_ordered(value : Int32) -> Int32 {
  if (value & 0x8000) != 0 {
    value & 0x7FFF
  } else {
    (value ^ 0xFFFF) & 0xFFFF
  }
}

///|
/// `x` divided by two to the `shift`, rounded to nearest with ties to even.
///
/// The doubling is what leaves the bit that decides a tie where the shift can
/// see it; adding the half-way value and that bit is the whole of
/// round-half-to-even.
fn b44_shift_and_round(x : Int32, shift : Int32) -> Int32 {
  let doubled = x << 1
  let halfway = (1 << shift) - 1
  let tie = (doubled >> (shift + 1)) & 1
  (doubled + halfway + tie) >> (shift + 1)
}

///|
/// One block of sixteen halves as fourteen bytes, or as three when every value
/// is the same and the writer asked for that.
///
/// Returns how many bytes were written, which is what tells the two spellings
/// apart later: a third byte of `0xfc` is a shift field of sixty-three, which no
/// fourteen-byte block reaches.
fn b44_pack_block(
  block : FixedArray[Int32],
  out : FixedArray[Byte],
  at : Int32,
  flat : Bool,
) -> Int32 {
  let ordered : FixedArray[Int32] = FixedArray::make(16, 0)
  let mut largest = 0
  for i in 0..<16 {
    let value = b44_to_ordered(block[i])
    ordered[i] = value
    if largest < value {
      largest = value
    }
  }
  let differences : FixedArray[Int32] = FixedArray::make(16, 0)
  let runs : FixedArray[Int32] = FixedArray::make(15, 0)
  let mut shift = 0
  let mut lowest = 0
  let mut highest = 0
  // Every difference, biased into six bits, has to land in nought to sixty-three.
  // The shift that makes that true is found by trying: the first one that fits
  // keeps the most of the block's low bits.
  while true {
    for i in 0..<16 {
      differences[i] = b44_shift_and_round(largest - ordered[i], shift)
    }
    runs[0] = differences[0] - differences[4] + 0x20
    runs[1] = differences[4] - differences[8] + 0x20
    runs[2] = differences[8] - differences[12] + 0x20
    runs[3] = differences[0] - differences[1] + 0x20
    runs[4] = differences[4] - differences[5] + 0x20
    runs[5] = differences[8] - differences[9] + 0x20
    runs[6] = differences[12] - differences[13] + 0x20
    runs[7] = differences[1] - differences[2] + 0x20
    runs[8] = differences[5] - differences[6] + 0x20
    runs[9] = differences[9] - differences[10] + 0x20
    runs[10] = differences[13] - differences[14] + 0x20
    runs[11] = differences[2] - differences[3] + 0x20
    runs[12] = differences[6] - differences[7] + 0x20
    runs[13] = differences[10] - differences[11] + 0x20
    runs[14] = differences[14] - differences[15] + 0x20
    lowest = runs[0]
    highest = runs[0]
    for i in 1..<15 {
      if lowest > runs[i] {
        lowest = runs[i]
      }
      if highest < runs[i] {
        highest = runs[i]
      }
    }
    if lowest >= 0 && highest < 64 {
      break
    }
    shift = shift + 1
  }
  if flat && lowest == 0x20 && highest == 0x20 {
    // Sixteen identical values: the first of them, and a shift no block of
    // fourteen bytes can name.
    out[at] = ((ordered[0] >> 8) & 0xFF).to_byte()
    out[at + 1] = (ordered[0] & 0xFF).to_byte()
    out[at + 2] = b'\xfc'
    return 3
  }
  // The pixel that holds the largest value is written as itself rather than as a
  // rounded difference, so that the most important value of the block is the one
  // that comes back exact.
  let first = if flat {
    ordered[0]
  } else {
    largest - (differences[0] << shift)
  }
  out[at] = ((first >> 8) & 0xFF).to_byte()
  out[at + 1] = (first & 0xFF).to_byte()
  out[at + 2] = ((shift << 2) | (runs[0] >> 4)).to_byte()
  out[at + 3] = ((runs[0] << 4) | (runs[1] >> 2)).to_byte()
  out[at + 4] = ((runs[1] << 6) | runs[2]).to_byte()
  out[at + 5] = ((runs[3] << 2) | (runs[4] >> 4)).to_byte()
  out[at + 6] = ((runs[4] << 4) | (runs[5] >> 2)).to_byte()
  out[at + 7] = ((runs[5] << 6) | runs[6]).to_byte()
  out[at + 8] = ((runs[7] << 2) | (runs[8] >> 4)).to_byte()
  out[at + 9] = ((runs[8] << 4) | (runs[9] >> 2)).to_byte()
  out[at + 10] = ((runs[9] << 6) | runs[10]).to_byte()
  out[at + 11] = ((runs[11] << 2) | (runs[12] >> 4)).to_byte()
  out[at + 12] = ((runs[12] << 4) | (runs[13] >> 2)).to_byte()
  out[at + 13] = ((runs[13] << 6) | runs[14]).to_byte()
  14
}

///|
/// One block of three or fourteen bytes as sixteen halves: the differences are
/// added back up the block, and the order the packer imposed is undone.
fn b44_unpack_block(
  body : BytesView,
  at : Int32,
  block : FixedArray[Int32],
) -> Int32 raise @raster.Refused {
  if at + 3 > body.length() {
    raise @raster.Truncated(at~, want=3)
  }
  let first = (body[at].to_int() << 8) | body[at + 1].to_int()
  if body[at + 2].to_int() >= 13 << 2 {
    let single = b44_from_ordered(first)
    for i in 0..<16 {
      block[i] = single
    }
    return 3
  }
  if at + 14 > body.length() {
    raise @raster.Truncated(at~, want=14)
  }
  let b2 = body[at + 2].to_int()
  let b3 = body[at + 3].to_int()
  let b4 = body[at + 4].to_int()
  let b5 = body[at + 5].to_int()
  let b6 = body[at + 6].to_int()
  let b7 = body[at + 7].to_int()
  let b8 = body[at + 8].to_int()
  let b9 = body[at + 9].to_int()
  let b10 = body[at + 10].to_int()
  let b11 = body[at + 11].to_int()
  let b12 = body[at + 12].to_int()
  let b13 = body[at + 13].to_int()
  let shift = b2 >> 2
  let bias = 0x20 << shift
  let s : FixedArray[Int32] = FixedArray::make(16, 0)
  s[0] = first
  s[4] = (first + ((((b2 << 4) | (b3 >> 4)) & 0x3F) << shift) - bias) & 0xFFFF
  s[8] = (s[4] + ((((b3 << 2) | (b4 >> 6)) & 0x3F) << shift) - bias) & 0xFFFF
  s[12] = (s[8] + ((b4 & 0x3F) << shift) - bias) & 0xFFFF
  s[1] = (first + (b5 >> 2 << shift) - bias) & 0xFFFF
  s[5] = (s[4] + ((((b5 << 4) | (b6 >> 4)) & 0x3F) << shift) - bias) & 0xFFFF
  s[9] = (s[8] + ((((b6 << 2) | (b7 >> 6)) & 0x3F) << shift) - bias) & 0xFFFF
  s[13] = (s[12] + ((b7 & 0x3F) << shift) - bias) & 0xFFFF
  s[2] = (s[1] + (b8 >> 2 << shift) - bias) & 0xFFFF
  s[6] = (s[5] + ((((b8 << 4) | (b9 >> 4)) & 0x3F) << shift) - bias) & 0xFFFF
  s[10] = (s[9] + ((((b9 << 2) | (b10 >> 6)) & 0x3F) << shift) - bias) & 0xFFFF
  s[14] = (s[13] + ((b10 & 0x3F) << shift) - bias) & 0xFFFF
  s[3] = (s[2] + (b11 >> 2 << shift) - bias) & 0xFFFF
  s[7] = (s[6] + ((((b11 << 4) | (b12 >> 4)) & 0x3F) << shift) - bias) & 0xFFFF
  s[11] = (s[10] + ((((b12 << 2) | (b13 >> 6)) & 0x3F) << shift) - bias) &
    0xFFFF
  s[15] = (s[14] + ((b13 & 0x3F) << shift) - bias) & 0xFFFF
  for i in 0..<16 {
    block[i] = b44_from_ordered(s[i])
  }
  14
}

///|
/// The half a bit pattern stands for, as a double, which is the type the table
/// below is built in.
fn b44_half(bits : Int32) -> Double {
  @raster.half_to_float(bits).to_double()
}

///|
/// `8 * log (x)` over every half, which is what undoes the exponentiation the
/// writer of a perceptually linear channel applied before packing it.
///
/// A negative value leaves the domain of the logarithm, and the format writes
/// the infinity a logarithm at nought produces rather than nought: the table's
/// first entry, and its nought with a sign, are both minus infinity.
///
/// One entry does not come out of a double-precision logarithm the way it comes
/// out of the single-precision one the format's own generator used, and it is
/// written down rather than approximated. A test compares the whole table
/// against that generator's.
fn b44_log_table() -> FixedArray[Int32] {
  let table : FixedArray[Int32] = FixedArray::make(65536, 0)
  for bits in 0..<65536 {
    let value = b44_half(bits)
    table[bits] = if (bits & 0x7C00) == 0x7C00 {
      0
    } else if value < 0.0 {
      0
    } else if value == 0.0 {
      0xFC00
    } else {
      @raster.float_to_half(Float::from_double(8.0 * @math.ln(value)))
    }
  }
  table[7544] = 0xD13C
  table
}

///|
/// Whether a channel asks for the curve, which is the one thing about a chunk
/// that needs a table of sixty-five thousand entries.
fn b44_needs_table(channels : Array[Channel]) -> Bool {
  let mut needed = false
  for channel in channels {
    if channel.kind == 1 && channel.linear {
      needed = true
    }
  }
  needed
}

///|
/// How many sixteen-bit words one pixel of every channel takes.
fn words_per_pixel(channels : Array[Channel]) -> Int32 {
  let mut total = 0
  for channel in channels {
    total = total + channel.sample / 2
  }
  total
}

///|
/// The words of one half channel's plane, read from its blocks.
///
/// Blocks past the right edge and below the bottom are written by the packer by
/// repeating the last column and the last row, so a reader writes back only the
/// part of a block that is inside the picture.
fn b44_read_plane(
  body : BytesView,
  start : Int32,
  plane : FixedArray[Int32],
  base : Int32,
  width : Int32,
  lines : Int32,
  logs : FixedArray[Int32]?,
) -> Int32 raise @raster.Refused {
  let block : FixedArray[Int32] = FixedArray::make(16, 0)
  let mut at = start
  let mut y = 0
  while y < lines {
    let mut x = 0
    while x < width {
      at = at + b44_unpack_block(body, at, block)
      if logs is Some(table) {
        for i in 0..<16 {
          block[i] = table[block[i]]
        }
      }
      for dy in 0..<B44_BLOCK {
        let row = y + dy
        if row < lines {
          for dx in 0..<B44_BLOCK {
            let column = x + dx
            if column < width {
              plane[base + row * width + column] = block[dy * B44_BLOCK + dx]
            }
          }
        }
      }
      x = x + B44_BLOCK
    }
    y = y + B44_BLOCK
  }
  at
}

///|
/// A chunk of B44 blocks, as the row-major bytes the rest of the reader wants.
fn b44_unpack(
  body : BytesView,
  channels : Array[Channel],
  width : Int32,
  lines : Int32,
  logs? : FixedArray[Int32],
) -> Bytes raise @raster.Refused {
  let logs = logs.unwrap_or([])
  let plane = width * lines
  let words : FixedArray[Int32] = FixedArray::make(
    plane * words_per_pixel(channels),
    0,
  )
  let mut at = 0
  let mut base = 0
  for channel in channels {
    let count = plane * (channel.sample / 2)
    if channel.kind == 1 {
      // Only a channel of halves is compressed. A header that marks one of them
      // perceptually linear gets the table that undoes the exponentiation.
      let table = if channel.linear { Some(logs) } else { None }
      at = b44_read_plane(body, at, words, base, width, lines, table)
    } else {
      for i in 0..<count {
        if at + 2 > body.length() {
          raise @raster.Truncated(at~, want=2)
        }
        words[base + i] = le16(body, at)
        at = at + 2
      }
    }
    base = base + count
  }
  // The channel-planar words back into the scanline-interleaved order every
  // other compression is in.
  let out : FixedArray[Byte] = FixedArray::make(
    plane * words_per_pixel(channels) * 2,
    b'\x00',
  )
  let mut to = 0
  for line in 0..<lines {
    let mut origin = 0
    for channel in channels {
      let span = width * (channel.sample / 2)
      let from = origin + line * span
      for i in 0..<span {
        let word = words[from + i]
        out[to] = (word & 0xFF).to_byte()
        out[to + 1] = ((word >> 8) & 0xFF).to_byte()
        to = to + 2
      }
      origin = origin + plane * (channel.sample / 2)
    }
  }
  Bytes::from_array(out.clamped_view())
}

///|
/// One half channel's plane as blocks, which is `b44_read_plane` the other way
/// round.
fn b44_write_plane(
  words : FixedArray[Int32],
  base : Int32,
  width : Int32,
  lines : Int32,
  exp : FixedArray[Int32]?,
  out : FixedArray[Byte],
  start : Int32,
  flat : Bool,
) -> Int32 {
  let block : FixedArray[Int32] = FixedArray::make(16, 0)
  let mut at = start
  let mut y = 0
  while y < lines {
    let mut x = 0
    while x < width {
      for dy in 0..<B44_BLOCK {
        let row = if y + dy < lines { y + dy } else { lines - 1 }
        for dx in 0..<B44_BLOCK {
          let column = if x + dx < width { x + dx } else { width - 1 }
          block[dy * B44_BLOCK + dx] = words[base + row * width + column]
        }
      }
      if exp is Some(table) {
        for i in 0..<16 {
          block[i] = table[block[i]]
        }
      }
      at = at + b44_pack_block(block, out, at, flat)
      x = x + B44_BLOCK
    }
    y = y + B44_BLOCK
  }
  at
}

///|
/// A chunk of row-major samples as B44 bytes.
///
/// `flat` is the difference between the two spellings: B44A writes three bytes
/// for a block of sixteen identical values, and B44 always writes fourteen.
fn b44_pack(
  raw : BytesView,
  channels : Array[Channel],
  width : Int32,
  lines : Int32,
  flat : Bool,
) -> Bytes {
  let plane = width * lines
  let total = plane * words_per_pixel(channels)
  let words : FixedArray[Int32] = FixedArray::make(total, 0)
  // The chunk arrives one scanline after another, each holding every channel in
  // turn; the blocks want one channel at a time.
  let mut at = 0
  let bases : FixedArray[Int32] = FixedArray::make(channels.length(), 0)
  let mut base = 0
  for i in 0..<channels.length() {
    bases[i] = base
    base = base + plane * (channels[i].sample / 2)
  }
  for line in 0..<lines {
    for i in 0..<channels.length() {
      let span = width * (channels[i].sample / 2)
      let origin = bases[i] + line * width * (channels[i].sample / 2)
      for j in 0..<span {
        words[origin + j] = le16(raw, at + j * 2)
      }
      at = at + span * 2
    }
  }
  // Fourteen bytes a block is the largest a block of halves can take, and the
  // rest of the channels are copied through, so this cannot overflow.
  let blocks = (width + B44_BLOCK - 1) /
    B44_BLOCK *
    ((lines + B44_BLOCK - 1) / B44_BLOCK)
  let out = @wire.Writer::new()
  let scratch : FixedArray[Byte] = FixedArray::make(
    blocks * 14 + total * 2,
    b'\x00',
  )
  let mut written = 0
  let mut origin = 0
  for channel in channels {
    let count = plane * (channel.sample / 2)
    if channel.kind == 1 {
      // This writer marks every channel as it came, so no block is exponential
      // before it is packed and no table is needed.
      written = b44_write_plane(
        words,
        origin,
        width,
        lines,
        None,
        scratch,
        written,
        flat,
      )
    } else {
      for i in 0..<count {
        let word = words[origin + i]
        scratch[written] = (word & 0xFF).to_byte()
        scratch[written + 1] = ((word >> 8) & 0xFF).to_byte()
        written = written + 2
      }
    }
    origin = origin + count
  }
  out.bytes(Bytes::from_array(scratch.clamped_view(end=written)))
  out.to_bytes()
}
