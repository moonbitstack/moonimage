// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// SGI: the samples in `samples_test.mbt`, and the writer against the reader.

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
  @sgi.decode(file) catch {
    error => abort("the sample should decode: \{error}")
  }
}

///|
fn refuses(file : Bytes) -> Bool {
  try {
    ignore(@sgi.decode(file))
    false
  } catch {
    _ => true
  }
}

///|
test "sgi: every sample decodes to the reference pixels" {
  for entry in samples {
    let (name, file, expected) = entry
    let image = read(file)
    // The sixteen-bit sample stays at sixteen bits; the rest come back as
    // eight.
    let pixels = if image.format == @raster.PixelFormat::Rgba16 {
      image.pixels
    } else {
      image.convert(@raster.PixelFormat::Rgba8).pixels
    }
    assert_eq(digest(pixels), expected, msg="\{name}")
  }
}

///|
test "sgi: a picture written comes back the right way up" {
  let width = 13
  let height = 9
  let pixels : FixedArray[Byte] = FixedArray::make(width * height * 4, b'\xFF')
  for y in 0..<height {
    for x in 0..<width {
      let p = (y * width + x) * 4
      pixels[p] = (x * 17).to_byte()
      pixels[p + 1] = (y * 25).to_byte()
      pixels[p + 2] = ((x * 3 + y * 5) % 256).to_byte()
    }
  }
  let picture = @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(pixels.clamped_view()),
  )
  let file = @sgi.encode(picture)
  // Three channels when the picture is opaque.
  assert_eq((file[10].to_int() << 8) | file[11].to_int(), 3)
  let back = read(file)
  assert_eq(back.width, width)
  assert_eq(back.height, height)
  assert_eq(
    digest(back.convert(@raster.PixelFormat::Rgba8).pixels),
    digest(picture.pixels),
  )
  // The first row in the file is the last row of the picture: its first sample
  // is the red of the bottom-left pixel, and the one at the start of the last
  // row is the red of the top-left pixel.
  assert_eq(file[512].to_int(), 0)
  assert_eq(file[512 + width * height].to_int(), (height - 1) * 25)
}

///|
test "sgi: four channels keep the alpha, and the file says so" {
  let pixels : FixedArray[Byte] = FixedArray::make(6 * 4 * 4, b'\x00')
  for i in 0..<(6 * 4) {
    pixels[i * 4] = (i * 9).to_byte()
    pixels[i * 4 + 1] = (i * 5).to_byte()
    pixels[i * 4 + 2] = (i * 3).to_byte()
    pixels[i * 4 + 3] = (200 - i).to_byte()
  }
  let picture = @raster.Image::of(
    6,
    4,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(pixels.clamped_view()),
  )
  let file = @sgi.encode(picture)
  assert_eq((file[10].to_int() << 8) | file[11].to_int(), 4)
  let back = read(file)
  assert_eq(
    digest(back.convert(@raster.PixelFormat::Rgba8).pixels),
    digest(picture.pixels),
  )
}

///|
test "sgi: run-length rows are refused by name" {
  let file : FixedArray[Byte] = FixedArray::make(600, b'\x00')
  file[0] = b'\x01'
  file[1] = b'\xDA'
  file[2] = b'\x01'
  file[3] = b'\x01'
  file[9] = b'\x02'
  file[11] = b'\x03'
  assert_true(refuses(Bytes::from_array(file.clamped_view())))
  // And a file that is not an SGI at all.
  let other : FixedArray[Byte] = FixedArray::make(600, b'\x00')
  assert_true(refuses(Bytes::from_array(other.clamped_view())))
}
