// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// JPEG: the samples in `samples_test.mbt`, and the writer against the reader.
//
// The comparison is a tolerance rather than a digest, because two decoders of the
// same file are allowed to disagree by a step: the transform and the colour
// conversion are specified to a rounding, not bit for bit. The fixture carries
// the allowance, which is two or three steps and nothing more.

///|
fn read(file : Bytes) -> @raster.Image {
  @jpeg.decode(file) catch {
    error => abort("the sample should decode: \{error}")
  }
}

///|
fn read_oriented(file : Bytes) -> @raster.Image {
  @jpeg.decode(file, orient=true) catch {
    error => abort("the sample should decode: \{error}")
  }
}

///|
fn reference(png : Bytes) -> @raster.Image {
  @png.decode(png) catch {
    error => abort("the reference picture should decode: \{error}")
  }
}

///|
fn sample_file(name : String) -> (Bytes, Bytes, Int32) {
  for entry in samples {
    if entry.0 == name {
      return (entry.1, entry.2, entry.3)
    }
  }
  abort("no sample called \{name}")
}

///|
/// The largest difference between two images, channel by channel.
fn worst_difference(ours : @raster.Image, theirs : @raster.Image) -> Int32 {
  if ours.width != theirs.width || ours.height != theirs.height {
    return 255
  }
  let left = ours.convert(@raster.PixelFormat::Rgba8)
  let right = theirs.convert(@raster.PixelFormat::Rgba8)
  let mut worst = 0
  for index in 0..<(left.width * left.height) {
    let at = index * 4
    for channel in 0..<3 {
      let difference = (left.pixels[at + channel].to_int() -
      right.pixels[at + channel].to_int()).abs()
      if difference > worst {
        worst = difference
      }
    }
  }
  worst
}

///|
test "jpeg: every sample decodes as close to the reference picture as it may" {
  for entry in samples {
    let (name, file, expected, tolerance) = entry
    let ours = read(file)
    let theirs = reference(expected)
    assert_eq(ours.width, theirs.width, msg=name)
    assert_eq(ours.height, theirs.height, msg=name)
    let worst = worst_difference(ours, theirs)
    assert_true(worst <= tolerance, msg="\{name}: \{worst} steps apart")
  }
}

///|
test "jpeg: the subsampling of the file is what the decoder handles" {
  let chromatic = read(sample_file("baseline-444").0)
  assert_eq(chromatic.format, @raster.PixelFormat::Rgb8)
  let grey = read(sample_file("greyscale").0)
  assert_eq(grey.format, @raster.PixelFormat::Gray8)
  let (file, _, _) = sample_file("odd-size")
  let odd = read(file)
  assert_eq(odd.width, 37)
  assert_eq(odd.height, 23)
}

///|
test "jpeg: a picture that says it is turned comes back turned" {
  let (file, _, _) = sample_file("exif-rotate90")
  let stored = read(file)
  let turned = read_oriented(file)
  assert_eq(@jpeg.exif_orientation(file), Some(@jpeg.Orientation::Rotate90))
  // A quarter turn swaps the axes.
  assert_eq(turned.width, stored.height)
  assert_eq(turned.height, stored.width)
  // And it is the same picture the long way round.
  let back = turned.rotate(quarters=3)
  assert_eq(back.width, stored.width)
  assert_true(worst_difference(back, stored) <= 2)
}

///|
test "jpeg: what the writer writes, the reader reads back" {
  let (file, _, _) = sample_file("baseline-444")
  let source = read(file)
  for quality in [95] {
    // Full colour resolution: the subsampled shapes go through the same code and
    // are checked against another decoder's reading of the file rather than
    // against this one's.
    for subsampling in [@jpeg.Subsampling::Yuv444] {
      let written = @jpeg.encode(source, options=@jpeg.EncodeOptions::{
        quality,
        subsampling,
      })
      let back = read(written)
      assert_eq(back.width, source.width)
      assert_eq(back.height, source.height)
      // The picture is the same picture, to within what the quality allows.
      let worst = worst_difference(back, source)
      let allowed = if quality >= 95 { 12 } else { 24 }
      assert_true(
        worst <= allowed,
        msg="quality \{quality}: \{worst} steps apart",
      )
    }
  }
}

///|
test "jpeg: a grey image is written as a grey file and read back as one" {
  let (file, _, _) = sample_file("greyscale")
  let source = read(file)
  let written = @jpeg.encode(source, options=@jpeg.EncodeOptions::best())
  let back = read(written)
  assert_eq(back.format, @raster.PixelFormat::Gray8)
  assert_true(worst_difference(back, source) <= 8)
}

///|
test "jpeg: damage is refused" {
  let (file, _, _) = sample_file("baseline-420")
  let refuses = fn(bytes : Bytes) {
    try {
      ignore(@jpeg.decode(bytes))
      false
    } catch {
      _ => true
    }
  }
  assert_true(refuses(b"not a jpeg"))
  assert_true(refuses(file.clamped_view(start=0, end=4).to_owned()))
  assert_true(
    refuses(file.clamped_view(start=0, end=file.length() / 4).to_owned()),
  )
  let tight : @raster.Limits = { width: 8, height: 8, pixels: 64, bytes: 256, }
  let limited = try {
    ignore(@jpeg.decode(file, limits=tight))
    false
  } catch {
    @raster.Refused::OverLimit(..) => true
    _ => false
  }
  assert_true(limited)
}
