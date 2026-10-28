// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// WebP: the container, both codecs, the alpha that travels beside a lossy
// picture, and the refusals in between.
//
// What a decoder produces is not a matter of taste: a lossless file has one
// correct decoding, and a lossy one has the reconstruction libwebp defines. So
// every fixture here is compared by digest against what libwebp reads back, and
// a difference of one sample anywhere fails the test.

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
test "webp: an animation composes to the frames libwebp composes" {
  for entry in webp_animations {
    let (name, file) = entry
    let animation = @webp.decode_animation(file) catch {
      error => abort("the fixture should decode: \{error}")
    }
    let mut shape = (0, 0, 0)
    for entry in webp_animation_shape {
      if entry.0 == name {
        shape = (entry.1, entry.2, entry.3)
      }
    }
    let (width, height, frames) = shape
    assert_eq(animation.width, width, msg=name)
    assert_eq(animation.height, height, msg=name)
    assert_eq(animation.frames.length(), frames, msg=name)
    let mut expected : Array[String] = []
    for entry in webp_animation_frames {
      if entry.0 == name {
        expected = entry.1
      }
    }
    let composed = animation.compose()
    assert_eq(composed.length(), expected.length(), msg=name)
    for index in 0..<composed.length() {
      // The canvas is sixteen-bit; an eight-bit source comes back through the
      // narrowing conversion without losing a step, so the digest is an equality.
      assert_eq(
        digest(composed[index].convert(@raster.PixelFormat::Rgba8).pixels),
        expected[index],
        msg="\{name} frame \{index}",
      )
    }
  }
}

///|
test "webp: what the animation writer writes, the reader reads back" {
  let base = read(by_name("lossless-rgb"))
  let dot = base.crop(0, 0, 8, 8) catch {
    error => abort("the rectangle fits: \{error}")
  }
  let animation = @raster.Animation::new(
    64,
    48,
    [
      @raster.Frame::new(base, delay=100),
      @raster.Frame::new(
        dot,
        x=16,
        y=16,
        delay=50,
        dispose=@raster.Dispose::Background,
      ),
    ],
    loops=3,
  )
  let file = @webp.encode_animation(animation)
  let back = @webp.decode_animation(file) catch {
    error => abort("what was written is read: \{error}")
  }
  assert_eq(back.width, 64)
  assert_eq(back.height, 48)
  assert_eq(back.loops, 3)
  assert_eq(back.frames.length(), 2)
  // The frames come back where they were put, with the rules they were given.
  assert_eq(back.frames[1].x, 16)
  assert_eq(back.frames[1].y, 16)
  assert_eq(back.frames[1].delay, 50)
  assert_eq(back.frames[1].dispose, @raster.Dispose::Background)
  // And the same picture, frame for frame, once composited.
  let before = animation.compose()
  let after = back.compose()
  assert_eq(before.length(), after.length())
  for index in 0..<before.length() {
    assert_eq(after[index].pixels, before[index].pixels, msg="frame \{index}")
  }
  // An offset of an odd number of pixels cannot be stored, and is refused
  // rather than rounded into a file that shows something else.
  let odd = @raster.Animation::new(64, 48, [
    @raster.Frame::new(dot, x=15, y=16, delay=10),
  ])
  let failed = try {
    ignore(@webp.encode_animation(odd))
    false
  } catch {
    @raster.Refused::Unsupported(..) => true
    _ => false
  }
  assert_true(failed)
}

///|
test "webp: an alpha chunk decodes without its container" {
  let (chunk, width, height, expected) = webp_alpha_chunk
  let plane = @webp.decode_alpha(
    chunk,
    width,
    height,
    @raster.Limits::default(),
  ) catch {
    error => abort("the chunk should decode on its own: \{error}")
  }
  assert_eq(plane.length(), width * height)
  assert_eq(digest(plane), expected)
  // The byte also names how the plane is stored, and two of those four numbers
  // were never assigned: a chunk that claims one of them is refused rather than
  // read as though it were the one next door.
  for compression in [b'\x02', b'\x03'] {
    let unknown = with_byte(chunk, 0, compression)
    let failed = try {
      ignore(
        @webp.decode_alpha(unknown, width, height, @raster.Limits::default()),
      )
      false
    } catch {
      @raster.Refused::Unsupported(..) => true
      _ => false
    }
    assert_true(failed)
  }
}

///|
test "webp: a lossy payload that cannot be decoded is refused" {
  let (payload, width, height) = webp_lossy_payload
  let image = @webp.decode_lossy(payload, @raster.Limits::default()) catch {
    error => abort("the payload should decode: \{error}")
  }
  assert_eq(image.width, width)
  assert_eq(image.height, height)
  // The low bit of the frame tag says "interframe", which a WebP never holds.
  assert_true(
    refuses_payload(with_byte(payload, 0, b'\x01'))
    is Some(@raster.Refused::Unsupported(..)),
  )
  // A key frame whose start code is not `9d 01 2a`.
  assert_true(
    refuses_payload(with_byte(payload, 3, b'\x00'))
    is Some(@raster.Refused::Unexpected(..)),
  )
  // A first partition that claims to run past the end of the payload, with the
  // profile and the display flag left legal so that the length is what fails.
  let long = with_byte(
    with_byte(with_byte(payload, 0, b'\xf0'), 1, b'\xff'),
    2,
    b'\x1f',
  )
  assert_true(refuses_payload(long) is Some(@raster.Refused::Truncated(..)))
  // A picture with a zero side.
  let flat = with_byte(
    with_byte(with_byte(with_byte(payload, 6, b'\x00'), 7, b'\x00'), 8, b'\x00'),
    9,
    b'\x00',
  )
  assert_true(refuses_payload(flat) is Some(@raster.Refused::Unexpected(..)))
  // Half a container, which leaves the last partition short.
  let file = by_name("lossy-pattern")
  assert_true(
    refuses(file.clamped_view(start=0, end=file.length() / 2).to_owned())
    is Some(_),
  )
}

///|
test "webp: an animation with a lossy frame decodes its alpha too" {
  let animation = @webp.decode_animation(by_name_animation("animation-lossy")) catch {
    error => abort("the fixture should decode: \{error}")
  }
  let mut translucent = 0
  for frame in animation.compose() {
    let rgba = frame.convert(@raster.PixelFormat::Rgba8)
    for index in 0..<(rgba.width * rgba.height) {
      if rgba.pixels[index * 4 + 3].to_int() < 255 {
        translucent = translucent + 1
      }
    }
  }
  assert_true(translucent > 0)
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
/// The file with one byte replaced, which is how a damaged file is made here.
fn with_byte(file : Bytes, index : Int32, value : Byte) -> Bytes {
  let copy = file.to_fixedarray()
  copy.set(index, value)
  Bytes::from_array(copy.clamped_view())
}

///|
fn by_name_animation(name : String) -> Bytes {
  for entry in webp_animations {
    if entry.0 == name {
      return entry.1
    }
  }
  abort("no animation called \{name}")
}

///|
fn refuses_payload(payload : Bytes) -> @raster.Refused? {
  try {
    ignore(@webp.decode_lossy(payload, @raster.Limits::default()))
    None
  } catch {
    error => Some(error)
  }
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
