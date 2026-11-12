// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// PCX: the samples in `samples_test.mbt`, and the writer against the reader.

///|
fn digest(bytes : BytesView) -> String {
  let mut value : UInt64 = 0xCBF29CE484222325
  for index in 0..<bytes.length() {
    value = (value ^ bytes[index].to_int().to_uint64()) * 0x100000001B3
  }
  let digits = "0123456789abcdef"
  let mut out = ""
  for index in 0..<16 {
    let shift = (15 - index) * 4
    let nibble = (value >> shift).to_int() & 0xF
    out = out + digits[nibble:nibble + 1].to_owned()
  }
  out
}

///|
fn read(file : Bytes) -> @raster.Image {
  @pcx.decode(file) catch {
    error => abort("the sample should decode: \{error}")
  }
}

///|
fn refuses(file : Bytes) -> Bool {
  try {
    ignore(@pcx.decode(file))
    false
  } catch {
    _ => true
  }
}

///|
test "pcx: every sample decodes to the pixels the palette names" {
  for entry in samples {
    let (name, file, expected) = entry
    let image = read(file)
    assert_eq(
      digest(image.convert(@raster.PixelFormat::Rgba8).pixels),
      expected,
      msg="\{name}",
    )
  }
}

///|
test "pcx: a picture written comes back" {
  let pixels : FixedArray[Byte] = FixedArray::make(23 * 17 * 4, b'\x00')
  for y in 0..<17 {
    for x in 0..<23 {
      let p = (y * 23 + x) * 4
      pixels[p] = (x * 11).to_byte()
      pixels[p + 1] = (y * 15).to_byte()
      pixels[p + 2] = ((x + y) * 7).to_byte()
      pixels[p + 3] = b'\xFF'
    }
  }
  let picture = @raster.Image::of(
    23,
    17,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(pixels.clamped_view()),
  )
  let file = @pcx.encode(picture)
  // Three planes when every pixel is opaque: the fourth is not written.
  assert_eq(file[65].to_int(), 3)
  let back = read(file)
  assert_eq(back.width, 23)
  assert_eq(back.height, 17)
  assert_eq(
    digest(back.convert(@raster.PixelFormat::Rgba8).pixels),
    digest(picture.pixels),
  )
}

///|
test "pcx: four planes carry the alpha" {
  let pixels : FixedArray[Byte] = FixedArray::make(9 * 5 * 4, b'\x00')
  for i in 0..<(9 * 5) {
    pixels[i * 4] = (i * 3).to_byte()
    pixels[i * 4 + 1] = (255 - i * 3).to_byte()
    pixels[i * 4 + 2] = (i * 7).to_byte()
    pixels[i * 4 + 3] = (i * 5).to_byte()
  }
  let picture = @raster.Image::of(
    9,
    5,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(pixels.clamped_view()),
  )
  let file = @pcx.encode(picture)
  assert_eq(file[65].to_int(), 4)
  let back = read(file)
  assert_eq(
    digest(back.convert(@raster.PixelFormat::Rgba8).pixels),
    digest(picture.pixels),
  )
}

///|
test "pcx: what is not one is refused, and says why" {
  // Nothing at all.
  assert_true(refuses(b""))
  // A header whose manufacturer code is not ZSoft's.
  let not_pcx : FixedArray[Byte] = FixedArray::make(160, b'\x00')
  not_pcx[0] = b'\x0B'
  assert_true(refuses(Bytes::from_array(not_pcx.clamped_view())))
  // A file that claims sixteen bits a pixel, which no reader writes.
  let odd : FixedArray[Byte] = FixedArray::make(160, b'\x00')
  odd[0] = b'\x0A'
  odd[1] = b'\x05'
  odd[2] = b'\x01'
  odd[3] = b'\x10'
  assert_true(refuses(Bytes::from_array(odd.clamped_view())))
}
