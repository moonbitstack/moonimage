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
    _ => 16
  }
}

///|
/// One channel of the file: its name, how wide its samples are, and how they
/// are to be read.
priv struct Channel {
  name : String
  sample : Int32
}

///|
/// The image in these bytes.
///
/// Every channel of the file is read; the result is an `RgbaF32` image, with the
/// channels that were not there filled in — grey becomes equal parts red, green
/// and blue, and a missing alpha becomes one.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
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
  if (flags & 0x200) != 0 {
    raise @raster.Unsupported(at=4, got="a tiled file")
  }
  if (flags & 0x800) != 0 {
    raise @raster.Unsupported(at=4, got="a deep file")
  }
  if (flags & 0x1000) != 0 {
    raise @raster.Unsupported(at=4, got="a multi-part file")
  }
  let (channels, compression, window, at) = read_header(bytes)
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
  let per_chunk = lines_per_chunk(compression)
  let chunks = (height + per_chunk - 1) / per_chunk
  if at.to_int64() + chunks.to_int64() * 8L > bytes.length().to_int64() {
    raise @raster.Truncated(at~, want=chunks * 8)
  }
  let row_bytes = row_size(channels, width)
  let sample_row = width * 16
  let out : FixedArray[Byte] = FixedArray::make(height * sample_row, b'\x00')
  // Alpha starts at one so that a picture without an alpha channel is opaque
  // rather than black.
  for i in 0..<(width * height) {
    @raster.put_float(out, i * 16 + 12, 1.0F)
  }
  for chunk in 0..<chunks {
    let offset = le64(bytes, at + chunk * 8)
    if offset < 0 || offset.to_int64() + 8L > bytes.length().to_int64() {
      raise @raster.Truncated(at=offset, want=8)
    }
    let first = le32(bytes, offset)
    let length = le32(bytes, offset + 4)
    if length < 0 ||
      offset.to_int64() + 8L + length.to_int64() > bytes.length().to_int64() {
      raise @raster.Truncated(at=offset + 4, want=length)
    }
    let body = bytes.clamped_view(start=offset + 8, end=offset + 8 + length)
    let lines = if first + per_chunk > height {
      height - first
    } else {
      per_chunk
    }
    let want = row_bytes * lines
    // A chunk that did not get smaller is stored as it came, whichever
    // compression the file names: a reader tells the two apart by the length,
    // because a compressed chunk is always shorter than the pixels it holds.
    let data = if body.length() >= want {
      // PIZ stores its words little-endian even when it stores them as they
      // came, so its uncompressed chunks still need turning over.
      match compression {
        Piz => piz_plain(body, want, channels, width, lines)
        _ => Bytes::from_array(body.to_array())
      }
    } else {
      match compression {
        None => Bytes::from_array(body.to_array())
        Rle => unpack_rle(body, want)
        Piz => piz_unpack(body, want, channels, width, lines)
        _ => inflate(body, want, compression)
      }
    }
    for line in 0..<lines {
      let y = top + first + line - top
      let source = line * row_bytes
      let mut at = source
      for channel in channels {
        let row = (first + line) * sample_row
        let give = channel_value(channel.name)
        for x in 0..<width {
          let value = sample_of(data, at, channel.sample)
          at = at + channel.sample
          if give >= 0 {
            @raster.put_float(out, row + x * 16 + give * 4, value)
          }
        }
      }
      let _ = y
    }
  }
  @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::RgbaF32,
    Bytes::from_array(out.clamped_view()),
  )
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
/// The channels, the compression, the data window, and where the offset table
/// starts.
fn read_header(
  bytes : BytesView,
) -> (Array[Channel], Compression, (Int32, Int32, Int32, Int32), Int32) raise @raster.Refused {
  let mut at = 8
  let mut channels : Array[Channel] = []
  let mut compression = Zip
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
      data_window = (
        le32(body, 0),
        le32(body, 4),
        le32(body, 8),
        le32(body, 12),
      )
      seen_window = true
    }
    at = at + size
  }
  if !seen_window {
    raise @raster.Unexpected(
      at=8,
      got="a header with no data window",
      want="a dataWindow attribute",
    )
  }
  if channels.is_empty() {
    raise @raster.Unexpected(
      at=8,
      got="a header with no channels",
      want="a channels attribute",
    )
  }
  (channels, compression, data_window, at)
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
    channels.push({ name: name.0, sample, })
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
