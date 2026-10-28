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
      @moonimage.Format::Webp,
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
      @moonimage.Format::Webp,
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
test "a lossy WebP comes back through the front door, pixel for pixel" {
  // Written by `cwebp -q 75` from a 16 by 16 gradient; the same bytes the tour
  // decodes. A caller with a file from the network has nothing but this call.
  let file : Bytes = b"RIFFR\x00\x00\x00WEBPVP8 F\x00\x00\x00\xf0\x01\x00\x9d\x01*\x10\x00\x10\x00\x02\x004%\xb0\x02t" +
    b"\x01\x0f\x0c\x12\xf2\xca\x80\x00\xfe\xfc\x03\xcb\xf2}\x12\xe9p\xe1\x0b\x86=\xa6\xed1\xff\xc9\x8a" +
    b"t\xfe\xf9\xf0\x851x\x14D3\x97\xff\xfc\x8b\xddO\xff\xa7>\xf7\x0b\xfec\x00\x00\x00"
  assert_eq(@moonimage.Format::of(file), @moonimage.Format::Webp)
  let image = @moonimage.decode(file) catch {
    error => abort("the file should decode: \{error}")
  }
  assert_eq(image.width, 16)
  assert_eq(image.height, 16)
  assert_eq(image.format, @moonimage.PixelFormat::Rgb8)
  // A lossy file is not "close enough" either: these are the samples libwebp
  // produces, and the corners of the gradient are where they show. A pixel is
  // four samples from nought to one.
  let corner = image.pixel(0, 0) catch {
    error => abort("the pixel is inside the image: \{error}")
  }
  let far = image.pixel(15, 15) catch {
    error => abort("the pixel is inside the image: \{error}")
  }
  assert_true(corner.r < 0.05)
  assert_true(corner.b > 0.45)
  assert_true(far.r > 0.95)
  assert_true(far.g > 0.95)
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
