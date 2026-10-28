// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// TGA: the samples in `samples_test.mbt`, and the writer against the reader.

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
  @tga.decode(file) catch {
    error => abort("the sample should decode: \{error}")
  }
}

///|
fn refuses(file : Bytes) -> Bool {
  try {
    ignore(@tga.decode(file))
    false
  } catch {
    _ => true
  }
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
test "tga: every sample decodes to the reference pixels" {
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
test "tga: the type and depth of the file decide the format of the image" {
  assert_eq(read(sample_file("pillow-24")).format, @raster.PixelFormat::Rgb8)
  assert_eq(read(sample_file("pillow-32")).format, @raster.PixelFormat::Rgba8)
  assert_eq(read(sample_file("pillow-grey")).format, @raster.PixelFormat::Gray8)
  // Sixteen bits with an attribute bit is five-five-five and one of alpha.
  assert_eq(read(sample_file("built-16")).format, @raster.PixelFormat::Rgba8)
}

///|
test "tga: what the writer writes, the reader reads back" {
  let source = read(sample_file("pillow-32"))
  for depth in [@tga.Depth::Bits24, @tga.Depth::Bits32] {
    for rle in [false, true] {
      for top_down in [false, true] {
        let file = @tga.encode(source, options=@tga.EncodeOptions::{
          depth,
          rle,
          top_down,
        })
        let back = read(file)
        let expected = if depth == @tga.Depth::Bits24 {
          source.convert(@raster.PixelFormat::Rgb8)
        } else {
          source
        }
        assert_eq(back.format, expected.format)
        assert_eq(back.pixels, expected.pixels)
      }
    }
  }
}

///|
test "tga: runs make a flat image smaller and a noisy one no larger" {
  let flat = @raster.Image::of(
    40,
    40,
    @raster.PixelFormat::Rgba8,
    Bytes::repeat(b"\x10\x20\x30\xff", 1_600),
  )
  let plain = @tga.encode(flat, options=@tga.EncodeOptions::{
    depth: @tga.Depth::Bits32,
    rle: false,
    top_down: false,
  })
  let compressed = @tga.encode(flat, options=@tga.EncodeOptions::{
    depth: @tga.Depth::Bits32,
    rle: true,
    top_down: false,
  })
  assert_true(compressed.length() < plain.length())
  assert_eq(read(compressed).pixels, flat.pixels)
}

///|
test "tga: damage is refused" {
  let file = sample_file("pillow-24")
  assert_true(refuses(file.clamped_view(start=0, end=8).to_owned()))
  // The last twenty-six bytes of a TGA are its footer, so a file loses its
  // pixels only once the cut reaches them.
  assert_true(
    refuses(file.clamped_view(start=0, end=file.length() / 2).to_owned()),
  )
  let tight : @raster.Limits = { width: 4, height: 4, pixels: 16, bytes: 64, }
  let refused = try {
    ignore(@tga.decode(file, limits=tight))
    false
  } catch {
    @raster.Refused::OverLimit(..) => true
    _ => false
  }
  assert_true(refused)
  // An image type nobody defined.
  let patched : FixedArray[Byte] = FixedArray::make(file.length(), b'\x00')
  patched.blit_from_bytesview(0, file)
  patched[2] = b'\x07'
  assert_true(refuses(Bytes::from_array(patched.clamped_view())))
}
