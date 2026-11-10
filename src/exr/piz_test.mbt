// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// PIZ, the compression that looks at the picture rather than at the bytes.
//
// The samples it is held to come out of OpenEXR 3.5.3, in `samples_test.mbt`,
// with the digest the format's own library read back from each one. So these are
// not comparisons against another implementation of the same idea: they are the
// format's own bytes with the format's own answer.

///|
/// The PIZ samples, which are the ones whose name says so.
fn piz_cases() -> Array[(String, Bytes, String)] {
  let cases : Array[(String, Bytes, String)] = []
  for sample in samples {
    if sample.0.contains("-piz") {
      cases.push(sample)
    }
  }
  cases
}

///|
test "PIZ files written by the format's library read back sample for sample" {
  let cases = piz_cases()
  assert_eq(cases.length(), 3)
  for sample in cases {
    let (name, bytes, expected) = sample
    let image = @exr.decode(bytes) catch { error => abort("\{name}: \{error}") }
    let got = float_digest_of(image)
    if got != expected {
      abort("\{name}: reads \{got}, the library read \{expected}")
    }
  }
}

///|
test "a PIZ file survives a round trip through this writer" {
  let (name, bytes, _) = piz_cases()[1]
  let image = @exr.decode(bytes) catch {
    error => abort("\{name} decodes: \{error}")
  }
  for half in [true, false] {
    let written = @exr.encode(image, options=@exr.EncodeOptions::{
      compression: @exr.Compression::Piz,
      half,
    })
    let back = @exr.decode(written) catch {
      error => abort("what this library writes decodes: \{error}")
    }
    assert_eq(float_digest_of(back), float_digest_of(image))
    // PIZ is worth writing only when it beats the pixels it holds.
    assert_eq(written.length() < image.width * image.height * 16, true)
  }
}

///|
test "a flat picture takes the run code and comes back whole" {
  let flat = @raster.Image::new(64, 40, @raster.PixelFormat::Rgba8)
  let written = @exr.encode(flat, options=@exr.EncodeOptions::{
    compression: @exr.Compression::Piz,
    half: true,
  })
  let back = @exr.decode(written) catch {
    error => abort("a flat picture decodes: \{error}")
  }
  assert_eq(float_digest_of(back), float_digest_of(flat))
  // Two chunks of thirty-two scanlines of nothing but zeroes come to far less
  // than the pixels they hold.
  assert_eq(written.length() < 64 * 40, true)
}

///|
test "PIZ keeps the range of a file of floats" {
  let (name, bytes, _) = piz_cases()[2]
  let image = @exr.decode(bytes) catch {
    error => abort("\{name} decodes: \{error}")
  }
  let wide = image.convert(@raster.PixelFormat::RgbaF32)
  let mut highest = 0.0
  for y in 0..<wide.height {
    for x in 0..<wide.width {
      let value = @raster.float_at(wide.pixels, y * wide.stride + x * 16).to_double()
      if value > highest {
        highest = value
      }
    }
  }
  // The picture rises above one on its right-hand half, which is the sample a
  // file of halves could not carry.
  assert_eq(highest > 1.9, true)
}
