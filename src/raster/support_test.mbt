// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The images the tests in this package share.
//
// One three by two image whose six pixels are all different, so that an operation
// which puts a pixel in the wrong place cannot pass by accident, and the two
// helpers every test needs to look inside an image without handling a refusal
// that cannot happen.

///|
fn sample() -> @raster.Image {
  let pixels : Bytes = b"\x0a\x14\x1e\xff\x28\x32\x3c\xff\x46\x50\x5a\xff" +
    b"\x64\x6e\x78\xff\x82\x8c\x96\xff\xa0\xaa\xb4\xff"
  image_of(3, 2, @raster.PixelFormat::Rgba8, pixels)
}

///|
fn image_of(
  width : Int32,
  height : Int32,
  format : @raster.PixelFormat,
  pixels : Bytes,
) -> @raster.Image {
  @raster.Image::of(width, height, format, pixels) catch {
    error => abort("the test image is well formed: \{error}")
  }
}

///|
/// The pixel at a coordinate, as four bytes.
fn at(
  image : @raster.Image,
  x : Int32,
  y : Int32,
) -> (Int32, Int32, Int32, Int32) {
  image.pixel(x, y).rgba8() catch {
    error => abort("in range: \{error}")
  }
}

///|
fn bytes_of(image : @raster.Image) -> Bytes {
  image.pixels
}

///|
/// The image as eight-bit RGBA bytes, which is what a comparison wants when the
/// two sides disagree about how many bits a sample takes.
fn rgba8_of(image : @raster.Image) -> Bytes {
  image.convert(@raster.PixelFormat::Rgba8).pixels
}
