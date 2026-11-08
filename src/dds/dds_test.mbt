// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// DirectDraw surfaces: the blocks, one format at a time.

///|
test "every sample decodes to the colours the block encodes" {
  for sample in samples {
    let (name, file, expected) = sample
    let image = @dds.decode(file) catch { error => abort("\{name}: \{error}") }
    let actual = digest_bytes(image.pixels)
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
test "BC4 puts its one channel in red and leaves the rest at the ends" {
  // Index nought is the first endpoint, which is the larger one here.
  let block = b"\xff\x00" + le48(0)
  let file = header(4, 4, b"ATI1") + block
  let image = @dds.decode(file) catch {
    error => abort("the texture decodes: \{error}")
  }
  assert_eq(image.pixel(2, 3).rgba8(), (255, 255, 0, 255))
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
