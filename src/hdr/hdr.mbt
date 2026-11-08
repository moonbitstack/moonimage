// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Radiance HDR: a picture of light rather than of a display.
//
// The format was written for a renderer, and it shows: a header of `KEY=value`
// lines, a resolution line that can put the origin in any of the four corners,
// and pixels that share one exponent between three mantissas. A shared exponent
// is what makes the format compact — three bytes of mantissa and one of
// exponent covers twelve orders of magnitude — and what makes it coarse, since
// a dark pixel next to a bright one loses its precision to the bright one.
//
// The samples are kept as floats and are not held to nought and one: a value
// above one is a highlight, which is the whole reason the format exists. The
// library's `RgbaF32` holds them unchanged, and a caller that wants a display
// picture converts, which clamps.
//
// https://floyd.lbl.gov/radiance/refer/filefmts.pdf

///|
/// The image in these bytes.
///
/// The result is `RgbaF32`, with alpha one: the format carries no transparency.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  let reader = Reader::new(bytes)
  let mut exposure = None
  let mut gamma = None
  let magic = reader.line()
  if !magic.equal_to_bytes(b"#?RADIANCE") && !magic.equal_to_bytes(b"#?RGBE") {
    raise @raster.Unknown(at=0, got=@raster.hex(bytes, 0, 8))
  }
  let mut format_seen = false
  while true {
    let line = reader.line()
    if line.length() == 0 {
      break
    }
    if line.equal_to_bytes(b"FORMAT=32-bit_rle_rgbe") {
      format_seen = true
    } else if line.has_prefix(b"EXPOSURE=") {
      exposure = Some(line.clamped_view(start=9, end=line.length()))
    } else if line.has_prefix(b"GAMMA=") {
      gamma = Some(line.clamped_view(start=6, end=line.length()))
    }
  }
  if !format_seen {
    raise @raster.Unsupported(at=reader.at, got="a format other than RGBE")
  }
  let resolution = reader.line()
  let (width, height, flipped, backwards) = parse_resolution(
    resolution,
    reader.at,
  )
  limits.check(width, height)
  let count = width.to_int64() * height.to_int64()
  if count * 16L > limits.bytes.to_int64() {
    raise @raster.OverLimit(limit=limits.bytes, got=2_147_483_647)
  }
  let pixels : FixedArray[Byte] = FixedArray::make(count.to_int() * 16, b'\x00')
  let line_buffer : FixedArray[Byte] = FixedArray::make(width * 4, b'\x00')
  for row in 0..<height {
    read_scanline(reader, line_buffer, width)
    let y = if flipped { height - 1 - row } else { row }
    for column in 0..<width {
      let x = if backwards { width - 1 - column } else { column }
      let at = line_buffer[column * 4].to_int()
      let green = line_buffer[column * 4 + 1].to_int()
      let blue = line_buffer[column * 4 + 2].to_int()
      let exponent = line_buffer[column * 4 + 3].to_int()
      let (r, g, b) = to_float(at, green, blue, exponent)
      let to = y * width + x
      @raster.put_float(pixels, to * 16, r)
      @raster.put_float(pixels, to * 16 + 4, g)
      @raster.put_float(pixels, to * 16 + 8, b)
      @raster.put_float(pixels, to * 16 + 12, 1.0F)
    }
  }
  let image = @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::RgbaF32,
    Bytes::from_array(pixels.clamped_view()),
  )
  { ..image, metadata: with_header(image.metadata, exposure, gamma), }
}

///|
/// The two header lines that change what a sample means, kept as text so that
/// writing the picture back says the same.
fn with_header(
  metadata : @raster.Metadata,
  exposure : BytesView?,
  gamma : BytesView?,
) -> @raster.Metadata {
  let texts : Array[@raster.Text] = []
  for text in metadata.texts {
    texts.push(text)
  }
  match exposure {
    Some(value) =>
      texts.push(@raster.Text::Latin(keyword="EXPOSURE", text=ascii_of(value)))
    None => ()
  }
  match gamma {
    Some(value) =>
      texts.push(@raster.Text::Latin(keyword="GAMMA", text=ascii_of(value)))
    None => ()
  }
  { ..metadata, texts, }
}

///|
fn ascii_of(bytes : BytesView) -> String {
  let characters : Array[Char] = []
  for i in 0..<bytes.length() {
    characters.push(bytes[i].to_int().unsafe_to_char())
  }
  String::from_array(characters.clamped_view())
}

///|
/// The four ways the resolution line can put the origin, as (width, height,
/// whether the rows run bottom to top, whether the columns run right to left).
fn parse_resolution(
  line : BytesView,
  at : Int32,
) -> (Int32, Int32, Bool, Bool) raise @raster.Refused {
  let fields = split(line)
  if fields.length() != 4 {
    raise @raster.Unexpected(
      at~,
      got="a resolution line of \{fields.length()} fields",
      want="an axis, a length, an axis and a length",
    )
  }
  let first = fields[0]
  let second = fields[2]
  if first.length() != 2 || second.length() != 2 {
    raise @raster.Unexpected(at~, got="an axis", want="one of -Y, +Y, -X, +X")
  }
  let first_axis = first[1].to_int()
  let second_axis = second[1].to_int()
  if !(first_axis == 0x58 || first_axis == 0x59) ||
    !(second_axis == 0x58 || second_axis == 0x59) ||
    first_axis == second_axis {
    raise @raster.Unexpected(at~, got="an axis", want="one of -Y, +Y, -X, +X")
  }
  let first_count = parse_number(fields[1], at)
  let second_count = parse_number(fields[3], at)
  if first_count <= 0 || second_count <= 0 {
    raise @raster.Unexpected(
      at~,
      got="a size with no pixels",
      want="a width and a height above zero",
    )
  }
  let rows_first = first_axis == 0x59
  let width = if rows_first { second_count } else { first_count }
  let height = if rows_first { first_count } else { second_count }
  let rows_sign = first[0].to_int()
  let columns_sign = second[0].to_int()
  // `-Y` counts rows upwards from the bottom of the picture, so the first
  // scanline in the file is the top one and no flip is needed; `+Y` is the
  // reverse.
  let flipped = rows_sign == 0x2B
  let backwards = columns_sign == 0x2D
  (width, height, flipped, backwards)
}

///|
/// One scanline, either run-length coded the way revision 2 of the format does
/// it or as plain four-byte pixels the way a narrow picture must be.
fn read_scanline(
  reader : Reader,
  line : FixedArray[Byte],
  width : Int32,
) -> Unit raise @raster.Refused {
  let prefix = reader.peek(4)
  let coded = width >= 8 &&
    width < 32768 &&
    prefix[0].to_int() == 2 &&
    prefix[1].to_int() == 2 &&
    ((prefix[2].to_int() << 8) | prefix[3].to_int()) == width
  if !coded {
    let flat = reader.take(width * 4)
    for i in 0..<(width * 4) {
      line[i] = flat[i]
    }
    return
  }
  reader.skip(4)
  for component in 0..<4 {
    let mut column = 0
    while column < width {
      let count = reader.byte()
      if count > 128 {
        let value = reader.byte().to_byte()
        let run = count - 128
        if column + run > width {
          raise @raster.Unexpected(
            at=reader.at,
            got="a run past the end of the row",
            want="at most \{width - column} more samples",
          )
        }
        for _ in 0..<run {
          line[column * 4 + component] = value
          column = column + 1
        }
      } else {
        if count == 0 {
          raise @raster.Unexpected(
            at=reader.at,
            got="a run of none",
            want="a run",
          )
        }
        if column + count > width {
          raise @raster.Unexpected(
            at=reader.at,
            got="a run past the end of the row",
            want="at most \{width - column} more samples",
          )
        }
        for _ in 0..<count {
          line[column * 4 + component] = reader.byte().to_byte()
          column = column + 1
        }
      }
    }
  }
}

///|
/// Three mantissas and a shared exponent as three floats.
///
/// The half added to each mantissa is what the format's own reader does: a
/// mantissa is the top eight bits of a fraction, so its middle is half a step
/// above the value it names, and adding it makes an encoded value round back to
/// itself instead of always downwards.
fn to_float(
  r : Int32,
  g : Int32,
  b : Int32,
  exponent : Int32,
) -> (Float, Float, Float) {
  if exponent == 0 {
    return (0.0F, 0.0F, 0.0F)
  }
  let scale = power_of_two(exponent - 136)
  (
    Float::from_double((r.to_double() + 0.5) * scale),
    Float::from_double((g.to_double() + 0.5) * scale),
    Float::from_double((b.to_double() + 0.5) * scale),
  )
}

///|
/// Two to the given power, for the range an exponent byte can name.
fn power_of_two(power : Int32) -> Double {
  let mut value = 1.0
  if power > 0 {
    for _ in 0..<(if power > 128 { 128 } else { power }) {
      value = value * 2.0
    }
  } else {
    for _ in 0..<(if power < -128 { 128 } else { -power }) {
      value = value / 2.0
    }
  }
  value
}

///|
/// The image as Radiance HDR bytes.
///
/// The picture is converted to floats first, so an eight-bit source keeps its
/// values exactly and a float source keeps its range.
pub fn encode(image : @raster.Image) -> Bytes {
  let floats = image.convert(@raster.PixelFormat::RgbaF32)
  let writer = @wire.Writer::new()
  writer.bytes(b"#?RADIANCE\n")
  writer.bytes(b"FORMAT=32-bit_rle_rgbe\n")
  for text in image.metadata.texts {
    let keyword = text.keyword()
    if keyword == "EXPOSURE" || keyword == "GAMMA" {
      writer.bytes(utf8_of(keyword))
      writer.u8(0x3D)
      writer.bytes(utf8_of(text.text()))
      writer.u8(0x0A)
    }
  }
  writer.u8(0x0A)
  writer.bytes(b"-Y ")
  number(writer, floats.height)
  writer.bytes(b" +X ")
  number(writer, floats.width)
  writer.u8(0x0A)
  let line : FixedArray[Byte] = FixedArray::make(floats.width * 4, b'\x00')
  let coded = floats.width >= 8 && floats.width < 32768
  for y in 0..<floats.height {
    for x in 0..<floats.width {
      let at = y * floats.stride + x * 16
      let r = @raster.float_at(floats.pixels, at)
      let g = @raster.float_at(floats.pixels, at + 4)
      let b = @raster.float_at(floats.pixels, at + 8)
      let (rm, gm, bm, exponent) = to_rgbe(r, g, b)
      line[x * 4] = rm.to_byte()
      line[x * 4 + 1] = gm.to_byte()
      line[x * 4 + 2] = bm.to_byte()
      line[x * 4 + 3] = exponent.to_byte()
    }
    if coded {
      write_coded(writer, line, floats.width)
    } else {
      for i in 0..<(floats.width * 4) {
        writer.u8(line[i].to_int())
      }
    }
  }
  writer.to_bytes()
}

///|
/// One scanline in the format's own run-length code: four planes, each a run of
/// repeated samples or a run of distinct ones.
fn write_coded(
  writer : @wire.Writer,
  line : FixedArray[Byte],
  width : Int32,
) -> Unit {
  writer.u8(2)
  writer.u8(2)
  writer.u8((width >> 8) & 0xFF)
  writer.u8(width & 0xFF)
  for component in 0..<4 {
    let mut column = 0
    while column < width {
      let value = line[column * 4 + component].to_int()
      let mut run = 1
      while column + run < width &&
            run < 127 &&
            line[(column + run) * 4 + component].to_int() == value {
        run = run + 1
      }
      if run >= 3 {
        writer.u8(128 + run)
        writer.u8(value)
        column = column + run
      } else {
        // A run of distinct samples, gathered until a repeat of three shows up.
        let start = column
        let mut fresh = 0
        while column < width && fresh < 128 {
          if column + 2 < width &&
            line[(column + 1) * 4 + component].to_int() ==
            line[column * 4 + component].to_int() &&
            line[(column + 2) * 4 + component].to_int() ==
            line[column * 4 + component].to_int() {
            break
          }
          column = column + 1
          fresh = fresh + 1
        }
        writer.u8(fresh)
        for i in start..<column {
          writer.u8(line[i * 4 + component].to_int())
        }
      }
    }
  }
}

///|
/// A float colour as three mantissas and a shared exponent.
fn to_rgbe(r : Float, g : Float, b : Float) -> (Int32, Int32, Int32, Int32) {
  let red = r.to_double()
  let green = g.to_double()
  let blue = b.to_double()
  let mut brightest = red
  if green > brightest {
    brightest = green
  }
  if blue > brightest {
    brightest = blue
  }
  if brightest < 1.0e-32 {
    return (0, 0, 0, 0)
  }
  // The mantissa is `brightest` scaled into [0.5, 1) and the exponent counts
  // how many doublings that took; the byte carries the exponent biased by 128.
  let mut mantissa = brightest
  let mut exponent = 0
  while mantissa >= 1.0 {
    mantissa = mantissa / 2.0
    exponent = exponent + 1
  }
  while mantissa < 0.5 {
    mantissa = mantissa * 2.0
    exponent = exponent - 1
  }
  if exponent < -128 || exponent > 127 {
    return (0, 0, 0, 0)
  }
  let scale = mantissa * 256.0 / brightest
  (
    clamp_byte((red * scale).to_int()),
    clamp_byte((green * scale).to_int()),
    clamp_byte((blue * scale).to_int()),
    exponent + 128,
  )
}

///|
fn clamp_byte(value : Int32) -> Int32 {
  if value < 0 {
    0
  } else if value > 255 {
    255
  } else {
    value
  }
}

///|
fn utf8_of(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
fn number(writer : @wire.Writer, value : Int32) -> Unit {
  if value == 0 {
    writer.u8(0x30)
    return
  }
  let digits : Array[Byte] = []
  let mut rest = value
  while rest > 0 {
    digits.push((0x30 + rest % 10).to_byte())
    rest = rest / 10
  }
  for i in 0..<digits.length() {
    writer.u8(digits[digits.length() - 1 - i].to_int())
  }
}

///|
fn split(line : BytesView) -> Array[BytesView] {
  let fields : Array[BytesView] = []
  let mut start = 0
  for i in 0..<line.length() {
    let code = line[i].to_int()
    if code == 0x20 || code == 0x09 {
      if i > start {
        fields.push(line[start:i])
      }
      start = i + 1
    }
  }
  if line.length() > start {
    fields.push(line[start:line.length()])
  }
  fields
}

///|
fn parse_number(text : BytesView, at : Int32) -> Int32 raise @raster.Refused {
  if text.length() == 0 {
    raise @raster.Truncated(at~, want=1)
  }
  let mut value : Int64 = 0L
  for i in 0..<text.length() {
    let code = text[i].to_int()
    if code < 0x30 || code > 0x39 {
      raise @raster.Unexpected(at~, got="a length", want="digits")
    }
    value = value * 10L + (code - 0x30).to_int64()
    if value > 2_147_483_647L {
      raise @raster.Unexpected(at~, got="a length", want="a 32-bit value")
    }
  }
  value.to_int()
}

///|
/// A reader over the header lines and the bytes that follow them.
priv struct Reader {
  data : BytesView
  mut at : Int32
}

///|
fn Reader::new(data : BytesView) -> Reader {
  { data, at: 0, }
}

///|
fn Reader::line(self : Reader) -> BytesView raise @raster.Refused {
  let start = self.at
  while self.at < self.data.length() {
    if self.data[self.at].to_int() == 0x0A {
      let text = self.data[start:self.at]
      self.at = self.at + 1
      return text
    }
    self.at = self.at + 1
  }
  // A file that ends without a blank line is still readable if the resolution
  // line was the last one; anything else is truncated.
  if start > 0 {
    let text = self.data[start:self.data.length()]
    self.at = self.data.length()
    return text
  }
  raise @raster.Truncated(at=start, want=1)
}

///|
fn Reader::peek(
  self : Reader,
  count : Int32,
) -> BytesView raise @raster.Refused {
  if self.at + count > self.data.length() {
    raise @raster.Truncated(at=self.at, want=count)
  }
  self.data[self.at:self.at + count]
}

///|
fn Reader::take(
  self : Reader,
  count : Int32,
) -> BytesView raise @raster.Refused {
  let bytes = self.peek(count)
  self.at = self.at + count
  bytes
}

///|
fn Reader::skip(self : Reader, count : Int32) -> Unit raise @raster.Refused {
  ignore(self.take(count))
  ()
}

///|
fn Reader::byte(self : Reader) -> Int32 raise @raster.Refused {
  let one = self.take(1)
  one[0].to_int()
}
