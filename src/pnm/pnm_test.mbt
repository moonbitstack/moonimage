// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The portable anymap, read against what Pillow wrote and written back in every
// shape the writer offers.

///|
test "every sample decodes to the pixels Pillow read" {
  for sample in samples {
    let (name, file, expected) = sample
    let actual = digest_of(
      @pnm.decode(file) catch {
        error => abort("\{name}: \{error}")
      },
    )
    if actual != expected {
      abort("\{name}: decoded to \{actual}, want \{expected}")
    }
  }
}

///|
test "each shape round trips at its own maximum" {
  let colour = image_of(3, 2, @raster.PixelFormat::Rgb8, ramp(18))
  for kind in [@pnm.Kind::Gray, @pnm.Kind::Rgb, @pnm.Kind::Any] {
    for maxval in [255, 65535] {
      let options : @pnm.EncodeOptions = { kind, maxval, ascii: false, }
      let back = @pnm.decode(@pnm.encode(colour, options~)) catch {
        error => abort("the file decodes: \{error}")
      }
      // A grey picture is not the colour one it came from, so only the shapes
      // that keep three channels are compared against it.
      if kind != @pnm.Kind::Gray {
        assert_eq(rgba8(back), rgba8(colour))
      }
    }
  }
}

///|
test "the digits spelling holds the same picture as the bytes" {
  let colour = image_of(3, 2, @raster.PixelFormat::Rgb8, ramp(18))
  let raw = @pnm.encode(colour, options={
    kind: @pnm.Kind::Rgb,
    maxval: 255,
    ascii: false,
  })
  let digits = @pnm.encode(colour, options={
    kind: @pnm.Kind::Rgb,
    maxval: 255,
    ascii: true,
  })
  assert_true(digits.has_prefix(b"P3"))
  assert_true(raw.has_prefix(b"P6"))
  let one = @pnm.decode(raw) catch { _ => abort("the raw file decodes") }
  let other = @pnm.decode(digits) catch {
    _ => abort("the digits file decodes")
  }
  assert_eq(rgba8(one), rgba8(other))
}

///|
test "a bit map is one bit a pixel with a padded row" {
  // Three pixels a row: the row takes one byte, and the last five bits are
  // padding that must not become pixels.
  let file = b"P4\n3 2\n\xa0\x40"
  let image = @pnm.decode(file) catch {
    error => abort("the bit map decodes: \{error}")
  }
  assert_eq(image.width, 3)
  assert_eq(image.height, 2)
  // One is black in this format, which is the opposite of every other sample.
  assert_eq(image.pixel(0, 0).rgba8(), (0, 0, 0, 255))
  assert_eq(image.pixel(1, 0).rgba8(), (255, 255, 255, 255))
}

///|
test "a sample above the declared maximum is refused" {
  let file = b"P2\n2 1\n7\n3 9\n"
  let refused = try {
    ignore(@pnm.decode(file))
    false
  } catch {
    @raster.Refused::Unexpected(..) => true
    _ => false
  }
  assert_true(refused)
}

///|
test "a header that stops before its samples is refused" {
  let file = b"P6\n4 4\n255\n\x00\x01\x02"
  let refused = try {
    ignore(@pnm.decode(file))
    false
  } catch {
    @raster.Refused::Truncated(..) => true
    _ => false
  }
  assert_true(refused)
}

///|
fn ramp(count : Int32) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(count, b'\x00')
  for i in 0..<count {
    out[i] = ((i * 37 + 11) % 256).to_byte()
  }
  Bytes::from_array(out.clamped_view())
}
