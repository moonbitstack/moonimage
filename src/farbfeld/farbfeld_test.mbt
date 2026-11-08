// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// farbfeld: a header, the samples, and nothing that could be got wrong.

///|
test "the sample decodes to the pixels it was built from" {
  for sample in samples {
    let (name, file, expected) = sample
    let image = @farbfeld.decode(file) catch {
      error => abort("\{name}: \{error}")
    }
    let actual = digest_of(image)
    if actual != expected {
      abort("\{name}: decoded to \{actual}, want \{expected}")
    }
  }
}

///|
test "sixteen bits a channel widens an eight-bit picture exactly" {
  let image = image_of(
    2,
    2,
    @raster.PixelFormat::Rgba8,
    b"\x00\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb\xcc\xdd\xee\xff",
  )
  let back = @farbfeld.decode(@farbfeld.encode(image)) catch {
    error => abort("the file decodes: \{error}")
  }
  assert_eq(back.format, @raster.PixelFormat::Rgba16)
  assert_eq(rgba8(back), image.pixels)
}

///|
test "a file that stops in the middle of the samples is refused" {
  let image = image_of(2, 2, @raster.PixelFormat::Rgba8, sample_pixels())
  let file = @farbfeld.encode(image)
  let short = cut(file, file.length() - 3)
  let refused = try {
    ignore(@farbfeld.decode(short))
    false
  } catch {
    @raster.Refused::Truncated(..) => true
    _ => false
  }
  assert_true(refused)
}

///|
test "a size past the limits is refused before anything is allocated" {
  let file = b"farbfeld\x7f\xff\xff\xff\x7f\xff\xff\xff"
  let refused = try {
    ignore(@farbfeld.decode(file))
    false
  } catch {
    @raster.Refused::OverLimit(..) => true
    _ => false
  }
  assert_true(refused)
}

///|
fn sample_pixels() -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  for i in 0..<16 {
    out[i] = (i * 13).to_byte()
  }
  Bytes::from_array(out.clamped_view())
}

///|
fn cut(file : Bytes, length : Int32) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(length, b'\x00')
  for i in 0..<length {
    out[i] = file[i]
  }
  Bytes::from_array(out.clamped_view())
}
