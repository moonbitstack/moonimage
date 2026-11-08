// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The entry point over the formats added since the first release: the signature
// that recognises each one, and the round trip that proves the two directions
// agree.

///|
fn plate() -> @moonimage.Image {
  let buffer : FixedArray[Byte] = FixedArray::make(6 * 4 * 4, b'\x00')
  for y in 0..<4 {
    for x in 0..<6 {
      let at = (y * 6 + x) * 4
      buffer[at] = (x * 40).to_byte()
      buffer[at + 1] = (y * 60).to_byte()
      buffer[at + 2] = ((x + y) * 20).to_byte()
      buffer[at + 3] = b'\xFF'
    }
  }
  @moonimage.Image::of(
    6,
    4,
    @moonimage.PixelFormat::Rgba8,
    Bytes::from_array(buffer.clamped_view()),
  ) catch {
    error => abort("the plate is well formed: \{error}")
  }
}

///|
test "each new format is recognised by its signature" {
  let image = plate()
  for
    format in [
      @moonimage.Format::Tiff,
      @moonimage.Format::Ico,
      @moonimage.Format::Pnm,
      @moonimage.Format::Hdr,
      @moonimage.Format::Exr,
      @moonimage.Format::Farbfeld,
    ] {
    let file = @moonimage.encode(image, format) catch {
      error => abort("\{format}: \{error}")
    }
    assert_eq(@moonimage.Format::of(file), format)
  }
}

///|
test "each new format round trips through the entry point" {
  let image = plate()
  for
    format in [
      @moonimage.Format::Tiff,
      @moonimage.Format::Ico,
      @moonimage.Format::Pnm,
      @moonimage.Format::Farbfeld,
    ] {
    let file = @moonimage.encode(image, format) catch {
      error => abort("\{format}: \{error}")
    }
    let back = @moonimage.decode(file) catch {
      error => abort("\{format}: \{error}")
    }
    assert_eq(back.width, image.width)
    assert_eq(back.height, image.height)
    assert_eq(back.convert(@moonimage.PixelFormat::Rgba8).pixels, image.pixels)
  }
}

///|
test "a read-only format is refused when it is asked to be written" {
  let refused = try {
    ignore(@moonimage.encode(plate(), @moonimage.Format::Dds))
    false
  } catch {
    @moonimage.Refused::Unsupported(..) => true
    _ => false
  }
  assert_true(refused)
}

///|
test "a still picture comes back as one frame whatever its format" {
  let image = plate()
  for
    format in [
      @moonimage.Format::Pnm,
      @moonimage.Format::Farbfeld,
      @moonimage.Format::Hdr,
    ] {
    let file = @moonimage.encode(image, format) catch {
      error => abort("\{format}: \{error}")
    }
    let animation = @moonimage.decode_animation(file) catch {
      error => abort("\{format}: \{error}")
    }
    assert_eq(animation.frames.length(), 1)
    assert_eq(animation.width, image.width)
  }
}

///|
test "a multi-page file comes back as a frame a page" {
  let image = plate()
  let file = @moonimage.encode_animation(
    @moonimage.Animation::new(6, 4, [
      @moonimage.Frame::new(image, delay=0),
      @moonimage.Frame::new(image.rotate(quarters=2), delay=0),
    ]),
    @moonimage.Format::Tiff,
  ) catch {
    error => abort("the pages encode: \{error}")
  }
  let animation = @moonimage.decode_animation(file) catch {
    error => abort("the pages decode: \{error}")
  }
  assert_eq(animation.frames.length(), 2)
}

///|
test "the name and the media type of each format" {
  assert_eq(@moonimage.Format::Tiff.extension(), "tiff")
  assert_eq(@moonimage.Format::Tiff.mime(), "image/tiff")
  assert_eq(@moonimage.Format::Farbfeld.extension(), "ff")
  assert_eq(@moonimage.Format::Pnm.mime(), "image/x-portable-anymap")
  assert_eq(@moonimage.Format::Exr.extension(), "exr")
  assert_eq(@moonimage.Format::Hdr.mime(), "image/vnd.radiance")
  assert_true(@moonimage.Format::Tiff.is_animated())
  assert_true(!@moonimage.Format::Pnm.is_animated())
}
