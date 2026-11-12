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
test "a decode can ask for the layout it is going to be drawn with" {
  // The file holds what it holds; a canvas draws RGBA. This is the call that
  // says so once, whichever format the bytes turned out to be.
  let image = plate()
  let file = @moonimage.encode(image, @moonimage.Format::Farbfeld) catch {
    error => abort("the plate encodes: \{error}")
  }
  let native = @moonimage.decode(file) catch {
    error => abort("the plate decodes: \{error}")
  }
  assert_eq(native.format, @moonimage.PixelFormat::Rgba16)
  let asked = @moonimage.decode(file, format=@moonimage.PixelFormat::Rgba8) catch {
    error => abort("the plate decodes: \{error}")
  }
  assert_eq(asked.format, @moonimage.PixelFormat::Rgba8)
  // Sixteen bits a channel and back is exact for eight-bit samples, so the
  // conversion is the only thing that happened.
  assert_eq(asked.pixels, image.pixels)
  // Asking for the layout the file already holds costs nothing: same picture.
  let same = @moonimage.decode(file, format=@moonimage.PixelFormat::Rgba16) catch {
    error => abort("the plate decodes: \{error}")
  }
  assert_eq(same.pixels, native.pixels)
}

///|
test "an animation takes the layout for every frame at once" {
  let image = plate()
  let file = @moonimage.encode_animation(
    @moonimage.Animation::new(image.width, image.height, [
      @moonimage.Frame::new(image),
    ]),
    @moonimage.Format::Webp,
  ) catch {
    error => abort("the animation encodes: \{error}")
  }
  let animation = @moonimage.decode_animation(
    file,
    format=@moonimage.PixelFormat::Rgba8,
  ) catch {
    error => abort("the animation decodes: \{error}")
  }
  assert_true(animation.frames.length() > 0)
  for frame in animation.frames {
    assert_eq(frame.image.format, @moonimage.PixelFormat::Rgba8)
  }
}

///|
test "a texture is written as a surface of plain samples" {
  let image = plate()
  let file = @moonimage.encode(image, @moonimage.Format::Dds) catch {
    error => abort("the texture is written: \{error}")
  }
  let back = @moonimage.decode(file) catch { error => abort("\{error}") }
  assert_eq(back.width, image.width)
  assert_eq(back.height, image.height)
  assert_eq(back.format, @moonimage.PixelFormat::Rgba8)
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

///|
test "an AVIF is recognised by its brand, and is not written" {
  // A HEIF file names itself with a brand inside the `ftyp` box rather than a
  // magic number at the front, so the four bytes at eight are what to read.
  let header = b"\x00\x00\x00 ftypavif\x00\x00\x00\x00avifmif1miaf"
  assert_eq(@moonimage.Format::of(header), @moonimage.Format::Avif)
  let sequence = b"\x00\x00\x00 ftypavis\x00\x00\x00\x00avisavif"
  assert_eq(@moonimage.Format::of(sequence), @moonimage.Format::Avif)
  assert_eq(@moonimage.Format::Avif.extension(), "avif")
  assert_eq(@moonimage.Format::Avif.mime(), "image/avif")
  assert_false(@moonimage.Format::Avif.is_animated())
  // Reading is one direction: an AV1 encoder is a great deal more than this
  // library carries, so the writer says so rather than writing something else.
  let mut refused = false
  let _ = @moonimage.encode(plate(), @moonimage.Format::Avif) catch {
    _ => {
      refused = true
      b""
    }
  }
  assert_true(refused)
}
