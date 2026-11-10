// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// PIZ, the compression OpenEXR uses for photographs.
//
// It is the one of the four that looks at the picture instead of the bytes. A
// chunk of a photograph holds a few thousand distinct sixteen-bit words out of
// sixty-five thousand; PIZ writes down which ones they were as a bitmap, numbers
// them one after another, and works from there. What follows is the wavelet: a
// lossless transform that turns neighbouring samples into a low value, the mean
// of the pair, and a high one, their difference. A photograph is smooth, so the
// differences are small and the means carry the picture, and a run of small
// numbers is what the Huffman coder beside this file is good at.
//
// The wavelet is the integer one, so it inverts exactly: the mean of two
// integers and their difference hold every bit of both. There are two spellings
// of it. The one used when every word fits in fourteen bits works in signed
// arithmetic and leaves the low bits alone; the one used for full sixteen-bit
// words works modulo 65536, which costs a little compression and cannot overflow.
//
// A chunk is thirty-two scanlines, and inside it the samples are grouped by
// channel: all of red, then all of green, which is what lets a wavelet run down
// a channel without stepping over the others.

///|
/// How many values a sixteen-bit word has, which is the range compression's
/// alphabet.
const PIZ_SYMBOLS : Int32 = 65536

///|
/// The bitmap that says which of those values appear, a bit each.
const PIZ_BITMAP : Int32 = 8192

///|
/// Where each channel's samples sit in a chunk, in words.
priv struct Planes {
  /// The word where a channel's plane starts.
  base : FixedArray[Int32]
  /// The words in one scanline of that channel.
  row : FixedArray[Int32]
  /// The words one sample of that channel takes: one for a half, two for a float.
  words : FixedArray[Int32]
  /// The words the whole chunk takes.
  total : Int32
}

///|
fn planes_of(channels : Array[Channel], width : Int32, lines : Int32) -> Planes {
  let count = channels.length()
  let base : FixedArray[Int32] = FixedArray::make(count, 0)
  let row : FixedArray[Int32] = FixedArray::make(count, 0)
  let words : FixedArray[Int32] = FixedArray::make(count, 0)
  let mut at = 0
  for i in 0..<count {
    base[i] = at
    words[i] = channels[i].sample / 2
    row[i] = width * words[i]
    at = at + row[i] * lines
  }
  { base, row, words, total: at, }
}

///|
/// A chunk that PIZ could not make smaller, written as it came.
fn piz_plain_of(
  raw : BytesView,
  channels : Array[Channel],
  width : Int32,
  lines : Int32,
) -> Bytes {
  piz_plain(raw, raw.length(), channels, width, lines)
}

///|
/// A chunk PIZ stored as it came.
///
/// PIZ works on sixteen-bit words rather than on bytes, but the buffer it is
/// handed is the same little-endian one the rest of the file uses, in the order
/// the rest of the reader wants it, so an uncompressed chunk is a copy.
fn piz_plain(
  body : BytesView,
  want : Int32,
  channels : Array[Channel],
  width : Int32,
  lines : Int32,
) -> Bytes {
  let _ = (channels, width, lines)
  let out : FixedArray[Byte] = FixedArray::make(want, b'\x00')
  for i in 0..<want {
    if i < body.length() {
      out[i] = body[i]
    }
  }
  Bytes::from_array(out.clamped_view())
}

///|
/// A chunk as PIZ bytes, or the chunk itself when compressing it does not pay.
fn piz_pack(
  raw : BytesView,
  channels : Array[Channel],
  width : Int32,
  lines : Int32,
) -> Bytes {
  let plan = planes_of(channels, width, lines)
  let words : FixedArray[UInt32] = FixedArray::make(plan.total, 0U)
  let mut at = 0
  for line in 0..<lines {
    for c in 0..<channels.length() {
      let span = plan.row[c]
      let origin = plan.base[c] + line * span
      for i in 0..<span {
        words[origin + i] = le16(raw, at + i * 2).reinterpret_as_uint()
      }
      at = at + span * 2
    }
  }
  let bitmap : FixedArray[Byte] = FixedArray::make(PIZ_BITMAP, b'\x00')
  let (lowest, highest) = bitmap_of(words, bitmap)
  let lut : FixedArray[Int32] = FixedArray::make(PIZ_SYMBOLS, 0)
  let ceiling = forward_lut(bitmap, lut)
  for i in 0..<plan.total {
    words[i] = lut[words[i].reinterpret_as_int()].reinterpret_as_uint()
  }
  for c in 0..<channels.length() {
    let span = plan.row[c]
    for j in 0..<plan.words[c] {
      wavelet_encode(
        words,
        plan.base[c] + j,
        width,
        plan.words[c],
        lines,
        span,
        ceiling,
      )
    }
  }
  let freq : FixedArray[UInt64] = FixedArray::make(HUFFMAN_SPAN, 0UL)
  let table = Table::new()
  let lengths : FixedArray[Int32] = FixedArray::make(HUFFMAN_SPAN, 0)
  let block = match huffman_encode(words, freq, table, lengths) {
    Some(bytes) => bytes
    None => return piz_plain_of(raw, channels, width, lines)
  }
  let writer = @wire.Writer::new()
  writer.u16_le(lowest)
  writer.u16_le(highest)
  if lowest <= highest {
    writer.bytes(
      Bytes::from_array(bitmap.clamped_view(start=lowest, end=highest + 1)),
    )
  }
  writer.u32_le(block.length())
  writer.bytes(block)
  let packed = writer.to_bytes()
  // A chunk that did not get smaller is written as it came: a reader tells the
  // two apart by the length, which is the whole chunk for one of them.
  if packed.length() >= raw.length() {
    piz_plain_of(raw, channels, width, lines)
  } else {
    packed
  }
}

///|
/// The chunk a PIZ block holds, in the row-by-row order the rest of the decoder
/// reads.
fn piz_unpack(
  body : BytesView,
  want : Int32,
  channels : Array[Channel],
  width : Int32,
  lines : Int32,
) -> Bytes raise @raster.Refused {
  if want % 2 != 0 {
    raise @raster.Unexpected(
      at=0,
      got="a chunk that is not a run of words",
      want="an even number of bytes",
    )
  }
  if body.length() < 4 {
    raise @raster.Truncated(at=0, want=4)
  }
  let lowest = body[0].to_int() | (body[1].to_int() << 8)
  let highest = body[2].to_int() | (body[3].to_int() << 8)
  if highest >= PIZ_BITMAP {
    raise @raster.Unexpected(
      at=2,
      got="a bitmap past its range",
      want="a bitmap inside eight thousand one hundred and ninety-two bytes",
    )
  }
  let bitmap : FixedArray[Byte] = FixedArray::make(PIZ_BITMAP, b'\x00')
  let mut at = 4
  if lowest <= highest {
    let span = highest - lowest + 1
    if at + span > body.length() {
      raise @raster.Truncated(at~, want=span)
    }
    for i in 0..<span {
      bitmap[lowest + i] = body[at + i]
    }
    at = at + span
  }
  let lut : FixedArray[Int32] = FixedArray::make(PIZ_SYMBOLS, 0)
  let ceiling = reverse_lut(bitmap, lut)
  if at + 4 > body.length() {
    raise @raster.Truncated(at~, want=4)
  }
  let size = le32(body, at)
  at = at + 4
  if size < 0 || at + size > body.length() {
    raise @raster.Truncated(at~, want=size)
  }
  let words = huffman_decode(
    body.clamped_view(start=at, end=at + size),
    want / 2,
  )
  let plan = planes_of(channels, width, lines)
  for c in 0..<channels.length() {
    let span = plan.row[c]
    for j in 0..<plan.words[c] {
      wavelet_decode(
        words,
        plan.base[c] + j,
        width,
        plan.words[c],
        lines,
        span,
        ceiling,
      )
    }
  }
  for i in 0..<plan.total {
    words[i] = lut[words[i].reinterpret_as_int()].reinterpret_as_uint()
  }
  let out : FixedArray[Byte] = FixedArray::make(want, b'\x00')
  let mut to = 0
  for line in 0..<lines {
    for c in 0..<channels.length() {
      let span = plan.row[c]
      let origin = plan.base[c] + line * span
      for i in 0..<span {
        let word = words[origin + i].reinterpret_as_int()
        out[to + i * 2] = (word & 0xFF).to_byte()
        out[to + i * 2 + 1] = ((word >> 8) & 0xFF).to_byte()
      }
      to = to + span * 2
    }
  }
  Bytes::from_array(out.clamped_view())
}

///|
/// Which words appear, and the first and last byte of the bitmap that hold a
/// bit — the two numbers the chunk writes.
///
/// Zero is not written down: a chunk of a picture always holds plenty of it, so
/// leaving its bit clear costs a reader nothing and saves the byte the bitmap
/// would need for it.
fn bitmap_of(
  words : FixedArray[UInt32],
  bitmap : FixedArray[Byte],
) -> (Int32, Int32) {
  for i in 0..<PIZ_BITMAP {
    bitmap[i] = b'\x00'
  }
  for word in words {
    let value = word.reinterpret_as_int()
    let at = value >> 3
    bitmap[at] = (bitmap[at].to_int() | (1 << (value & 7))).to_byte()
  }
  bitmap[0] = (bitmap[0].to_int() & 0xFE).to_byte()
  let mut lowest = PIZ_BITMAP - 1
  let mut highest = 0
  for i in 0..<PIZ_BITMAP {
    if bitmap[i] != b'\x00' {
      if lowest > i {
        lowest = i
      }
      if highest < i {
        highest = i
      }
    }
  }
  (lowest, highest)
}

///|
/// The bitmap as a table from a word to the value it was given, which is the
/// order the words appear in the bitmap. Returns the highest value written.
fn forward_lut(bitmap : FixedArray[Byte], lut : FixedArray[Int32]) -> Int32 {
  let mut next = 0
  for value in 0..<PIZ_SYMBOLS {
    let used = value == 0 ||
      (bitmap[value >> 3].to_int() & (1 << (value & 7))) != 0
    if used {
      lut[value] = next
      next = next + 1
    } else {
      lut[value] = 0
    }
  }
  next - 1
}

///|
/// The bitmap as a table from a number back to the word it stood for, which is
/// the inverse of `forward_lut`. Returns the highest value written.
///
/// The tail of the table is left at nought so that a corrupt chunk naming a
/// value past the end reads a word rather than out of the array.
fn reverse_lut(bitmap : FixedArray[Byte], lut : FixedArray[Int32]) -> Int32 {
  let mut next = 0
  for value in 0..<PIZ_SYMBOLS {
    if value == 0 || (bitmap[value >> 3].to_int() & (1 << (value & 7))) != 0 {
      lut[next] = value
      next = next + 1
    }
  }
  for i in next..<PIZ_SYMBOLS {
    lut[i] = 0
  }
  next - 1
}

///|
/// A word as the signed integer the fourteen-bit wavelet works with.
fn signed_word(word : UInt32) -> Int32 {
  let value = word.reinterpret_as_int()
  if value >= 32768 {
    value - 65536
  } else {
    value
  }
}

///|
/// A signed integer as the word a chunk holds.
fn word_of(value : Int32) -> UInt32 {
  (value & 0xFFFF).reinterpret_as_uint()
}

///|
/// One pair becomes its mean and its difference, in signed arithmetic. Used only
/// when every word is below 16384, where no sum can leave the type.
fn wenc14(a : Int32, b : Int32) -> (Int32, Int32) {
  ((a + b) >> 1, a - b)
}

///|
/// The pair a mean and a difference came from: the inverse of `wenc14`.
fn wdec14(low : Int32, high : Int32) -> (Int32, Int32) {
  let sum = low + (high & 1) + (high >> 1)
  (sum, sum - high)
}

///|
/// The same pair, modulo 65536, for words that use the whole range.
fn wenc16(a : Int32, b : Int32) -> (Int32, Int32) {
  let offset = (a + 32768) & 0xFFFF
  let mean = (offset + b) >> 1
  let difference = offset - b
  let placed = if difference < 0 { (mean + 32768) & 0xFFFF } else { mean }
  (placed, difference & 0xFFFF)
}

///|
/// The pair `wenc16` came from.
fn wdec16(low : Int32, high : Int32) -> (Int32, Int32) {
  let base = (low - (high >> 1)) & 0xFFFF
  ((high + base - 32768) & 0xFFFF, base)
}

///|
/// The wavelet over one channel plane, one level of detail at a time.
///
/// Each pass halves the step: pairs that are one apart become means and
/// differences, then pairs of means two apart, and so on until the plane is one
/// value. The three neighbours of every fourth value are the detail of that
/// level, and they are what compresses.
fn wavelet_encode(
  data : FixedArray[UInt32],
  origin : Int32,
  nx : Int32,
  ox : Int32,
  ny : Int32,
  oy : Int32,
  ceiling : Int32,
) -> Unit {
  let narrow = ceiling < 16384
  let smallest = if nx < ny { nx } else { ny }
  let mut p = 1
  let mut p2 = 2
  while p2 <= smallest {
    let ox1 = ox * p
    let ox2 = ox * p2
    let oy1 = oy * p
    let oy2 = oy * p2
    let last_row = oy * (ny - p2)
    let last_column = ox * (nx - p2)
    let mut py = 0
    while py <= last_row {
      let mut px = py
      while px <= py + last_column {
        let p01 = px + ox1
        let p10 = px + oy1
        let p11 = p10 + ox1
        let top = data[origin + px]
        let top_right = data[origin + p01]
        let bottom = data[origin + p10]
        let bottom_right = data[origin + p11]
        if narrow {
          let (low, high) = wenc14(signed_word(top), signed_word(top_right))
          let (low2, high2) = wenc14(
            signed_word(bottom),
            signed_word(bottom_right),
          )
          let (left, right) = wenc14(low, low2)
          let (left2, right2) = wenc14(high, high2)
          data[origin + px] = word_of(left)
          data[origin + p10] = word_of(right)
          data[origin + p01] = word_of(left2)
          data[origin + p11] = word_of(right2)
        } else {
          let (low, high) = wenc16(
            top.reinterpret_as_int(),
            top_right.reinterpret_as_int(),
          )
          let (low2, high2) = wenc16(
            bottom.reinterpret_as_int(),
            bottom_right.reinterpret_as_int(),
          )
          let (left, right) = wenc16(low, low2)
          let (left2, right2) = wenc16(high, high2)
          data[origin + px] = word_of(left)
          data[origin + p10] = word_of(right)
          data[origin + p01] = word_of(left2)
          data[origin + p11] = word_of(right2)
        }
        px = px + ox2
      }
      if (nx & p) != 0 {
        let p10 = px + oy1
        let top = data[origin + px]
        let bottom = data[origin + p10]
        let (low, high) = if narrow {
          wenc14(signed_word(top), signed_word(bottom))
        } else {
          wenc16(top.reinterpret_as_int(), bottom.reinterpret_as_int())
        }
        data[origin + px] = word_of(low)
        data[origin + p10] = word_of(high)
      }
      py = py + oy2
    }
    if (ny & p) != 0 {
      let mut px = py
      while px <= py + last_column {
        let p01 = px + ox1
        let left = data[origin + px]
        let right = data[origin + p01]
        let (low, high) = if narrow {
          wenc14(signed_word(left), signed_word(right))
        } else {
          wenc16(left.reinterpret_as_int(), right.reinterpret_as_int())
        }
        data[origin + px] = word_of(low)
        data[origin + p01] = word_of(high)
        px = px + ox2
      }
    }
    p = p2
    p2 = p2 * 2
  }
}

///|
/// The plane the wavelet was applied to, read back.
///
/// The levels are undone from the coarsest, which is the order they were applied
/// in reversed: a mean of means is only a mean once the levels below it are back.
fn wavelet_decode(
  data : FixedArray[UInt32],
  origin : Int32,
  nx : Int32,
  ox : Int32,
  ny : Int32,
  oy : Int32,
  ceiling : Int32,
) -> Unit {
  let narrow = ceiling < 16384
  let smallest = if nx < ny { nx } else { ny }
  let mut p = 1
  while p <= smallest {
    p = p << 1
  }
  p = p >> 1
  let mut p2 = p
  p = p >> 1
  while p >= 1 {
    let ox1 = ox * p
    let ox2 = ox * p2
    let oy1 = oy * p
    let oy2 = oy * p2
    let last_row = oy * (ny - p2)
    let last_column = ox * (nx - p2)
    let mut py = 0
    while py <= last_row {
      let mut px = py
      while px <= py + last_column {
        let p01 = px + ox1
        let p10 = px + oy1
        let p11 = p10 + ox1
        if narrow {
          let (low, low2) = wdec14(
            signed_word(data[origin + px]),
            signed_word(data[origin + p10]),
          )
          let (high, high2) = wdec14(
            signed_word(data[origin + p01]),
            signed_word(data[origin + p11]),
          )
          let (a, c) = wdec14(low, high)
          let (b, d) = wdec14(low2, high2)
          data[origin + px] = word_of(a)
          data[origin + p01] = word_of(c)
          data[origin + p10] = word_of(b)
          data[origin + p11] = word_of(d)
        } else {
          let (low, low2) = wdec16(
            data[origin + px].reinterpret_as_int(),
            data[origin + p10].reinterpret_as_int(),
          )
          let (high, high2) = wdec16(
            data[origin + p01].reinterpret_as_int(),
            data[origin + p11].reinterpret_as_int(),
          )
          let (a, c) = wdec16(low, high)
          let (b, d) = wdec16(low2, high2)
          data[origin + px] = word_of(a)
          data[origin + p01] = word_of(c)
          data[origin + p10] = word_of(b)
          data[origin + p11] = word_of(d)
        }
        px = px + ox2
      }
      if (nx & p) != 0 {
        let p10 = px + oy1
        let (low, high) = if narrow {
          wdec14(
            signed_word(data[origin + px]),
            signed_word(data[origin + p10]),
          )
        } else {
          wdec16(
            data[origin + px].reinterpret_as_int(),
            data[origin + p10].reinterpret_as_int(),
          )
        }
        data[origin + px] = word_of(low)
        data[origin + p10] = word_of(high)
      }
      py = py + oy2
    }
    if (ny & p) != 0 {
      let mut px = py
      while px <= py + last_column {
        let p01 = px + ox1
        let (low, high) = if narrow {
          wdec14(
            signed_word(data[origin + px]),
            signed_word(data[origin + p01]),
          )
        } else {
          wdec16(
            data[origin + px].reinterpret_as_int(),
            data[origin + p01].reinterpret_as_int(),
          )
        }
        data[origin + px] = word_of(low)
        data[origin + p01] = word_of(high)
        px = px + ox2
      }
    }
    p2 = p
    p = p >> 1
  }
}
