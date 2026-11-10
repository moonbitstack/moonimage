// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing OpenEXR.
//
// Three channels are written, or four when the picture has alpha, as plain RGB
// over a data window the size of the picture: that is the shape every reader
// opens without asking questions, and it is what a renderer hands to a
// compositor. The alpha is left out rather than written as ones when the
// picture has none, because a channel that says nothing still costs a scanline
// of zeroes in every chunk.
//
// The attributes are the six the specification calls required, written in the
// order they are listed there. Anything else — a colour space note, a frame
// number, the name of the program that made it — is not this library's to
// invent.

///|
/// How to write the file.
pub(all) struct EncodeOptions {
  /// The compression to use.
  compression : Compression
  /// Whether the samples are halves rather than floats. A half is what a
  /// picture of light is usually stored as: eleven bits of mantissa is more
  /// than a display has, and half the bytes.
  half : Bool
}

///|
/// ZIP, halves: sixteen scanlines to a chunk, and half the size.
pub fn EncodeOptions::default() -> EncodeOptions {
  { compression: Zip, half: true, }
}

///|
/// The image as OpenEXR bytes.
pub fn encode(image : @raster.Image, options? : EncodeOptions) -> Bytes {
  let options = options.unwrap_or(EncodeOptions::default())
  let floats = image.convert(@raster.PixelFormat::RgbaF32)
  let alpha = image.format.has_alpha()
  let width = floats.width
  let height = floats.height
  let names = if alpha { ["A", "B", "G", "R"] } else { ["B", "G", "R"] }
  let offsets = if alpha { [3, 2, 1, 0] } else { [2, 1, 0] }
  let sample = if options.half { 2 } else { 4 }
  let writer = @wire.Writer::new()
  writer.bytes(b"\x76\x2F\x31\x01")
  writer.u32_le(2)
  write_channels(writer, names, options.half)
  writer.bytes(b"compression\x00compression\x00")
  writer.u32_le(1)
  writer.u8(options.compression.code())
  for name in ["dataWindow", "displayWindow"] {
    writer.bytes(utf8(name))
    writer.u8(0)
    writer.bytes(b"box2i\x00")
    writer.u32_le(16)
    writer.u32_le(0)
    writer.u32_le(0)
    writer.u32_le(width - 1)
    writer.u32_le(height - 1)
  }
  writer.bytes(b"lineOrder\x00lineOrder\x00")
  writer.u32_le(1)
  writer.u8(0)
  writer.bytes(b"pixelAspectRatio\x00float\x00")
  writer.u32_le(4)
  writer.u32_le(0x3F800000)
  writer.bytes(b"screenWindowCenter\x00v2f\x00")
  writer.u32_le(8)
  writer.u32_le(0)
  writer.u32_le(0)
  writer.bytes(b"screenWindowWidth\x00float\x00")
  writer.u32_le(4)
  writer.u32_le(0x3F800000)
  writer.u8(0)
  let per_chunk = lines_per_chunk(options.compression)
  let chunks = (height + per_chunk - 1) / per_chunk
  let table_at = writer.length()
  writer.zeros(chunks * 8)
  let row_bytes = names.length() * width * sample
  for chunk in 0..<chunks {
    let first = chunk * per_chunk
    let lines = if first + per_chunk > height {
      height - first
    } else {
      per_chunk
    }
    let raw : FixedArray[Byte] = FixedArray::make(row_bytes * lines, b'\x00')
    let mut at = 0
    for line in 0..<lines {
      for channel in 0..<names.length() {
        let give = offsets[channel]
        for x in 0..<width {
          let value = @raster.float_at(
            floats.pixels,
            (first + line) * floats.stride + x * 16 + give * 4,
          )
          // Every number in the file is little-endian, samples included.
          if sample == 2 {
            let bits = float_to_half(value)
            raw[at] = (bits & 0xFF).to_byte()
            raw[at + 1] = ((bits >> 8) & 0xFF).to_byte()
          } else {
            let bits = value.reinterpret_as_uint().reinterpret_as_int()
            raw[at] = (bits & 0xFF).to_byte()
            raw[at + 1] = ((bits >> 8) & 0xFF).to_byte()
            raw[at + 2] = ((bits >> 16) & 0xFF).to_byte()
            raw[at + 3] = ((bits >> 24) & 0xFF).to_byte()
          }
          at = at + sample
        }
      }
    }
    let packed = pack(
      raw,
      row_bytes * lines,
      options.compression,
      names.length(),
      width,
      lines,
      sample,
    )
    let here = writer.length()
    // The offset table was reserved before the first chunk, so its entry is
    // filled in by rewriting the eight bytes in place.
    let table = table_at + chunk * 8
    let _ = table
    writer.u32_le(first)
    writer.u32_le(packed.length())
    writer.bytes(packed)
    let _ = here
  }
  let body = writer.to_bytes()
  // The offsets are known only after the chunks were written, so the table is
  // patched in the finished bytes: a chunk's offset is where its scanline
  // number starts, eight bytes of table before each one.
  patch_offsets(body, table_at, height, per_chunk, chunks)
}

///|
/// Fill the reserved offset table in the finished file.
fn patch_offsets(
  body : Bytes,
  table_at : Int32,
  height : Int32,
  per_chunk : Int32,
  chunks : Int32,
) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(body.length(), b'\x00')
  for i in 0..<body.length() {
    out[i] = body[i]
  }
  // Walk the chunks once more to learn where each one starts.
  let mut at = table_at + chunks * 8
  for chunk in 0..<chunks {
    put64(out, table_at + chunk * 8, at)
    let length = body[at + 4].to_int() |
      (body[at + 5].to_int() << 8) |
      (body[at + 6].to_int() << 16) |
      (body[at + 7].to_int() << 24)
    at = at + 8 + length
  }
  let _ = height
  let _ = per_chunk
  Bytes::from_array(out.clamped_view())
}

///|
fn put64(out : FixedArray[Byte], at : Int32, value : Int32) -> Unit {
  out[at] = (value & 0xFF).to_byte()
  out[at + 1] = ((value >> 8) & 0xFF).to_byte()
  out[at + 2] = ((value >> 16) & 0xFF).to_byte()
  out[at + 3] = ((value >> 24) & 0xFF).to_byte()
  out[at + 4] = 0
  out[at + 5] = 0
  out[at + 6] = 0
  out[at + 7] = 0
}

///|
/// The channel list attribute, which is a name, a sample type and two words of
/// sampling rates for each channel, then a nought.
fn write_channels(
  writer : @wire.Writer,
  names : Array[String],
  half : Bool,
) -> Unit {
  let body = @wire.Writer::new()
  for name in names {
    body.bytes(utf8(name))
    body.u8(0)
    body.u32_le(if half { 1 } else { 2 })
    body.u8(0)
    body.u8(0)
    body.u8(0)
    body.u8(0)
    body.u32_le(1)
    body.u32_le(1)
  }
  body.u8(0)
  let bytes = body.to_bytes()
  writer.bytes(b"channels\x00chlist\x00")
  writer.u32_le(bytes.length())
  writer.bytes(bytes)
}

///|
/// What a sample of this width is, as far as a compression that looks inside it
/// is concerned.
fn kind_of(sample : Int32) -> Int32 {
  if sample == 2 {
    1
  } else {
    2
  }
}

///|
/// A chunk, split into two halves and differenced, then compressed.
fn pack(
  raw : FixedArray[Byte],
  want : Int32,
  compression : Compression,
  channel_count : Int32,
  width : Int32,
  lines : Int32,
  sample : Int32,
) -> Bytes {
  let bytes = Bytes::from_array(raw.clamped_view())
  if compression == None {
    return bytes
  }
  if compression == Piz || compression == Pxr24 {
    // Both read the chunk by channel rather than by row, and both do their own
    // packing; nothing in front of them.
    let channels : Array[Channel] = []
    for _ in 0..<channel_count {
      channels.push({ name: "", sample, kind: kind_of(sample), })
    }
    if compression == Piz {
      return piz_pack(bytes, channels, width, lines)
    }
    return pxr24_pack(bytes, channels, width, lines)
  }
  let packed = scramble(raw, want)
  let shorter = if compression == Rle {
    run_length(packed)
  } else {
    @zlib.zlib(packed)
  }
  // A chunk that did not get smaller is written as it came: a reader tells the
  // two apart by the length.
  if shorter.length() >= want {
    bytes
  } else {
    shorter
  }
}

///|
/// The chunk as RLE and deflate both see it: the even bytes first, the odd ones
/// after them, and then the difference from the byte before, offset by the
/// middle of the range so that a small difference is a small number either way.
fn scramble(raw : FixedArray[Byte], want : Int32) -> Bytes {
  let half = (want + 1) / 2
  let split : FixedArray[Byte] = FixedArray::make(want, b'\x00')
  for i in 0..<want {
    if i % 2 == 0 {
      split[i / 2] = raw[i]
    } else if half + i / 2 < want {
      split[half + i / 2] = raw[i]
    }
  }
  let out : FixedArray[Byte] = FixedArray::make(want, b'\x00')
  out[0] = split[0]
  for i in 1..<want {
    let value = split[i].to_int() - split[i - 1].to_int() + 128
    out[i] = (value & 0xFF).to_byte()
  }
  Bytes::from_array(out.clamped_view())
}

///|
fn run_length(data : BytesView) -> Bytes {
  let writer = @wire.Writer::new()
  let end = data.length()
  let mut runs = 0
  while runs < end {
    let mut rune = runs + 1
    let mut repeats = 0
    while rune < end && data[rune] == data[runs] && repeats < 127 {
      rune = rune + 1
      repeats = repeats + 1
    }
    if repeats >= 2 {
      // Three of a kind or more: a count of the repeats after the first, then
      // the byte itself.
      writer.u8(repeats)
      writer.u8(data[runs].to_int())
      runs = rune
    } else {
      let mut fresh = repeats + 1
      while rune < end &&
            (
              rune + 1 >= end ||
              data[rune] != data[rune + 1] ||
              rune + 2 >= end ||
              data[rune + 1] != data[rune + 2]
            ) &&
            fresh < 127 {
        fresh = fresh + 1
        rune = rune + 1
      }
      // A literal run: the count negated, then the bytes.
      writer.u8(256 - fresh)
      while runs < rune {
        writer.u8(data[runs].to_int())
        runs = runs + 1
      }
    }
    rune = rune + 1
    if runs < rune - 1 {
      runs = rune - 1
    }
  }
  writer.to_bytes()
}

///|
fn utf8(text : String) -> Bytes {
  @utf8.encode(text)
}
