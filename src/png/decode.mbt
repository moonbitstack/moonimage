// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Reading PNG.
//
// The shape of the job: a header that says how wide, how deep and how the
// samples are arranged; a palette and a transparency key that change what a
// sample means; a deflate stream that has to be inflated to exactly the size the
// header predicted; a filter per row that has to be undone against the row above;
// and, if the image is interlaced, seven passes that each cover a different set
// of pixels.
//
// Every one of those is checked against the header rather than against the bytes
// that happen to be there, because the bytes are what a damaged file gets wrong.

///|
/// What IHDR says.
priv struct Header {
  width : Int32
  height : Int32
  depth : Int32
  color : Int32
  interlace : Bool
}

///|
/// How many samples a pixel has, given the colour type.
fn channels_of(color : Int32) -> Int32 {
  match color {
    0 => 1
    2 => 3
    3 => 1
    4 => 2
    _ => 4
  }
}

///|
/// The three bytes of each palette entry. Alpha is not here: a palette's alpha is
/// a separate chunk, and a file that has none has an opaque palette.
priv struct Palette {
  red : Array[Int32]
  green : Array[Int32]
  blue : Array[Int32]
}

///|
/// What makes a sample transparent, in the four ways the format says it.
priv enum Trns {
  /// Nothing: every sample is opaque.
  Opaque
  /// A grey value, or a colour, that means transparent rather than a colour.
  Key(red~ : Int32, green~ : Int32, blue~ : Int32)
  /// One alpha per palette entry.
  Entries(alpha~ : Array[Int32])
}

///|
/// One frame of an APNG while it is being read: where it goes, how long it
/// stays, and the compressed data that has arrived for it so far.
priv struct FrameData {
  width : Int32
  height : Int32
  x : Int32
  y : Int32
  delay_num : Int32
  delay_den : Int32
  dispose : Int32
  blend : Int32
  parts : Array[BytesView]
}

///|
/// Everything a file said, before any of it is turned into pixels.
priv struct Parsed {
  header : Header
  palette : Palette?
  trns : Trns
  metadata : @raster.Metadata
  /// The compressed image: one frame for a still PNG, the first frame for an
  /// APNG whose first frame is the default image.
  data : Array[BytesView]
  /// The frames of an APNG, in order. Empty for a still image.
  frames : Array[FrameData]
  /// How many times the animation plays; 0 means forever.
  plays : Int32
}

///|
/// The image in a PNG file.
///
/// Raises `Refused` on any damage, including a chunk whose CRC does not match.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  let parsed = parse(bytes, limits)
  let parts = if parsed.data.is_empty() {
    parsed.frames[0].parts
  } else {
    parsed.data
  }
  uncompress(parsed, parts, parsed.header, limits)
}

///|
/// Every frame of an APNG. A PNG that is not animated comes back as one frame
/// covering the whole canvas.
pub fn decode_animation(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Animation raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  let parsed = parse(bytes, limits)
  let parts = if parsed.data.is_empty() {
    parsed.frames[0].parts
  } else {
    parsed.data
  }
  let picture = uncompress(parsed, parts, parsed.header, limits)
  let canvas_width = parsed.header.width
  let canvas_height = parsed.header.height
  if parsed.frames.is_empty() {
    return @raster.Animation::new(
      canvas_width,
      canvas_height,
      [@raster.Frame::new(picture)],
      metadata=picture.metadata,
    )
  }
  let frames : Array[@raster.Frame] = []
  for frame in parsed.frames {
    let header = {
      width: frame.width,
      height: frame.height,
      depth: parsed.header.depth,
      color: parsed.header.color,
      interlace: parsed.header.interlace,
    }
    let decoded = uncompress(parsed, frame.parts, header, limits)
    frames.push(
      @raster.Frame::new(
        decoded,
        x=frame.x,
        y=frame.y,
        delay=delay_of(frame),
        dispose=dispose_of(frame.dispose),
        blend=blend_of(frame.blend),
      ),
    )
  }
  @raster.Animation::new(
    canvas_width,
    canvas_height,
    frames,
    loops=parsed.plays,
    metadata=picture.metadata,
  )
}

///|
/// A frame's delay in milliseconds. A zero denominator means one hundredth of a
/// second, which is what a file that forgot to say gets.
fn delay_of(frame : FrameData) -> Int32 {
  let denominator = if frame.delay_den == 0 { 100 } else { frame.delay_den }
  (frame.delay_num * 1000 + denominator / 2) / denominator
}

///|
fn dispose_of(code : Int32) -> @raster.Dispose {
  match code {
    1 => @raster.Dispose::Background
    2 => @raster.Dispose::Previous
    _ => @raster.Dispose::Keep
  }
}

///|
fn blend_of(code : Int32) -> @raster.Blend {
  if code == 0 {
    @raster.Blend::Source
  } else {
    @raster.Blend::Over
  }
}

///|
/// Walk the chunk list, checking what can be checked without decompressing
/// anything.
fn parse(
  bytes : BytesView,
  limits : @raster.Limits,
) -> Parsed raise @raster.Refused {
  if bytes.length() < 8 || !bytes[0:8].equal_to_bytes(signature) {
    if bytes.length() < 8 {
      raise @raster.Truncated(at=0, want=8 - bytes.length())
    }
    raise @raster.Unknown(at=0, got=@raster.hex(bytes, 0, 8))
  }
  let cursor = @wire.Cursor::new(bytes)
  cursor.seek(8)
  let mut header : Header? = None
  let mut palette : Palette? = None
  let mut palette_seen = false
  let mut trns : Trns = Opaque
  let mut gamma : Double? = None
  let mut chromaticities : @raster.Chromaticities? = None
  let mut intent : @raster.Intent? = None
  let mut icc : @raster.Icc? = None
  let texts : Array[@raster.Text] = []
  let data : Array[BytesView] = []
  let frames : Array[FrameData] = []
  let mut plays = 0
  let mut seen_actl = false
  let mut frame_open = false
  let mut first_frame_is_default = false
  let mut seen_idat = false
  let mut seen_iend = false
  while !cursor.is_empty() {
    let chunk = read_chunk(cursor, true)
    match chunk.kind {
      "IHDR" => {
        if header is Some(_) {
          raise @raster.Unexpected(
            at=chunk.at,
            got="a second IHDR",
            want="one header",
          )
        }
        header = Some(read_header(chunk, limits))
      }
      "PLTE" => {
        palette = Some(read_palette(chunk))
        palette_seen = true
      }
      "tRNS" => trns = read_trns(chunk, palette)
      "gAMA" => {
        if chunk.data.length() != 4 {
          raise @raster.Truncated(at=chunk.at, want=4 - chunk.data.length())
        }
        let word = be32(chunk.data, 0)
        if word != 0 {
          gamma = Some(word.to_double() / 100_000.0)
        }
      }
      "cHRM" => chromaticities = Some(read_chromaticities(chunk))
      "sRGB" => {
        if chunk.data.length() != 1 {
          raise @raster.Truncated(at=chunk.at, want=1 - chunk.data.length())
        }
        let code = chunk.data[0].to_int()
        intent = @raster.Intent::of(code)
        if intent is None {
          raise @raster.Unexpected(
            at=chunk.at,
            got="intent \{code}",
            want="0 to 3",
          )
        }
      }
      "iCCP" => icc = Some(read_icc(chunk, limits))
      "tEXt" => texts.push(read_text(chunk))
      "zTXt" => texts.push(read_ztxt(chunk, limits))
      "iTXt" => texts.push(read_itxt(chunk, limits))
      "acTL" => {
        if chunk.data.length() < 8 {
          raise @raster.Truncated(at=chunk.at, want=8 - chunk.data.length())
        }
        plays = be32(chunk.data, 4)
        seen_actl = true
      }
      "fcTL" => {
        if !seen_idat {
          first_frame_is_default = true
        }
        frames.push(read_frame(chunk, limits))
        frame_open = true
      }
      "fdAT" => {
        if !frame_open {
          raise @raster.Unexpected(
            at=chunk.at,
            got="fdAT before fcTL",
            want="a frame header",
          )
        }
        if chunk.data.length() < 4 {
          raise @raster.Truncated(at=chunk.at, want=4 - chunk.data.length())
        }
        let payload = chunk.data.clamped_view(start=4, end=chunk.data.length())
        frames[frames.length() - 1].parts.push(payload)
      }
      "IDAT" => {
        seen_idat = true
        if frame_open && first_frame_is_default && frames.length() == 1 {
          frames[0].parts.push(chunk.data)
        } else {
          data.push(chunk.data)
        }
      }
      "IEND" => {
        seen_iend = true
        break
      }
      _ => {
        // A chunk whose first letter is upper case is critical: a decoder that
        // does not know it cannot assume it was safe to ignore.
        let first = chunk.kind[0]
        if first.to_int() >= 65 && first.to_int() <= 90 {
          raise @raster.Unsupported(at=chunk.at, got=chunk.kind)
        }
      }
    }
  }
  let header = match header {
    Some(header) => header
    None => raise @raster.Unexpected(at=8, got="no IHDR", want="a header chunk")
  }
  if !seen_iend {
    raise @raster.Truncated(at=bytes.length(), want=1)
  }
  if data.is_empty() && frames.is_empty() {
    raise @raster.Unexpected(
      at=0,
      got="no image data",
      want="at least one IDAT",
    )
  }
  if header.color == 3 && !palette_seen {
    raise @raster.Unexpected(at=0, got="an indexed image", want="a PLTE chunk")
  }
  if seen_actl && frames.is_empty() {
    raise @raster.Unexpected(
      at=0,
      got="an animation with no frames",
      want="one fcTL or more",
    )
  }
  {
    header,
    palette,
    trns,
    metadata: { gamma, chromaticities, intent, icc, texts, },
    data,
    frames,
    plays,
  }
}

///|
fn read_header(
  chunk : Chunk,
  limits : @raster.Limits,
) -> Header raise @raster.Refused {
  if chunk.data.length() != 13 {
    raise @raster.Truncated(at=chunk.at + 8, want=13 - chunk.data.length())
  }
  let width = be32(chunk.data, 0)
  let height = be32(chunk.data, 4)
  let depth = chunk.data[8].to_int()
  let color = chunk.data[9].to_int()
  let compression = chunk.data[10].to_int()
  let filter = chunk.data[11].to_int()
  let interlace = chunk.data[12].to_int()
  if width == 0 || height == 0 {
    raise @raster.Unexpected(
      at=chunk.at + 8,
      got="a header with no pixels",
      want="a width and a height above zero",
    )
  }
  limits.check(width, height)
  if compression != 0 {
    raise @raster.Unsupported(
      at=chunk.at + 18,
      got="compression \{compression}",
    )
  }
  if filter != 0 {
    raise @raster.Unsupported(at=chunk.at + 19, got="filter method \{filter}")
  }
  if interlace > 1 {
    raise @raster.Unexpected(
      at=chunk.at + 20,
      got="interlace \{interlace}",
      want="0 or 1",
    )
  }
  let allowed = match color {
    0 => depth == 1 || depth == 2 || depth == 4 || depth == 8 || depth == 16
    2 => depth == 8 || depth == 16
    3 => depth == 1 || depth == 2 || depth == 4 || depth == 8
    4 => depth == 8 || depth == 16
    6 => depth == 8 || depth == 16
    _ => false
  }
  if !allowed {
    raise @raster.Unexpected(
      at=chunk.at + 16,
      got="depth \{depth} with colour type \{color}",
      want="a depth that colour type allows",
    )
  }
  { width, height, depth, color, interlace: interlace == 1, }
}

///|
fn read_palette(chunk : Chunk) -> Palette raise @raster.Refused {
  let length = chunk.data.length()
  if length == 0 || length % 3 != 0 || length > 768 {
    raise @raster.Unexpected(
      at=chunk.at,
      got="a palette of \{length} bytes",
      want="a multiple of three, up to 768",
    )
  }
  let red : Array[Int32] = []
  let green : Array[Int32] = []
  let blue : Array[Int32] = []
  for entry in 0..<(length / 3) {
    red.push(chunk.data[entry * 3].to_int())
    green.push(chunk.data[entry * 3 + 1].to_int())
    blue.push(chunk.data[entry * 3 + 2].to_int())
  }
  { red, green, blue, }
}

///|
fn read_trns(chunk : Chunk, palette : Palette?) -> Trns raise @raster.Refused {
  match palette {
    Some(palette) => {
      if chunk.data.length() > palette.red.length() {
        raise @raster.Unexpected(
          at=chunk.at,
          got="more alphas than palette entries",
          want="at most one per entry",
        )
      }
      let alpha : Array[Int32] = []
      for index in 0..<chunk.data.length() {
        alpha.push(chunk.data[index].to_int())
      }
      Entries(alpha~)
    }
    None =>
      // Without a palette, `tRNS` is a sample value that means transparent: two
      // bytes for grey, six for colour. It has to wait for the header to know
      // which, and the header is read first, so the shape of the chunk decides.
      if chunk.data.length() == 2 {
        let value = be16(chunk.data, 0)
        Key(red=value, green=value, blue=value)
      } else if chunk.data.length() == 6 {
        Key(
          red=be16(chunk.data, 0),
          green=be16(chunk.data, 2),
          blue=be16(chunk.data, 4),
        )
      } else {
        raise @raster.Unexpected(
          at=chunk.at,
          got="a key of \{chunk.data.length()} bytes",
          want="two for grey, six for colour",
        )
      }
  }
}

///|
fn read_chromaticities(
  chunk : Chunk,
) -> @raster.Chromaticities raise @raster.Refused {
  if chunk.data.length() != 32 {
    raise @raster.Truncated(at=chunk.at, want=32 - chunk.data.length())
  }
  let scale = 100_000.0
  {
    white_x: be32(chunk.data, 0).to_double() / scale,
    white_y: be32(chunk.data, 4).to_double() / scale,
    red_x: be32(chunk.data, 8).to_double() / scale,
    red_y: be32(chunk.data, 12).to_double() / scale,
    green_x: be32(chunk.data, 16).to_double() / scale,
    green_y: be32(chunk.data, 20).to_double() / scale,
    blue_x: be32(chunk.data, 24).to_double() / scale,
    blue_y: be32(chunk.data, 28).to_double() / scale,
  }
}

///|
fn read_icc(
  chunk : Chunk,
  limits : @raster.Limits,
) -> @raster.Icc raise @raster.Refused {
  let name_end = find_zero(chunk.data, 0)
  if name_end < 0 || name_end + 2 > chunk.data.length() {
    raise @raster.Unexpected(
      at=chunk.at,
      got="a profile with no name",
      want="a name then a method",
    )
  }
  let scheme = chunk.data[name_end + 1].to_int()
  if scheme != 0 {
    raise @raster.Unsupported(
      at=chunk.at + 8 + name_end + 1,
      got="profile method \{scheme}",
    )
  }
  let compressed = chunk.data.clamped_view(
    start=name_end + 2,
    end=chunk.data.length(),
  )
  let profile = inflate(compressed, limits)
  { name: latin1(chunk.data.clamped_view(start=0, end=name_end)), profile, }
}

///|
fn read_text(chunk : Chunk) -> @raster.Text raise @raster.Refused {
  let keyword_end = find_zero(chunk.data, 0)
  if keyword_end < 0 {
    raise @raster.Unexpected(
      at=chunk.at,
      got="a keyword with no end",
      want="a null-terminated keyword",
    )
  }
  @raster.Text::Latin(
    keyword=latin1(chunk.data.clamped_view(start=0, end=keyword_end)),
    text=latin1(
      chunk.data.clamped_view(start=keyword_end + 1, end=chunk.data.length()),
    ),
  )
}

///|
fn read_ztxt(
  chunk : Chunk,
  limits : @raster.Limits,
) -> @raster.Text raise @raster.Refused {
  let keyword_end = find_zero(chunk.data, 0)
  if keyword_end < 0 || keyword_end + 2 > chunk.data.length() {
    raise @raster.Unexpected(
      at=chunk.at,
      got="a keyword with no end",
      want="a null-terminated keyword",
    )
  }
  let scheme = chunk.data[keyword_end + 1].to_int()
  if scheme != 0 {
    raise @raster.Unsupported(
      at=chunk.at + 8 + keyword_end + 1,
      got="text method \{scheme}",
    )
  }
  let compressed = chunk.data.clamped_view(
    start=keyword_end + 2,
    end=chunk.data.length(),
  )
  @raster.Text::Compressed(
    keyword=latin1(chunk.data.clamped_view(start=0, end=keyword_end)),
    text=latin1(inflate(compressed, limits)),
  )
}

///|
fn read_itxt(
  chunk : Chunk,
  limits : @raster.Limits,
) -> @raster.Text raise @raster.Refused {
  let name_end = find_zero(chunk.data, 0)
  if name_end < 0 || name_end + 3 > chunk.data.length() {
    raise @raster.Unexpected(
      at=chunk.at,
      got="an international text with no keyword",
      want="a keyword",
    )
  }
  let compressed = chunk.data[name_end + 1].to_int() == 1
  let scheme = chunk.data[name_end + 2].to_int()
  if compressed && scheme != 0 {
    raise @raster.Unsupported(
      at=chunk.at + 8 + name_end + 2,
      got="text method \{scheme}",
    )
  }
  let language_end = find_zero(chunk.data, name_end + 3)
  if language_end < 0 {
    raise @raster.Unexpected(
      at=chunk.at,
      got="a language tag with no end",
      want="a null-terminated tag",
    )
  }
  let translated_end = find_zero(chunk.data, language_end + 1)
  if translated_end < 0 {
    raise @raster.Unexpected(
      at=chunk.at,
      got="a translated keyword with no end",
      want="a null-terminated keyword",
    )
  }
  let body = chunk.data.clamped_view(
    start=translated_end + 1,
    end=chunk.data.length(),
  )
  let text = if compressed { inflate(body, limits) } else { body.to_owned() }
  @raster.Text::International(
    keyword=latin1(chunk.data.clamped_view(start=0, end=name_end)),
    language=latin1(
      chunk.data.clamped_view(start=name_end + 3, end=language_end),
    ),
    translated=utf8_text(
      chunk.data.clamped_view(start=language_end + 1, end=translated_end),
    ),
    text=utf8_text(text),
  )
}

///|
fn read_frame(
  chunk : Chunk,
  limits : @raster.Limits,
) -> FrameData raise @raster.Refused {
  if chunk.data.length() != 26 {
    raise @raster.Truncated(at=chunk.at, want=26 - chunk.data.length())
  }
  let width = be32(chunk.data, 4)
  let height = be32(chunk.data, 8)
  if width == 0 || height == 0 {
    raise @raster.Unexpected(
      at=chunk.at + 12,
      got="a frame with no pixels",
      want="a width and a height above zero",
    )
  }
  limits.check(width, height)
  {
    width,
    height,
    x: be32(chunk.data, 12),
    y: be32(chunk.data, 16),
    delay_num: be16(chunk.data, 20),
    delay_den: be16(chunk.data, 22),
    dispose: chunk.data[24].to_int(),
    blend: chunk.data[25].to_int(),
    parts: [],
  }
}

///|
/// The offset of the next zero byte, or -1 when there is none.
fn find_zero(data : BytesView, from : Int32) -> Int32 {
  let mut index = from
  while index < data.length() {
    if data[index].to_int() == 0 {
      return index
    }
    index = index + 1
  }
  -1
}

///|
fn be16(data : BytesView, at : Int32) -> Int32 {
  data[at].to_int() * 256 + data[at + 1].to_int()
}

///|
fn be32(data : BytesView, at : Int32) -> Int32 {
  data[at].to_int() * 16_777_216 +
  data[at + 1].to_int() * 65_536 +
  data[at + 2].to_int() * 256 +
  data[at + 3].to_int()
}

///|
/// Inflate a zlib stream, turning the compressor's refusal into this library's.
fn inflate(
  data : BytesView,
  limits : @raster.Limits,
) -> Bytes raise @raster.Refused {
  @zlib.unzlib(data, limit=limits.bytes) catch {
    _ =>
      raise @raster.Unexpected(
        at=0,
        got="a deflate stream that does not decode",
        want="a complete zlib stream",
      )
  }
}

///|
/// Inflate the image data, undo the row filters, and expand the samples into a
/// pixel format.
fn uncompress(
  parsed : Parsed,
  parts : Array[BytesView],
  header : Header,
  limits : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let compressed = concat(parts)
  let raw = inflate(compressed, limits)
  let channels = channels_of(header.color)
  let bits = channels * header.depth
  let bytes_per_pixel = if bits < 8 { 1 } else { bits / 8 }
  let format = format_of(header, parsed.trns)
  let stride = header.width * format.bytes()
  let dest : FixedArray[Byte] = FixedArray::make(
    stride * header.height,
    b'\x00',
  )
  if header.interlace {
    let mut offset = 0
    for pass in 0..<7 {
      let (x0, y0, dx, dy) = pass_of(pass)
      let width = pass_size(header.width, x0, dx)
      let height = pass_size(header.height, y0, dy)
      if width == 0 || height == 0 {
        continue
      }
      let row_bytes = (width * bits + 7) / 8
      let needed = height * (row_bytes + 1)
      if offset + needed > raw.length() {
        raise @raster.Truncated(at=offset, want=offset + needed - raw.length())
      }
      let rows = unfilter(raw, offset, row_bytes, height, bytes_per_pixel)
      place(
        dest,
        stride,
        format,
        header,
        rows,
        width,
        height,
        x0,
        y0,
        dx,
        dy,
        parsed.palette,
        parsed.trns,
      )
      offset = offset + needed
    }
  } else {
    let row_bytes = (header.width * bits + 7) / 8
    let needed = header.height * (row_bytes + 1)
    if needed > raw.length() {
      raise @raster.Truncated(at=raw.length(), want=needed - raw.length())
    }
    let rows = unfilter(raw, 0, row_bytes, header.height, bytes_per_pixel)
    place(
      dest,
      stride,
      format,
      header,
      rows,
      header.width,
      header.height,
      0,
      0,
      1,
      1,
      parsed.palette,
      parsed.trns,
    )
  }
  {
    width: header.width,
    height: header.height,
    format,
    stride,
    pixels: Bytes::from_array(dest.clamped_view()),
    premultiplied: false,
    metadata: parsed.metadata,
  }
}

///|
/// Join the IDAT payloads, which a file may split across as many chunks as it
/// likes and a writer usually splits at about eight kilobytes.
fn concat(parts : Array[BytesView]) -> Bytes {
  let builder = @buffer.Buffer::Buffer()
  for part in parts {
    builder.write_bytesview(part)
  }
  builder.to_bytes()
}

///|
/// The pixel format a header and its transparency lead to.
fn format_of(header : Header, trns : Trns) -> @raster.PixelFormat {
  let wide = header.depth == 16
  match header.color {
    0 =>
      if trns is Key(_) {
        if wide {
          @raster.PixelFormat::GrayAlpha16
        } else {
          @raster.PixelFormat::GrayAlpha8
        }
      } else if wide {
        @raster.PixelFormat::Gray16
      } else {
        @raster.PixelFormat::Gray8
      }
    2 =>
      if trns is Key(_) {
        if wide {
          @raster.PixelFormat::Rgba16
        } else {
          @raster.PixelFormat::Rgba8
        }
      } else if wide {
        @raster.PixelFormat::Rgb16
      } else {
        @raster.PixelFormat::Rgb8
      }
    3 =>
      if trns is Entries(_) {
        @raster.PixelFormat::Rgba8
      } else {
        @raster.PixelFormat::Rgb8
      }
    4 =>
      if wide {
        @raster.PixelFormat::GrayAlpha16
      } else {
        @raster.PixelFormat::GrayAlpha8
      }
    _ =>
      if wide {
        @raster.PixelFormat::Rgba16
      } else {
        @raster.PixelFormat::Rgba8
      }
  }
}

///|
/// Undo the per-row filters, which are the only stateful part of the format: each
/// row is stored as a difference from the row above, or from the pixel to its
/// left, or from both.
fn unfilter(
  raw : BytesView,
  start : Int32,
  row_bytes : Int32,
  height : Int32,
  bpp : Int32,
) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(row_bytes * height, b'\x00')
  for row in 0..<height {
    let filter = raw[start + row * (row_bytes + 1)].to_int()
    let from = start + row * (row_bytes + 1) + 1
    let to = row * row_bytes
    let above = to - row_bytes
    for index in 0..<row_bytes {
      let value = raw[from + index].to_int()
      let left = if index >= bpp { out[to + index - bpp].to_int() } else { 0 }
      let up = if row > 0 { out[above + index].to_int() } else { 0 }
      let upper_left = if row > 0 && index >= bpp {
        out[above + index - bpp].to_int()
      } else {
        0
      }
      let restored = match filter {
        0 => value
        1 => value + left
        2 => value + up
        3 => value + (left + up) / 2
        4 => value + paeth(left, up, upper_left)
        _ => value
      }
      out[to + index] = (restored & 0xFF).to_byte()
    }
  }
  Bytes::from_array(out.clamped_view())
}

///|
/// The Paeth predictor: whichever of the three neighbours the gradient points at.
fn paeth(left : Int32, up : Int32, upper_left : Int32) -> Int32 {
  let estimate = left + up - upper_left
  let to_left = if estimate > left { estimate - left } else { left - estimate }
  let to_up = if estimate > up { estimate - up } else { up - estimate }
  let to_corner = if estimate > upper_left {
    estimate - upper_left
  } else {
    upper_left - estimate
  }
  if to_left <= to_up && to_left <= to_corner {
    left
  } else if to_up <= to_corner {
    up
  } else {
    upper_left
  }
}

///|
/// Where an Adam7 pass starts and how far apart its pixels are.
fn pass_of(pass : Int32) -> (Int32, Int32, Int32, Int32) {
  match pass {
    0 => (0, 0, 8, 8)
    1 => (4, 0, 8, 8)
    2 => (0, 4, 4, 8)
    3 => (2, 0, 4, 4)
    4 => (0, 2, 2, 4)
    5 => (1, 0, 2, 2)
    _ => (0, 1, 1, 2)
  }
}

///|
/// How many pixels a pass covers along one axis.
fn pass_size(total : Int32, start : Int32, step : Int32) -> Int32 {
  if total <= start {
    0
  } else {
    (total - start + step - 1) / step
  }
}

///|
/// Turn one pass of unfiltered samples into pixels in the destination image.
fn place(
  dest : FixedArray[Byte],
  stride : Int32,
  format : @raster.PixelFormat,
  header : Header,
  rows : BytesView,
  width : Int32,
  height : Int32,
  x0 : Int32,
  y0 : Int32,
  dx : Int32,
  dy : Int32,
  palette : Palette?,
  trns : Trns,
) -> Unit raise @raster.Refused {
  let channels = channels_of(header.color)
  let depth = header.depth
  let row_bytes = (width * channels * depth + 7) / 8
  let pixel = format.bytes()
  // A sample is opaque at the top of its own depth: 255 in eight bits, 65535 in
  // sixteen, and a key only ever makes one of them transparent.
  let solid = if depth == 16 { 65535 } else { 255 }
  for row in 0..<height {
    let base = row * row_bytes
    for column in 0..<width {
      let x = x0 + column * dx
      let y = y0 + row * dy
      let to = y * stride + x * pixel
      match header.color {
        0 => {
          let value = sample(rows, base, column, depth)
          let grey = scale_sample(value, depth)
          let alpha = match trns {
            Key(red~, ..) => if value == red { 0 } else { solid }
            _ => solid
          }
          write_grey(dest, to, format, grey, alpha)
        }
        2 => {
          let r = sample(rows, base, column * 3, depth)
          let g = sample(rows, base, column * 3 + 1, depth)
          let b = sample(rows, base, column * 3 + 2, depth)
          let alpha = match trns {
            Key(red~, green~, blue~) =>
              if r == red && g == green && b == blue {
                0
              } else {
                solid
              }
            _ => solid
          }
          write_colour(dest, to, format, r, g, b, alpha)
        }
        3 => {
          let index = sample(rows, base, column, depth)
          let entry = match palette {
            Some(palette) => palette
            None =>
              raise @raster.Unexpected(
                at=0,
                got="an indexed image",
                want="a palette",
              )
          }
          if index >= entry.red.length() {
            raise @raster.Unexpected(
              at=0,
              got="palette index \{index}",
              want="an index below \{entry.red.length()}",
            )
          }
          let alpha = match trns {
            Entries(alpha~) =>
              if index < alpha.length() {
                alpha[index]
              } else {
                255
              }
            Opaque => 255
            _ => 255
          }
          dest[to] = entry.red[index].to_byte()
          dest[to + 1] = entry.green[index].to_byte()
          dest[to + 2] = entry.blue[index].to_byte()
          if pixel > 3 {
            dest[to + 3] = alpha.to_byte()
          }
        }
        4 => {
          let grey = scale_sample(sample(rows, base, column * 2, depth), depth)
          let alpha = scale_sample(
            sample(rows, base, column * 2 + 1, depth),
            depth,
          )
          write_grey(dest, to, format, grey, alpha)
        }
        _ => {
          let red = sample(rows, base, column * 4, depth)
          let green = sample(rows, base, column * 4 + 1, depth)
          let blue = sample(rows, base, column * 4 + 2, depth)
          let alpha = sample(rows, base, column * 4 + 3, depth)
          write_colour(dest, to, format, red, green, blue, alpha)
        }
      }
    }
  }
}

///|
/// One sample out of a row, whether it is a whole byte, two bytes, or a few bits
/// packed with its neighbours.
fn sample(
  rows : BytesView,
  base : Int32,
  index : Int32,
  depth : Int32,
) -> Int32 {
  match depth {
    8 => rows[base + index].to_int()
    16 =>
      rows[base + index * 2].to_int() * 256 +
      rows[base + index * 2 + 1].to_int()
    _ => {
      let bit = index * depth
      let byte = rows[base + bit / 8].to_int()
      let shift = 8 - depth - bit % 8
      (byte >> shift) & ((1 << depth) - 1)
    }
  }
}

///|
/// A sample widened to eight bits, which is what the format means by a one, two
/// or four-bit grey: the ends of the range are black and white, and the values
/// between are evenly spaced.
fn scale_sample(value : Int32, depth : Int32) -> Int32 {
  match depth {
    1 => value * 255
    2 => value * 85
    4 => value * 17
    8 => value
    _ => value
  }
}

///|
/// Write a grey pixel, which is either one sample or two, in eight or sixteen
/// bits.
fn write_grey(
  dest : FixedArray[Byte],
  to : Int32,
  format : @raster.PixelFormat,
  grey : Int32,
  alpha : Int32,
) -> Unit {
  match format {
    @raster.PixelFormat::Gray8 => dest[to] = grey.to_byte()
    @raster.PixelFormat::GrayAlpha8 => {
      dest[to] = grey.to_byte()
      dest[to + 1] = alpha.to_byte()
    }
    @raster.PixelFormat::Gray16 => {
      dest[to] = ((grey >> 8) & 0xFF).to_byte()
      dest[to + 1] = (grey & 0xFF).to_byte()
    }
    @raster.PixelFormat::GrayAlpha16 => {
      dest[to] = ((grey >> 8) & 0xFF).to_byte()
      dest[to + 1] = (grey & 0xFF).to_byte()
      dest[to + 2] = ((alpha >> 8) & 0xFF).to_byte()
      dest[to + 3] = (alpha & 0xFF).to_byte()
    }
    _ => ()
  }
}

///|
/// Write a colour pixel: three samples, or four when the destination has alpha.
fn write_colour(
  dest : FixedArray[Byte],
  to : Int32,
  format : @raster.PixelFormat,
  red : Int32,
  green : Int32,
  blue : Int32,
  alpha : Int32,
) -> Unit {
  match format {
    @raster.PixelFormat::Rgb8 => {
      dest[to] = red.to_byte()
      dest[to + 1] = green.to_byte()
      dest[to + 2] = blue.to_byte()
    }
    @raster.PixelFormat::Rgba8 => {
      dest[to] = red.to_byte()
      dest[to + 1] = green.to_byte()
      dest[to + 2] = blue.to_byte()
      dest[to + 3] = alpha.to_byte()
    }
    @raster.PixelFormat::Rgb16 => {
      put16(dest, to, red)
      put16(dest, to + 2, green)
      put16(dest, to + 4, blue)
    }
    @raster.PixelFormat::Rgba16 => {
      put16(dest, to, red)
      put16(dest, to + 2, green)
      put16(dest, to + 4, blue)
      put16(dest, to + 6, alpha)
    }
    _ => ()
  }
}

///|
fn put16(dest : FixedArray[Byte], at : Int32, value : Int32) -> Unit {
  dest[at] = ((value >> 8) & 0xFF).to_byte()
  dest[at + 1] = (value & 0xFF).to_byte()
}
