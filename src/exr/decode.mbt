// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// OpenEXR: a picture of light, with a header that says what each channel means.
//
// The header is a list of attributes, each with a name, a type and a length, so
// a reader skips what it does not know instead of failing on it. Two attributes
// decide how the pixels are laid out: the channel list, which names each channel
// and says how wide its samples are, and the compression, which says how a chunk
// of scanlines was packed.
//
// A chunk holds a whole number of scanlines — one for RLE and ZIPS, sixteen for
// ZIP, thirty-two for PIZ — and inside it the channels come one after another,
// each contributing one row of samples per scanline. Before compressing, the
// bytes are split into two halves and differenced, which is what makes a
// photograph of a lit surface compress at all: neighbouring samples differ by a
// little, and a little is mostly zero in the high byte.
//
// PIZ does something else again: it hides inside the wavelet in `piz.mbt`, which
// looks at the picture rather than at the bytes.
//
// https://openexr.com/en/latest/OpenEXRFileLayout.html

///|
/// How a chunk of scanlines was packed.
#derive(Eq, Debug)
pub(all) enum Compression {
  /// As they are.
  None
  /// A byte-oriented run-length code.
  Rle
  /// Deflate, one scanline to a chunk.
  Zips
  /// Deflate, sixteen scanlines to a chunk.
  Zip
  /// A bitmap of the words used, a wavelet, and a Huffman code.
  Piz
  /// Twenty-four bits of every sample, split by significance and differenced.
  Pxr24
  /// Blocks of four by four halves, fourteen bytes each: four bits of a sample
  /// kept, everything below them dropped.
  B44
  /// The same, with a block of one value written in three bytes instead.
  B44a
  /// Eight-by-eight blocks of a picture turned into frequencies and quantized,
  /// thirty-two scanlines to a chunk.
  Dwaa
  /// The same with two hundred and fifty-six scanlines to a chunk, which suits a
  /// photograph better and a strip of a tiled render worse.
  Dwab
}

///|
pub extend Compression with Eq::{equal, not_equal}

///|
pub extend Compression with Debug::{to_repr}

///|
/// The number a file writes for this compression.
pub fn Compression::code(self : Compression) -> Int32 {
  match self {
    None => 0
    Rle => 1
    Zips => 2
    Zip => 3
    Piz => 4
    Pxr24 => 5
    B44 => 6
    B44a => 7
    Dwaa => 8
    Dwab => 9
  }
}

///|
/// The compression a number stands for, or `None` for one this library does not
/// read.
pub fn Compression::of(code : Int32) -> Compression? {
  match code {
    0 => Some(None)
    1 => Some(Rle)
    2 => Some(Zips)
    3 => Some(Zip)
    4 => Some(Piz)
    5 => Some(Pxr24)
    6 => Some(B44)
    7 => Some(B44a)
    8 => Some(Dwaa)
    9 => Some(Dwab)
    _ => None
  }
}

///|
/// How many scanlines a chunk of this compression holds.
fn lines_per_chunk(compression : Compression) -> Int32 {
  match compression {
    // A chunk of one scanline: the three that do not look across scanlines have
    // nothing to gain from holding more, and a reader that stumbles on damage
    // loses one line rather than sixteen.
    None | Rle | Zips => 1
    Piz => 32
    B44 | B44a | Dwaa => 32
    Dwab => 256
    _ => 16
  }
}

///|
/// One channel of the file: its name, how wide its samples are, and how they
/// are to be read.
priv struct Channel {
  name : String
  /// How wide a sample is, in bytes.
  sample : Int32
  /// What a sample is: nought for an unsigned integer, one for a half, two for
  /// a float. PXR24 stores each of the three differently.
  kind : Int32
  /// Whether the samples are already perceptually uniform, which B44 and DWA
  /// each act on in their own way: a channel that is not gets a curve applied
  /// before the lossy step.
  linear : Bool
}

///|
/// The image in these bytes, which is the first part of the file when it has
/// more than one.
///
/// Every channel of the part is read; the result is an `RgbaF32` image, with the
/// channels that were not there filled in — grey becomes equal parts red, green
/// and blue, and a missing alpha becomes one.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let parts = match limits {
    Some(value) => decode_parts(bytes, limits=value)
    None => decode_parts(bytes)
  }
  parts[0]
}

///|
/// Every part of the file, in the order the file lists them.
///
/// A file of one image has one part. A file of several — a beauty pass and its
/// depth, two views of the same shot — carries a header for each, and each part
/// has its own channels, its own compression and its own window. The window of
/// the first part is the display window of all of them, which is why a picture
/// with no pixels of its own is still a part.
pub fn decode_parts(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> Array[@raster.Image] raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  if bytes.length() < 8 {
    raise @raster.Truncated(at=0, want=8)
  }
  if bytes[0].to_int() != 0x76 ||
    bytes[1].to_int() != 0x2F ||
    bytes[2].to_int() != 0x31 ||
    bytes[3].to_int() != 0x01 {
    raise @raster.Unknown(at=0, got=@raster.hex(bytes, 0, 8))
  }
  let flags = le32(bytes, 4)
  if (flags & 0x800) != 0 {
    raise @raster.Unsupported(at=4, got="a deep file")
  }
  // A multi-part file ends its list of headers with an empty one; a file of a
  // single image has just the one, and the byte after it is the offset table.
  let multi = (flags & 0x1000) != 0
  let parts : Array[Part] = []
  let mut at = 8
  if multi {
    while true {
      if at >= bytes.length() {
        raise @raster.Truncated(at~, want=1)
      }
      if bytes[at].to_int() == 0 {
        at = at + 1
        break
      }
      let (part, next) = read_part(bytes, at)
      parts.push(part)
      at = next
    }
  } else {
    let (part, next) = read_part(bytes, 8)
    parts.push(part)
    at = next
  }
  if parts.is_empty() {
    raise @raster.Unexpected(at=8, got="a file with no parts", want="one part")
  }
  let images : Array[@raster.Image] = []
  for index in 0..<parts.length() {
    let part = parts[index]
    // The tables are one after another, each as long as its part's chunks.
    if at.to_int64() + part.chunks.to_int64() * 8L > bytes.length().to_int64() {
      raise @raster.Truncated(at~, want=part.chunks * 8)
    }
    let located = { ..part, table: at, }
    at = at + part.chunks * 8
    let number = if multi { Some(index) } else { None }
    images.push(decode_part(bytes, located, limits, number))
  }
  images
}

///|
/// One part of a file: what its header says about how its pixels are laid out.
priv struct Part {
  channels : Array[Channel]
  compression : Compression
  window : (Int32, Int32, Int32, Int32)
  /// The size of a tile, or nothing when the part holds scanlines. A tiled part
  /// stores a rectangle of the picture per chunk, and its chunks are in tile
  /// order rather than in scanline order.
  tiles : (Int32, Int32)?
  /// How many entries the part's offset table holds.
  chunks : Int32
  /// Where that table starts.
  table : Int32
}

///|
fn decode_part(
  bytes : BytesView,
  part : Part,
  limits : @raster.Limits,
  number : Int32?,
) -> @raster.Image raise @raster.Refused {
  let (channels, compression, window) = (
    part.channels,
    part.compression,
    part.window,
  )
  let (left, top, right, bottom) = window
  let width = right - left + 1
  let height = bottom - top + 1
  if width <= 0 || height <= 0 {
    raise @raster.Unexpected(
      at=0,
      got="a window with no pixels",
      want="a data window above zero",
    )
  }
  limits.check(width, height)
  let row_bytes = row_size(channels, width)
  let sample_row = width * 16
  // A chunk of B44 whose channels ask for the perceptual curve needs a table of
  // sixty-five thousand entries, and one part's worth of chunks needs one of
  // them: it is built here rather than in each chunk.
  let b44_logs = if (compression == B44 || compression == B44a) &&
    b44_needs_table(channels) {
    b44_log_table()
  } else {
    []
  }
  let out : FixedArray[Byte] = FixedArray::make(height * sample_row, b'\x00')
  // Alpha starts at one so that a picture without an alpha channel is opaque
  // rather than black.
  for i in 0..<(width * height) {
    @raster.put_float(out, i * 16 + 12, 1.0F)
  }
  match part.tiles {
    Some((tile_width, tile_height)) =>
      decode_tiles(
        bytes, part, out, width, height, tile_width, tile_height, number, b44_logs,
      )
    None =>
      decode_scanlines(
        bytes, part, out, width, height, row_bytes, sample_row, number, b44_logs,
      )
  }
  @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::RgbaF32,
    Bytes::from_array(out.clamped_view()),
  )
}

///|
/// A part whose chunks are runs of scanlines: the chunk table says where each
/// run begins, and the run says which line it starts at.
fn decode_scanlines(
  bytes : BytesView,
  part : Part,
  out : FixedArray[Byte],
  width : Int32,
  height : Int32,
  row_bytes : Int32,
  sample_row : Int32,
  number : Int32?,
  b44_logs : FixedArray[Int32],
) -> Unit raise @raster.Refused {
  let per_chunk = lines_per_chunk(part.compression)
  let chunks = (height + per_chunk - 1) / per_chunk
  for chunk in 0..<chunks {
    let offset = le64(bytes, part.table + chunk * 8)
    let mut head = offset
    match number {
      Some(index) => {
        if offset < 0 || offset.to_int64() + 12L > bytes.length().to_int64() {
          raise @raster.Truncated(at=offset, want=12)
        }
        if le32(bytes, offset) != index {
          raise @raster.Unexpected(
            at=offset,
            got="a chunk of another part",
            want="the chunk this part's table points at",
          )
        }
        head = offset + 4
      }
      None => ()
    }
    if head < 0 || head.to_int64() + 8L > bytes.length().to_int64() {
      raise @raster.Truncated(at=head, want=8)
    }
    let first = le32(bytes, head)
    let length = le32(bytes, head + 4)
    if length < 0 ||
      head.to_int64() + 8L + length.to_int64() > bytes.length().to_int64() {
      raise @raster.Truncated(at=head + 4, want=length)
    }
    if first < 0 || first >= height {
      raise @raster.Unexpected(
        at=head,
        got="a chunk at line \{first}",
        want="a line inside the picture",
      )
    }
    let lines = if first + per_chunk > height {
      height - first
    } else {
      per_chunk
    }
    let body = bytes.clamped_view(start=head + 8, end=head + 8 + length)
    let data = unpack_chunk(
      body,
      part.compression,
      part.channels,
      width,
      lines,
      row_bytes * lines,
      b44_logs,
    )
    place_region(out, data, part.channels, width, lines, 0, first, sample_row)
  }
}

///|
/// A part whose chunks are tiles: one rectangle of the picture each, in the
/// order the tiles run, with the tiles at the right and the bottom cropped to
/// the window rather than padded with whatever was there.
fn decode_tiles(
  bytes : BytesView,
  part : Part,
  out : FixedArray[Byte],
  width : Int32,
  height : Int32,
  tile_width : Int32,
  tile_height : Int32,
  number : Int32?,
  b44_logs : FixedArray[Int32],
) -> Unit raise @raster.Refused {
  let across = (width + tile_width - 1) / tile_width
  let down = (height + tile_height - 1) / tile_height
  let sample_row = width * 16
  for ty in 0..<down {
    for tx in 0..<across {
      let index = ty * across + tx
      // A file with more levels than the first holds their entries after these,
      // and they are not this reader's: the picture is the first level.
      if index >= part.chunks {
        raise @raster.Truncated(at=part.table + index * 8, want=8)
      }
      let offset = le64(bytes, part.table + index * 8)
      let mut head = offset
      match number {
        Some(part_index) => {
          if offset < 0 || offset.to_int64() + 24L > bytes.length().to_int64() {
            raise @raster.Truncated(at=offset, want=24)
          }
          if le32(bytes, offset) != part_index {
            raise @raster.Unexpected(
              at=offset,
              got="a tile of another part",
              want="the tile this part's table points at",
            )
          }
          head = offset + 4
        }
        None => ()
      }
      if head < 0 || head.to_int64() + 20L > bytes.length().to_int64() {
        raise @raster.Truncated(at=head, want=20)
      }
      let tile_x = le32(bytes, head)
      let tile_y = le32(bytes, head + 4)
      // The two level coordinates that follow say which level of a mipmapped
      // file the tile belongs to; the first level is the picture.
      let level_x = le32(bytes, head + 8)
      let level_y = le32(bytes, head + 12)
      if tile_x < 0 || tile_x >= across || tile_y < 0 || tile_y >= down {
        raise @raster.Unexpected(
          at=head,
          got="a tile at (\{tile_x}, \{tile_y})",
          want="a tile inside the picture",
        )
      }
      if level_x != 0 || level_y != 0 {
        raise @raster.Unsupported(at=head + 8, got="a tile of a lower level")
      }
      let length = le32(bytes, head + 16)
      if length < 0 ||
        head.to_int64() + 20L + length.to_int64() > bytes.length().to_int64() {
        raise @raster.Truncated(at=head + 16, want=length)
      }
      let x0 = tile_x * tile_width
      let y0 = tile_y * tile_height
      let columns = if x0 + tile_width > width {
        width - x0
      } else {
        tile_width
      }
      let lines = if y0 + tile_height > height {
        height - y0
      } else {
        tile_height
      }
      let body = bytes.clamped_view(start=head + 20, end=head + 20 + length)
      let data = unpack_chunk(
        body,
        part.compression,
        part.channels,
        columns,
        lines,
        row_size(part.channels, columns) * lines,
        b44_logs,
      )
      place_region(out, data, part.channels, columns, lines, x0, y0, sample_row)
    }
  }
}

///|
/// A chunk, unpacked into the bytes of the rows it holds.
fn unpack_chunk(
  body : BytesView,
  compression : Compression,
  channels : Array[Channel],
  width : Int32,
  lines : Int32,
  want : Int32,
  b44_logs : FixedArray[Int32],
) -> Bytes raise @raster.Refused {
  // A chunk that did not get smaller is stored as it came, whichever compression
  // the file names: a reader tells the two apart by the length, because a
  // compressed chunk is always shorter than the pixels it holds.
  if body.length() >= want {
    // PIZ stores its words little-endian even when it stores them as they came,
    // so its uncompressed chunks still need turning over.
    return match compression {
      Piz => piz_plain(body, want, channels, width, lines)
      _ => Bytes::from_array(body.to_array())
    }
  }
  match compression {
    None => Bytes::from_array(body.to_array())
    Rle => unpack_rle(body, want)
    Piz => piz_unpack(body, want, channels, width, lines)
    Pxr24 => pxr24_unpack(body, want, channels, width, lines)
    B44 | B44a => b44_unpack(body, channels, width, lines, logs=b44_logs)
    Dwaa | Dwab => dwa_unpack(body, channels, width, lines)
    _ => inflate(body, want, compression)
  }
}

///|
/// A rectangle of the chunk's bytes written into the picture at the place it
/// belongs.
fn place_region(
  out : FixedArray[Byte],
  data : BytesView,
  channels : Array[Channel],
  width : Int32,
  lines : Int32,
  x0 : Int32,
  y0 : Int32,
  sample_row : Int32,
) -> Unit {
  let mut at = 0
  for line in 0..<lines {
    let row = (y0 + line) * sample_row
    for channel in channels {
      let give = channel_value(channel.name)
      for x in 0..<width {
        let value = sample_of(data, at, channel.sample)
        at = at + channel.sample
        if give == 4 {
          // A luminance channel is the picture in grey, so it fills all three
          // of red, green and blue.
          @raster.put_float(out, row + (x0 + x) * 16, value)
          @raster.put_float(out, row + (x0 + x) * 16 + 4, value)
          @raster.put_float(out, row + (x0 + x) * 16 + 8, value)
        } else if give >= 0 {
          @raster.put_float(out, row + (x0 + x) * 16 + give * 4, value)
        }
      }
    }
  }
}

///|
/// Which of the four samples of the result a channel fills, or minus one for a
/// channel this library has no place for.
fn channel_value(name : String) -> Int32 {
  if name == "R" {
    0
  } else if name == "G" {
    1
  } else if name == "B" {
    2
  } else if name == "A" {
    3
  } else if name == "Y" {
    4
  } else {
    -1
  }
}

///|
/// How many bytes one scanline of all the channels takes.
fn row_size(channels : Array[Channel], width : Int32) -> Int32 {
  let mut total = 0
  for channel in channels {
    total = total + width * channel.sample
  }
  total
}

///|
fn sample_of(data : BytesView, at : Int32, size : Int32) -> Float {
  if size == 2 {
    half_to_float(le16(data, at))
  } else if size == 4 {
    Float::reinterpret_from_uint(le32(data, at).reinterpret_as_uint())
  } else {
    // A thirty-two-bit unsigned sample is a mask or an index rather than a
    // colour; it is scaled into the range a sample lives in.
    Float::from_double(le32(data, at).to_double() / 4294967295.0)
  }
}

///|
/// One header, and where the next one begins.
///
/// A header is a list of attributes, and a reader skips the ones it does not
/// know by length. The ones that matter here are the channels, the compression,
/// the data window, and — for a tiled part — the size of a tile.
fn read_part(
  bytes : BytesView,
  start : Int32,
) -> (Part, Int32) raise @raster.Refused {
  let mut at = start
  let mut channels : Array[Channel] = []
  let mut compression = Zip
  let mut tiles : (Int32, Int32)? = None
  let mut counted = -1
  let window = (0, 0, -1, -1)
  let mut seen_window = false
  let mut data_window = window
  while true {
    if at >= bytes.length() {
      raise @raster.Truncated(at~, want=1)
    }
    if bytes[at].to_int() == 0 {
      at = at + 1
      break
    }
    let name = cstring(bytes, at)
    at = name.1
    let kind = cstring(bytes, at)
    at = kind.1
    let size = le32(bytes, at)
    at = at + 4
    if size < 0 || at + size > bytes.length() {
      raise @raster.Truncated(at~, want=size)
    }
    let body = bytes.clamped_view(start=at, end=at + size)
    if name.0 == "channels" {
      channels = read_channels(body)
    } else if name.0 == "compression" {
      let code = body[0].to_int()
      compression = match Compression::of(code) {
        Some(known) => known
        None => raise @raster.Unsupported(at~, got="a compression of \{code}")
      }
    } else if name.0 == "dataWindow" {
      if body.length() < 16 {
        raise @raster.Truncated(at~, want=16)
      }
      data_window = (
        le32(body, 0),
        le32(body, 4),
        le32(body, 8),
        le32(body, 12),
      )
      seen_window = true
    } else if name.0 == "tiles" {
      if body.length() < 9 {
        raise @raster.Truncated(at~, want=9)
      }
      let tile_width = le32(body, 0)
      let tile_height = le32(body, 4)
      if tile_width <= 0 || tile_height <= 0 {
        raise @raster.Unexpected(
          at~,
          got="a tile of \{tile_width} by \{tile_height}",
          want="a tile with pixels in it",
        )
      }
      // The ninth byte is the level mode, and the tenth the rounding of a
      // level; neither changes where the first level's tiles are.
      tiles = Some((tile_width, tile_height))
    } else if name.0 == "chunkCount" {
      if body.length() < 4 {
        raise @raster.Truncated(at~, want=4)
      }
      counted = le32(body, 0)
    } else if name.0 == "type" {
      let kind = ascii(body)
      if kind != "scanlineimage" && kind != "tiledimage" {
        raise @raster.Unsupported(at~, got="a part of type \{kind}")
      }
    }
    at = at + size
  }
  if !seen_window {
    raise @raster.Unexpected(
      at=start,
      got="a header with no data window",
      want="a dataWindow attribute",
    )
  }
  if channels.is_empty() {
    raise @raster.Unexpected(
      at=start,
      got="a header with no channels",
      want="a channels attribute",
    )
  }
  let width = data_window.2 - data_window.0 + 1
  let height = data_window.3 - data_window.1 + 1
  let chunks = if counted >= 0 {
    // A part of a file with several writes how many chunks it has, because a
    // reader cannot know which compression each part uses until it has read
    // them all.
    counted
  } else {
    match tiles {
      Some((tile_width, tile_height)) =>
        (width + tile_width - 1) /
        tile_width *
        ((height + tile_height - 1) / tile_height)
      None => {
        let per_chunk = lines_per_chunk(compression)
        (height + per_chunk - 1) / per_chunk
      }
    }
  }
  (
    { channels, compression, window: data_window, tiles, chunks, table: at, },
    at,
  )
}

///|
/// The channel list: a name, how wide the samples are, and two words the format
/// reserves for sampling rates that nothing writes.
fn read_channels(body : BytesView) -> Array[Channel] raise @raster.Refused {
  let channels : Array[Channel] = []
  let mut at = 0
  while at < body.length() && body[at].to_int() != 0 {
    let name = cstring(body, at)
    at = name.1
    if at + 16 > body.length() {
      raise @raster.Truncated(at~, want=16)
    }
    let kind = le32(body, at)
    let sample = match kind {
      0 => 4
      1 => 2
      2 => 4
      _ => raise @raster.Unsupported(at~, got="a sample type of \{kind}")
    }
    // A byte the specification calls `pLinear`, then three reserved ones.
    let linear = body[at + 4].to_int() != 0
    channels.push({ name: name.0, sample, kind, linear, })
    at = at + 16
  }
  channels
}

///|
/// A null-terminated string, and where it ended.
fn cstring(
  bytes : BytesView,
  at : Int32,
) -> (String, Int32) raise @raster.Refused {
  let mut end = at
  while end < bytes.length() && bytes[end].to_int() != 0 {
    end = end + 1
  }
  if end >= bytes.length() {
    raise @raster.Truncated(at~, want=1)
  }
  (ascii(bytes.clamped_view(start=at, end~)), end + 1)
}

///|
fn ascii(bytes : BytesView) -> String {
  let characters : Array[Char] = []
  for i in 0..<bytes.length() {
    characters.push(bytes[i].to_int().unsafe_to_char())
  }
  String::from_array(characters.clamped_view())
}

///|
/// The run-length code: a signed count, then that many bytes, or that many of
/// the byte after it.
fn unpack_rle(body : BytesView, want : Int32) -> Bytes raise @raster.Refused {
  let packed = expand(body, want)
  reorder(packed, want)
}

///|
/// Deflate with the split and difference this format puts in front of it.
fn inflate(
  body : BytesView,
  want : Int32,
  compression : Compression,
) -> Bytes raise @raster.Refused {
  let _ = compression
  let packed = @zlib.unzlib(body, limit=want) catch {
    _ =>
      raise @raster.Unexpected(
        at=0,
        got="a deflate stream that does not inflate",
        want="a deflate stream",
      )
  }
  reorder(packed, want)
}

///|
/// Undo the difference between neighbours and the split into two halves.
///
/// The order is the writer's, reversed: RLE and deflate both work on a buffer
/// whose even bytes come first and whose odd bytes follow, and on which
/// neighbour differences were taken afterwards.
fn reorder(packed : BytesView, want : Int32) -> Bytes {
  let half = (want + 1) / 2
  let spread : FixedArray[Byte] = FixedArray::make(want, b'\x00')
  for i in 0..<want {
    spread[i] = if i < packed.length() { packed[i] } else { b'\x00' }
  }
  for i in 1..<want {
    let value = spread[i].to_int() + spread[i - 1].to_int() - 128
    spread[i] = (value & 0xFF).to_byte()
  }
  let out : FixedArray[Byte] = FixedArray::make(want, b'\x00')
  for i in 0..<want {
    out[i] = if i % 2 == 0 {
      spread[i / 2]
    } else if half + i / 2 < want {
      spread[half + i / 2]
    } else {
      b'\x00'
    }
  }
  Bytes::from_array(out.clamped_view())
}

///|
fn expand(body : BytesView, want : Int32) -> Bytes raise @raster.Refused {
  let out : FixedArray[Byte] = FixedArray::make(want, b'\x00')
  let mut at = 0
  let mut produced = 0
  while produced < want {
    if at >= body.length() {
      raise @raster.Truncated(at~, want=want - produced)
    }
    let count = body[at].to_int()
    at = at + 1
    let signed = if count > 127 { count - 256 } else { count }
    if signed < 0 {
      // A negative count is a literal run of that many bytes.
      let run = -signed
      if at + run > body.length() {
        raise @raster.Truncated(at~, want=run)
      }
      for i in 0..<run {
        if produced < want {
          out[produced] = body[at + i]
          produced = produced + 1
        }
      }
      at = at + run
    } else {
      // A count of n is n + 1 copies of the byte after it.
      if at >= body.length() {
        raise @raster.Truncated(at~, want=1)
      }
      let value = body[at]
      at = at + 1
      for _ in 0..<=signed {
        if produced < want {
          out[produced] = value
          produced = produced + 1
        }
      }
    }
  }
  Bytes::from_array(out.clamped_view())
}

///|
fn le32(bytes : BytesView, at : Int32) -> Int32 {
  bytes[at].to_int() |
  (bytes[at + 1].to_int() << 8) |
  (bytes[at + 2].to_int() << 16) |
  (bytes[at + 3].to_int() << 24)
}

///|
fn le64(bytes : BytesView, at : Int32) -> Int32 {
  let low = le32(bytes, at)
  let high = le32(bytes, at + 4)
  if high != 0 {
    // A file larger than two gigabytes is refused rather than wrapped: nothing
    // this library is asked to read is that big, and wrapping would read the
    // wrong bytes quietly.
    2_147_483_647
  } else {
    low
  }
}

///|

///|
/// A sixteen-bit sample of the file, which is little-endian like every other
/// number in it.
fn le16(bytes : BytesView, at : Int32) -> Int32 {
  bytes[at].to_int() | (bytes[at + 1].to_int() << 8)
}

///|

///|
/// A half-precision sample as a float.
///
/// Half is this format's own sample type — a scanline of an OpenEXR is a run of
/// them unless it was written as float — so this is the conversion a reader of
/// this package reaches for, and it is the one `raster` keeps for every format
/// whose samples are halves. There is one implementation of it, here and there
/// and in a block of BC6H alike.
pub fn half_to_float(bits : Int32) -> Float {
  @raster.half_to_float(bits)
}

///|
/// A float as a half-precision sample, rounded to nearest.
///
/// The inverse, and the one a writer needs: a sample that does not fit becomes
/// the nearest half, which is an infinity when it is too large and nought when it
/// is too small.
pub fn float_to_half(value : Float) -> Int32 {
  @raster.float_to_half(value)
}
