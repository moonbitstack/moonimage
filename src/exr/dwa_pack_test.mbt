// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// OpenEXR's two frequency-domain compressions, written.

///|
/// A picture that changes slowly from one pixel to the next, which is what a
/// transform of eight-by-eight blocks is for: a block of unrelated values is the
/// one case no quantizer of frequencies can hold.
fn dwa_picture(width : Int32, height : Int32) -> @raster.Image {
  let out : FixedArray[Byte] = FixedArray::make(width * height * 16, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let across = x.to_double() / width.to_double()
      let down = y.to_double() / height.to_double()
      let at = (y * width + x) * 16
      @raster.put_float(out, at, Float::from_double(across))
      @raster.put_float(out, at + 4, Float::from_double(down))
      @raster.put_float(out, at + 8, Float::from_double((across + down) / 2.0))
      @raster.put_float(out, at + 12, Float::from_double(0.5 + down / 2.0))
    }
  }
  image_of(
    width,
    height,
    @raster.PixelFormat::RgbaF32,
    Bytes::from_array(out.clamped_view()),
  )
}

///|
/// The largest difference between two pictures, channel by channel, as a
/// fraction of a sample.
fn dwa_gap(left : @raster.Image, right : @raster.Image) -> Double {
  let a = left.convert(@raster.PixelFormat::RgbaF32).pixels
  let b = right.convert(@raster.PixelFormat::RgbaF32).pixels
  let mut worst = 0.0
  for i in 0..<(a.length() / 4) {
    let difference = (@raster.float_at(a, i * 4) - @raster.float_at(b, i * 4)).to_double()
    let magnitude = if difference < 0.0 { -difference } else { difference }
    if magnitude > worst {
      worst = magnitude
    }
  }
  worst
}

///|
test "the two compressions write less than the samples they hold" {
  let image = dwa_picture(41, 23)
  let samples = 41 * 23 * 4 * 2
  for compression in [@exr.Compression::Dwaa, @exr.Compression::Dwab] {
    let file = @exr.encode(image, options=@exr.EncodeOptions::{
      compression,
      half: true,
    })
    // A transform of frequencies is what a photograph is stored with; a
    // gradient of two directions is the easy case, and it still has to be
    // smaller than the samples, or the file would have been written as they
    // came.
    if file.length() >= samples {
      abort("\{compression.code()}: \{file.length()} bytes against \{samples}")
    }
  }
}

///|
test "a picture comes back within a hundredth of a sample" {
  let image = dwa_picture(41, 23)
  for compression in [@exr.Compression::Dwaa, @exr.Compression::Dwab] {
    let file = @exr.encode(image, options=@exr.EncodeOptions::{
      compression,
      half: true,
    })
    let back = @exr.decode(file) catch {
      error => abort("\{compression.code()}: \{error}")
    }
    assert_eq(back.width, 41)
    assert_eq(back.height, 23)
    let gap = dwa_gap(image, back)
    // The quantizer is allowed to move a coefficient by a step of a frequency,
    // and a block of eight by eight adds those steps back up: a hundredth is
    // what the level the format defaults to works out to on a gradient, and the
    // same picture through the format's own writer lands at the same place.
    if gap > 0.01 {
      abort("\{compression.code()}: \{gap}")
    }
  }
}

///|
test "a chunk too small to gain is stored as it came" {
  let pixels : FixedArray[Byte] = FixedArray::make(2 * 2 * 16, b'\x00')
  for i in 0..<16 {
    @raster.put_float(pixels, i * 4, Float::from_double(i.to_double() / 16.0))
  }
  let image = image_of(
    2,
    2,
    @raster.PixelFormat::RgbaF32,
    Bytes::from_array(pixels.clamped_view()),
  )
  let file = @exr.encode(image, options=@exr.EncodeOptions::{
    compression: @exr.Compression::Dwaa,
    half: true,
  })
  let back = @exr.decode(file) catch { error => abort("\{error}") }
  assert_eq(dwa_gap(image, back), 0.0)
}
