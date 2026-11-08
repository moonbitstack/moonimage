// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Radiance HDR: the run-length code, the four origins, and the range the format
// exists for.

///|
test "the sample decodes to the floats the generator computed" {
  for sample in samples {
    let (name, file, expected) = sample
    let image = @hdr.decode(file) catch { error => abort("\{name}: \{error}") }
    let actual = float_digest_of(image)
    if actual != expected {
      abort("\{name}: decoded to \{actual}, want \{expected}")
    }
  }
}

///|
test "a highlight survives a round trip above one" {
  let bright : FixedArray[Byte] = FixedArray::make(3 * 2 * 16, b'\x00')
  let values = [(8.0, 2.0, 0.5), (1.0, 2.0, 4.0), (0.0, 0.0, 0.0)]
  for i in 0..<6 {
    let (r, g, b) = values[i % 3]
    @raster.put_float(bright, i * 16, Float::from_double(r))
    @raster.put_float(bright, i * 16 + 4, Float::from_double(g))
    @raster.put_float(bright, i * 16 + 8, Float::from_double(b))
    @raster.put_float(bright, i * 16 + 12, 1.0F)
  }
  let image = @raster.Image::of(
    3,
    2,
    @raster.PixelFormat::RgbaF32,
    Bytes::from_array(bright.clamped_view()),
  ) catch {
    error => abort("the test image is well formed: \{error}")
  }
  let file = @hdr.encode(image)
  let back = @hdr.decode(file) catch {
    error => abort("the file decodes: \{error}")
  }
  // Eight bits of mantissa is what the format has: a value comes back within a
  // quarter of a percent of itself, and eight stays eight rather than clamping
  // to one.
  let (r, g, b, a) = sample_of(back, 0, 0)
  assert_true(r > 7.9 && r < 8.1)
  assert_true(g > 1.9 && g < 2.1)
  assert_true(b > 0.4 && b < 0.6)
  assert_eq(a, 1.0)
}

///|
test "a narrow picture is stored without the run-length code" {
  let narrow = @raster.Image::new(4, 2, @raster.PixelFormat::RgbaF32)
  let file = @hdr.encode(narrow)
  let back = @hdr.decode(file) catch {
    error => abort("the narrow file decodes: \{error}")
  }
  assert_eq(back.width, 4)
  assert_eq(back.height, 2)
}

///|
test "the origin can be any of the four corners" {
  let width = 8
  let height = 2
  // Two scanlines of eight distinct pixels, each written flat: the header says
  // where the first one belongs.
  let pixels : Array[(Int32, Int32, Int32, Int32)] = []
  for y in 0..<height {
    for x in 0..<width {
      pixels.push((128 + x * 3, 128 + y * 5, 128, 129))
    }
  }
  let flat = flat_body(pixels)
  let top_down = b"#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 8\n" + flat
  let bottom_up = b"#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n+Y 2 +X 8\n" + flat
  let one = @hdr.decode(top_down) catch {
    error => abort("the file decodes: \{error}")
  }
  let other = @hdr.decode(bottom_up) catch {
    error => abort("the file decodes: \{error}")
  }
  // The same bytes, read from the other end: the two pictures are each other
  // upside down.
  assert_eq(sample_of(one, 0, 0), sample_of(other, 0, 1))
  assert_eq(sample_of(one, 3, 1), sample_of(other, 3, 0))
}

///|
test "a header with no format line is refused" {
  let file = b"#?RADIANCE\nEXPOSURE=1.0\n\n-Y 2 +X 8\n"
  let refused = try {
    ignore(@hdr.decode(file))
    false
  } catch {
    @raster.Refused::Unsupported(..) => true
    _ => false
  }
  assert_true(refused)
}

///|
/// Two scanlines of four bytes a pixel, with no run-length code.
fn flat_body(pixels : Array[(Int32, Int32, Int32, Int32)]) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(pixels.length() * 4, b'\x00')
  for i in 0..<pixels.length() {
    let (r, g, b, e) = pixels[i]
    out[i * 4] = r.to_byte()
    out[i * 4 + 1] = g.to_byte()
    out[i * 4 + 2] = b.to_byte()
    out[i * 4 + 3] = e.to_byte()
  }
  Bytes::from_array(out.clamped_view())
}

///|
/// The four floats of one pixel, read without handling a refusal that cannot
/// happen at a coordinate the test chose.
fn sample_of(
  image : @raster.Image,
  x : Int32,
  y : Int32,
) -> (Double, Double, Double, Double) {
  let at = y * image.stride + x * 16
  (
    @raster.float_at(image.pixels, at).to_double(),
    @raster.float_at(image.pixels, at + 4).to_double(),
    @raster.float_at(image.pixels, at + 8).to_double(),
    @raster.float_at(image.pixels, at + 12).to_double(),
  )
}
