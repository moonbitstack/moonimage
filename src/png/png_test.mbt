// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// PNG against PngSuite, and the writer against the reader.
//
// PngSuite is the format's own test suite: 175 files, every colour type at every
// depth it allows, interlaced and not, with palettes, transparency and gamma,
// and fourteen files that are deliberately broken. The suite publishes a
// reference decoding of each valid file, which is what the digest here is.

///|
/// The digest the fixtures were generated with: FNV-1a, sixty-four bits, as
/// sixteen hexadecimal digits.
fn digest(bytes : BytesView) -> String {
  let mut value : UInt64 = 0xCBF29CE484222325
  for index in 0..<bytes.length() {
    value = (value ^ bytes[index].to_int().to_uint64()) * 0x100000001B3
  }
  let digits = "0123456789abcdef"
  let mut out = ""
  for index in 0..<16 {
    let shift = (15 - index) * 4
    let nibble = (value >> shift).to_int() & 0xF
    out = out + digits[nibble:nibble + 1].to_owned()
  }
  out
}

///|
fn read(bytes : Bytes) -> @raster.Image {
  @png.decode(bytes) catch {
    error => abort("the fixture should decode: \{error}")
  }
}

///|
fn refuses(bytes : Bytes) -> Bool {
  try {
    ignore(@png.decode(bytes))
    false
  } catch {
    _ => true
  }
}

///|
fn pixels_of(image : @raster.Image) -> Bytes {
  image.convert(@raster.PixelFormat::Rgba16).pixels
}

///|
/// One file of the suite, by name.
fn suite_file(name : String) -> Bytes {
  for entry in png_suite {
    if entry.0 == name {
      return entry.1
    }
  }
  abort("PngSuite has no file called \{name}")
}

///|
/// The reference digest for one file of the suite.
fn suite_expected(name : String) -> String {
  for entry in png_suite_expected {
    if entry.0 == name {
      return entry.1
    }
  }
  abort("PngSuite has no reference for \{name}")
}

///|
test "pngsuite: every valid image decodes to the reference pixels" {
  for entry in png_suite {
    let (name, file) = entry
    let image = read(file)
    assert_eq(digest(pixels_of(image)), suite_expected(name), msg=name)
  }
}

///|
test "pngsuite: every invalid image is refused" {
  for entry in png_suite_invalid {
    let (name, file) = entry
    assert_true(refuses(file), msg=name)
  }
}

///|
test "pngsuite: the shape and the format of a few files are what the header says" {
  let grey = read(suite_file("basn0g01"))
  assert_eq(grey.format, @raster.PixelFormat::Gray8)
  assert_eq(grey.width, 32)
  let colour = read(suite_file("basn2c16"))
  assert_eq(colour.format, @raster.PixelFormat::Rgb16)
  let palette = read(suite_file("basn3p08"))
  assert_eq(palette.format, @raster.PixelFormat::Rgb8)
  let alpha = read(suite_file("basn6a08"))
  assert_eq(alpha.format, @raster.PixelFormat::Rgba8)
  let transparent = read(suite_file("tbwn3p08"))
  assert_eq(transparent.format, @raster.PixelFormat::Rgba8)
}

///|
test "pngsuite: gamma and primaries are read out of the file" {
  let image = read(suite_file("g10n2c08"))
  let gamma = match image.metadata.gamma {
    Some(gamma) => gamma
    None => abort("the file has a gAMA chunk")
  }
  assert_true(gamma > 0.0 && gamma < 3.0)
  let primaries = read(suite_file("ccwn2c08"))
  assert_true(primaries.metadata.chromaticities is Some(_))
}

///|
test "png: what the writer writes, the reader reads back" {
  let source = read(suite_file("basn6a08"))
  for
    format in [
      @raster.PixelFormat::Gray8,
      @raster.PixelFormat::GrayAlpha8,
      @raster.PixelFormat::Rgb8,
      @raster.PixelFormat::Rgba8,
      @raster.PixelFormat::Gray16,
      @raster.PixelFormat::GrayAlpha16,
      @raster.PixelFormat::Rgb16,
      @raster.PixelFormat::Rgba16,
    ] {
    let picture = source.convert(format)
    let back = read(
      @png.encode(picture, options=@png.EncodeOptions::{
        level: 6,
        filter: @png.Filter::Adaptive,
        interlace: false,
        metadata: true,
        palette: false,
      }),
    )
    assert_eq(back.format, format)
    assert_eq(back.width, picture.width)
    assert_eq(back.height, picture.height)
    assert_eq(back.pixels, picture.pixels)
  }
  // A float image is written as sixteen bits, because that is the most a PNG can
  // hold, and comes back as such.
  let floats = source.convert(@raster.PixelFormat::RgbaF32)
  let back = read(@png.encode(floats))
  assert_eq(back.format, @raster.PixelFormat::Rgba16)
  assert_eq(back.pixels, floats.convert(@raster.PixelFormat::Rgba16).pixels)
}

///|
test "png: every filter, every level and interlacing write the same pixels" {
  let picture = read(suite_file("basn2c08"))
  for
    filter in [
      @png.Filter::Adaptive,
      @png.Filter::None,
      @png.Filter::Sub,
      @png.Filter::Up,
      @png.Filter::Average,
      @png.Filter::Paeth,
    ] {
    for level in [0, 1, 6, 9] {
      for interlace in [false, true] {
        let file = @png.encode(picture, options=@png.EncodeOptions::{
          level,
          filter,
          interlace,
          metadata: true,
          palette: false,
        })
        let back = read(file)
        assert_eq(back.pixels, picture.pixels)
        assert_eq(back.metadata.gamma, picture.metadata.gamma)
      }
    }
  }
}

///|
test "png: the metadata a file was given is the metadata it comes back with" {
  let picture = read(suite_file("basn2c08"))
  let annotated = @raster.Image::of(
    picture.width,
    picture.height,
    picture.format,
    picture.pixels,
    metadata=@raster.Metadata::{
      gamma: Some(0.45455),
      chromaticities: Some(@raster.Chromaticities::srgb()),
      intent: Some(@raster.Intent::Relative),
      icc: Some(@raster.Icc::{ name: "test", profile: b"\x00\x01\x02\x03", }),
      texts: [
        @raster.Text::Latin(keyword="Title", text="a picture"),
        @raster.Text::Compressed(keyword="Comment", text="a longer note"),
        @raster.Text::International(
          keyword="Description",
          language="en",
          translated="a description",
          text="with an accent: café",
        ),
      ],
    },
  )
  let back = read(@png.encode(annotated))
  assert_eq(back.metadata.gamma, Some(0.45455))
  assert_eq(back.metadata.chromaticities, Some(@raster.Chromaticities::srgb()))
  assert_eq(back.metadata.intent, Some(@raster.Intent::Relative))
  assert_eq(
    back.metadata.icc,
    Some(@raster.Icc::{ name: "test", profile: b"\x00\x01\x02\x03", }),
  )
  assert_eq(back.metadata.texts.length(), 3)
  assert_eq(back.metadata.texts[0].keyword(), "Title")
  assert_eq(back.metadata.texts[0].text(), "a picture")
  assert_eq(back.metadata.texts[1].text(), "a longer note")
  assert_eq(back.metadata.texts[2].keyword(), "Description")
  assert_eq(back.metadata.texts[2].text(), "with an accent: café")
}

///|
test "png: an animation keeps its frames, delays and rules" {
  let red = @raster.Image::of(
    4,
    4,
    @raster.PixelFormat::Rgba8,
    Bytes::repeat(b"\xff\x00\x00\xff", 16),
  )
  let dot = @raster.Image::of(
    1,
    1,
    @raster.PixelFormat::Rgba8,
    b"\x00\xff\x00\x80",
  )
  let animation = @raster.Animation::new(
    4,
    4,
    [
      @raster.Frame::new(red, delay=120, dispose=@raster.Dispose::Keep),
      @raster.Frame::new(
        dot,
        x=2,
        y=2,
        delay=80,
        dispose=@raster.Dispose::Background,
        blend=@raster.Blend::Over,
      ),
      @raster.Frame::new(
        dot,
        x=0,
        y=0,
        delay=40,
        dispose=@raster.Dispose::Previous,
        blend=@raster.Blend::Source,
      ),
    ],
    loops=3,
  )
  let file = @png.encode_animation(animation)
  let back = animate(file)
  assert_eq(back.width, 4)
  assert_eq(back.height, 4)
  assert_eq(back.loops, 3)
  assert_eq(back.frames.length(), 3)
  assert_eq(back.frames[0].delay, 120)
  assert_eq(back.frames[1].delay, 80)
  assert_eq(back.frames[1].dispose, @raster.Dispose::Background)
  assert_eq(back.frames[1].blend, @raster.Blend::Over)
  assert_eq(back.frames[2].dispose, @raster.Dispose::Previous)
  // The composed pictures are the ones the frames described.
  let before = animation.compose()
  let after = back.compose()
  for index in 0..<3 {
    assert_eq(
      after[index].convert(@raster.PixelFormat::Rgba8).pixels,
      before[index].convert(@raster.PixelFormat::Rgba8).pixels,
    )
  }
}

///|
test "png: a still image decodes as an animation of one frame" {
  let picture = read(suite_file("basn0g04"))
  let animation = animate(suite_file("basn0g04"))
  assert_eq(animation.frames.length(), 1)
  assert_eq(animation.width, picture.width)
  assert_eq(animation.frames[0].image.pixels, picture.pixels)
}

///|
test "png: damage is refused rather than decoded into half a picture" {
  let file = suite_file("basn2c08")
  // A byte flipped inside the compressed data fails its CRC.
  let broken : FixedArray[Byte] = FixedArray::make(file.length(), b'\x00')
  broken.blit_from_bytesview(0, file)
  broken[60] = (broken[60].to_int() ^ 0xFF).to_byte()
  assert_true(refuses(Bytes::from_array(broken.clamped_view())))
  // So does a file that stops in the middle.
  assert_true(
    refuses(file.clamped_view(start=0, end=file.length() / 2).to_owned()),
  )
  // And one with a byte taken out of the middle.
  let spliced = @buffer.Buffer::Buffer()
  spliced.write_bytesview(file.clamped_view(start=0, end=40))
  spliced.write_bytesview(file.clamped_view(start=41, end=file.length()))
  assert_true(refuses(spliced.to_bytes()))
  // A file that is not a PNG at all.
  assert_true(refuses(b"GIF89a and then some"))
}

///|
test "png: the limits are checked before anything is allocated" {
  let file = suite_file("basn2c08")
  let tight : @raster.Limits = {
    width: 16,
    height: 16,
    pixels: 256,
    bytes: 4_096,
  }
  let refused = try {
    ignore(@png.decode(file, limits=tight))
    false
  } catch {
    @raster.Refused::OverLimit(..) => true
    _ => false
  }
  assert_true(refused)
}

///|
test "png: a file with an unknown critical chunk is refused, an ancillary one skipped" {
  let file = suite_file("basn0g08")
  // Everything up to IEND, then a chunk nobody knows, then IEND itself.
  let body = @wire.Writer::new()
  body.bytes(file.clamped_view(start=0, end=file.length() - 12))
  // Lower case first letter: ancillary, and a reader may skip it.
  body.bytes(chunk(b"zzZz", b"\x01\x02\x03"))
  body.bytes(file.clamped_view(start=file.length() - 12, end=file.length()))
  assert_true(!refuses(body.to_bytes()))
  // Upper case first letter: critical, and unknown, so there is no honest way to
  // carry on.
  let critical = @wire.Writer::new()
  critical.bytes(file.clamped_view(start=0, end=file.length() - 12))
  critical.bytes(chunk(b"ZzZz", b"\x01\x02\x03"))
  critical.bytes(file.clamped_view(start=file.length() - 12, end=file.length()))
  assert_true(refuses(critical.to_bytes()))
}

///|
fn animate(file : Bytes) -> @raster.Animation {
  @png.decode_animation(file) catch {
    error => abort("the animation should decode: \{error}")
  }
}

///|
/// A chunk with its CRC, for the tests that build a file by hand.
fn chunk(kind : Bytes, data : Bytes) -> Bytes {
  let out = @wire.Writer::new()
  out.u32_be(data.length())
  out.bytes(kind)
  out.bytes(data)
  let mut crc = 0xFFFF_FFFFU
  for index in 0..<4 {
    crc = crc_byte(crc, kind[index].to_int())
  }
  for index in 0..<data.length() {
    crc = crc_byte(crc, data[index].to_int())
  }
  out.u32_be((crc ^ 0xFFFF_FFFFU).reinterpret_as_int())
  out.to_bytes()
}

///|
fn crc_byte(value : UInt32, byte : Int32) -> UInt32 {
  let mut crc = value ^ byte.reinterpret_as_uint()
  for _ in 0..<8 {
    crc = if (crc & 1U) != 0U { (crc >> 1) ^ 0xEDB8_8320U } else { crc >> 1 }
  }
  crc
}

///|
/// Whether the file has a chunk of this name, which is how a test sees which
/// colour type the writer chose.
fn has_chunk(file : Bytes, name : String) -> Bool {
  let mut index = 8
  while index + 8 <= file.length() {
    let mut kind = ""
    for offset in 0..<4 {
      kind = kind +
        file[index + 4 + offset].to_int().unsafe_to_char().to_string()
    }
    if kind == name {
      return true
    }
    let length = file[index].to_int() * 16_777_216 +
      file[index + 1].to_int() * 65_536 +
      file[index + 2].to_int() * 256 +
      file[index + 3].to_int()
    index = index + 12 + length
  }
  false
}

///|
/// A picture with `count` colours and a transparent corner.
fn few_colours_sized(count : Int32, size : Int32) -> @raster.Image {
  let out = @buffer.Buffer::Buffer()
  for y in 0..<size {
    for x in 0..<size {
      let index = (x + y) % count
      out.write_byte((index * 37 % 256).to_byte())
      out.write_byte((index * 91 % 256).to_byte())
      out.write_byte((index * 53 % 256).to_byte())
      out.write_byte(if x < 4 && y < 4 { 0 } else { 255 })
    }
  }
  @raster.Image::of(size, size, @raster.PixelFormat::Rgba8, out.to_bytes()) catch {
    error => abort("the picture is well formed: \{error}")
  }
}

///|
fn few_colours(count : Int32) -> @raster.Image {
  few_colours_sized(count, 16)
}

///|
test "png: a picture of few colours is written as a palette" {
  // A sprite: sixty-four pixels square, four colours, a transparent corner. The
  // palette replaces three bytes with two bits and the table is amortised after
  // one row.
  let image = few_colours_sized(4, 64)
  let file = @png.encode(image)
  assert_true(has_chunk(file, "PLTE"))
  assert_true(has_chunk(file, "tRNS"))
  assert_eq(read(file).convert(@raster.PixelFormat::Rgba8).pixels, image.pixels)
  let plain = @png.encode(image, options=@png.EncodeOptions::{
    level: 6,
    filter: @png.Filter::Adaptive,
    interlace: false,
    metadata: true,
    palette: false,
  })
  assert_true(file.length() < plain.length())
  // Every count is decodable, whichever of the two the writer kept.
  for count in [2, 3, 5, 16, 17, 100, 256] {
    let picture = few_colours(count)
    let written = @png.encode(picture)
    assert_eq(
      read(written).convert(@raster.PixelFormat::Rgba8).pixels,
      picture.pixels,
      msg="round trip of \{count} colours",
    )
  }
}

///|
test "png: a palette is only used when it is smaller" {
  // Two hundred colours on a gradient: the table and the noisier indices cost
  // more than the three bytes a pixel they replace, so the writer keeps the true
  // colour file it made alongside.
  let image = few_colours(200)
  let file = @png.encode(image)
  let plain = @png.encode(image, options=@png.EncodeOptions::{
    level: 6,
    filter: @png.Filter::Adaptive,
    interlace: false,
    metadata: true,
    palette: false,
  })
  assert_true(file.length() <= plain.length())
  assert_eq(read(file).convert(@raster.PixelFormat::Rgba8).pixels, image.pixels)
}

///|
test "png: a picture with more than 256 colours falls back to true colour" {
  let out = @buffer.Buffer::Buffer()
  for y in 0..<32 {
    for x in 0..<32 {
      out.write_byte((x * 8).to_byte())
      out.write_byte((y * 8).to_byte())
      out.write_byte((x * y % 256).to_byte())
      out.write_byte((255).to_byte())
    }
  }
  let image = @raster.Image::of(
    32,
    32,
    @raster.PixelFormat::Rgba8,
    out.to_bytes(),
  ) catch {
    error => abort("the picture is well formed: \{error}")
  }
  let file = @png.encode(image)
  assert_true(!has_chunk(file, "PLTE"))
  assert_eq(read(file).pixels, image.pixels)
}

///|
test "png: a palette can be turned off" {
  let image = few_colours(4)
  let file = @png.encode(image, options=@png.EncodeOptions::{
    level: 6,
    filter: @png.Filter::Adaptive,
    interlace: false,
    metadata: true,
    palette: false,
  })
  assert_true(!has_chunk(file, "PLTE"))
  assert_eq(read(file).convert(@raster.PixelFormat::Rgba8).pixels, image.pixels)
}
