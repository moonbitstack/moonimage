// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// TIFF, read against files libtiff wrote and written back for every shape the
// writer claims.

///|
fn decoded(file : Bytes) -> @raster.Image {
  @tiff.decode(file) catch {
    error => abort("the sample decodes: \{error}")
  }
}

///|
fn encoded(image : @raster.Image, options : @tiff.EncodeOptions) -> Bytes {
  @tiff.encode(image, options~)
}

///|
fn sample_image() -> @raster.Image {
  image_of(
    4,
    5,
    @raster.PixelFormat::Rgba8,
    b"\x10\x20\x30\x40\x50\x60\x70\x80\x90\xa0\xb0\xc0\xd0\xe0\xf0\x01" +
    b"\x11\x21\x31\x41\x51\x61\x71\x81\x91\xa1\xb1\xc1\xd1\xe1\xf1\x02" +
    b"\x12\x22\x32\x42\x52\x62\x72\x82\x92\xa2\xb2\xc2\xd2\xe2\xf2\x03" +
    b"\x13\x23\x33\x43\x53\x63\x73\x83\x93\xa3\xb3\xc3\xd3\xe3\xf3\x04" +
    b"\x14\x24\x34\x44\x54\x64\x74\x84\x94\xa4\xb4\xc4\xd4\xe4\xf4\x05",
  )
}

///|
test "every sample decodes to the pixels Pillow read" {
  for sample in samples {
    let (name, file, expected) = sample
    let actual = digest_of(decoded(file))
    if actual != expected {
      abort("\{name}: decoded to \{actual}, want \{expected}")
    }
  }
}

///|
test "a multi-page file comes back page by page" {
  let pages = @tiff.decode_pages(pages) catch {
    error => abort("the sample decodes: \{error}")
  }
  assert_eq(pages.length(), page_digests.length())
  for index in 0..<pages.length() {
    let actual = digest_of(pages[index])
    if actual != page_digests[index] {
      abort("page \{index}: decoded to \{actual}")
    }
  }
}

///|
test "every compression round trips" {
  let image = sample_image()
  for
    compression in [
      @tiff.Compression::None,
      @tiff.Compression::Lzw,
      @tiff.Compression::PackBits,
      @tiff.Compression::Deflate,
    ] {
    for predictor in [false, true] {
      if predictor && compression == @tiff.Compression::None {
        continue
      }
      let options : @tiff.EncodeOptions = {
        compression,
        rows_per_strip: 2,
        predictor,
      }
      let file = encoded(image, options)
      let back = decoded(file)
      assert_eq(rgba8(back), rgba8(image))
    }
  }
}

///|
test "every shape round trips" {
  let shape = image_of(
    3,
    2,
    @raster.PixelFormat::GrayAlpha16,
    b"\x00\x10\x00\x20\x00\x30\x00\x40\x00\x50\x00\x60" +
    b"\x00\x70\x00\x80\x00\x90\x00\xa0\x00\xb0\x00\xc0",
  )
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
    let image = shape.convert(format)
    let back = decoded(encoded(image, @tiff.EncodeOptions::default()))
    if back.format != format {
      abort("\{format}: came back as \{back.format}")
    }
    assert_eq(rgba8(back), rgba8(image))
  }
}

///|
test "a second page is written and read back as a page" {
  let first = sample_image()
  let second = sample_image().rotate(quarters=2)
  let file = @tiff.encode_pages([first, second])
  let pages = @tiff.decode_pages(file) catch {
    error => abort("the pages decode: \{error}")
  }
  assert_eq(pages.length(), 2)
  assert_eq(rgba8(pages[0]), rgba8(first))
  assert_eq(rgba8(pages[1]), rgba8(second))
}

///|
test "an orientation tag comes back as a number one to eight" {
  assert_eq(@tiff.orientation(pages), Some(1))
}

///|
/// A picture wider than a tile and not a multiple of one, so that the last
/// column and the last row of tiles are the padded ones.
fn tiled_image() -> @raster.Image {
  let width = 35
  let height = 21
  let pixels : FixedArray[Byte] = FixedArray::make(width * height * 4, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let at = (y * width + x) * 4
      pixels[at] = (x * 7).to_byte()
      pixels[at + 1] = (y * 11).to_byte()
      pixels[at + 2] = ((x + y) * 3).to_byte()
      pixels[at + 3] = b'\xff'
    }
  }
  image_of(
    width,
    height,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(pixels.clamped_view()),
  )
}

///|
test "a tiled page round trips at every compression" {
  let image = tiled_image()
  for
    compression in [
      @tiff.Compression::None,
      @tiff.Compression::Lzw,
      @tiff.Compression::PackBits,
      @tiff.Compression::Deflate,
    ] {
    let options : @tiff.EncodeOptions = {
      compression,
      rows_per_strip: 0,
      predictor: compression == @tiff.Compression::Deflate,
    }
    let file = @tiff.encode_tiled(image, 16, 16, options~)
    let back = decoded(file)
    assert_eq(back.width, 35)
    assert_eq(back.height, 21)
    assert_eq(digest_of(back), digest_of(image))
  }
}

///|
test "a tiled page and a page of strips hold the same pixels" {
  let image = tiled_image()
  let strips = encoded(image, @tiff.EncodeOptions::default())
  let tiles = @tiff.encode_tiled(image, 16, 16)
  // Different files, the same picture: the shape of a page is not part of what
  // it says.
  assert_eq(digest_of(decoded(tiles)), digest_of(decoded(strips)))
}

///|
test "an LZW stream stays in step past the widening of its codes" {
  // A page of a few thousand bytes grows the code width twice, and a writer
  // that grows it one code early or one code late reads back as a picture with
  // a seam in it rather than as a refusal.
  let image = tiled_image()
  let file = encoded(image, @tiff.EncodeOptions::{
    compression: @tiff.Compression::Lzw,
    rows_per_strip: 0,
    predictor: false,
  })
  assert_eq(digest_of(decoded(file)), digest_of(image))
}
