// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing a lossy WebP, and reading it back with this library's own decoder.

///|
/// A picture that changes in two directions at once, with a hard edge across it:
/// what a lossy codec has to keep, and where it shows what it threw away.
fn lossy_picture(width : Int32, height : Int32) -> @raster.Image {
  let pixels : FixedArray[Byte] = FixedArray::make(width * height * 4, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let at = (y * width + x) * 4
      let red = x * 255 / (width - 1)
      let green = y * 255 / (height - 1)
      let blue = if x + y > width { 220 } else { 40 }
      pixels[at] = red.to_byte()
      pixels[at + 1] = green.to_byte()
      pixels[at + 2] = blue.to_byte()
      pixels[at + 3] = b'\xFF'
    }
  }
  @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(pixels.clamped_view()),
  ) catch {
    error => abort("the test picture is well formed: \{error}")
  }
}

///|
/// How far two pictures are apart, on the average of the squares of the
/// differences — the measure a lossy codec is judged by.
fn root_mean_square(left : @raster.Image, right : @raster.Image) -> Double {
  let a = left.convert(@raster.PixelFormat::Rgba8).pixels
  let b = right.convert(@raster.PixelFormat::Rgba8).pixels
  let mut total = 0.0
  for i in 0..<(a.length() / 4) {
    for channel in 0..<3 {
      let difference = (a[i * 4 + channel].to_int() -
      b[i * 4 + channel].to_int()).to_double()
      total = total + difference * difference
    }
  }
  (total / (left.width * left.height * 3).to_double()).sqrt()
}

///|
test "a lossy picture reads back as the picture it was made from" {
  let image = lossy_picture(67, 45)
  let file = @webp.encode_lossy(image)
  let back = @webp.decode(file) catch { error => abort("\{error}") }
  assert_eq(back.width, 67)
  assert_eq(back.height, 45)
  let error = root_mean_square(image, back)
  println("lossy rmse \{error}")
  if error > 12.0 {
    abort("the picture came back too far away: \{error}")
  }
}

///|
test "the quality of a lossy picture moves with the number asked for" {
  let image = lossy_picture(48, 33)
  let mut previous = -1.0
  for quality in [20, 50, 80, 95] {
    let file = @webp.encode_lossy(image, quality~)
    let back = @webp.decode(file) catch { error => abort("\{error}") }
    let error = root_mean_square(image, back)
    println("quality \{quality}: \{file.length()} bytes, \{error}")
    assert_true(error < previous || previous < 0.0)
    previous = error
  }
}

///|
test "a lossy picture with alpha keeps its alpha exactly" {
  let image = lossy_picture(32, 20)
  let pixels = image.pixels
  let out : FixedArray[Byte] = FixedArray::make(32 * 20 * 4, b'\x00')
  for i in 0..<(32 * 20) {
    for c in 0..<3 {
      out[i * 4 + c] = pixels[i * 4 + c]
    }
    out[i * 4 + 3] = (i % 256).to_byte()
  }
  let with_alpha = @raster.Image::of(
    32,
    20,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(out.clamped_view()),
  ) catch {
    error => abort("\{error}")
  }
  let file = @webp.encode_lossy(with_alpha)
  let back = @webp.decode(file) catch { error => abort("\{error}") }
  let a = with_alpha.pixels
  let b = back.convert(@raster.PixelFormat::Rgba8).pixels
  for i in 0..<(32 * 20) {
    assert_eq(a[i * 4 + 3].to_int(), b[i * 4 + 3].to_int())
  }
}
