// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The Huffman coder PIZ puts in front of its wavelets.
//
// A chunk of a PIZ file is a run of sixteen-bit words, and they are usually the
// same handful of values over and over: a wavelet turns a photograph into a
// field of small numbers, and a small field of numbers is a few symbols seen
// very often. So the coder is a plain canonical Huffman one, with two additions
// the format's writer made and its reader depends on.
//
// A code table is sent as lengths alone, which is all a canonical code needs;
// runs of lengths that are nought are themselves run-length coded, because a
// chunk uses a few dozen of the sixty-five thousand symbols and would otherwise
// send a table of mostly noughts.
//
// One symbol is invented beyond the highest one used and given a frequency of
// one. It never stands for data: it introduces a byte of repeat count, so that a
// run of the same word costs two codes and a byte rather than a code per word.
//
// Codes go out most significant bit first, the six-bit lengths are packed the
// same way, and the last byte is padded with zeroes on the right.

///|
/// The largest symbol plus the invented one: the format's table size.
const HUFFMAN_SPAN : Int32 = 65537

///|
/// How many bits the first decoding table resolves.
const HUFFMAN_WINDOW : Int32 = 14

///|
/// The longest code the format allows.
const HUFFMAN_LONGEST : Int32 = 58

///|
/// The first six-bit value that stands for a run of noughts, then the one that
/// stands for a long run of them.
const HUFFMAN_SHORT_RUN : Int32 = 59

///|
/// The six-bit value that introduces a run of six or more.
const HUFFMAN_LONG_RUN : Int32 = 63

///|
/// The shortest run written in the long form, and the longest either form
/// expresses.
const HUFFMAN_LONG_RUN_FIRST : Int32 = 6

///|
/// The longest run of noughts one code can stand for: a byte of count on top of
/// the shortest long run.
const HUFFMAN_LONG_RUN_LAST : Int32 = 261

///|
/// A code table, packed as the format keeps it: the length in the low six bits,
/// the code above them.
priv struct Table {
  entries : FixedArray[UInt64]
  mut low : Int32
  mut high : Int32
}

///|
fn Table::new() -> Table {
  { entries: FixedArray::make(HUFFMAN_SPAN, 0UL), low: 0, high: 0, }
}

///|
fn length_of(entry : UInt64) -> Int32 {
  (entry & 63UL).to_int()
}

///|
fn code_of(entry : UInt64) -> UInt64 {
  entry >> 6
}

///|
/// Turn lengths into canonical codes, in place, over the symbols the table
/// covers.
///
/// The rules the format fixes: a shorter code, filled with zeroes on the right,
/// is numerically larger than a longer one, and codes of the same length ascend
/// with the symbol. Both sides of a file build the same table from the lengths
/// alone, which is why the lengths are all that is written down.
fn canonicalise(table : Table) -> Unit {
  let counts : FixedArray[UInt64] = FixedArray::make(59, 0UL)
  for symbol in table.low..<=table.high {
    let length = length_of(table.entries[symbol])
    if length > 0 && length <= HUFFMAN_LONGEST {
      counts[length] = counts[length] + 1UL
    }
  }
  let mut next = 0UL
  let mut length = HUFFMAN_LONGEST
  while length > 0 {
    let carried = (next + counts[length]) >> 1
    counts[length] = next
    next = carried
    length = length - 1
  }
  for symbol in table.low..<=table.high {
    let width = length_of(table.entries[symbol])
    if width > 0 {
      table.entries[symbol] = width.to_uint64() | (counts[width] << 6)
      counts[width] = counts[width] + 1UL
    }
  }
}

///|
/// A bit sink that writes most significant bit first.
priv struct BitSink {
  bytes : Array[Byte]
  mut bits : UInt32
  mut count : Int32
}

///|
fn BitSink::new() -> BitSink {
  { bytes: [], bits: 0U, count: 0, }
}

///|
/// Append the low `width` bits of `value`, the topmost of them first.
///
/// The sink holds fewer than eight bits between calls and a code is at most
/// fifty-eight wide, so the code goes in a piece at a time rather than shifting
/// a sixty-four-bit accumulator by seventy bits in one go.
fn BitSink::put(self : BitSink, value : UInt64, width : Int32) -> Unit {
  let mut left = width
  while left > 0 {
    let room = 8 - self.count
    let take = if left < room { left } else { room }
    let shift = left - take
    let mask = (1UL << take) - 1UL
    self.bits = (self.bits << take) | ((value >> shift) & mask).to_uint()
    self.count = self.count + take
    left = left - take
    if self.count == 8 {
      self.bytes.push((self.bits & 0xFFU).to_byte())
      self.bits = 0U
      self.count = 0
    }
  }
}

///|
/// The bytes written, and how many bits of the last one are real.
fn BitSink::finish(self : BitSink) -> (Bytes, Int32) {
  let mut total = self.bytes.length() * 8
  if self.count > 0 {
    self.bytes.push((self.bits << (8 - self.count)).to_byte())
    total = total + self.count
  }
  (Bytes::from_array(self.bytes), total)
}

///|
/// A bit source that reads most significant bit first, holding what it has read
/// in a window that is refilled a byte at a time.
priv struct BitSource {
  data : BytesView
  mut pos : Int32
  mut window : UInt64
  mut held : Int32
}

///|
fn BitSource::new(data : BytesView) -> BitSource {
  { data, pos: 0, window: 0UL, held: 0, }
}

///|
/// How many bits are left to read, counting the ones in the window.
fn BitSource::left(self : BitSource) -> Int32 {
  self.held + (self.data.length() - self.pos) * 8
}

///|
/// The next `width` bits without consuming them; fewer are available at the end
/// of the input, and the window then holds what there was.
fn BitSource::peek(self : BitSource, width : Int32) -> UInt64 {
  while self.held < width && self.pos < self.data.length() {
    self.window = (self.window << 8) | self.data[self.pos].to_int().to_uint64()
    self.pos = self.pos + 1
    self.held = self.held + 8
  }
  if self.held < width {
    return self.window & ((1UL << self.held) - 1UL)
  }
  (self.window >> (self.held - width)) & ((1UL << width) - 1UL)
}

///|
fn BitSource::drop(self : BitSource, width : Int32) -> Unit {
  self.held = self.held - width
}

///|
/// Huffman lengths from frequencies, in place.
///
/// Two queues, one of leaves sorted by frequency and one of the nodes those
/// leaves were merged into. A heap would pick the two smallest in the same
/// order; the two queues do it without the bookkeeping, because the sum of two
/// merged frequencies is never smaller than either, so what a merge appends is
/// already in order.
///
/// Returns false when the tree came out deeper than the format can write, which
/// is a chunk spread so evenly over the symbols that no code of fifty-eight bits
/// describes it. The caller then stores the chunk as it is.
fn build_lengths(
  freq : FixedArray[UInt64],
  table : Table,
  lengths : FixedArray[Int32],
) -> Bool {
  let used : Array[(UInt64, Int32)] = []
  for symbol in table.low..<=table.high {
    if freq[symbol] > 0UL {
      used.push((freq[symbol], symbol))
    }
  }
  for symbol in table.low..<=table.high {
    lengths[symbol] = 0
  }
  let leaves = used.length()
  if leaves == 0 {
    return false
  }
  used.sort_by(fn(one, other) {
    if one.0 != other.0 {
      if one.0 < other.0 {
        -1
      } else {
        1
      }
    } else {
      one.1 - other.1
    }
  })
  if leaves == 1 {
    // One symbol takes one bit rather than none: a code of no bits would ask a
    // reader to consume nothing and never advance.
    lengths[used[0].1] = 1
    return true
  }
  let nodes = leaves * 2 - 1
  let weight : FixedArray[UInt64] = FixedArray::make(nodes, 0UL)
  let left : FixedArray[Int32] = FixedArray::make(nodes, -1)
  let right : FixedArray[Int32] = FixedArray::make(nodes, -1)
  let symbol_of : FixedArray[Int32] = FixedArray::make(nodes, -1)
  for i in 0..<leaves {
    weight[i] = used[i].0
    symbol_of[i] = used[i].1
  }
  let mut next_leaf = 0
  let mut next_node = 0
  let mut made = leaves
  while made < nodes {
    let picked : Array[Int32] = []
    while picked.length() < 2 {
      let have_leaf = next_leaf < leaves
      let have_node = leaves + next_node < made
      let take_leaf = if have_leaf && have_node {
        weight[next_leaf] <= weight[leaves + next_node]
      } else {
        have_leaf
      }
      if take_leaf {
        picked.push(next_leaf)
        next_leaf = next_leaf + 1
      } else {
        picked.push(leaves + next_node)
        next_node = next_node + 1
      }
    }
    weight[made] = weight[picked[0]] + weight[picked[1]]
    left[made] = picked[0]
    right[made] = picked[1]
    made = made + 1
  }
  let depth : FixedArray[Int32] = FixedArray::make(nodes, 0)
  let stack : Array[Int32] = [nodes - 1]
  while !stack.is_empty() {
    let node = stack.pop().unwrap()
    let child = left[node]
    if child < 0 {
      if depth[node] > HUFFMAN_LONGEST {
        return false
      }
      lengths[symbol_of[node]] = depth[node]
    } else {
      depth[child] = depth[node] + 1
      depth[right[node]] = depth[node] + 1
      stack.push(child)
      stack.push(right[node])
    }
  }
  true
}

///|
/// The table for one chunk of words: the frequencies come in, the codes go out,
/// and the lowest and highest symbol used come back.
///
/// The invented symbol goes one past the highest one used, with a frequency of
/// one, so that it takes the longest code in the table and costs a reader
/// almost nothing to skip.
fn build_encoding(
  freq : FixedArray[UInt64],
  table : Table,
  lengths : FixedArray[Int32],
) -> Bool {
  let mut lowest = 0
  while lowest < HUFFMAN_SPAN && freq[lowest] == 0UL {
    lowest = lowest + 1
  }
  if lowest >= HUFFMAN_SPAN {
    return false
  }
  let mut highest = lowest
  let mut symbol = lowest
  while symbol < HUFFMAN_SPAN {
    if freq[symbol] > 0UL {
      highest = symbol
    }
    symbol = symbol + 1
  }
  if highest + 1 >= HUFFMAN_SPAN {
    return false
  }
  highest = highest + 1
  freq[highest] = 1UL
  table.low = lowest
  table.high = highest
  if !build_lengths(freq, table, lengths) {
    return false
  }
  for i in lowest..<=highest {
    table.entries[i] = lengths[i].to_uint64()
  }
  canonicalise(table)
  true
}

///|
/// The table as the format writes it: six-bit lengths from the lowest symbol to
/// the highest, with runs of noughts shortened.
fn pack_table(table : Table) -> (Bytes, Int32) {
  let sink = BitSink::new()
  let mut symbol = table.low
  while symbol <= table.high {
    let length = length_of(table.entries[symbol])
    if length == 0 {
      let mut run = 1
      while symbol < table.high && run < HUFFMAN_LONG_RUN_LAST {
        if length_of(table.entries[symbol + 1]) > 0 {
          break
        }
        symbol = symbol + 1
        run = run + 1
      }
      if run >= 2 {
        if run >= HUFFMAN_LONG_RUN_FIRST {
          sink.put(HUFFMAN_LONG_RUN.to_uint64(), 6)
          sink.put((run - HUFFMAN_LONG_RUN_FIRST).to_uint64(), 8)
        } else {
          sink.put((HUFFMAN_SHORT_RUN + run - 2).to_uint64(), 6)
        }
        symbol = symbol + 1
        continue
      }
    }
    sink.put(length.to_uint64(), 6)
    symbol = symbol + 1
  }
  sink.finish()
}

///|
/// One symbol, and the words it stands for repeated `run` times beyond the first.
///
/// Repeating is worth it when the two codes and the byte cost less than the
/// codes they replace; `run` counts the repeats, not the first word.
fn send_code(
  sink : BitSink,
  entry : UInt64,
  run : Int32,
  run_entry : UInt64,
) -> Unit {
  let width = length_of(entry)
  let run_width = length_of(run_entry)
  if width + run_width + 8 < width * run {
    sink.put(code_of(entry), width)
    sink.put(code_of(run_entry), run_width)
    sink.put(run.to_uint64(), 8)
  } else {
    let mut left = run
    while left >= 0 {
      sink.put(code_of(entry), width)
      left = left - 1
    }
  }
}

///|
/// The words as a Huffman block: five words of header, the table, the codes.
///
/// Returns `None` when no table describes the words, which is a tree deeper than
/// the format allows; the caller then stores the chunk as it is.
fn huffman_encode(
  words : FixedArray[UInt32],
  freq : FixedArray[UInt64],
  table : Table,
  lengths : FixedArray[Int32],
) -> Bytes? {
  let count = words.length()
  if count == 0 {
    return None
  }
  for i in 0..<HUFFMAN_SPAN {
    freq[i] = 0UL
  }
  for word in words {
    freq[word.reinterpret_as_int()] = freq[word.reinterpret_as_int()] + 1UL
  }
  if !build_encoding(freq, table, lengths) {
    return None
  }
  let (table_bytes, _) = pack_table(table)
  let sink = BitSink::new()
  let run_entry = table.entries[table.high]
  let mut symbol = words[0]
  let mut run = 0
  for i in 1..<count {
    let next = words[i]
    if run == 255 || symbol != next {
      send_code(
        sink,
        table.entries[symbol.reinterpret_as_int()],
        run,
        run_entry,
      )
      run = 0
      symbol = next
    } else {
      run = run + 1
    }
  }
  send_code(sink, table.entries[symbol.reinterpret_as_int()], run, run_entry)
  let (data, bits) = sink.finish()
  let writer = @wire.Writer::new()
  writer.u32_le(table.low)
  writer.u32_le(table.high)
  writer.u32_le(table_bytes.length())
  writer.u32_le(bits)
  writer.u32_le(0)
  writer.bytes(table_bytes)
  writer.bytes(data)
  Some(writer.to_bytes())
}

///|
/// The lengths a table carries, read back out of the packed form.
fn unpack_table(
  source : BitSource,
  table : Table,
) -> Unit raise @raster.Refused {
  let mut symbol = table.low
  while symbol <= table.high {
    if source.left() < 6 {
      raise @raster.Truncated(at=0, want=6)
    }
    let packed = source.peek(6).to_int()
    source.drop(6)
    if packed == HUFFMAN_LONG_RUN {
      if source.left() < 8 {
        raise @raster.Truncated(at=0, want=8)
      }
      let run = source.peek(8).to_int() + HUFFMAN_LONG_RUN_FIRST
      source.drop(8)
      if symbol + run > table.high + 1 {
        raise @raster.Unexpected(
          at=0,
          got="a run of lengths past the table",
          want="a run inside the table",
        )
      }
      for _ in 0..<run {
        table.entries[symbol] = 0UL
        symbol = symbol + 1
      }
    } else if packed >= HUFFMAN_SHORT_RUN {
      let run = packed - HUFFMAN_SHORT_RUN + 2
      if symbol + run > table.high + 1 {
        raise @raster.Unexpected(
          at=0,
          got="a run of lengths past the table",
          want="a run inside the table",
        )
      }
      for _ in 0..<run {
        table.entries[symbol] = 0UL
        symbol = symbol + 1
      }
    } else {
      table.entries[symbol] = packed.to_uint64()
      symbol = symbol + 1
    }
  }
}

///|
/// A table turned into what decoding reads: a first table for the short codes,
/// and the code of each length for the long ones.
priv struct Decoder {
  primary_symbol : FixedArray[Int32]
  primary_width : FixedArray[Int32]
  first : FixedArray[UInt64]
  counts : FixedArray[Int32]
  symbols : Array[Int32]
  starts : FixedArray[Int32]
}

///|
fn Decoder::of(table : Table) -> Decoder raise @raster.Refused {
  let decoder : Decoder = {
    primary_symbol: FixedArray::make(1 << HUFFMAN_WINDOW, -1),
    primary_width: FixedArray::make(1 << HUFFMAN_WINDOW, 0),
    first: FixedArray::make(59, 0UL),
    counts: FixedArray::make(59, 0),
    symbols: [],
    starts: FixedArray::make(59, 0),
  }
  for symbol in table.low..<=table.high {
    let width = length_of(table.entries[symbol])
    if width > HUFFMAN_LONGEST {
      raise @raster.Unexpected(
        at=0,
        got="a code longer than the format allows",
        want="a code of at most fifty-eight bits",
      )
    }
    if width > 0 {
      decoder.counts[width] = decoder.counts[width] + 1
    }
  }
  let mut next = 0UL
  let mut width = HUFFMAN_LONGEST
  while width > 0 {
    let carried = (next + decoder.counts[width].to_uint64()) >> 1
    decoder.first[width] = next
    next = carried
    width = width - 1
  }
  // Long codes are found by comparing against the codes of their length, so the
  // symbols are listed in the order the codes ascend: by length, then symbol.
  let mut at = 0
  for width in 0..<=HUFFMAN_LONGEST {
    decoder.starts[width] = at
    at = at + decoder.counts[width]
  }
  let cursor : FixedArray[Int32] = FixedArray::make(59, 0)
  for width in 0..<=HUFFMAN_LONGEST {
    cursor[width] = decoder.starts[width]
  }
  let ordered : FixedArray[Int32] = FixedArray::make(at, 0)
  for symbol in table.low..<=table.high {
    let width = length_of(table.entries[symbol])
    if width > 0 {
      ordered[cursor[width]] = symbol
      cursor[width] = cursor[width] + 1
    }
  }
  for symbol in ordered {
    decoder.symbols.push(symbol)
  }
  for symbol in table.low..<=table.high {
    let width = length_of(table.entries[symbol])
    if width > 0 && width <= HUFFMAN_WINDOW {
      let code = code_of(table.entries[symbol])
      if code >> width != 0UL {
        raise @raster.Unexpected(
          at=0,
          got="a code wider than its length",
          want="a code that fits its length",
        )
      }
      let base = (code << (HUFFMAN_WINDOW - width)).to_int()
      let span = 1 << (HUFFMAN_WINDOW - width)
      for i in 0..<span {
        if decoder.primary_width[base + i] != 0 {
          raise @raster.Unexpected(
            at=0,
            got="two codes with one prefix",
            want="a prefix code",
          )
        }
        decoder.primary_width[base + i] = width
        decoder.primary_symbol[base + i] = symbol
      }
    }
  }
  decoder
}

///|
/// The words the block holds, of which `count` are expected.
///
/// A block that runs out early, or that names a symbol its table does not have,
/// is refused rather than filled in with zeroes: a chunk of a photograph is not
/// something to guess at.
fn huffman_decode(
  data : BytesView,
  count : Int32,
) -> FixedArray[UInt32] raise @raster.Refused {
  if data.length() < 20 {
    raise @raster.Truncated(at=0, want=20)
  }
  let low = le32(data, 0)
  let high = le32(data, 4)
  let bits = le32(data, 12)
  if low < 0 ||
    high < 0 ||
    low >= HUFFMAN_SPAN ||
    high >= HUFFMAN_SPAN ||
    low > high {
    raise @raster.Unexpected(
      at=0,
      got="a table outside the symbols",
      want="a table inside them",
    )
  }
  if bits < 0 {
    raise @raster.Unexpected(
      at=12,
      got="a count of bits below zero",
      want="a count",
    )
  }
  let source = BitSource::new(data.clamped_view(start=20, end=data.length()))
  let table = Table::new()
  table.low = low
  table.high = high
  unpack_table(source, table)
  canonicalise(table)
  let decoder = Decoder::of(table)
  let payload = data.clamped_view(start=20 + source.pos, end=data.length())
  let stream = BitSource::new(payload)
  let out : FixedArray[UInt32] = FixedArray::make(count, 0U)
  let mut produced = 0
  let mut left = bits
  while produced < count && left > 0 {
    let take = if left < HUFFMAN_WINDOW { left } else { HUFFMAN_WINDOW }
    if stream.left() < take {
      raise @raster.Truncated(at=0, want=take)
    }
    let peeked = stream.peek(take)
    let index = if take == HUFFMAN_WINDOW {
      peeked
    } else {
      peeked << (HUFFMAN_WINDOW - take)
    }
    let mut width = decoder.primary_width[index.to_int()]
    let mut symbol = decoder.primary_symbol[index.to_int()]
    if width == 0 || width > take {
      // A prefix the first table does not resolve: a code longer than its
      // window, found by comparing against the codes of that length.
      let mut found = false
      let mut long = HUFFMAN_WINDOW + 1
      while long <= HUFFMAN_LONGEST && long <= left && !found {
        let count_at = decoder.counts[long]
        if count_at > 0 && stream.left() >= long {
          let code = stream.peek(long)
          let first = decoder.first[long]
          if code >= first && code < first + count_at.to_uint64() {
            width = long
            symbol = decoder.symbols[decoder.starts[long] +
              (code - first).to_int()]
            found = true
          }
        }
        long = long + 1
      }
      if !found {
        raise @raster.Unexpected(
          at=0,
          got="a code no table entry matches",
          want="a code of the table",
        )
      }
    }
    stream.drop(width)
    left = left - width
    let (placed, extra) = emit(out, produced, count, symbol, stream, high)
    produced = placed
    if extra > left {
      raise @raster.Truncated(at=0, want=extra)
    }
    left = left - extra
  }
  if produced != count {
    raise @raster.Truncated(at=0, want=count - produced)
  }
  out
}

///|
/// Place one symbol's words, which is one word unless the symbol introduces a
/// run, and say how many bits of repeat count that took.
fn emit(
  out : FixedArray[UInt32],
  produced : Int32,
  count : Int32,
  symbol : Int32,
  stream : BitSource,
  run_symbol : Int32,
) -> (Int32, Int32) raise @raster.Refused {
  if symbol != run_symbol {
    out[produced] = symbol.reinterpret_as_uint()
    return (produced + 1, 0)
  }
  if produced == 0 {
    raise @raster.Unexpected(
      at=0,
      got="a run with nothing before it",
      want="a word for the run to repeat",
    )
  }
  if stream.left() < 8 {
    raise @raster.Truncated(at=0, want=8)
  }
  let repeat = stream.peek(8).to_int()
  stream.drop(8)
  if produced + repeat > count {
    raise @raster.Unexpected(
      at=0,
      got="a run past the end of the chunk",
      want="a run inside it",
    )
  }
  let value = out[produced - 1]
  let mut placed = produced
  for _ in 0..<repeat {
    out[placed] = value
    placed = placed + 1
  }
  (placed, 8)
}
