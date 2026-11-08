// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Reading TIFF.
//
// A page is a directory of tags; the samples live in strips, which are rows
// grouped for compression, and the tags say how many rows a strip holds and
// where each one starts. Everything else follows from four numbers — bits per
// sample, samples per pixel, photometric interpretation, and whether the
// samples of a pixel are together or in planes of their own.
//
// The library reads the shapes a picture is actually stored in: grey, grey with
// alpha, RGB, RGB with alpha, and palette, at one, two, four, eight and sixteen
// bits, uncompressed or under any of the three compressions the format defines.
// Tiles are refused rather than misread, because a tile is a different way of
// laying out the same rows and reading one as strips gives a scrambled picture
// that looks like a bug in the decoder rather than a shape it does not read.

///|
/// The first page in these bytes.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let pages = decode_pages(bytes, limits?)
  pages[0]
}

///|
/// Every page, in the order the directories chain.
pub fn decode_pages(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> Array[@raster.Image] raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  let (little, first) = header(bytes)
  let pages : Array[@raster.Image] = []
  let mut at = first
  let mut seen = 0
  while at > 0 {
    if seen >= 256 {
      raise @raster.OverLimit(limit=256, got=seen + 1)
    }
    let directory = read_directory(bytes, at, little, 4096)
    pages.push(page_of(bytes, directory, little, limits))
    at = directory.next
    seen = seen + 1
  }
  if pages.is_empty() {
    raise @raster.Unexpected(
      at=0,
      got="a file with no pages",
      want="at least one directory",
    )
  }
  pages
}

///|
/// The orientation tag of the first page, which is the same eight numbers a
/// JPEG writes in its EXIF block.
pub fn orientation(bytes : BytesView) -> Int32? {
  let (little, first) = header(bytes) catch { _ => return None }
  if first <= 0 {
    return None
  }
  let directory = read_directory(bytes, first, little, 4096) catch {
    _ => return None
  }
  let value = directory.number(tag_orientation, 1)
  if value >= 1 && value <= 8 {
    Some(value)
  } else {
    None
  }
}

///|
/// The byte order and where the first directory is.
fn header(bytes : BytesView) -> (Bool, Int32) raise @raster.Refused {
  if bytes.length() < 8 {
    raise @raster.Truncated(at=0, want=8)
  }
  let first = bytes[0].to_int()
  let second = bytes[1].to_int()
  let little = if first == 0x49 && second == 0x49 {
    true
  } else if first == 0x4D && second == 0x4D {
    false
  } else {
    raise @raster.Unknown(at=0, got=@raster.hex(bytes, 0, 8))
  }
  let version = word(bytes, 2, little)
  if version == 43 {
    raise @raster.Unsupported(at=2, got="a BigTIFF header")
  }
  if version != 42 {
    raise @raster.Unknown(at=2, got="a header version of \{version}")
  }
  let first_ifd = long(bytes, 4, little)
  if first_ifd < 8 || first_ifd + 2 > bytes.length() {
    raise @raster.Truncated(at=4, want=2)
  }
  (little, first_ifd)
}

///|
/// One page: its strips, decompressed, undone of their prediction, and read
/// into the library's own layouts.
fn page_of(
  data : BytesView,
  directory : Directory,
  little : Bool,
  limits : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  if directory.find(322) is Some(_) {
    raise @raster.Unsupported(at=0, got="a tiled TIFF")
  }
  let width = directory.number(tag_image_width, 0)
  let height = directory.number(tag_image_length, 0)
  if width <= 0 || height <= 0 {
    raise @raster.Unexpected(
      at=0,
      got="a page with no pixels",
      want="a width and a height above zero",
    )
  }
  limits.check(width, height)
  let code = directory.number(tag_compression, 1)
  let compression = match Compression::of(code) {
    Some(known) => known
    None => raise @raster.Unsupported(at=0, got="a compression of \{code}")
  }
  let samples = directory.number(tag_samples_per_pixel, 1)
  let bits = directory.number(tag_bits_per_sample, 1)
  let photometric = directory.number(tag_photometric, 1)
  let planar = directory.number(tag_planar, 1)
  let predictor = directory.number(tag_predictor, 1)
  let fill_order = directory.number(tag_fill_order, 1)
  let rows_per_strip = directory.number(tag_rows_per_strip, height)
  if samples < 1 || samples > 4 {
    raise @raster.Unsupported(at=0, got="\{samples} samples a pixel")
  }
  if bits != 1 && bits != 2 && bits != 4 && bits != 8 && bits != 16 {
    raise @raster.Unsupported(at=0, got="\{bits} bits a sample")
  }
  if planar != 1 && planar != 2 {
    raise @raster.Unsupported(at=0, got="a planar configuration of \{planar}")
  }
  if predictor != 1 && predictor != 2 {
    raise @raster.Unsupported(at=0, got="a predictor of \{predictor}")
  }
  let offsets = directory.numbers(tag_strip_offsets)
  let counts = directory.numbers(tag_strip_byte_counts)
  if offsets.is_empty() || counts.is_empty() {
    raise @raster.Unexpected(
      at=0,
      got="a page with no strips",
      want="at least one strip offset",
    )
  }
  let strip_rows = if rows_per_strip <= 0 || rows_per_strip > height {
    height
  } else {
    rows_per_strip
  }
  let planes = if planar == 2 { samples } else { 1 }
  // A strip of a chunky page holds whole pixels; a strip of a planar page holds
  // one channel of them, which is why the two row lengths differ.
  let row_length = if planar == 2 {
    (width.to_int64() * bits.to_int64() + 7L).to_int() / 8
  } else {
    (width.to_int64() * samples.to_int64() * bits.to_int64() + 7L).to_int() / 8
  }
  let rows_of = (height + strip_rows - 1) / strip_rows
  if offsets.length() < rows_of * planes {
    raise @raster.Unexpected(
      at=0,
      got="\{offsets.length()} strips",
      want="\{rows_of * planes} for a page this tall",
    )
  }
  let raw : FixedArray[Byte] = FixedArray::make(
    row_length * height * planes,
    b'\x00',
  )
  let mut total = 0
  for index in 0..<(rows_of * planes) {
    let offset = offsets[index]
    let length = counts[index]
    if offset < 0 ||
      length < 0 ||
      offset.to_int64() + length.to_int64() > data.length().to_int64() {
      raise @raster.Truncated(at=offset, want=length)
    }
    let body = data.clamped_view(start=offset, end=offset + length)
    let first_row = index % rows_of * strip_rows
    let rows = if first_row + strip_rows > height {
      height - first_row
    } else {
      strip_rows
    }
    let want = row_length * rows
    total = total + want
    limits.check_bytes(total)
    let strip = inflate_strip(body, want, compression)
    let plane = index / rows_of
    let base = plane * row_length * height
    for row in 0..<rows {
      let source = row * row_length
      let target = base + (first_row + row) * row_length
      for k in 0..<row_length {
        let value = strip[source + k].to_int()
        raw[target + k] = (if fill_order == 2 {
          reverse_bits(value)
        } else {
          value
        }).to_byte()
      }
    }
  }
  if predictor == 2 {
    undo_prediction(raw, row_length, height * planes, samples, bits, planar)
  }
  let image = assemble_page(
    raw, width, height, samples, bits, photometric, planar, row_length, little, directory,
  )
  { ..image, metadata: metadata_of(directory), }
}

///|
/// One strip, decompressed to exactly the size the tags promised.
fn inflate_strip(
  body : BytesView,
  want : Int32,
  compression : Compression,
) -> FixedArray[Byte] raise @raster.Refused {
  match compression {
    None => {
      if body.length() < want {
        raise @raster.Truncated(at=0, want=want - body.length())
      }
      copy_to_fixed(body, want)
    }
    PackBits => unpack_bits(body, want)
    Lzw => unpack_lzw(body, want)
    Deflate => {
      // The specification says a zlib stream, and a few writers emit a bare
      // deflate one; the two-byte check tells them apart without guessing.
      let wrapped = body.length() >= 2 &&
        body[0].to_int() == 0x78 &&
        (body[0].to_int() * 256 + body[1].to_int()) % 31 == 0
      let out = if wrapped {
        @zlib.unzlib(body, limit=want) catch {
          _ => bare_inflate(body, want)
        }
      } else {
        bare_inflate(body, want)
      }
      if out.length() < want {
        raise @raster.Truncated(at=0, want=want - out.length())
      }
      copy_to_fixed(out, want)
    }
  }
}

///|
/// A deflate stream with no wrapper, and its refusal in this library's words.
fn bare_inflate(body : BytesView, want : Int32) -> Bytes raise @raster.Refused {
  @deflate.inflate(body, limit=want) catch {
    _ =>
      raise @raster.Unexpected(
        at=0,
        got="a deflate stream that does not inflate",
        want="a deflate stream",
      )
  }
}

///|
fn copy_to_fixed(data : BytesView, want : Int32) -> FixedArray[Byte] {
  let out : FixedArray[Byte] = FixedArray::make(want, b'\x00')
  for i in 0..<want {
    out[i] = data[i]
  }
  out
}

///|
fn reverse_bits(value : Int32) -> Int32 {
  let mut out = 0
  for i in 0..<8 {
    if ((value >> i) & 1) == 1 {
      out = out | (1 << (7 - i))
    }
  }
  out
}

///|
/// Horizontal differencing undone, sample by sample along each row.
///
/// Sixteen-bit samples are handled as the words they are, in the file's own
/// byte order: the addition is modulo sixty-five thousand five hundred and
/// thirty-six, which is what a sixteen-bit sample is.
fn undo_prediction(
  raw : FixedArray[Byte],
  row_length : Int32,
  rows : Int32,
  samples : Int32,
  bits : Int32,
  planar : Int32,
) -> Unit {
  if bits != 8 && bits != 16 {
    return
  }
  let step = if bits == 16 { 2 } else { 1 }
  let span = if planar == 2 { step } else { samples * step }
  let count = row_length / step
  for y in 0..<rows {
    let row = y * row_length
    for index in span..<count {
      let at = row + index * step
      if step == 1 {
        raw[at] = (raw[at].to_int() + raw[at - span].to_int()).to_byte()
      } else {
        let value = raw[at].to_int() * 256 +
          raw[at + 1].to_int() +
          (raw[at - span].to_int() * 256 + raw[at - span + 1].to_int())
        let wrapped = value & 0xFFFF
        raw[at] = ((wrapped >> 8) & 0xFF).to_byte()
        raw[at + 1] = (wrapped & 0xFF).to_byte()
      }
    }
  }
}

///|
/// The decompressed strips as one of the library's layouts.
fn assemble_page(
  raw : FixedArray[Byte],
  width : Int32,
  height : Int32,
  samples : Int32,
  bits : Int32,
  photometric : Int32,
  planar : Int32,
  row_length : Int32,
  little : Bool,
  directory : Directory,
) -> @raster.Image raise @raster.Refused {
  if photometric == 3 {
    return palette_page(raw, width, height, bits, row_length, directory)
  }
  let gray = photometric == 0 || photometric == 1
  if !gray && photometric != 2 {
    raise @raster.Unsupported(at=0, got="a photometric of \{photometric}")
  }
  let has_alpha = samples == 2 || samples == 4
  let format = match (gray, has_alpha, bits) {
    (true, false, 8) => @raster.PixelFormat::Gray8
    (true, true, 8) => @raster.PixelFormat::GrayAlpha8
    (true, false, 16) => @raster.PixelFormat::Gray16
    (true, true, 16) => @raster.PixelFormat::GrayAlpha16
    (false, false, 8) => @raster.PixelFormat::Rgb8
    (false, true, 8) => @raster.PixelFormat::Rgba8
    (false, false, 16) => @raster.PixelFormat::Rgb16
    _ => @raster.PixelFormat::Rgba16
  }
  let channels = format.channels()
  let sample_bytes = format.bytes() / channels
  let out : FixedArray[Byte] = FixedArray::make(
    width * height * format.bytes(),
    b'\x00',
  )
  let invert = photometric == 0
  let plane_step = row_length * height
  for y in 0..<height {
    for x in 0..<width {
      let target = (y * width + x) * format.bytes()
      for channel in 0..<channels {
        let value = if planar == 2 {
          read_sample(
            raw,
            channel * plane_step + y * row_length,
            x,
            bits,
            little,
          )
        } else {
          read_sample(raw, y * row_length, x * samples + channel, bits, little)
        }
        let scaled = scale_sample(value, bits, invert)
        if sample_bytes == 2 {
          out[target + channel * 2] = ((scaled >> 8) & 0xFF).to_byte()
          out[target + channel * 2 + 1] = (scaled & 0xFF).to_byte()
        } else {
          out[target + channel] = scaled.to_byte()
        }
      }
    }
  }
  @raster.Image::of(
    width,
    height,
    format,
    Bytes::from_array(out.clamped_view()),
  )
}

///|
/// The `index`th sample of a row that starts at `row`.
fn read_sample(
  raw : FixedArray[Byte],
  row : Int32,
  index : Int32,
  bits : Int32,
  little : Bool,
) -> Int32 {
  match bits {
    8 => raw[row + index].to_int()
    16 => {
      let at = row + index * 2
      let first = raw[at].to_int()
      let second = raw[at + 1].to_int()
      if little {
        (second << 8) | first
      } else {
        (first << 8) | second
      }
    }
    4 => {
      let byte = raw[row + index / 2].to_int()
      if index % 2 == 0 {
        byte >> 4
      } else {
        byte & 0xF
      }
    }
    2 => {
      let byte = raw[row + index / 4].to_int()
      (byte >> (6 - index % 4 * 2)) & 0x3
    }
    _ => {
      let byte = raw[row + index / 8].to_int()
      (byte >> (7 - index % 8)) & 1
    }
  }
}

///|
/// A sample widened to the full range of the layout it is going into.
fn scale_sample(value : Int32, bits : Int32, invert : Bool) -> Int32 {
  let wide = if bits == 16 { 65535 } else { 255 }
  if bits == 8 || bits == 16 {
    return if invert { wide - value } else { value }
  }
  let top = (1 << bits) - 1
  let scaled = (value * wide + top / 2) / top
  if invert {
    wide - scaled
  } else {
    scaled
  }
}

///|
/// A palette page: one index a pixel, and three tables of sixteen-bit entries
/// holding all the reds, then all the greens, then all the blues.
fn palette_page(
  raw : FixedArray[Byte],
  width : Int32,
  height : Int32,
  bits : Int32,
  row_length : Int32,
  directory : Directory,
) -> @raster.Image raise @raster.Refused {
  let map = directory.numbers(tag_color_map)
  let entries = 1 << bits
  if map.length() < entries * 3 {
    raise @raster.Unexpected(
      at=0,
      got="\{map.length()} colour map entries",
      want="\{entries * 3} for \{bits}-bit indices",
    )
  }
  let out : FixedArray[Byte] = FixedArray::make(width * height * 3, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let index = read_sample(raw, y * row_length, x, bits, true)
      let at = (y * width + x) * 3
      out[at] = ((map[index] >> 8) & 0xFF).to_byte()
      out[at + 1] = ((map[entries + index] >> 8) & 0xFF).to_byte()
      out[at + 2] = ((map[entries * 2 + index] >> 8) & 0xFF).to_byte()
    }
  }
  @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::Rgb8,
    Bytes::from_array(out.clamped_view()),
  )
}

///|
/// The ICC profile, if the page carries one.
fn metadata_of(directory : Directory) -> @raster.Metadata {
  match directory.bytes(tag_icc) {
    Some(profile) =>
      {
        ..@raster.Metadata::default(),
        icc: Some({ name: "ICC", profile: copy_bytes(profile), }),
      }
    None => @raster.Metadata::default()
  }
}

///|
/// The bytes of a view, as bytes of their own.
fn copy_bytes(view : BytesView) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(view.length(), b'\x00')
  for i in 0..<view.length() {
    out[i] = view[i]
  }
  Bytes::from_array(out.clamped_view())
}
