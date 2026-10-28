// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// GIF: the samples in `samples_test.mbt`, and the writer against the reader.

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
fn read(file : Bytes) -> @raster.Image {
  @gif.decode(file) catch {
    error => abort("the sample should decode: \{error}")
  }
}

///|
fn animate(file : Bytes) -> @raster.Animation {
  @gif.decode_animation(file) catch {
    error => abort("the animation should decode: \{error}")
  }
}

///|
fn refuses(file : Bytes) -> Bool {
  try {
    ignore(@gif.decode(file))
    false
  } catch {
    _ => true
  }
}

///|
fn sample_file(name : String) -> Bytes {
  for entry in samples {
    if entry.0 == name {
      return entry.1
    }
  }
  abort("no sample called \{name}")
}

///|
test "gif: every still sample decodes to the reference pixels" {
  for entry in samples {
    let (name, file, expected) = entry
    let image = read(file)
    assert_eq(
      digest(image.convert(@raster.PixelFormat::Rgba8).pixels),
      expected,
      msg=name,
    )
  }
}

///|
test "gif: every animation composes to the reference frames, with their delays" {
  for entry in animations {
    let (name, file, expected) = entry
    let animation = animate(file)
    let pictures = animation.compose()
    assert_eq(pictures.length(), expected.length(), msg=name)
    assert_eq(animation.frames.length(), expected.length(), msg=name)
    for index in 0..<expected.length() {
      let (delay, digest_expected) = expected[index]
      assert_eq(animation.frames[index].delay, delay, msg=name)
      assert_eq(
        digest(pictures[index].convert(@raster.PixelFormat::Rgba8).pixels),
        digest_expected,
        msg=name,
      )
    }
  }
}

///|
test "gif: the loop count and the canvas come back" {
  let animation = animate(sample_animation("pillow-animation"))
  assert_eq(animation.width, 40)
  assert_eq(animation.height, 30)
  assert_eq(animation.loops, 2)
  assert_eq(animation.frames.length(), 3)
}

///|
fn sample_animation(name : String) -> Bytes {
  for entry in animations {
    if entry.0 == name {
      return entry.1
    }
  }
  abort("no animation called \{name}")
}

///|
test "gif: a palette image with four colours comes back as rich as it went in" {
  let image = read(sample_file("pillow-four-colours"))
  assert_eq(image.format, @raster.PixelFormat::Rgba8)
  // A GIF has no alpha beyond one transparent index, so every opaque pixel is
  // opaque here.
  let mut all_opaque = true
  for y in 0..<image.height {
    for x in 0..<image.width {
      let pixel = image.pixel(x, y) catch {
        error => abort("in range: \{error}")
      }
      if pixel.a < 1.0 {
        all_opaque = false
      }
    }
  }
  assert_true(all_opaque)
}

///|
test "gif: what the writer writes, the reader reads back" {
  let source = read(sample_file("pillow-static"))
  for dither in [false, true] {
    let file = @gif.encode(source, options=@gif.EncodeOptions::{
      dither,
      transparent: true,
    })
    let back = read(file)
    assert_eq(back.width, source.width)
    assert_eq(back.height, source.height)
    // The palette was chosen from the image, so the pixels are exactly the ones
    // that went in: no colour was merged away.
    assert_eq(back.pixels, source.pixels)
  }
}

///|
test "gif: an image with more colours than a palette holds still round trips" {
  let wide = @raster.Image::of(
    32,
    32,
    @raster.PixelFormat::Rgba8,
    gradient(32, 32),
  )
  let file = @gif.encode(wide, options=@gif.EncodeOptions::{
    dither: false,
    transparent: false,
  })
  let back = read(file)
  assert_eq(back.width, 32)
  assert_eq(back.height, 32)
  // Every pixel must be close to what it was: a palette of 256 cannot hold a
  // gradient exactly, but it can hold it nearly.
  let mut worst = 0
  for y in 0..<32 {
    for x in 0..<32 {
      let original = wide.pixel(x, y) catch {
        error => abort("in range: \{error}")
      }
      let decoded = back.pixel(x, y) catch {
        error => abort("in range: \{error}")
      }
      let (r0, g0, b0, _) = original.rgba8()
      let (r1, g1, b1, _) = decoded.rgba8()
      let difference = (r0 - r1).abs() + (g0 - g1).abs() + (b0 - b1).abs()
      if difference > worst {
        worst = difference
      }
    }
  }
  assert_true(worst < 40)
}

///|
/// A gradient with more distinct colours than a GIF palette has entries.
fn gradient(width : Int32, height : Int32) -> Bytes {
  let out = @buffer.Buffer::Buffer()
  for y in 0..<height {
    for x in 0..<width {
      out.write_byte((x * 8).to_byte())
      out.write_byte((y * 8).to_byte())
      out.write_byte((x * y % 256).to_byte())
      out.write_byte((255).to_byte())
    }
  }
  out.to_bytes()
}

///|
test "gif: an animation written here composes to the frames that went in" {
  let first = sample_file("pillow-static")
  let image = read(first)
  let dot = @raster.Image::of(
    4,
    4,
    @raster.PixelFormat::Rgba8,
    Bytes::repeat(b"\xff\x00\x00\xff", 16),
  )
  let animation = @raster.Animation::new(
    image.width,
    image.height,
    [
      @raster.Frame::new(image, delay=100, dispose=@raster.Dispose::Keep),
      @raster.Frame::new(
        dot,
        x=2,
        y=2,
        delay=50,
        dispose=@raster.Dispose::Background,
      ),
    ],
    loops=1,
  )
  let file = @gif.encode_animation(animation)
  let back = animate(file)
  assert_eq(back.frames.length(), 2)
  assert_eq(back.loops, 1)
  let composed = back.compose()
  let original = animation.compose()
  for index in 0..<2 {
    assert_eq(
      digest(composed[index].convert(@raster.PixelFormat::Rgba8).pixels),
      digest(original[index].convert(@raster.PixelFormat::Rgba8).pixels),
    )
  }
}

///|
test "gif: damage is refused" {
  let file = sample_file("pillow-static")
  assert_true(refuses(b"not a gif"))
  assert_true(refuses(file.clamped_view(start=0, end=10).to_owned()))
  assert_true(
    refuses(file.clamped_view(start=0, end=file.length() / 3).to_owned()),
  )
  let tight : @raster.Limits = { width: 4, height: 4, pixels: 16, bytes: 64, }
  let refused = try {
    ignore(@gif.decode(file, limits=tight))
    false
  } catch {
    @raster.Refused::OverLimit(..) => true
    _ => false
  }
  assert_true(refused)
}
