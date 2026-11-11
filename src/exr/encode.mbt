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
//
// A file may hold more than one picture. The header of a file with several is
// written once per part, each with a name of its own and a count of its chunks,
// then one offset table per part, and every chunk in front of its data says
// which part it belongs to. The parts share a display window, which is the
// window of the first, so that a compositor can lay them over one another.

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
  let source = source_of(image, options)
  let writer = @wire.Writer::new()
  writer.bytes(b"\x76\x2F\x31\x01")
  writer.u32_le(2)
  write_header(writer, source, None, 0, (source.width, source.height))
  let table_at = writer.length()
  writer.zeros(source.chunks() * 8)
  let positions : Array[Int32] = []
  for chunk in 0..<source.chunks() {
    positions.push(writer.length())
    write_chunk(writer, None, source, chunk)
  }
  patch(writer.to_bytes(), table_at, positions)
}

///|
/// The pictures as one file of several parts, each with a name.
///
/// The name is what a reader uses to tell them apart — `RGBA` and `depth`, or
/// `left` and `right` — and it has to be unique within the file. Every part
/// takes the same compression and the same sample width, which is what a
/// renderer writing a beauty pass and its auxiliary passes hand over; a part
/// that wants another compression is a file of its own.
///
/// The pictures share a display window: the window of the first, which is the
/// one a compositor draws. A part with fewer pixels than that of the first is
/// placed at its own data window, which is where the first part's display
/// window says it belongs.
pub fn encode_parts(
  parts : Array[(String, @raster.Image)],
  options? : EncodeOptions,
) -> Bytes {
  if parts.is_empty() {
    abort("a file of several parts needs at least one")
  }
  let options = options.unwrap_or(EncodeOptions::default())
  let writer = @wire.Writer::new()
  writer.bytes(b"\x76\x2F\x31\x01")
  // The second flag is the one that says the file holds more than one part; a
  // reader that does not know it stops rather than reading the first header as
  // the whole file.
  writer.u32_le(2 | 0x1000)
  let sources : Array[Source] = []
  for part in parts {
    sources.push(source_of(part.1, options))
  }
  // The display window is one window for the file: the window of the first part,
  // which is the picture a compositor draws. A part of fewer pixels sits at its
  // own data window, and the format refuses a file whose parts disagree.
  let display = (sources[0].width, sources[0].height)
  for index in 0..<sources.length() {
    write_header(
      writer,
      sources[index],
      Some(parts[index].0),
      sources[index].chunks(),
      display,
    )
  }
  // An empty header ends the list.
  writer.u8(0)
  let tables : Array[Int32] = []
  for source in sources {
    tables.push(writer.length())
    writer.zeros(source.chunks() * 8)
  }
  let positions : Array[Array[Int32]] = []
  for index in 0..<sources.length() {
    let here : Array[Int32] = []
    for chunk in 0..<sources[index].chunks() {
      here.push(writer.length())
      write_chunk(writer, Some(index), sources[index], chunk)
    }
    positions.push(here)
  }
  let mut body = writer.to_bytes()
  for index in 0..<sources.length() {
    body = patch(body, tables[index], positions[index])
  }
  body
}

///|
/// One picture, gathered into the shape the file stores: its channels, the
/// window, and the raw bytes of each chunk.
priv struct Source {
  floats : @raster.Image
  names : Array[String]
  /// Which of the four samples of the converted picture each channel takes.
  offsets : Array[Int32]
  sample : Int32
  width : Int32
  height : Int32
  compression : Compression
  curve : DwaCurve?
}

///|
fn source_of(image : @raster.Image, options : EncodeOptions) -> Source {
  let alpha = image.format.has_alpha()
  let names = if alpha { ["A", "B", "G", "R"] } else { ["B", "G", "R"] }
  let offsets = if alpha { [3, 2, 1, 0] } else { [2, 1, 0] }
  {
    floats: image.convert(@raster.PixelFormat::RgbaF32),
    names,
    offsets,
    sample: if options.half {
      2
    } else {
      4
    },
    width: image.width,
    height: image.height,
    compression: options.compression,
    curve: if options.compression == Dwaa || options.compression == Dwab {
      Some(dwa_curve())
    } else {
      None
    },
  }
}

///|
fn Source::chunks(self : Source) -> Int32 {
  let per_chunk = lines_per_chunk(self.compression)
  (self.height + per_chunk - 1) / per_chunk
}

///|
/// A header: the six required attributes, sorted by name, then the two a part
/// of a file with several needs.
fn write_header(
  writer : @wire.Writer,
  source : Source,
  name : String?,
  chunk_count : Int32,
  display : (Int32, Int32),
) -> Unit {
  write_channels(writer, source.names, source.sample == 2)
  match name {
    Some(_) => write_int_attribute(writer, "chunkCount", chunk_count)
    None => ()
  }
  writer.bytes(b"compression\x00compression\x00")
  writer.u32_le(1)
  writer.u8(source.compression.code())
  for attribute in ["dataWindow", "displayWindow"] {
    let (across, down) = if attribute == "dataWindow" {
      (source.width, source.height)
    } else {
      display
    }
    writer.bytes(utf8(attribute))
    writer.u8(0)
    writer.bytes(b"box2i\x00")
    writer.u32_le(16)
    writer.u32_le(0)
    writer.u32_le(0)
    writer.u32_le(across - 1)
    writer.u32_le(down - 1)
  }
  writer.bytes(b"lineOrder\x00lineOrder\x00")
  writer.u32_le(1)
  writer.u8(0)
  match name {
    Some(part) => {
      writer.bytes(b"name\x00string\x00")
      let encoded = utf8(part)
      writer.u32_le(encoded.length())
      writer.bytes(encoded)
    }
    None => ()
  }
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
  match name {
    Some(_) => {
      // A part of a file with several says what kind of part it is; a reader
      // that finds one kind and expects another stops rather than misreads it.
      writer.bytes(b"type\x00string\x00")
      let kind = b"scanlineimage"
      writer.u32_le(kind.length())
      writer.bytes(kind)
    }
    None => ()
  }
  writer.u8(0)
}

///|
fn write_int_attribute(
  writer : @wire.Writer,
  name : String,
  value : Int32,
) -> Unit {
  writer.bytes(utf8(name))
  writer.u8(0)
  writer.bytes(b"int\x00")
  writer.u32_le(4)
  writer.u32_le(value)
}

///|
/// One chunk: where its scanlines begin, how long it is, and its bytes — with
/// the number of its part in front when the file holds several.
fn write_chunk(
  writer : @wire.Writer,
  part : Int32?,
  source : Source,
  chunk : Int32,
) -> Unit {
  let per_chunk = lines_per_chunk(source.compression)
  let first = chunk * per_chunk
  let lines = if first + per_chunk > source.height {
    source.height - first
  } else {
    per_chunk
  }
  let sample = source.sample
  let row_bytes = source.names.length() * source.width * sample
  let raw : FixedArray[Byte] = FixedArray::make(row_bytes * lines, b'\x00')
  let mut at = 0
  for line in 0..<lines {
    for channel in 0..<source.names.length() {
      let give = source.offsets[channel]
      for x in 0..<source.width {
        let value = @raster.float_at(
          source.floats.pixels,
          (first + line) * source.floats.stride + x * 16 + give * 4,
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
    source.compression,
    source.names,
    source.width,
    lines,
    sample,
    source.curve,
  )
  match part {
    Some(index) => writer.u32_le(index)
    None => ()
  }
  writer.u32_le(first)
  writer.u32_le(packed.length())
  writer.bytes(packed)
}

///|
/// Fill a reserved offset table in the finished file with the places its chunks
/// were written.
fn patch(body : Bytes, table_at : Int32, positions : Array[Int32]) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(body.length(), b'\x00')
  for i in 0..<body.length() {
    out[i] = body[i]
  }
  for chunk in 0..<positions.length() {
    put64(out, table_at + chunk * 8, positions[chunk])
  }
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
  names : Array[String],
  width : Int32,
  lines : Int32,
  sample : Int32,
  curve : DwaCurve?,
) -> Bytes {
  let bytes = Bytes::from_array(raw.clamped_view())
  if compression == None {
    return bytes
  }
  let channel_count = names.length()
  if compression == Dwaa || compression == Dwab {
    // The frequencies of a block depend on what the channel means, so this one
    // needs the names the others do not.
    let channels : Array[Channel] = []
    for name in names {
      channels.push({ name, sample, kind: kind_of(sample), linear: false, })
    }
    let tables = curve.unwrap_or(dwa_curve())
    let packed = dwa_pack(bytes, channels, width, lines, tables)
    return if packed.length() >= want { bytes } else { packed }
  }
  if compression == Piz || compression == Pxr24 {
    // Both read the chunk by channel rather than by row, and both do their own
    // packing; nothing in front of them.
    let channels : Array[Channel] = []
    for _ in 0..<channel_count {
      channels.push({ name: "", sample, kind: kind_of(sample), linear: false, })
    }
    if compression == Piz {
      return piz_pack(bytes, channels, width, lines)
    }
    return pxr24_pack(bytes, channels, width, lines)
  }
  if compression == B44 || compression == B44a {
    // Blocks rather than bytes: the channel list is what says where one
    // channel's blocks end and the next begins.
    let channels : Array[Channel] = []
    for _ in 0..<channel_count {
      channels.push({ name: "", sample, kind: kind_of(sample), linear: false, })
    }
    let packed = b44_pack(bytes, channels, width, lines, compression == B44a)
    return if packed.length() >= want { bytes } else { packed }
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
