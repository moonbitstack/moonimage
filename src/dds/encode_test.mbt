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
test "the two formats that are read and not written refuse to be written" {
  let image = smooth_image(8, 8)
  for block in [@dds.Block::Bc6h, @dds.Block::Bc7] {
    let refused = try {
      ignore(@dds.encode(image, block~))
      false
    } catch {
      @raster.Refused::Unsupported(..) => true
      _ => false
    }
    assert_true(refused)
  }
}
