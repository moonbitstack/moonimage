// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The filters measured against an implementation nobody in this repository
// wrote. The cases come from `scripts/fixtures/formats.py`, which resampled and
// blurred the same picture with Pillow and stored both sides.

///|
/// The largest difference between two runs of samples, channel by channel.
fn widest_gap(one : Bytes, other : Bytes) -> Int32 {
  let mut worst = 0
  let count = if one.length() < other.length() {
    one.length()
  } else {
    other.length()
  }
  for i in 0..<count {
    let gap = (one[i].to_int() - other[i].to_int()).abs()
    if gap > worst {
      worst = gap
    }
  }
  worst
}

///|
/// The filter a case was made with, by the number the generator wrote.
fn sampling_of(code : Int32) -> @raster.Sampling {
  match code {
    0 => @raster.Sampling::Nearest
    1 => @raster.Sampling::Bilinear
    2 => @raster.Sampling::CatmullRom
    _ => @raster.Sampling::Lanczos
  }
}

///|
test "scaling agrees with Pillow to within one step of a sample" {
  for case in cases {
    let (name, width, height, code, source, expected) = case
    let image = image_of(13, 9, @raster.PixelFormat::Rgba8, source)
    let scaled = image.scale(width, height, sampling=sampling_of(code)) catch {
      error => abort("\{name}: \{error}")
    }
    let gap = widest_gap(rgba8_of(scaled), expected)
    if gap > 1 {
      abort("\{name}: differs from Pillow by \{gap}")
    }
  }
}

///|
test "a blurred picture is the kernel convolved, to within one step" {
  for case in blur_cases {
    let (name, radius, source, _, analytic) = case
    let image = image_of(13, 9, @raster.PixelFormat::Rgba8, source)
    let blurred = image.blur(radius)
    let gap = widest_gap(rgba8_of(blurred), analytic)
    if gap > 1 {
      abort("\{name}: differs from the kernel by \{gap}")
    }
  }
}

///|
test "and is as close to Pillow as an approximate Gaussian can be" {
  // Pillow computes a Gaussian blur as three box blurs, which is a different
  // curve with the same width; the bound here is what that comes to on this
  // picture, reported rather than held to a step.
  for case in blur_cases {
    let (name, radius, source, pillow, _) = case
    let image = image_of(13, 9, @raster.PixelFormat::Rgba8, source)
    let blurred = image.blur(radius)
    let gap = widest_gap(rgba8_of(blurred), pillow)
    if gap > 40 {
      abort("\{name}: differs from Pillow by \{gap}")
    }
  }
}
