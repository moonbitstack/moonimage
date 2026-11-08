// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The portable anymap: seven formats that share a parser.
//
// PBM holds one bit per pixel, PGM one sample, PPM three, and PAM any number
// from one to four with a header that says which. All seven begin with a
// two-character signature, then a run of ASCII numbers separated by whitespace
// and `#` comments; the six that are not PAM then follow with either ASCII
// digits or raw samples, which is the only difference the signature carries.
//
// Two rules of the family are worth stating because they trip up readers. The
// first is that in a bit map one is black and nought is white, the opposite of
// every other sample here. The second is that a row of a bit map is padded to a
// byte boundary, so the row stride of P4 is not the width divided by eight when
// the width is not a multiple of eight.

///|
/// The image in these bytes.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  let reader = Reader::new(bytes)
  let kind = reader.magic()
  if kind == 7 {
    return decode_pam(reader, limits)
  }
  let width = reader.number()
  let height = reader.number()
  let maxval = if kind == 1 || kind == 4 { 1 } else { reader.number() }
  if width <= 0 || height <= 0 {
    raise @raster.Unexpected(
      at=reader.at,
      got="a size with no pixels",
      want="a width and a height above zero",
    )
  }
  limits.check(width, height)
  if maxval < 1 || maxval > 65535 {
    raise @raster.Unexpected(
      at=reader.at,
      got="a maximum of \{maxval}",
      want="one to sixty-five thousand five hundred and thirty-five",
    )
  }
  let bits = if maxval < 256 { 8 } else { 16 }
  match kind {
    1 | 2 | 3 => decode_ascii(reader, kind, width, height, maxval, limits)
    4 => decode_bits(reader, width, height, limits)
    _ => decode_raw(reader, kind, width, height, maxval, bits, limits)
  }
}

///|
/// PBM, read as black and white samples: a set bit is black.
fn decode_bits(
  reader : Reader,
  width : Int32,
  height : Int32,
  limits : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let stride = (width + 7) / 8
  let needed = stride.to_int64() * height.to_int64()
  if needed > limits.bytes.to_int64() {
    raise @raster.OverLimit(limit=limits.bytes, got=2_147_483_647)
  }
  let body = reader.rest()
  if body.length().to_int64() < needed {
    raise @raster.Truncated(
      at=reader.at,
      want=(needed - body.length().to_int64()).to_int(),
    )
  }
  let pixels : FixedArray[Byte] = FixedArray::make(width * height, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let byte = body[y * stride + x / 8].to_int()
      let bit = (byte >> (7 - x % 8)) & 1
      pixels[y * width + x] = (if bit == 1 { 0 } else { 255 }).to_byte()
    }
  }
  @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::Gray8,
    Bytes::from_array(pixels.clamped_view()),
  )
}

///|
/// P1, P2 or P3: the samples as decimal numbers.
fn decode_ascii(
  reader : Reader,
  kind : Int32,
  width : Int32,
  height : Int32,
  maxval : Int32,
  limits : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let channels = if kind == 3 { 3 } else { 1 }
  let count = width.to_int64() * height.to_int64() * channels.to_int64()
  if count * 4L > limits.bytes.to_int64() {
    raise @raster.OverLimit(limit=limits.bytes, got=2_147_483_647)
  }
  let total = count.to_int()
  let pixels : FixedArray[Byte] = FixedArray::make(total, b'\x00')
  if kind == 1 {
    for i in 0..<total {
      let bit = reader.number()
      pixels[i] = (if bit != 0 { 0 } else { 255 }).to_byte()
    }
  } else {
    for i in 0..<total {
      let value = reader.number()
      if value < 0 || value > maxval {
        raise @raster.Unexpected(
          at=reader.at,
          got="a sample of \{value}",
          want="nought to \{maxval}",
        )
      }
      pixels[i] = to_byte(value, maxval).to_byte()
    }
  }
  let format = if channels == 3 {
    @raster.PixelFormat::Rgb8
  } else {
    @raster.PixelFormat::Gray8
  }
  @raster.Image::of(
    width,
    height,
    format,
    Bytes::from_array(pixels.clamped_view()),
  )
}

///|
/// P5 or P6: one or two bytes per sample, big-endian.
fn decode_raw(
  reader : Reader,
  kind : Int32,
  width : Int32,
  height : Int32,
  maxval : Int32,
  bits : Int32,
  limits : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let channels = if kind == 6 { 3 } else { 1 }
  let count = width.to_int64() * height.to_int64() * channels.to_int64()
  let sample_bytes = if bits == 8 { 1 } else { 2 }
  let needed = count * sample_bytes.to_int64()
  if needed > limits.bytes.to_int64() {
    raise @raster.OverLimit(limit=limits.bytes, got=2_147_483_647)
  }
  let body = reader.rest()
  if body.length().to_int64() < needed {
    raise @raster.Truncated(
      at=reader.at,
      want=(needed - body.length().to_int64()).to_int(),
    )
  }
  let format = match (channels, bits) {
    (3, 8) => @raster.PixelFormat::Rgb8
    (3, 16) => @raster.PixelFormat::Rgb16
    (1, 8) => @raster.PixelFormat::Gray8
    _ => @raster.PixelFormat::Gray16
  }
  let total = count.to_int()
  let full = if bits == 8 { maxval == 255 } else { maxval == 65535 }
  if full {
    let pixels : FixedArray[Byte] = FixedArray::make(needed.to_int(), b'\x00')
    for i in 0..<needed.to_int() {
      pixels[i] = body[i]
    }
    return @raster.Image::of(
      width,
      height,
      format,
      Bytes::from_array(pixels.clamped_view()),
    )
  }
  // A maximum that is not the full range means every sample is a fraction of
  // it, so the samples are rescaled to the full range of the layout.
  let pixels : FixedArray[Byte] = FixedArray::make(needed.to_int(), b'\x00')
  for i in 0..<total {
    if bits == 8 {
      let value = body[i].to_int()
      if value > maxval {
        raise @raster.Unexpected(
          at=reader.at + i,
          got="a sample of \{value}",
          want="nought to \{maxval}",
        )
      }
      pixels[i] = to_byte(value, maxval).to_byte()
    } else {
      let value = body[i * 2].to_int() * 256 + body[i * 2 + 1].to_int()
      if value > maxval {
        raise @raster.Unexpected(
          at=reader.at + i * 2,
          got="a sample of \{value}",
          want="nought to \{maxval}",
        )
      }
      let scaled = to_word(value, maxval)
      pixels[i * 2] = ((scaled >> 8) & 0xFF).to_byte()
      pixels[i * 2 + 1] = (scaled & 0xFF).to_byte()
    }
  }
  @raster.Image::of(
    width,
    height,
    format,
    Bytes::from_array(pixels.clamped_view()),
  )
}

///|
/// P7, the one with a header of its own.
fn decode_pam(
  reader : Reader,
  limits : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let mut width = 0
  let mut height = 0
  let mut depth = 0
  let mut maxval = 0
  while true {
    let line = reader.line()
    let text = trim(line)
    if text.equal_to_bytes(b"ENDHDR") {
      break
    }
    if text.length() == 0 || text[0].to_int() == 0x23 {
      continue
    }
    let key = field(line, 0)
    let value = field(line, 1)
    if key.equal_to_bytes(b"WIDTH") {
      width = parse_number(value, reader.at)
    } else if key.equal_to_bytes(b"HEIGHT") {
      height = parse_number(value, reader.at)
    } else if key.equal_to_bytes(b"DEPTH") {
      depth = parse_number(value, reader.at)
    } else if key.equal_to_bytes(b"MAXVAL") {
      maxval = parse_number(value, reader.at)
    }
  }
  if width <= 0 || height <= 0 || depth < 1 || depth > 4 {
    raise @raster.Unexpected(
      at=reader.at,
      got="a header of \{width} by \{height} by \{depth}",
      want="a size above zero and one to four channels",
    )
  }
  if maxval < 1 || maxval > 65535 {
    raise @raster.Unexpected(
      at=reader.at,
      got="a maximum of \{maxval}",
      want="one to sixty-five thousand five hundred and thirty-five",
    )
  }
  limits.check(width, height)
  let shape = match depth {
    1 => @raster.PixelFormat::Gray8
    2 => @raster.PixelFormat::GrayAlpha8
    3 => @raster.PixelFormat::Rgb8
    _ => @raster.PixelFormat::Rgba8
  }
  let wide = maxval > 255
  let format = if wide { widen(shape) } else { shape }
  let sample_bytes = if wide { 2 } else { 1 }
  let count = width.to_int64() * height.to_int64() * depth.to_int64()
  let needed = count * sample_bytes.to_int64()
  if needed > limits.bytes.to_int64() {
    raise @raster.OverLimit(limit=limits.bytes, got=2_147_483_647)
  }
  // PAM's samples follow the last header line's newline with nothing in
  // between, unlike the other six kinds, which have one space.
  let body = reader.data.clamped_view(start=reader.at, end=reader.data.length())
  if body.length().to_int64() < needed {
    raise @raster.Truncated(
      at=reader.at,
      want=(needed - body.length().to_int64()).to_int(),
    )
  }
  let total = count.to_int()
  let pixels : FixedArray[Byte] = FixedArray::make(needed.to_int(), b'\x00')
  let full = if wide { maxval == 65535 } else { maxval == 255 }
  if full {
    for i in 0..<needed.to_int() {
      pixels[i] = body[i]
    }
  } else {
    for i in 0..<total {
      if wide {
        let value = body[i * 2].to_int() * 256 + body[i * 2 + 1].to_int()
        if value > maxval {
          raise @raster.Unexpected(
            at=reader.at + i * 2,
            got="a sample of \{value}",
            want="nought to \{maxval}",
          )
        }
        let scaled = to_word(value, maxval)
        pixels[i * 2] = ((scaled >> 8) & 0xFF).to_byte()
        pixels[i * 2 + 1] = (scaled & 0xFF).to_byte()
      } else {
        let value = body[i].to_int()
        if value > maxval {
          raise @raster.Unexpected(
            at=reader.at + i,
            got="a sample of \{value}",
            want="nought to \{maxval}",
          )
        }
        pixels[i] = to_byte(value, maxval).to_byte()
      }
    }
  }
  @raster.Image::of(
    width,
    height,
    format,
    Bytes::from_array(pixels.clamped_view()),
  )
}

///|
/// The sixteen-bit layout with the same shape as an eight-bit one.
fn widen(format : @raster.PixelFormat) -> @raster.PixelFormat {
  match format {
    @raster.PixelFormat::Gray8 => @raster.PixelFormat::Gray16
    @raster.PixelFormat::GrayAlpha8 => @raster.PixelFormat::GrayAlpha16
    @raster.PixelFormat::Rgb8 => @raster.PixelFormat::Rgb16
    _ => @raster.PixelFormat::Rgba16
  }
}

///|
/// A sample out of `maxval` as a byte out of 255, rounded.
fn to_byte(value : Int32, maxval : Int32) -> Int32 {
  if maxval == 255 {
    return value
  }
  (value.to_int64() * 255L + maxval.to_int64() / 2L).to_int() / maxval
}

///|
/// A sample out of `maxval` as a word out of 65535, rounded.
fn to_word(value : Int32, maxval : Int32) -> Int32 {
  if maxval == 65535 {
    return value
  }
  (value.to_int64() * 65535L + maxval.to_int64() / 2L).to_int() / maxval
}

///|
/// A reader over ASCII numbers, which is what the portable family is made of.
///
/// Kept separate from `Cursor` because the tokens are variable length and the
/// separators are three kinds of whitespace plus comments.
priv struct Reader {
  data : BytesView
  mut at : Int32
}

///|
fn Reader::new(data : BytesView) -> Reader {
  { data, at: 0, }
}

///|
/// Which of the seven formats this is.
fn Reader::magic(self : Reader) -> Int32 raise @raster.Refused {
  if self.data.length() < 2 || self.data[0].to_int() != 0x50 {
    raise @raster.Unknown(at=0, got=@raster.hex(self.data, 0, 8))
  }
  let kind = self.data[1].to_int() - 0x30
  if kind < 1 || kind > 7 {
    raise @raster.Unknown(at=0, got=@raster.hex(self.data, 0, 8))
  }
  self.at = 2
  kind
}

///|
/// The next run of non-space, non-comment bytes.
fn Reader::token(self : Reader) -> BytesView raise @raster.Refused {
  self.skip_space()
  let start = self.at
  while self.at < self.data.length() {
    let byte = self.data[self.at].to_int()
    if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
      break
    }
    self.at = self.at + 1
  }
  if self.at == start {
    raise @raster.Truncated(at=start, want=1)
  }
  self.data[start:self.at]
}

///|
/// The next number, which must be one.
fn Reader::number(self : Reader) -> Int32 raise @raster.Refused {
  parse_number(self.token(), self.at)
}

///|
/// Everything that is left, past exactly one whitespace byte.
///
/// One, not as much as there is: a reader that skipped all of it would eat a
/// first sample that happens to be nought, which is a black corner and a file
/// that decodes one pixel short.
fn Reader::rest(self : Reader) -> BytesView raise @raster.Refused {
  if self.at >= self.data.length() {
    raise @raster.Truncated(at=self.at, want=1)
  }
  let byte = self.data[self.at].to_int()
  if byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D {
    raise @raster.Unexpected(
      at=self.at,
      got="more header",
      want="a single space before the samples",
    )
  }
  self.at = self.at + 1
  self.data.clamped_view(start=self.at, end=self.data.length())
}

///|
/// One line, without its terminator.
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
  raise @raster.Truncated(at=start, want=1)
}

///|
/// Past whitespace and comments.
fn Reader::skip_space(self : Reader) -> Unit {
  while self.at < self.data.length() {
    let byte = self.data[self.at].to_int()
    if byte == 0x23 {
      while self.at < self.data.length() && self.data[self.at].to_int() != 0x0A {
        self.at = self.at + 1
      }
    } else if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
      self.at = self.at + 1
    } else {
      break
    }
  }
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
      raise @raster.Unexpected(
        at~,
        got="a token that is not a number",
        want="digits",
      )
    }
    value = value * 10L + (code - 0x30).to_int64()
    if value > 2_147_483_647L {
      raise @raster.Unexpected(
        at~,
        got="a number too large to keep",
        want="a 32-bit value",
      )
    }
  }
  value.to_int()
}

///|
/// A line without its trailing blanks.
fn trim(line : BytesView) -> BytesView {
  let mut start = 0
  let mut end = line.length()
  while start < end {
    let code = line[start].to_int()
    if code == 0x20 || code == 0x09 || code == 0x0D {
      start = start + 1
    } else {
      break
    }
  }
  while end > start {
    let code = line[end - 1].to_int()
    if code == 0x20 || code == 0x09 || code == 0x0D {
      end = end - 1
    } else {
      break
    }
  }
  line[start:end]
}

///|
/// The `index`th blank-separated field of a header line.
fn field(line : BytesView, index : Int32) -> BytesView {
  let mut start = 0
  let mut seen = 0
  let mut i = 0
  while i <= line.length() {
    let at_end = i == line.length()
    let blank = !at_end &&
      (line[i].to_int() == 0x20 || line[i].to_int() == 0x09)
    if at_end || blank {
      if i > start {
        if seen == index {
          return line[start:i]
        }
        seen = seen + 1
      }
      start = i + 1
    }
    i = i + 1
  }
  line.clamped_view(start=line.length(), end=line.length())
}
