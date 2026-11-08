// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The tags and shapes TIFF is made of, and the two codecs that are not deflate.
//
// TIFF is a directory of numeric tags pointing at data anywhere in the file,
// and everything else — how wide the picture is, whether the samples are
// sixteen bits or one, whether the rows are reversed — is one of those tags.
// This file holds the numbers, the reader that turns a directory into answers,
// and the two run-length codes the format defined for itself; the deflate one
// is the library's.

///|
let tag_image_width : Int32 = 256

///|
let tag_image_length : Int32 = 257

///|
let tag_bits_per_sample : Int32 = 258

///|
let tag_compression : Int32 = 259

///|
let tag_photometric : Int32 = 262

///|
let tag_fill_order : Int32 = 266

///|
let tag_strip_offsets : Int32 = 273

///|
let tag_orientation : Int32 = 274

///|
let tag_samples_per_pixel : Int32 = 277

///|
let tag_rows_per_strip : Int32 = 278

///|
let tag_strip_byte_counts : Int32 = 279

///|
let tag_planar : Int32 = 284

///|
let tag_predictor : Int32 = 317

///|
let tag_color_map : Int32 = 320

///|
let tag_extra_samples : Int32 = 338

///|
let tag_icc : Int32 = 34675

///|
/// How the samples of a strip are packed.
#derive(Eq, Debug)
pub(all) enum Compression {
  /// Stored as they are.
  None
  /// LZW, with the code width growing one code early, which is what the
  /// specification's appendix asks for.
  Lzw
  /// PackBits: a signed count, then that many bytes or that many repeats.
  PackBits
  /// Deflate, as a zlib stream or as a bare one; both appear in the wild.
  Deflate
}

///|
pub extend Compression with Eq::{equal, not_equal}

///|
pub extend Compression with Debug::{to_repr}

///|
/// The number a file writes for this compression.
pub fn Compression::code(self : Compression) -> Int32 {
  match self {
    None => 1
    Lzw => 5
    PackBits => 32773
    Deflate => 8
  }
}

///|
/// The compression a number stands for, or `None` for one this library does not
/// read.
pub fn Compression::of(code : Int32) -> Compression? {
  match code {
    1 => Some(None)
    5 => Some(Lzw)
    8 | 32946 => Some(Deflate)
    32773 => Some(PackBits)
    _ => None
  }
}

///|
/// One directory entry, as a tag, a type, and the values or the bytes.
priv struct Field {
  tag : Int32
  values : Array[Int32]
  raw : BytesView
}

///|
/// A directory: the entries, and where the next one is.
priv struct Directory {
  fields : Array[Field]
  next : Int32
}

///|
/// The directory starting at `at`, in the byte order the header declared.
fn read_directory(
  data : BytesView,
  at : Int32,
  little : Bool,
  at_most : Int32,
) -> Directory raise @raster.Refused {
  if at < 0 || at + 2 > data.length() {
    raise @raster.Truncated(at~, want=2)
  }
  let count = word(data, at, little)
  if count > at_most {
    raise @raster.OverLimit(limit=at_most, got=count)
  }
  let fields : Array[Field] = []
  for index in 0..<count {
    let base = at + 2 + index * 12
    if base + 12 > data.length() {
      raise @raster.Truncated(at=base, want=base + 12 - data.length())
    }
    let tag = word(data, base, little)
    let kind = word(data, base + 2, little)
    let many = long(data, base + 4, little)
    let size = type_size(kind)
    if size == 0 || many < 0 {
      continue
    }
    let total = many.to_int64() * size.to_int64()
    let body = if total <= 4L {
      data.clamped_view(start=base + 8, end=base + 12)
    } else {
      let offset = long(data, base + 8, little)
      if offset < 0 || offset.to_int64() + total > data.length().to_int64() {
        raise @raster.Truncated(at=base + 8, want=total.to_int())
      }
      data.clamped_view(start=offset, end=offset + total.to_int())
    }
    fields.push(read_field(tag, kind, many, body, little))
  }
  let next = long(data, at + 2 + count * 12, little)
  { fields, next, }
}

///|
fn read_field(
  tag : Int32,
  kind : Int32,
  count : Int32,
  body : BytesView,
  little : Bool,
) -> Field {
  let values : Array[Int32] = []
  if kind != 2 && kind != 7 {
    for index in 0..<count {
      values.push(
        match kind {
          1 | 6 => body[index].to_int()
          3 | 8 => word(body, index * 2, little)
          4 | 9 | 11 => long(body, index * 4, little)
          _ => 0
        },
      )
    }
  }
  { tag, values, raw: body, }
}

///|
/// How many bytes one value of this type takes, or nought for a type this
/// library does not know.
fn type_size(kind : Int32) -> Int32 {
  match kind {
    1 | 2 | 6 | 7 => 1
    3 | 8 => 2
    4 | 9 | 11 => 4
    5 | 10 | 12 => 8
    _ => 0
  }
}

///|
fn Directory::find(self : Directory, tag : Int32) -> Field? {
  for field in self.fields {
    if field.tag == tag {
      return Some(field)
    }
  }
  None
}

///|
/// The first value of a tag, or the caller's default.
fn Directory::number(self : Directory, tag : Int32, missing : Int32) -> Int32 {
  match self.find(tag) {
    Some(field) =>
      if field.values.is_empty() {
        missing
      } else {
        field.values[0]
      }
    None => missing
  }
}

///|
/// Every value of a tag, in the order the file had them.
fn Directory::numbers(self : Directory, tag : Int32) -> Array[Int32] {
  match self.find(tag) {
    Some(field) => field.values
    None => []
  }
}

///|
/// The bytes of a byte-valued tag, or nothing.
fn Directory::bytes(self : Directory, tag : Int32) -> BytesView? {
  match self.find(tag) {
    Some(field) => Some(field.raw)
    None => None
  }
}

///|
fn word(data : BytesView, at : Int32, little : Bool) -> Int32 {
  if little {
    data[at].to_int() | (data[at + 1].to_int() << 8)
  } else {
    (data[at].to_int() << 8) | data[at + 1].to_int()
  }
}

///|
fn long(data : BytesView, at : Int32, little : Bool) -> Int32 {
  if little {
    data[at].to_int() |
    (data[at + 1].to_int() << 8) |
    (data[at + 2].to_int() << 16) |
    (data[at + 3].to_int() << 24)
  } else {
    (data[at].to_int() << 24) |
    (data[at + 1].to_int() << 16) |
    (data[at + 2].to_int() << 8) |
    data[at + 3].to_int()
  }
}

///|
/// PackBits, which is a signed count followed by that many samples.
///
/// A count from nought to a hundred and twenty-seven means that many bytes
/// follow as they are; from minus one to minus a hundred and twenty-seven means
/// the next byte repeated that many times plus one; minus a hundred and
/// twenty-eight is a no-op that encoders emit to resynchronise.
fn unpack_bits(
  data : BytesView,
  want : Int32,
) -> FixedArray[Byte] raise @raster.Refused {
  let out : FixedArray[Byte] = FixedArray::make(want, b'\x00')
  let mut at = 0
  let mut produced = 0
  while produced < want {
    if at >= data.length() {
      raise @raster.Truncated(at~, want=want - produced)
    }
    let count = data[at].to_int()
    at = at + 1
    let signed = if count > 127 { count - 256 } else { count }
    if signed >= 0 {
      let run = signed + 1
      if at + run > data.length() {
        raise @raster.Truncated(at~, want=run)
      }
      for i in 0..<run {
        if produced < want {
          out[produced] = data[at + i]
          produced = produced + 1
        }
      }
      at = at + run
    } else if signed != -128 {
      let run = 1 - signed
      if at >= data.length() {
        raise @raster.Truncated(at~, want=1)
      }
      let value = data[at]
      at = at + 1
      for _ in 0..<run {
        if produced < want {
          out[produced] = value
          produced = produced + 1
        }
      }
    }
  }
  out
}

///|
/// LZW as TIFF defines it: most significant bit first, codes starting at nine
/// bits, a table of four thousand and ninety-six entries with the first two
/// hundred and fifty-six of them the single bytes.
///
/// The width grows one code early — the decoder widens when the table reaches
/// one below the limit, because the encoder has already written the wider code.
/// That off-by-one is the whole of the difference between this and every other
/// LZW in use, and getting it wrong costs the last strip of every picture.
fn unpack_lzw(
  data : BytesView,
  want : Int32,
) -> FixedArray[Byte] raise @raster.Refused {
  let out : FixedArray[Byte] = FixedArray::make(want, b'\x00')
  let prefix : FixedArray[Int32] = FixedArray::make(4096, 0)
  let suffix : FixedArray[Int32] = FixedArray::make(4096, 0)
  let length : FixedArray[Int32] = FixedArray::make(4096, 1)
  let stack : FixedArray[Byte] = FixedArray::make(4097, b'\x00')
  for i in 0..<256 {
    suffix[i] = i
    length[i] = 1
  }
  let mut produced = 0
  let mut bits = 0
  let mut pool = 0L
  let mut at = 0
  let mut width = 9
  let mut next = 258
  let mut old = -1
  while produced < want {
    while bits < width && at < data.length() {
      pool = (pool << 8) | data[at].to_int64()
      at = at + 1
      bits = bits + 8
    }
    if bits < width {
      raise @raster.Truncated(at~, want=want - produced)
    }
    let code = ((pool >> (bits - width)) & ((1L << width) - 1L)).to_int()
    bits = bits - width
    if code == 257 {
      break
    }
    if code == 256 {
      width = 9
      next = 258
      old = -1
      continue
    }
    if code > next {
      raise @raster.Unexpected(
        at~,
        got="an LZW code of \{code}",
        want="a code the table has",
      )
    }
    let mut depth = 0
    let mut walk = code
    if code == next {
      if old < 0 {
        raise @raster.Unexpected(
          at~,
          got="a code with no string",
          want="a code",
        )
      }
      walk = old
    }
    while true {
      stack[depth] = suffix[walk].to_byte()
      depth = depth + 1
      if length[walk] <= 1 {
        break
      }
      walk = prefix[walk]
      if depth > 4096 {
        raise @raster.Unexpected(
          at~,
          got="a string with no start",
          want="a chain",
        )
      }
    }
    if code == next {
      stack[depth] = suffix[walk].to_byte()
      depth = depth + 1
    }
    for i in 0..<depth {
      if produced < want {
        out[produced] = stack[depth - 1 - i]
        produced = produced + 1
      }
    }
    if old >= 0 && next < 4096 {
      let mut head = code
      if code == next {
        head = old
      }
      while length[head] > 1 {
        head = prefix[head]
      }
      prefix[next] = old
      suffix[next] = suffix[head]
      length[next] = length[old] + 1
      next = next + 1
      if next == (1 << width) - 1 && width < 12 {
        width = width + 1
      }
    }
    old = code
  }
  out
}

///|
/// LZW, the other way: the same table and the same early widening, so that a
/// reader that follows the specification reads what this writes.
fn pack_lzw(data : BytesView) -> Bytes {
  let bits = BitWriter::new()
  let codes : FixedArray[Int32] = FixedArray::make(4096, -1)
  let prefix : FixedArray[Int32] = FixedArray::make(4096, 0)
  let suffix : FixedArray[Int32] = FixedArray::make(4096, 0)
  bits.write(256, 9)
  let mut width = 9
  let mut next = 258
  let mut old = -1
  for index in 0..<data.length() {
    let byte = data[index].to_int()
    if old < 0 {
      old = byte
      continue
    }
    let hash = ((old << 4) ^ byte) % 4096
    let mut probe = hash
    let mut found = -1
    while codes[probe] >= 0 {
      let candidate = codes[probe]
      if prefix[candidate] == old && suffix[candidate] == byte {
        found = candidate
        break
      }
      probe = (probe + 1) % 4096
      if probe == hash {
        break
      }
    }
    if found >= 0 {
      old = found
      continue
    }
    bits.write(old, width)
    if next < 4096 {
      prefix[next] = old
      suffix[next] = byte
      codes[probe] = next
      next = next + 1
      if next == (1 << width) - 1 && width < 12 {
        width = width + 1
      }
    } else {
      bits.write(256, width)
      for i in 0..<4096 {
        codes[i] = -1
      }
      width = 9
      next = 258
    }
    old = byte
  }
  if old >= 0 {
    bits.write(old, width)
  }
  bits.write(257, width)
  bits.finish()
}

///|
/// Codes packed most significant bit first, which is how TIFF writes them.
priv struct BitWriter {
  writer : @wire.Writer
  mut pool : Int64
  mut bits : Int32
}

///|
fn BitWriter::new() -> BitWriter {
  { writer: @wire.Writer::new(), pool: 0L, bits: 0, }
}

///|
fn BitWriter::write(self : BitWriter, code : Int32, width : Int32) -> Unit {
  self.pool = (self.pool << width) | code.to_int64()
  self.bits = self.bits + width
  while self.bits >= 8 {
    self.writer.u8(((self.pool >> (self.bits - 8)) & 0xFFL).to_int())
    self.bits = self.bits - 8
  }
  if self.bits > 0 {
    self.pool = self.pool & ((1L << self.bits) - 1L)
  } else {
    self.pool = 0L
  }
}

///|
fn BitWriter::finish(self : BitWriter) -> Bytes {
  if self.bits > 0 {
    self.writer.u8(((self.pool << (8 - self.bits)) & 0xFFL).to_int())
    self.bits = 0
  }
  self.writer.to_bytes()
}
