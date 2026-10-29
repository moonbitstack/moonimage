// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The program the guide walks through, in order.
//
// It is here so that every snippet on that page has been run: the output printed
// below each one on the page is the output this prints. `moon run` it and the
// numbers should be the ones the page shows.

///|
/// A picture made from nothing: four columns, three rows, five colours.
///
/// Written out pixel by pixel so that the guide has a file whose contents are
/// known — every later number on the page comes from this one.
fn picture() -> @raster.Image raise @raster.Refused {
  let palette : Array[(Int32, Int32, Int32, Int32)] = [
    (214, 178, 92, 255),
    (122, 58, 44, 255),
    (79, 106, 84, 255),
    (36, 28, 21, 255),
    (244, 237, 222, 128),
  ]
  let bytes : FixedArray[Byte] = FixedArray::make(4 * 3 * 4, b'\x00')
  for y in 0..<3 {
    for x in 0..<4 {
      let (r, g, b, a) = palette[(y * 4 + x) % palette.length()]
      let at = (y * 4 + x) * 4
      bytes[at] = r.to_byte()
      bytes[at + 1] = g.to_byte()
      bytes[at + 2] = b.to_byte()
      bytes[at + 3] = a.to_byte()
    }
  }
  @raster.Image::of(
    4,
    3,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(bytes.clamped_view()),
  )
}

///|
/// The whole of a small copy in one function: read, scale, write.
///
/// This is the function the homepage shows, and the shape most callers end up
/// with — the format is discovered rather than passed in, and the error is the
/// one value that can go wrong.
fn small_copy(file : Bytes) -> Bytes raise @moonimage.Refused {
  let image = @moonimage.decode(file)
  let small = image.scale(320, 200)
  @moonimage.encode(small, @moonimage.Format::Webp)
}

///|
fn main {
  // A picture, and what it says about itself.
  let image = picture() catch {
    error => abort("the picture is well formed: \{error}")
  }
  println(
    "\{image.width} x \{image.height}, \{image.format}, \{image.pixels.length()} bytes",
  )

  // Writing it out as a PNG, and reading it back.
  let file = @moonimage.encode(image, @moonimage.Format::Png)
  let back = @moonimage.decode(file) catch {
    error => abort("the file is one this library wrote: \{error}")
  }
  println(
    "\{file.length()} bytes of PNG, read back as \{back.width} x \{back.height} \{back.format}",
  )

  // One pixel, as four numbers between nought and one.
  let pixel = back.pixel(1, 0) catch {
    error => abort("inside the picture: \{error}")
  }
  let eighth = fn(value : Double) -> Int32 { (value * 255.0 + 0.5).to_int() }
  println(
    "pixel (1, 0), eight bits a sample: \{eighth(pixel.r)} \{eighth(pixel.g)} \{eighth(pixel.b)} \{eighth(pixel.a)}",
  )

  // The same pixel after a change of layout.
  let grey = back.convert(@raster.PixelFormat::Gray8)
  let shade = grey.pixel(1, 0) catch {
    error => abort("inside the picture: \{error}")
  }
  println("as grey: \{grey.format}, \{eighth(shade.r)}")

  // The same picture as a thumbnail, through the one function the homepage
  // shows.
  let thumb = small_copy(file) catch {
    error => abort("the copy is well formed: \{error}")
  }
  println("as a 320 x 200 WebP: \{thumb.length()} bytes")

  // Geometry: each call gives a new picture.
  let turned = back.rotate(quarters=1)
  let mirrored = back.flip_horizontal()
  let cut = back.crop(0, 0, 2, 2) catch {
    error => abort("the rectangle fits: \{error}")
  }
  let small = back.scale(8, 6) catch {
    error => abort("the size is legal: \{error}")
  }
  println(
    "turned \{turned.width} x \{turned.height}, mirrored \{mirrored.width} x \{mirrored.height}, cut \{cut.width} x \{cut.height}, scaled \{small.width} x \{small.height}",
  )

  // Every format this library writes, with the size it came to.
  let formats : Array[(@moonimage.Format, String)] = [
    (@moonimage.Format::Png, "png"),
    (@moonimage.Format::Qoi, "qoi"),
    (@moonimage.Format::Bmp, "bmp"),
    (@moonimage.Format::Tga, "tga"),
    (@moonimage.Format::Jpeg, "jpeg"),
    (@moonimage.Format::Gif, "gif"),
    (@moonimage.Format::Webp, "webp"),
  ]
  for entry in formats {
    let (format, name) = entry
    let written = @moonimage.encode(back, format)
    println("\{name}: \{written.length()} bytes")
  }

  // Two frames, written as an animated GIF and read back.
  let animation = @moonimage.Animation::new(
    4,
    3,
    [
      @moonimage.Frame::new(back, delay=100),
      @moonimage.Frame::new(turned, delay=50),
    ],
    loops=0,
  )
  let gif = @moonimage.encode_animation(animation, @moonimage.Format::Gif) catch {
    error => abort("the animation is well formed: \{error}")
  }
  let again = @moonimage.decode_animation(gif) catch {
    error => abort("the file is one this library wrote: \{error}")
  }
  let frames = again.compose()
  println(
    "\{gif.length()} bytes of GIF, \{again.frames.length()} frames, first delay \{again.frames[0].delay}, \{frames.length()} composed",
  )

  // A file that is not one: the error says where and what.
  let broken = file.clamped_view(start=0, end=file.length() / 2).to_owned()
  let refused = try {
    ignore(@moonimage.decode(broken))
    "it did not"
  } catch {
    error => error.to_string()
  }
  println("half a file: \{refused}")

  // And a ceiling on what a file is allowed to ask for.
  let limits = @raster.Limits::{ width: 2, height: 2, pixels: 4, bytes: 1024, }
  let capped = try {
    ignore(@moonimage.decode(file, limits~))
    "it did not"
  } catch {
    error => error.to_string()
  }
  println("two by two limit: \{capped}")
}
