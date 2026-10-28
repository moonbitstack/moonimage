// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The entry point: one call for whichever format the bytes are, one for whichever
// the caller wants them to become.

///|
fn sample() -> @moonimage.Image {
  let out = @buffer.Buffer::Buffer()
  for y in 0..<8 {
    for x in 0..<8 {
      out.write_byte((x * 16).to_byte())
      out.write_byte((y * 16).to_byte())
      out.write_byte((x * y % 256).to_byte())
      out.write_byte((255).to_byte())
    }
  }
  let pixels = out.to_bytes()
  @moonimage.Image::of(8, 8, @moonimage.PixelFormat::Rgba8, pixels) catch {
    error => abort("the sample image is well formed: \{error}")
  }
}

///|
test "the format is recognised by what the bytes start with" {
  let image = sample()
  for
    format in [
      @moonimage.Format::Png,
      @moonimage.Format::Qoi,
      @moonimage.Format::Bmp,
      @moonimage.Format::Gif,
      @moonimage.Format::Jpeg,
      @moonimage.Format::Tga,
    ] {
    let file = @moonimage.encode(image, format)
    assert_eq(@moonimage.Format::of(file), format)
  }
}

///|
test "what is written is what is read, for the formats that keep every pixel" {
  let image = sample()
  for
    format in [
      @moonimage.Format::Png,
      @moonimage.Format::Qoi,
      @moonimage.Format::Bmp,
      @moonimage.Format::Tga,
    ] {
    let file = @moonimage.encode(image, format)
    let back = @moonimage.decode(file) catch {
      error => abort("the file should decode: \{error}")
    }
    assert_eq(back.width, image.width)
    assert_eq(back.height, image.height)
    assert_eq(
      back.convert(@moonimage.PixelFormat::Rgba8).pixels,
      image.pixels,
      msg="format \{format}",
    )
  }
}

///|
test "a lossy format comes back close, not equal" {
  let image = sample()
  let file = @moonimage.encode(image, @moonimage.Format::Jpeg)
  let back = @moonimage.decode(file) catch {
    error => abort("the file should decode: \{error}")
  }
  assert_eq(back.width, image.width)
  let decoded = back.convert(@moonimage.PixelFormat::Rgba8)
  let mut worst = 0
  for index in 0..<(decoded.width * decoded.height) {
    for channel in 0..<3 {
      let difference = (decoded.pixels[index * 4 + channel].to_int() -
      image.pixels[index * 4 + channel].to_int()).abs()
      if difference > worst {
        worst = difference
      }
    }
  }
  assert_true(worst <= 40)
}

///|
test "an animation of one frame is what a still image decodes as" {
  let image = sample()
  let file = @moonimage.encode(image, @moonimage.Format::Gif)
  let animation = @moonimage.decode_animation(file) catch {
    error => abort("the file should decode: \{error}")
  }
  assert_eq(animation.frames.length(), 1)
  assert_eq(animation.width, image.width)
}

///|
test "the limits a caller passes reach the reader" {
  let file = @moonimage.encode(sample(), @moonimage.Format::Png)
  let tight : @moonimage.Limits = {
    width: 4,
    height: 4,
    pixels: 16,
    bytes: 64,
  }
  let refused = try {
    ignore(@moonimage.decode(file, limits=tight))
    false
  } catch {
    @moonimage.Refused::OverLimit(..) => true
    _ => false
  }
  assert_true(refused)
}

///|
test "bytes that are no image at all are refused, and the refusal says what they are" {
  let refused = try {
    ignore(@moonimage.decode(b"hello, world"))
    None
  } catch {
    error => Some(error)
  }
  assert_true(refused is Some(@moonimage.Refused::Unknown(..)))
}

///|
test "every format the library names can be written" {
  let image = sample()
  for
    format in [
      @moonimage.Format::Png,
      @moonimage.Format::Qoi,
      @moonimage.Format::Bmp,
      @moonimage.Format::Tga,
      @moonimage.Format::Jpeg,
      @moonimage.Format::Gif,
      @moonimage.Format::Webp,
    ] {
    let file = @moonimage.encode(image, format)
    assert_eq(@moonimage.Format::of(file), format)
  }
}

///|
test "WebP is lossless, so what it writes it reads back exactly" {
  let image = sample()
  let file = @moonimage.encode(image, @moonimage.Format::Webp)
  let back = @moonimage.decode(file) catch {
    error => abort("the file should decode: \{error}")
  }
  assert_eq(back.convert(@moonimage.PixelFormat::Rgba8).pixels, image.pixels)
}
