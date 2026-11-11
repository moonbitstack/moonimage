// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// OpenEXR files whose chunks are tiles, and files of more than one part.

///|
test "a tiled file decodes to the pixels its own reader sees" {
  for (name, file, expected) in tiled {
    let image = @exr.decode(file) catch { error => abort("\{name}: \{error}") }
    let actual = float_digest_of(image)
    if actual != expected {
      abort("\{name}: decoded to \{actual}, want \{expected}")
    }
  }
}

///|
test "a tiled file keeps the size of its window" {
  let (name, file, _) = tiled[0]
  let image = @exr.decode(file) catch { error => abort("\{name}: \{error}") }
  assert_eq(image.width, 41)
  assert_eq(image.height, 23)
}

///|
test "every part of a file with several decodes" {
  for (name, file, expected) in parts {
    let images = @exr.decode_parts(file) catch {
      error => abort("\{name}: \{error}")
    }
    assert_eq(images.length(), expected.length())
    for index in 0..<images.length() {
      let actual = float_digest_of(images[index])
      if actual != expected[index] {
        abort(
          "\{name} part \{index}: decoded to \{actual}, want \{expected[index]}",
        )
      }
    }
  }
}

///|
test "decode takes the first part, which is the one of the picture" {
  let (name, file, expected) = parts[0]
  let image = @exr.decode(file) catch { error => abort("\{name}: \{error}") }
  assert_eq(float_digest_of(image), expected[0])
  assert_eq(image.width, 41)
  assert_eq(image.height, 23)
}

///|
test "a tiled file of frequencies decodes within a step of a half" {
  for (name, file, packed) in tiled_dwa {
    let image = @exr.decode(file) catch { error => abort("\{name}: \{error}") }
    let count = image.width * image.height
    let expected = @zlib.unzlib(packed[:], limit=count * 16) catch {
      _ => abort("\{name}: the pixels it was written with do not inflate")
    }
    let mut worst = 0.0
    for i in 0..<count {
      for channel in 0..<4 {
        let at = i * 16 + channel * 4
        let difference = (@raster.float_at(image.pixels, at).to_double() -
        @raster.float_at(expected, at).to_double()).abs()
        if difference > worst {
          worst = difference
        }
      }
    }
    if worst > DWA_TOLERANCE {
      abort("\{name}: differs from the reference by \{worst}")
    }
  }
}

///|
test "a file of several parts this library writes holds the pictures it was given" {
  let first = image_of(13, 9, @raster.PixelFormat::RgbaF32, floats(117))
  let second = image_of(6, 4, @raster.PixelFormat::RgbaF32, floats(24))
  let file = @exr.encode_parts([("colour", first), ("thumbnail", second)])
  let images = @exr.decode_parts(file) catch {
    error => abort("the file this library wrote does not read: \{error}")
  }
  assert_eq(images.length(), 2)
  // The numbers of the test picture are multiples of a sixteenth, which is exact
  // as a half, so a round trip through the file loses nothing.
  assert_eq(float_digest_of(images[0]), float_digest_of(first))
  assert_eq(images[1].width, 6)
  assert_eq(images[1].height, 4)
  assert_eq(float_digest_of(images[1]), float_digest_of(second))
}

///|
test "several parts are written in every compression the file takes" {
  let first = image_of(11, 7, @raster.PixelFormat::RgbaF32, floats(77))
  let second = image_of(5, 3, @raster.PixelFormat::RgbaF32, floats(15))
  for
    compression in [
      @exr.Compression::None,
      @exr.Compression::Zip,
      @exr.Compression::Piz,
      @exr.Compression::Pxr24,
    ] {
    let file = @exr.encode_parts([("a", first), ("b", second)], options=@exr.EncodeOptions::{
      compression,
      half: true,
    })
    let images = @exr.decode_parts(file) catch {
      error => abort("\{compression.code()}: \{error}")
    }
    assert_eq(images.length(), 2)
    assert_eq(float_digest_of(images[0]), float_digest_of(first))
    assert_eq(float_digest_of(images[1]), float_digest_of(second))
  }
}
