// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Icons and cursors: the samples Pillow wrote, the direction a cursor points,
// and the round trip the writer has to make.

///|
test "every sample decodes to the pixels Pillow read" {
  for sample in samples {
    let (name, file, expected) = sample
    let actual = digest_of(
      @ico.decode(file) catch {
        error => abort("\{name}: \{error}")
      },
    )
    if actual != expected {
      abort("\{name}: decoded to \{actual}, want \{expected}")
    }
  }
}

///|
test "an icon written here is read back by this library" {
  let image = image_of_pixels()
  let file = @ico.encode(image)
  let all = @ico.decode_all(file) catch {
    error => abort("the icon decodes: \{error}")
  }
  assert_eq(all.length(), 1)
  assert_eq(rgba_of(all[0].image), rgba_of(image))
}

///|
test "a cursor keeps the spot it points at" {
  let image = image_of_pixels()
  let file = @ico.encode(image, options=@ico.EncodeOptions::cursor(3, 5))
  let all = @ico.decode_all(file) catch {
    error => abort("the cursor decodes: \{error}")
  }
  assert_eq(all[0].hot_x, 3)
  assert_eq(all[0].hot_y, 5)
}

///|
test "sizes are stored at the sizes asked for" {
  let image = image_of_pixels()
  let options : @ico.EncodeOptions = {
    kind: @ico.Kind::Icon,
    sizes: [8, 16],
    hot_x: 0,
    hot_y: 0,
  }
  let file = @ico.encode(image, options~)
  let all = @ico.decode_all(file) catch {
    error => abort("the icon decodes: \{error}")
  }
  assert_eq(all.length(), 2)
  assert_eq(all[0].image.width, 8)
  assert_eq(all[1].image.width, 16)
  // The widest is what a caller that asked for "the icon" gets.
  assert_eq((@ico.decode(file) catch { _ => abort("it decodes") }).width, 16)
}

///|
test "a directory that points past the end is refused" {
  let file = @ico.encode(image_of_pixels())
  let broken = truncate(file, file.length() - 8)
  let refused = try {
    ignore(@ico.decode(broken))
    false
  } catch {
    @raster.Refused::Truncated(..) => true
    _ => false
  }
  assert_true(refused)
}

///|
fn truncate(file : Bytes, length : Int32) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(length, b'\x00')
  for i in 0..<length {
    out[i] = file[i]
  }
  Bytes::from_array(out.clamped_view())
}

///|
fn image_of_pixels() -> @raster.Image {
  let buffer : FixedArray[Byte] = FixedArray::make(16 * 16 * 4, b'\x00')
  for y in 0..<16 {
    for x in 0..<16 {
      let at = (y * 16 + x) * 4
      buffer[at] = (x * 16).to_byte()
      buffer[at + 1] = (y * 16).to_byte()
      buffer[at + 2] = ((x + y) * 8).to_byte()
      buffer[at + 3] = (if x + y < 16 { 255 } else { 128 }).to_byte()
    }
  }
  @raster.Image::of(
    16,
    16,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(buffer.clamped_view()),
  ) catch {
    error => abort("the test image is well formed: \{error}")
  }
}

///|
fn rgba_of(image : @raster.Image) -> Bytes {
  image.convert(@raster.PixelFormat::Rgba8).pixels
}
