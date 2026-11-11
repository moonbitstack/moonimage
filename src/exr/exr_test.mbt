// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// OpenEXR: the three compressions, halves against floats, and the half-precision
// conversion the format turns on.

///|
test "every sample decodes to the samples it was built from" {
  for sample in samples {
    let (name, file, expected) = sample
    let image = @exr.decode(file) catch { error => abort("\{name}: \{error}") }
    let actual = float_digest_of(image)
    if actual != expected {
      abort("\{name}: decoded to \{actual}, want \{expected}")
    }
  }
}

///|
test "each compression round trips" {
  let image = image_of(5, 4, @raster.PixelFormat::RgbaF32, floats(20))
  for
    compression in [
      @exr.Compression::None,
      @exr.Compression::Rle,
      @exr.Compression::Zips,
      @exr.Compression::Zip,
    ] {
    for half in [true, false] {
      let options : @exr.EncodeOptions = { compression, half, }
      let back = @exr.decode(@exr.encode(image, options~)) catch {
        error => abort("the file decodes: \{error}")
      }
      assert_eq(back.width, 5)
      assert_eq(back.height, 4)
      // A half has eleven bits of mantissa; the values here are multiples of a
      // sixteenth, which a half holds exactly.
      assert_eq(rgba8(back), rgba8(image))
    }
  }
}

///|
test "a half and a float agree on the values both can hold" {
  for bits in [0x3C00, 0x4000, 0x3800, 0x0001, 0x7C00, 0xBC00] {
    let value = @exr.half_to_float(bits)
    let back = @exr.float_to_half(value)
    if bits == 0x0001 {
      // The smallest subnormal rounds to itself only when written back with the
      // same rounding the format uses, which is what this checks.
      assert_eq(back, bits)
    } else {
      assert_eq(back, bits)
    }
  }
}

///|
test "a deep file is refused rather than read as an ordinary one" {
  // A deep file stores a list of samples per pixel rather than a sample, which
  // is a different way of reading every channel in it; a reader that took it
  // for an ordinary file would produce a picture of the wrong samples.
  let image = image_of(2, 2, @raster.PixelFormat::RgbaF32, floats(4))
  let file = @exr.encode(image)
  let deep = raise_flag(file, 0x800)
  let refused = try {
    ignore(@exr.decode(deep))
    false
  } catch {
    @raster.Refused::Unsupported(..) => true
    _ => false
  }
  assert_true(refused)
}

///|
test "a file whose header stops early is refused" {
  let refused = try {
    ignore(@exr.decode(b"\x76\x2f\x31\x01\x02\x00\x00\x00chan"))
    false
  } catch {
    @raster.Refused::Truncated(..) => true
    _ => false
  }
  assert_true(refused)
}

///|
/// The file with one flag bit set in its version word.
fn raise_flag(file : Bytes, flag : Int32) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(file.length(), b'\x00')
  for i in 0..<file.length() {
    out[i] = file[i]
  }
  let word = out[4].to_int() |
    (out[5].to_int() << 8) |
    (out[6].to_int() << 16) |
    (out[7].to_int() << 24)
  let changed = word | flag
  out[4] = (changed & 0xFF).to_byte()
  out[5] = ((changed >> 8) & 0xFF).to_byte()
  out[6] = ((changed >> 16) & 0xFF).to_byte()
  out[7] = ((changed >> 24) & 0xFF).to_byte()
  Bytes::from_array(out.clamped_view())
}

///|
/// A picture whose samples are multiples of a sixteenth, so that a half holds
/// them exactly and the round trip can be compared byte for byte.
fn floats(count : Int32) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(count * 16, b'\x00')
  for i in 0..<count {
    @raster.put_float(
      out,
      i * 16,
      Float::from_double((i % 16).to_double() / 16.0),
    )
    @raster.put_float(
      out,
      i * 16 + 4,
      Float::from_double((i * 3 % 16).to_double() / 16.0),
    )
    @raster.put_float(
      out,
      i * 16 + 8,
      Float::from_double((i * 7 % 16).to_double() / 16.0),
    )
    @raster.put_float(out, i * 16 + 12, 1.0F)
  }
  Bytes::from_array(out.clamped_view())
}
