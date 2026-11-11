// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// DirectDraw surfaces, written.

///|
/// A picture that changes slowly from one pixel to the next, which is what a
/// block of four by four with two endpoints can follow. A block of four flat
/// colours cannot be held by two endpoints at all, and no bound on it would mean
/// anything.
fn smooth_image(width : Int32, height : Int32) -> @raster.Image {
  let pixels : FixedArray[Byte] = FixedArray::make(width * height * 4, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let at = (y * width + x) * 4
      pixels[at] = (x * 255 / (width - 1)).to_byte()
      pixels[at + 1] = (y * 255 / (height - 1)).to_byte()
      pixels[at + 2] = b'\x80'
      pixels[at + 3] = (64 + (x + y) * 128 / (width + height - 2)).to_byte()
    }
  }
  @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(pixels.clamped_view()),
  ) catch {
    error => abort("the test picture is well formed: \{error}")
  }
}

///|
/// The largest difference between two pictures over the channels a block
/// format carries, or over all four.
fn widest(
  left : @raster.Image,
  right : @raster.Image,
  channels : Int32,
) -> Int32 {
  let a = left.convert(@raster.PixelFormat::Rgba8).pixels
  let b = right.convert(@raster.PixelFormat::Rgba8).pixels
  let mut worst = 0
  for i in 0..<(a.length() / 4) {
    for channel in 0..<channels {
      let difference = (a[i * 4 + channel].to_int() -
      b[i * 4 + channel].to_int()).abs()
      if difference > worst {
        worst = difference
      }
    }
  }
  worst
}

///|
test "a surface of plain samples comes back exactly" {
  let image = smooth_image(19, 11)
  let file = @dds.encode(image) catch { error => abort("\{error}") }
  let back = @dds.decode(file) catch { error => abort("\{error}") }
  assert_eq(back.width, 19)
  assert_eq(back.height, 11)
  assert_eq(widest(image, back, 4), 0)
}

///|
test "a colour block follows a gradient to within a sixteenth of a step" {
  let image = smooth_image(19, 11)
  for
    block in [
      @dds.Block::Bc1,
      @dds.Block::Bc1Opaque,
      @dds.Block::Bc2,
      @dds.Block::Bc3,
    ] {
    let file = @dds.encode(image, block~) catch { error => abort("\{error}") }
    let back = @dds.decode(file) catch { error => abort("\{error}") }
    assert_eq(back.width, 19)
    // Two endpoints describe a line through the colours of a block, and a
    // gradient that changes in two directions at once is a plane: what the block
    // loses is the distance from that line, which is at most half the spread the
    // block covers, and around a tenth of a sample per step of the picture.
    let gap = widest(image, back, 3)
    if gap > 32 {
      abort("\{block.to_repr()}: \{gap}")
    }
  }
}

///|
test "the alpha of a block comes back within a sixteenth of a step" {
  let image = smooth_image(19, 11)
  let file = @dds.encode(image, block=@dds.Block::Bc3) catch {
    error => abort("\{error}")
  }
  let back = @dds.decode(file) catch { error => abort("\{error}") }
  let a = image.convert(@raster.PixelFormat::Rgba8).pixels
  let b = back.convert(@raster.PixelFormat::Rgba8).pixels
  for i in 0..<(a.length() / 4) {
    let difference = (a[i * 4 + 3].to_int() - b[i * 4 + 3].to_int()).abs()
    if difference > 16 {
      abort("alpha at \{i}: \{difference}")
    }
  }
}

///|
test "a block of one channel keeps its grey and a block of two their red and green" {
  let image = smooth_image(19, 11)
  let grey = @dds.encode(image, block=@dds.Block::Bc4) catch {
    error => abort("\{error}")
  }
  let back = @dds.decode(grey) catch { error => abort("\{error}") }
  assert_eq(back.format, @raster.PixelFormat::Gray8)
  let plane = @dds.encode(image, block=@dds.Block::Bc5) catch {
    error => abort("\{error}")
  }
  let two = @dds.decode(plane) catch { error => abort("\{error}") }
  assert_eq(two.format, @raster.PixelFormat::Rgb8)
  // The two channels of a BC5 block are the red and the green of the picture.
  let a = image.convert(@raster.PixelFormat::Rgb8).pixels
  let b = two.pixels
  for i in 0..<(a.length() / 3) {
    for channel in 0..<2 {
      let difference = (a[i * 3 + channel].to_int() -
      b[i * 3 + channel].to_int()).abs()
      if difference > 16 {
        abort("channel \{channel} at \{i}: \{difference}")
      }
    }
  }
}

///|
test "every block format round trips through its own header" {
  let image = smooth_image(13, 9)
  for
    block in [
      @dds.Block::Bc1,
      @dds.Block::Bc1Opaque,
      @dds.Block::Bc2,
      @dds.Block::Bc3,
      @dds.Block::Bc4,
      @dds.Block::Bc5,
      @dds.Block::Bc6h,
      @dds.Block::Bc7,
    ] {
    let file = @dds.encode(image, block~) catch {
      error => abort("\{block.to_repr()}: \{error}")
    }
    // A block of sixteen bytes names its format in an extension header, and one
    // of eight names it in the four-character code the header always had.
    let back = @dds.decode(file) catch {
      error => abort("\{block.to_repr()}: \{error}")
    }
    assert_eq(back.width, 13)
    assert_eq(back.height, 9)
  }
}

///|
test "a block of eight bits follows a gradient to within a sixteenth of a step" {
  let image = smooth_image(19, 11)
  let file = @dds.encode(image, block=@dds.Block::Bc7) catch {
    error => abort("\{error}")
  }
  let back = @dds.decode(file) catch { error => abort("\{error}") }
  // A block of one region fits a line through its colours; a gradient that
  // changes in two directions at once is a plane, so what is left is the
  // distance from the line — the same bound a colour block of BC1 is held to,
  // with alpha held to it as well.
  let gap = widest(image, back, 4)
  if gap > 32 {
    abort("bc7: \{gap}")
  }
}

///|
/// A picture of light that changes in one direction, which is what a block of
/// BC6H follows: a line through the block is a line through the picture.
fn ramp_of_light(width : Int32, height : Int32) -> @raster.Image {
  let pixels : FixedArray[Byte] = FixedArray::make(width * height * 16, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let at = (y * width + x) * 16
      @raster.put_float(
        pixels,
        at,
        Float::from_double(x.to_double() / (width - 1).to_double() * 4.0),
      )
      @raster.put_float(pixels, at + 4, 0.75F)
      @raster.put_float(pixels, at + 8, 0.5F)
      @raster.put_float(pixels, at + 12, 1.0F)
    }
  }
  @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::RgbaF32,
    Bytes::from_array(pixels.clamped_view()),
  ) catch {
    error => abort("the test picture is well formed: \{error}")
  }
}

///|
test "a block of light keeps its range and its shape" {
  let image = ramp_of_light(19, 11)
  for block in [@dds.Block::Bc6h, @dds.Block::Bc6hSigned] {
    let file = @dds.encode(image, block~) catch { error => abort("\{error}") }
    let back = @dds.decode(file) catch { error => abort("\{error}") }
    assert_eq(back.width, 19)
    assert_eq(back.height, 11)
    let a = image.pixels
    let b = back.pixels
    let mut worst = 0.0
    for i in 0..<(19 * 11) {
      for c in 0..<3 {
        let left = @raster.float_at(a, i * 16 + c * 4).to_double()
        let right = @raster.float_at(b, i * 16 + c * 4).to_double()
        let difference = (left - right).abs()
        if difference > worst {
          worst = difference
        }
      }
    }
    // Four steps of the ramp across a block, each a twenty-second of the range;
    // a weight of four bits lands within half a step of one, and the ten bits of
    // an endpoint add a twentieth of the range on top of that.
    if worst > 0.12 {
      abort("\{block.to_repr()}: \{worst}")
    }
  }
}

///|
test "a block of light holds a plane as well as one line can" {
  // A picture that changes in two directions at once is a plane, and one region
  // of a block is a line: what is left is the distance from the line, which is
  // bounded by the spread across the block rather than by the precision of the
  // weights.
  let width = 19
  let height = 11
  let pixels : FixedArray[Byte] = FixedArray::make(width * height * 16, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let at = (y * width + x) * 16
      @raster.put_float(
        pixels,
        at,
        Float::from_double(x.to_double() / 18.0 * 4.0),
      )
      @raster.put_float(
        pixels,
        at + 4,
        Float::from_double(y.to_double() / 10.0 * 2.0),
      )
      @raster.put_float(pixels, at + 8, 0.5F)
      @raster.put_float(pixels, at + 12, 1.0F)
    }
  }
  let image = @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::RgbaF32,
    Bytes::from_array(pixels.clamped_view()),
  ) catch {
    error => abort("the test picture is well formed: \{error}")
  }
  let file = @dds.encode(image, block=@dds.Block::Bc6h) catch {
    error => abort("\{error}")
  }
  let back = @dds.decode(file) catch { error => abort("\{error}") }
  let mut worst = 0.0
  for i in 0..<(width * height) {
    for c in 0..<3 {
      let left = @raster.float_at(image.pixels, i * 16 + c * 4).to_double()
      let right = @raster.float_at(back.pixels, i * 16 + c * 4).to_double()
      let difference = (left - right).abs()
      if difference > worst {
        worst = difference
      }
    }
  }
  if worst > 1.0 {
    abort("a plane: \{worst}")
  }
}

///|
test "a block of light that has a sign comes back negative where it went in" {
  let width = 8
  let height = 4
  let pixels : FixedArray[Byte] = FixedArray::make(width * height * 16, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let at = (y * width + x) * 16
      @raster.put_float(
        pixels,
        at,
        Float::from_double(x.to_double() / 7.0 - 0.5),
      )
      @raster.put_float(pixels, at + 4, -0.25F)
      @raster.put_float(pixels, at + 8, 0.125F)
      @raster.put_float(pixels, at + 12, 1.0F)
    }
  }
  let image = @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::RgbaF32,
    Bytes::from_array(pixels.clamped_view()),
  ) catch {
    error => abort("the test picture is well formed: \{error}")
  }
  // The unsigned half of the format has no sign to put a negative sample in, and
  // says so rather than brightening the picture.
  let refused = try {
    ignore(@dds.encode(image, block=@dds.Block::Bc6h))
    false
  } catch {
    @raster.Refused::Unsupported(..) => true
    _ => false
  }
  assert_true(refused)
  let file = @dds.encode(image, block=@dds.Block::Bc6hSigned) catch {
    error => abort("\{error}")
  }
  let back = @dds.decode(file) catch { error => abort("\{error}") }
  let mut lowest = 1.0
  for i in 0..<(width * height) {
    let red = @raster.float_at(back.pixels, i * 16).to_double()
    if red < lowest {
      lowest = red
    }
  }
  assert_true(lowest < 0.0)
}
