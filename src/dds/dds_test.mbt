// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// DirectDraw surfaces: the blocks, one format at a time.

///|
test "every sample decodes to the colours the block encodes" {
  for sample in samples {
    let (name, file, expected) = sample
    let image = @dds.decode(file) catch { error => abort("\{name}: \{error}") }
    let actual = digest_of(image)
    if actual != expected {
      abort("\{name}: decoded to \{actual}, want \{expected}")
    }
  }
}

///|
test "the middle two entries of a four-colour block are thirds" {
  let first = 0xF800
  let second = 0x001F
  // 0xAAAAAAAA as a signed word: every pair of bits is ten.
  let block = le16(first) + le16(second) + le32(-1431655766)
  let file = header(4, 4, b"DXT1") + block
  let image = @dds.decode(file) catch {
    error => abort("the texture decodes: \{error}")
  }
  // Every pair of bits is ten, which is index two: two thirds of the way from
  // the first endpoint to the second.
  assert_eq(image.pixel(0, 0).rgba8(), (170, 0, 85, 255))
  assert_eq(image.pixel(3, 3).rgba8(), (170, 0, 85, 255))
}

///|
test "the three-colour form has a transparent entry" {
  // The first endpoint is the smaller, which is what asks for the form with a
  // transparent fourth entry.
  let file = header(4, 4, b"DXT1") +
    le16(0x001F) +
    le16(0xF800) +
    le32(0xFFFFFFFF)
  let image = @dds.decode(file) catch {
    error => abort("the texture decodes: \{error}")
  }
  assert_eq(image.pixel(0, 0).rgba8(), (0, 0, 0, 0))
}

///|
test "BC4 is a grey picture, because one channel is one channel" {
  // Index nought is the first endpoint, which is the larger one here.
  let block = b"\xff\x00" + le48(0)
  let file = header(4, 4, b"ATI1") + block
  let image = @dds.decode(file) catch {
    error => abort("the texture decodes: \{error}")
  }
  assert_eq(image.format, @raster.PixelFormat::Gray8)
  assert_eq(image.pixel(2, 3).rgba8(), (255, 255, 255, 255))
}

///|
test "BC5 is red and green, which is what a normal map is stored as" {
  let block = b"\xff\x00" + le48(0) + b"\x00\xff" + le48(0)
  let file = header(4, 4, b"ATI2") + block
  let image = @dds.decode(file) catch {
    error => abort("the texture decodes: \{error}")
  }
  assert_eq(image.format, @raster.PixelFormat::Rgb8)
  // The first block is the red channel, the second the green, and blue is left
  // at nought rather than invented.
  assert_eq(image.pixel(0, 0).rgba8(), (255, 0, 0, 255))
}

///|
test "the six-step alpha of BC3 has a nought and a two hundred and fifty-five" {
  // The first endpoint is the smaller, which is what asks for the six-step
  // form: four interpolated values, then nought and two hundred and fifty-five.
  // Indices nought, one and two for the first three pixels, nought after.
  let alpha = b"\x00\xff" + le48(136)
  let colour = le16(0xF800) + le16(0x001F) + le32(0)
  let file = header(4, 4, b"DXT5") + alpha + colour
  let image = @dds.decode(file) catch {
    error => abort("the texture decodes: \{error}")
  }
  assert_eq(image.pixel(0, 0).rgba8().3, 0)
  assert_eq(image.pixel(1, 0).rgba8().3, 255)
  // The first interpolated step is four fifths of the way from nought to
  // two hundred and fifty-five, which is fifty-one.
  assert_eq(image.pixel(2, 0).rgba8().3, 51)
}

///|
test "a block that is not there is refused" {
  let file = header(8, 8, b"DXT5")
  let refused = try {
    ignore(@dds.decode(file))
    false
  } catch {
    @raster.Refused::Truncated(..) => true
    _ => false
  }
  assert_true(refused)
}

///|
test "a format this library does not read is refused by name" {
  let file = header(4, 4, b"DXT2") + le32(0) + le32(0) + le32(0) + le32(0)
  let refused = try {
    ignore(@dds.decode(file))
    false
  } catch {
    @raster.Refused::Unsupported(..) => true
    _ => false
  }
  assert_true(refused)
}

///|
fn header(width : Int32, height : Int32, fourcc : Bytes) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(128, b'\x00')
  let put = fn(at : Int32, value : Int32) {
    out[at] = (value & 0xFF).to_byte()
    out[at + 1] = ((value >> 8) & 0xFF).to_byte()
    out[at + 2] = ((value >> 16) & 0xFF).to_byte()
    out[at + 3] = ((value >> 24) & 0xFF).to_byte()
  }
  out[0] = b'D'
  out[1] = b'D'
  out[2] = b'S'
  out[3] = b' '
  for i in 0..<4 {
    out[84 + i] = fourcc[i]
  }
  put(4, 124)
  put(12, height)
  put(16, width)
  put(76, 32)
  put(80, 4)
  Bytes::from_array(out.clamped_view())
}

///|
fn le16(value : Int32) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(2, b'\x00')
  out[0] = (value & 0xFF).to_byte()
  out[1] = ((value >> 8) & 0xFF).to_byte()
  Bytes::from_array(out.clamped_view())
}

///|
fn le32(value : Int32) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(4, b'\x00')
  out[0] = (value & 0xFF).to_byte()
  out[1] = ((value >> 8) & 0xFF).to_byte()
  out[2] = ((value >> 16) & 0xFF).to_byte()
  out[3] = ((value >> 24) & 0xFF).to_byte()
  Bytes::from_array(out.clamped_view())
}

///|
fn le48(value : Int32) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(6, b'\x00')
  for i in 0..<6 {
    out[i] = ((value >> (i * 8)) & 0xFF).to_byte()
  }
  Bytes::from_array(out.clamped_view())
}

///|
/// A header whose format is named by a DXGI number, which is how every texture
/// written since Direct3D 10 does it.
fn header10(width : Int32, height : Int32, dxgi : Int32) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(148, b'\x00')
  let put = fn(at : Int32, value : Int32) {
    out[at] = (value & 0xFF).to_byte()
    out[at + 1] = ((value >> 8) & 0xFF).to_byte()
    out[at + 2] = ((value >> 16) & 0xFF).to_byte()
    out[at + 3] = ((value >> 24) & 0xFF).to_byte()
  }
  let fourcc = b"DX10"
  out[0] = b'D'
  out[1] = b'D'
  out[2] = b'S'
  out[3] = b' '
  for i in 0..<4 {
    out[84 + i] = fourcc[i]
  }
  put(4, 124)
  put(12, height)
  put(16, width)
  put(76, 32)
  put(80, 4)
  // The DXGI header: format, dimension of three, no misc flags, one array
  // element, no alpha mode.
  put(128, dxgi)
  put(132, 3)
  put(144, 1)
  Bytes::from_array(out.clamped_view())
}

///|
test "BC7 written as a DXGI format is eight bits a channel" {
  // Mode three with everything else at nought: black, and opaque, because that
  // mode has no alpha field.
  let block : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  block[0] = b'\x08'
  let file = header10(4, 4, 98) + Bytes::from_array(block.clamped_view())
  let image = @dds.decode(file) catch {
    error => abort("the texture decodes: \{error}")
  }
  assert_eq(image.format, @raster.PixelFormat::Rgba8)
  assert_eq(image.pixel(0, 0).rgba8(), (0, 0, 0, 255))
}

///|
test "BC6H is a picture of light, so it comes back as floats" {
  // Mode nought with everything else at nought: every endpoint is nought, so
  // every sample is the half for nought and the picture is black.
  let block : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  let file = header10(4, 4, 95) + Bytes::from_array(block.clamped_view())
  let image = @dds.decode(file) catch {
    error => abort("the texture decodes: \{error}")
  }
  assert_eq(image.format, @raster.PixelFormat::RgbaF32)
  let (red, green, blue, alpha) = image.pixel(2, 3).rgba8()
  assert_eq(red, 0)
  assert_eq(green, 0)
  assert_eq(blue, 0)
  // The format has no alpha, so a pixel is as opaque as one can be; the eight
  // bit view of that is two hundred and fifty-five.
  assert_eq(alpha, 255)
}

///|
test "a DXGI format above BC7 is still refused by name" {
  let file = header10(4, 4, 99) +
    Bytes::from_array(FixedArray::make(16, b'\x00').clamped_view())
  let refused = try {
    ignore(@dds.decode(file))
    false
  } catch {
    @raster.Refused::Unsupported(..) => true
    _ => false
  }
  assert_true(refused)
}
