// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// B44 and B44A: a block of sixteen halves kept in fourteen bytes, and the three
// bytes a flat block is kept in.

///|
/// How far a block comes back from what went in.
///
/// A block keeps fifteen six-bit differences and one value written whole, so the
/// step it rounds to is a sixty-fourth of the span the block covers at most, and
/// half of that is the worst rounding. The picture here is smooth, which is what
/// B44 is for; a block of sixteen unrelated values is the one case it cannot
/// hold, and no bound on it would mean anything.
const B44_STEP : Double = 0.03125

///|
test "a picture written as blocks comes back within a step" {
  let image = image_of(11, 7, @raster.PixelFormat::RgbaF32, ramp(77))
  for compression in [@exr.Compression::B44, @exr.Compression::B44a] {
    let options : @exr.EncodeOptions = { compression, half: true, }
    let back = @exr.decode(@exr.encode(image, options~)) catch {
      error => abort("the file decodes: \{error}")
    }
    assert_eq(back.width, 11)
    assert_eq(back.height, 7)
    let floats_in = image.convert(@raster.PixelFormat::RgbaF32).pixels
    let floats_out = back.convert(@raster.PixelFormat::RgbaF32).pixels
    let mut worst = 0.0
    for i in 0..<(11 * 7 * 4) {
      let difference = (@raster.float_at(floats_in, i * 4).to_double() -
      @raster.float_at(floats_out, i * 4).to_double()).abs()
      if difference > worst {
        worst = difference
      }
    }
    if worst > B44_STEP {
      abort("lost \{worst}")
    }
  }
}

///|
test "a flat picture is three bytes a block in B44A and fourteen in B44" {
  let flat = image_of(8, 8, @raster.PixelFormat::RgbaF32, solid(64, 0.5))
  let short = @exr.encode(flat, options={
    compression: @exr.Compression::B44a,
    half: true,
  })
  let long = @exr.encode(flat, options={
    compression: @exr.Compression::B44,
    half: true,
  })
  // Eight by eight is four blocks of four by four, and four channels: three
  // bytes against fourteen for every one of them.
  assert_eq(long.length() - short.length(), 4 * 4 * 11)
  let back = @exr.decode(short) catch {
    error => abort("the file decodes: \{error}")
  }
  // A block of one value is written as that value, so it comes back exactly.
  assert_eq(rgba8(back), rgba8(flat))
}

///|
/// A picture that changes slowly from one pixel to the next, which is what a
/// block of four by four has to hold: B44 keeps the difference between
/// neighbours, so a block whose neighbours are far apart is the one case it
/// cannot hold.
fn ramp(count : Int32) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(count * 16, b'\x00')
  for i in 0..<count {
    @raster.put_float(out, i * 16, Float::from_double(i.to_double() / 512.0))
    @raster.put_float(
      out,
      i * 16 + 4,
      Float::from_double((count - i).to_double() / 512.0),
    )
    @raster.put_float(out, i * 16 + 8, 0.25F)
    @raster.put_float(out, i * 16 + 12, 1.0F)
  }
  Bytes::from_array(out.clamped_view())
}

///|
/// A picture whose every sample is the same value.
fn solid(count : Int32, value : Double) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(count * 16, b'\x00')
  for i in 0..<count {
    for channel in 0..<4 {
      @raster.put_float(
        out,
        i * 16 + channel * 4,
        if channel == 3 {
          1.0F
        } else {
          Float::from_double(value)
        },
      )
    }
  }
  Bytes::from_array(out.clamped_view())
}
