// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// BMP: the samples in `samples_test.mbt`, and the writer against the reader.

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
  @bmp.decode(file) catch {
    error => abort("the sample should decode: \{error}")
  }
}

///|
fn refuses(file : Bytes) -> Bool {
  try {
    ignore(@bmp.decode(file))
    false
  } catch {
    _ => true
  }
}

///|
test "bmp: every sample decodes to the reference pixels" {
  for entry in samples {
    let (name, file, expected) = entry
    let image = read(file)
    assert_eq(
      digest(image.convert(@raster.PixelFormat::Rgba8).pixels),
      expected,
      msg=name,
    )
  }
}

///|
test "bmp: the depth of the file decides the format of the image" {
  assert_eq(read(sample_file("pillow-24")).format, @raster.PixelFormat::Rgb8)
  assert_eq(read(sample_file("pillow-32")).format, @raster.PixelFormat::Rgba8)
  assert_eq(
    read(sample_file("pillow-8-palette")).format,
    @raster.PixelFormat::Rgb8,
  )
  assert_eq(read(sample_file("built-rle4")).format, @raster.PixelFormat::Rgb8)
  assert_eq(
    read(sample_file("built-32-alpha")).format,
    @raster.PixelFormat::Rgba8,
  )
}

///|
fn sample_file(name : String) -> Bytes {
  for entry in samples {
    if entry.0 == name {
      return entry.1
    }
  }
  abort("no sample called \{name}")
}

///|
test "bmp: what the writer writes, the reader reads back" {
  let source = read(samples[0].1).convert(@raster.PixelFormat::Rgba8)
  for depth in [@bmp.Depth::Bits24, @bmp.Depth::Bits32] {
    for top_down in [false, true] {
      let file = @bmp.encode(source, options=@bmp.EncodeOptions::{
        depth,
        top_down,
      })
      let back = read(file)
      let expected = if depth == @bmp.Depth::Bits24 {
        source.convert(@raster.PixelFormat::Rgb8)
      } else {
        source
      }
      assert_eq(back.format, expected.format)
      assert_eq(back.pixels, expected.pixels)
    }
  }
}

///|
test "bmp: damage is refused" {
  let file = samples[0].1
  assert_true(refuses(b"not a bitmap"))
  assert_true(
    refuses(file.clamped_view(start=0, end=file.length() / 3).to_owned()),
  )
  // A height that would ask for a gigabyte is refused before it is allocated.
  let tight : @raster.Limits = { width: 4, height: 4, pixels: 16, bytes: 64, }
  let refused = try {
    ignore(@bmp.decode(file, limits=tight))
    false
  } catch {
    @raster.Refused::OverLimit(..) => true
    _ => false
  }
  assert_true(refused)
  // A compression nobody implements.
  let patched : FixedArray[Byte] = FixedArray::make(file.length(), b'\x00')
  patched.blit_from_bytesview(0, file)
  patched[30] = b'\x07'
  assert_true(refuses(Bytes::from_array(patched.clamped_view())))
}
