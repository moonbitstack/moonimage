// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing TIFF.
//
// The file is laid out the way a reader wants it rather than the way it is
// easiest to write: header, then the strips of every page, then the directories.
// Every offset is therefore known before it is written, and one pass over the
// bytes produces the whole file — a directory that pointed forwards would have
// to be patched after the fact.
//
// The tags written are the smallest set a reader needs: the size, the samples,
// the compression, where the strips are and how long they are. A file with
// nothing else in it is a file no reader has to guess about.

///|
/// How to write the file.
pub(all) struct EncodeOptions {
  /// The compression to use.
  compression : Compression
  /// How many rows go into a strip. Zero means all of them, which is what a
  /// picture that is going to be read whole wants.
  rows_per_strip : Int32
  /// Whether the samples are differenced along each row before compression,
  /// which makes a photograph compress better at the cost of one pass.
  predictor : Bool
}

///|
/// One strip per page, uncompressed: the file any reader opens.
pub fn EncodeOptions::default() -> EncodeOptions {
  { compression: None, rows_per_strip: 0, predictor: false, }
}

///|
/// Deflate with the predictor on, which is what a photograph should be stored
/// as: the difference between neighbours is a small number, and deflate is very
/// good at small numbers.
pub fn EncodeOptions::squeezed() -> EncodeOptions {
  { compression: Deflate, rows_per_strip: 0, predictor: true, }
}

///|
/// The image as a TIFF with one page.
pub fn encode(image : @raster.Image, options? : EncodeOptions) -> Bytes {
  encode_pages([image], options?)
}

///|
/// The image as a TIFF whose samples are tiles rather than strips.
///
/// A tile is a rectangle of the page, compressed on its own, and the tiles at the
/// right and the bottom are padded to the full tile rather than cut short — a
/// reader of a tiled page always unpacks a whole tile. Sixteen by sixteen is the
/// size the format's own tools write; anything else is the caller's business,
/// and a reader that follows the format reads it.
pub fn encode_tiled(
  image : @raster.Image,
  tile_width : Int32,
  tile_height : Int32,
  options? : EncodeOptions,
) -> Bytes {
  let options = options.unwrap_or(EncodeOptions::default())
  let plan = plan_of_tiled(image, options, tile_width, tile_height)
  write_plans([plan])
}

///|
/// Several images as the pages of one file.
pub fn encode_pages(
  images : Array[@raster.Image],
  options? : EncodeOptions,
) -> Bytes {
  let options = options.unwrap_or(EncodeOptions::default())
  let plans : Array[Plan] = []
  for image in images {
    plans.push(plan_of(image, options))
  }
  write_plans(plans)
}

///|
/// The header, the bodies of every page one after another, then the directories.
fn write_plans(plans : Array[Plan]) -> Bytes {
  let writer = @wire.Writer::new()
  writer.u8(0x49)
  writer.u8(0x49)
  writer.u16_le(42)
  let mut at = 8
  for plan in plans {
    for strip in plan.strips {
      at = at + strip.length()
    }
  }
  writer.u32_le(at)
  for plan in plans {
    for strip in plan.strips {
      writer.bytes(strip)
    }
  }
  let directories : Array[Int32] = []
  let mut walking = at
  for index in 0..<plans.length() {
    directories.push(walking)
    walking = walking + entry_size(plans[index])
  }
  for index in 0..<plans.length() {
    let next = if index + 1 < plans.length() {
      directories[index + 1]
    } else {
      0
    }
    write_directory(writer, plans, index, directories[index], next)
  }
  writer.to_bytes()
}

///|
/// What one page is made of, once its strips have been compressed.
priv struct Plan {
  width : Int32
  height : Int32
  samples : Int32
  bits : Int32
  photometric : Int32
  rows_per_strip : Int32
  predictor : Int32
  alpha : Int32
  compression : Compression
  /// The strips of a page, or its tiles: a tile is a strip in every way but the
  /// shape the reader gives it, which the tile tags say.
  strips : Array[Bytes]
  tiles : (Int32, Int32)?
  icc : Bytes?
}

///|
fn plan_of(image : @raster.Image, options : EncodeOptions) -> Plan {
  // A float page would need the sample-format tag and a reader that honours it;
  // sixteen bits is what the rest of this library speaks, and the conversion
  // clamps, which is what writing a picture to a file does.
  let source = if image.format.is_float() {
    image.convert(@raster.PixelFormat::Rgba16)
  } else {
    image
  }
  let format = source.format
  let samples = format.channels()
  let bits = format.bits()
  let photometric = if format.is_gray() { 1 } else { 2 }
  let alpha = if format.is_gray() {
    if samples == 2 {
      1
    } else {
      0
    }
  } else if samples == 4 {
    1
  } else {
    0
  }
  let rows_per_strip = if options.rows_per_strip <= 0 ||
    options.rows_per_strip > source.height {
    source.height
  } else {
    options.rows_per_strip
  }
  let predictor = if options.predictor && (bits == 8 || bits == 16) {
    2
  } else {
    1
  }
  let row_bytes = source.width * samples * bits / 8
  let strips : Array[Bytes] = []
  let mut row = 0
  while row < source.height {
    let rows = if row + rows_per_strip > source.height {
      source.height - row
    } else {
      rows_per_strip
    }
    let body : FixedArray[Byte] = FixedArray::make(row_bytes * rows, b'\x00')
    for y in 0..<rows {
      for k in 0..<row_bytes {
        body[y * row_bytes + k] = source.pixels[(row + y) * source.stride + k]
      }
    }
    if predictor == 2 {
      apply_prediction(body, row_bytes, rows, samples, bits)
    }
    if bits == 16 {
      // The image keeps its sixteen-bit samples big-endian and the header this
      // writer produces says little, so each word is turned over once here
      // rather than at every read.
      swap_words(body, row_bytes * rows)
    }
    let packed = Bytes::from_array(body.clamped_view())
    strips.push(
      match options.compression {
        None => packed
        Lzw => pack_lzw(packed)
        PackBits => pack_bits(packed)
        Deflate => @zlib.zlib(packed)
      },
    )
    row = row + rows
  }
  {
    width: source.width,
    height: source.height,
    samples,
    bits,
    photometric,
    rows_per_strip,
    predictor,
    alpha,
    compression: options.compression,
    strips,
    tiles: None,
    icc: match source.metadata.icc {
      Some(profile) => Some(profile.profile)
      None => None
    },
  }
}

///|
/// What a tiled page is made of: the same header as a page of strips, and the
/// rectangles of the picture instead of its rows.
fn plan_of_tiled(
  image : @raster.Image,
  options : EncodeOptions,
  tile_width : Int32,
  tile_height : Int32,
) -> Plan {
  if tile_width <= 0 || tile_height <= 0 {
    abort("a tile needs a width and a height above zero")
  }
  let source = if image.format.is_float() {
    image.convert(@raster.PixelFormat::Rgba16)
  } else {
    image
  }
  let format = source.format
  let samples = format.channels()
  let bits = format.bits()
  let pixel_bytes = samples * bits / 8
  let photometric = if format.is_gray() { 1 } else { 2 }
  let alpha = if format.is_gray() {
    if samples == 2 {
      1
    } else {
      0
    }
  } else if samples == 4 {
    1
  } else {
    0
  }
  let predictor = if options.predictor && (bits == 8 || bits == 16) {
    2
  } else {
    1
  }
  let tile_row = tile_width * pixel_bytes
  let across = (source.width + tile_width - 1) / tile_width
  let down = (source.height + tile_height - 1) / tile_height
  let tiles : Array[Bytes] = []
  for ty in 0..<down {
    for tx in 0..<across {
      // A tile is a whole tile even where the picture stops: what lies beyond
      // the last column is nought, which is what the format's own writers leave
      // there and what a reader skips.
      let body : FixedArray[Byte] = FixedArray::make(
        tile_row * tile_height,
        b'\x00',
      )
      for y in 0..<tile_height {
        let source_y = ty * tile_height + y
        if source_y >= source.height {
          continue
        }
        let mut x = 0
        while x < tile_width && tx * tile_width + x < source.width {
          let source_at = source_y * source.stride +
            (tx * tile_width + x) * pixel_bytes
          let target = y * tile_row + x * pixel_bytes
          for k in 0..<pixel_bytes {
            body[target + k] = source.pixels[source_at + k]
          }
          x = x + 1
        }
      }
      if predictor == 2 {
        apply_prediction(body, tile_row, tile_height, samples, bits)
      }
      if bits == 16 {
        swap_words(body, tile_row * tile_height)
      }
      let packed = Bytes::from_array(body.clamped_view())
      tiles.push(
        match options.compression {
          None => packed
          Lzw => pack_lzw(packed)
          PackBits => pack_bits(packed)
          Deflate => @zlib.zlib(packed)
        },
      )
    }
  }
  {
    width: source.width,
    height: source.height,
    samples,
    bits,
    photometric,
    rows_per_strip: 0,
    predictor,
    alpha,
    compression: options.compression,
    strips: tiles,
    tiles: Some((tile_width, tile_height)),
    icc: match source.metadata.icc {
      Some(profile) => Some(profile.profile)
      None => None
    },
  }
}

///|
/// Horizontal differencing, the inverse of what the reader undoes.
///
/// Taken from the end of the row backwards, so that each difference is against
/// the sample that has not been overwritten yet.
fn apply_prediction(
  body : FixedArray[Byte],
  row_bytes : Int32,
  rows : Int32,
  samples : Int32,
  bits : Int32,
) -> Unit {
  let step = if bits == 16 { 2 } else { 1 }
  let span = samples * step
  let count = row_bytes / step
  for y in 0..<rows {
    let row = y * row_bytes
    let mut index = count - 1
    while index >= span {
      let at = row + index * step
      if step == 1 {
        body[at] = (body[at].to_int() - body[at - span].to_int()).to_byte()
      } else {
        let value = body[at].to_int() * 256 +
          body[at + 1].to_int() -
          (body[at - span].to_int() * 256 + body[at - span + 1].to_int())
        let wrapped = value & 0xFFFF
        body[at] = ((wrapped >> 8) & 0xFF).to_byte()
        body[at + 1] = (wrapped & 0xFF).to_byte()
      }
      index = index - 1
    }
  }
}

///|
fn swap_words(body : FixedArray[Byte], length : Int32) -> Unit {
  let mut at = 0
  while at + 1 < length {
    let high = body[at]
    body[at] = body[at + 1]
    body[at + 1] = high
    at = at + 2
  }
}

///|
/// PackBits: runs of three or more become a repeat, everything else is copied.
fn pack_bits(data : BytesView) -> Bytes {
  let writer = @wire.Writer::new()
  let mut at = 0
  while at < data.length() {
    let mut run = 1
    while at + run < data.length() && run < 128 && data[at + run] == data[at] {
      run = run + 1
    }
    if run >= 3 {
      writer.u8(257 - run)
      writer.u8(data[at].to_int())
      at = at + run
    } else {
      let start = at
      let mut fresh = 0
      while at < data.length() && fresh < 128 {
        if at + 2 < data.length() &&
          data[at + 1] == data[at] &&
          data[at + 2] == data[at] {
          break
        }
        at = at + 1
        fresh = fresh + 1
      }
      writer.u8(fresh - 1)
      for i in start..<at {
        writer.u8(data[i].to_int())
      }
    }
  }
  writer.to_bytes()
}

///|
/// One tag and the bytes of its value.
priv struct Entry {
  tag : Int32
  kind : Int32
  count : Int32
  value : FixedArray[Byte]
}

///|
/// The tags of a page, in the order TIFF wants them: ascending by number.
fn entries_of(plan : Plan) -> Array[Entry] {
  let entries : Array[Entry] = []
  entries.push(long_entry(tag_image_width, plan.width))
  entries.push(long_entry(tag_image_length, plan.height))
  match plan.tiles {
    Some((tile_width, tile_height)) => {
      entries.push(long_entry(tag_tile_width, tile_width))
      entries.push(long_entry(tag_tile_length, tile_height))
    }
    None => ()
  }
  entries.push(
    shorts_entry(tag_bits_per_sample, repeat(plan.bits, plan.samples)),
  )
  entries.push(short_entry(tag_compression, plan.compression.code()))
  entries.push(short_entry(tag_photometric, plan.photometric))
  entries.push(short_entry(tag_samples_per_pixel, plan.samples))
  match plan.tiles {
    Some(_) => {
      entries.push(longs_entry(tag_tile_offsets, []))
      entries.push(longs_entry(tag_tile_byte_counts, []))
    }
    None => {
      entries.push(longs_entry(tag_strip_offsets, []))
      entries.push(long_entry(tag_rows_per_strip, plan.rows_per_strip))
      entries.push(longs_entry(tag_strip_byte_counts, []))
    }
  }
  entries.push(short_entry(tag_planar, 1))
  if plan.predictor != 1 {
    entries.push(short_entry(tag_predictor, plan.predictor))
  }
  if plan.alpha > 0 {
    let kinds : Array[Int32] = []
    for _ in 0..<plan.alpha {
      kinds.push(2)
    }
    entries.push(shorts_entry(tag_extra_samples, kinds))
  }
  match plan.icc {
    Some(profile) =>
      entries.push({
        tag: tag_icc,
        kind: 7,
        count: profile.length(),
        value: bytes_of(profile),
      })
    None => ()
  }
  entries
}

///|
fn repeat(value : Int32, times : Int32) -> Array[Int32] {
  let values : Array[Int32] = []
  for _ in 0..<times {
    values.push(value)
  }
  values
}

///|
fn bytes_of(data : Bytes) -> FixedArray[Byte] {
  let out : FixedArray[Byte] = FixedArray::make(data.length(), b'\x00')
  for i in 0..<data.length() {
    out[i] = data[i]
  }
  out
}

///|
fn short_entry(tag : Int32, value : Int32) -> Entry {
  { tag, kind: 3, count: 1, value: short_bytes([value]), }
}

///|
fn shorts_entry(tag : Int32, values : Array[Int32]) -> Entry {
  { tag, kind: 3, count: values.length(), value: short_bytes(values), }
}

///|
fn long_entry(tag : Int32, value : Int32) -> Entry {
  { tag, kind: 4, count: 1, value: long_bytes([value]), }
}

///|
fn longs_entry(tag : Int32, values : Array[Int32]) -> Entry {
  { tag, kind: 4, count: values.length(), value: long_bytes(values), }
}

///|
fn short_bytes(values : Array[Int32]) -> FixedArray[Byte] {
  let out : FixedArray[Byte] = FixedArray::make(values.length() * 2, b'\x00')
  for i in 0..<values.length() {
    out[i * 2] = (values[i] & 0xFF).to_byte()
    out[i * 2 + 1] = ((values[i] >> 8) & 0xFF).to_byte()
  }
  out
}

///|
fn long_bytes(values : Array[Int32]) -> FixedArray[Byte] {
  let out : FixedArray[Byte] = FixedArray::make(values.length() * 4, b'\x00')
  for i in 0..<values.length() {
    out[i * 4] = (values[i] & 0xFF).to_byte()
    out[i * 4 + 1] = ((values[i] >> 8) & 0xFF).to_byte()
    out[i * 4 + 2] = ((values[i] >> 16) & 0xFF).to_byte()
    out[i * 4 + 3] = ((values[i] >> 24) & 0xFF).to_byte()
  }
  out
}

///|
/// How many bytes a page's directory takes.
fn entry_size(plan : Plan) -> Int32 {
  directory_size(entries_of(plan))
}

///|
/// The count, twelve bytes a tag, the pointer to the next directory, and
/// whatever values did not fit inside their entry.
fn directory_size(entries : Array[Entry]) -> Int32 {
  2 + entries.length() * 12 + 4 + extra_size(entries)
}

///|
fn extra_size(entries : Array[Entry]) -> Int32 {
  let mut total = 0
  for entry in entries {
    if entry.value.length() > 4 {
      total = total + entry.value.length() + entry.value.length() % 2
    }
  }
  total
}

///|
/// Write one directory, with its strip offsets and byte counts filled in.
fn write_directory(
  writer : @wire.Writer,
  plans : Array[Plan],
  index : Int32,
  directory_at : Int32,
  next : Int32,
) -> Unit {
  let plan = plans[index]
  let mut strip_at = 8
  for i in 0..<index {
    for strip in plans[i].strips {
      strip_at = strip_at + strip.length()
    }
  }
  let offsets : Array[Int32] = []
  let counts : Array[Int32] = []
  let mut here = strip_at
  for strip in plan.strips {
    offsets.push(here)
    counts.push(strip.length())
    here = here + strip.length()
  }
  let filled : Array[Entry] = []
  for entry in entries_of(plan) {
    if entry.tag == tag_strip_offsets || entry.tag == tag_tile_offsets {
      filled.push(longs_entry(entry.tag, offsets))
    } else if entry.tag == tag_strip_byte_counts ||
      entry.tag == tag_tile_byte_counts {
      filled.push(longs_entry(entry.tag, counts))
    } else {
      filled.push(entry)
    }
  }
  writer.u16_le(filled.length())
  let mut extra = directory_at + 2 + filled.length() * 12 + 4
  for entry in filled {
    writer.u16_le(entry.tag)
    writer.u16_le(entry.kind)
    writer.u32_le(entry.count)
    if entry.value.length() <= 4 {
      for i in 0..<4 {
        writer.u8(
          if i < entry.value.length() {
            entry.value[i].to_int()
          } else {
            0
          },
        )
      }
    } else {
      writer.u32_le(extra)
      extra = extra + entry.value.length() + entry.value.length() % 2
    }
  }
  writer.u32_le(next)
  for entry in filled {
    if entry.value.length() > 4 {
      for i in 0..<entry.value.length() {
        writer.u8(entry.value[i].to_int())
      }
      if entry.value.length() % 2 == 1 {
        writer.u8(0)
      }
    }
  }
}
