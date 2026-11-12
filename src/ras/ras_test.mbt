// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Sun raster: the samples in `samples_test.mbt`, and the writer against the
// reader.

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
  @ras.decode(file) catch {
    error => abort("the sample should decode: \{error}")
  }
}

///|
fn refuses(file : Bytes) -> Bool {
  try {
    ignore(@ras.decode(file))
    false
  } catch {
    _ => true
  }
}

///|
test "ras: every sample decodes to the reference pixels" {
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
test "ras: a picture written comes back, odd width and all" {
  // An odd width is the case that catches a reader walking samples flat: the
  // row carries a byte of padding that belongs to nothing.
  let width = 11
  let height = 7
  let pixels : FixedArray[Byte] = FixedArray::make(width * height * 4, b'\xFF')
  for y in 0..<height {
    for x in 0..<width {
      let p = (y * width + x) * 4
      pixels[p] = (x * 21).to_byte()
      pixels[p + 1] = (y * 31).to_byte()
      pixels[p + 2] = ((x * 7 + y * 9) % 256).to_byte()
    }
  }
  let picture = @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(pixels.clamped_view()),
  )
  let file = @ras.encode(picture)
  let back = read(file)
  assert_eq(back.width, width)
  assert_eq(back.height, height)
  assert_eq(
    digest(back.convert(@raster.PixelFormat::Rgba8).pixels),
    digest(picture.pixels),
  )
}

///|
test "ras: the fourth byte carries alpha for this library and nothing for others" {
  let pixels : FixedArray[Byte] = FixedArray::make(5 * 3 * 4, b'\x00')
  for i in 0..<(5 * 3) {
    pixels[i * 4] = (i * 13).to_byte()
    pixels[i * 4 + 1] = (i * 7).to_byte()
    pixels[i * 4 + 2] = (i * 3).to_byte()
    pixels[i * 4 + 3] = (255 - i).to_byte()
  }
  let picture = @raster.Image::of(
    5,
    3,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(pixels.clamped_view()),
  )
  let file = @ras.encode(picture)
  // Depth thirty-two when the picture is not opaque.
  let depth = (file[12].to_int() << 24) |
    (file[13].to_int() << 16) |
    (file[14].to_int() << 8) |
    file[15].to_int()
  assert_eq(depth, 32)
  let back = read(file)
  assert_eq(
    digest(back.convert(@raster.PixelFormat::Rgba8).pixels),
    digest(picture.pixels),
  )
}

///|
test "ras: what is not one is refused" {
  assert_true(refuses(b""))
  let other : FixedArray[Byte] = FixedArray::make(64, b'\x00')
  assert_true(refuses(Bytes::from_array(other.clamped_view())))
  // A Sun raster with a depth no reader carries.
  let odd : FixedArray[Byte] = FixedArray::make(64, b'\x00')
  odd[0] = b'\x59'
  odd[1] = b'\xA6'
  odd[2] = b'\x6A'
  odd[3] = b'\x95'
  odd[7] = b'\x04'
  odd[11] = b'\x04'
  odd[15] = b'\x07'
  assert_true(refuses(Bytes::from_array(odd.clamped_view())))
}
