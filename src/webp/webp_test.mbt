// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// WebP: the container, the lossless codec, and the refusals in between.

///|
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
  @webp.decode(bytes) catch {
    error => abort("the fixture should decode: \{error}")
  }
}

///|
/// The shape a sample should have, from the fixture itself.
fn expected_size(name : String) -> (Int32, Int32) {
  for entry in webp_samples_size {
    if entry.0 == name {
      return (entry.1, entry.2)
    }
  }
  abort("no size recorded for \{name}")
}

///|
test "webp: every sample decodes to the pixels libwebp reads" {
  for entry in webp_samples {
    let (name, file, expected) = entry
    let image = read(file)
    let (width, height) = expected_size(name)
    assert_eq(image.width, width, msg=name)
    assert_eq(image.height, height, msg=name)
    // Both codecs have one correct decoding, so this is an equality and not a
    // tolerance: a lossy file is not "close enough", it is exact. What makes
    // that possible is that the reader reproduces libwebp's own reconstruction,
    // including the loop filter and the interpolation of chroma between rows.
    assert_eq(
      digest(image.convert(@raster.PixelFormat::Rgba8).pixels),
      expected,
      msg=name,
    )
  }
}

///|
test "webp: a lossy image carries its alpha in its own chunk" {
  let image = read(by_name("lossy-alpha"))
  assert_eq(image.format, @raster.PixelFormat::Rgba8)
  let mut transparent = 0
  let mut solid = 0
  for index in 0..<(image.width * image.height) {
    let alpha = image.pixels[index * 4 + 3].to_int()
    if alpha == 0 {
      transparent = transparent + 1
    } else if alpha == 255 {
      solid = solid + 1
    }
  }
  assert_true(transparent > 0)
  assert_true(solid > 0)
}

///|
test "webp: a lossless image keeps its alpha exactly" {
  let image = read(webp_samples[1].1)
  let rgba = image.convert(@raster.PixelFormat::Rgba8)
  let mut transparent = 0
  let mut solid = 0
  for index in 0..<(rgba.width * rgba.height) {
    let alpha = rgba.pixels[index * 4 + 3].to_int()
    if alpha == 0 {
      transparent = transparent + 1
    } else if alpha == 255 {
      solid = solid + 1
    }
  }
  assert_true(transparent > 0)
  assert_true(solid > 0)
}

///|
test "webp: what the writer writes, the reader reads back" {
  let source = read(webp_samples[0].1)
  for
    format in [
      @raster.PixelFormat::Rgb8,
      @raster.PixelFormat::Rgba8,
      @raster.PixelFormat::Gray8,
    ] {
    let picture = source.convert(format)
    let file = @webp.encode(picture)
    let back = read(file)
    assert_eq(back.width, picture.width)
    assert_eq(back.height, picture.height)
    assert_eq(back.convert(format).pixels, picture.pixels)
  }
  // A picture with alpha, which decides whether the header claims to use it.
  let alpha = read(webp_samples[1].1).convert(@raster.PixelFormat::Rgba8)
  let back = read(@webp.encode(alpha))
  assert_eq(back.convert(@raster.PixelFormat::Rgba8).pixels, alpha.pixels)
}

///|
test "webp: a file whose container is damaged is refused" {
  let file = webp_samples[0].1
  // Not RIFF at all.
  assert_true(
    refuses(b"not a webp at all") is Some(@raster.Refused::Unknown(..)),
  )
  // RIFF, but not WebP.
  assert_true(
    refuses(b"RIFF\x04\x00\x00\x00NOPE") is Some(@raster.Refused::Unknown(..)),
  )
  // A chunk that runs past the end of the file.
  let body = @wire.Writer::new()
  body.bytes(b"WEBP")
  body.bytes(b"VP8L")
  body.u32_le(1_000)
  body.u8(0x2F)
  let writer = @wire.Writer::new()
  writer.bytes(b"RIFF")
  writer.u32_le(body.length())
  writer.bytes(body.to_bytes())
  assert_true(
    refuses(writer.to_bytes()) is Some(@raster.Refused::Truncated(..)),
  )
  // Half a file.
  assert_true(
    refuses(file.clamped_view(start=0, end=file.length() / 2).to_owned())
    is Some(_),
  )
}

///|
test "webp: a chunk nobody knows is skipped, and a still file is one frame" {
  let file = webp_samples[0].1
  // Rebuild the file with an extra private chunk before the image.
  let chunks : Array[(String, BytesView)] = []
  let cursor = @wire.Cursor::new(file)
  ignore(cursor.bytes(12))
  while cursor.left() >= 8 {
    let name = @utf8.decode_lossy(cursor.bytes(4))
    let size = cursor.u32_le()
    let payload = cursor.bytes(size)
    if size % 2 == 1 && cursor.left() > 0 {
      ignore(cursor.u8())
    }
    chunks.push((name, payload))
  }
  let rebuilt = @wire.Writer::new()
  rebuilt.bytes(b"WEBP")
  rebuilt.bytes(b"ZZZZ")
  rebuilt.u32_le(2)
  rebuilt.u8(1)
  rebuilt.u8(2)
  for chunk in chunks {
    rebuilt.bytes(@utf8.encode(chunk.0))
    rebuilt.u32_le(chunk.1.length())
    rebuilt.bytes(chunk.1)
    if chunk.1.length() % 2 == 1 {
      rebuilt.u8(0)
    }
  }
  let payload = rebuilt.to_bytes()
  let writer = @wire.Writer::new()
  writer.bytes(b"RIFF")
  writer.u32_le(payload.length())
  writer.bytes(payload)
  let patched = writer.to_bytes()
  assert_eq(read(patched).width, read(file).width)
  // And the same file is an animation of one frame.
  let animation = @webp.decode_animation(patched) catch {
    error => abort("the file is an animation of one frame: \{error}")
  }
  assert_eq(animation.frames.length(), 1)
  assert_eq(animation.width, read(file).width)
}

///|
/// The bytes of one sample, by the name the fixture gives it.
fn by_name(name : String) -> Bytes {
  for entry in webp_samples {
    if entry.0 == name {
      return entry.1
    }
  }
  abort("no sample called \{name}")
}

///|
fn refuses(file : Bytes) -> @raster.Refused? {
  try {
    ignore(@webp.decode(file))
    None
  } catch {
    error => Some(error)
  }
}
