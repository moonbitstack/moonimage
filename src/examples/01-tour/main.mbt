// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The whole surface in one run, so that a reader can see what this is for before
// reading any of it.
//
//     moon run src/examples/tour

///|
/// A small picture with a gradient, a little noise and a transparent corner: the
/// three things a codec has to get right.
fn paint(width : Int32, height : Int32) -> @moonimage.Image {
  let out = @buffer.Buffer::Buffer()
  let mut seed = 12345
  for y in 0..<height {
    for x in 0..<width {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
      let noise = if x > width / 2 { (seed >> 16) & 31 } else { 0 }
      let red = (x * 255 / (width - 1) + noise) & 0xFF
      let green = (y * 255 / (height - 1)) & 0xFF
      let blue = ((x + y) * 3) & 0xFF
      let alpha = if x < width / 4 && y < height / 4 { 0 } else { 255 }
      out.write_byte(red.to_byte())
      out.write_byte(green.to_byte())
      out.write_byte(blue.to_byte())
      out.write_byte(alpha.to_byte())
    }
  }
  @moonimage.Image::of(
    width,
    height,
    @moonimage.PixelFormat::Rgba8,
    out.to_bytes(),
  ) catch {
    error => abort("the painted image is well formed: \{error}")
  }
}

///|
#coverage.skip
fn main raise {
  let image = paint(64, 48)
  println(
    "a \{image.width} by \{image.height} picture, \{image.format.bytes()} bytes a pixel",
  )

  // The same picture in other shapes: a wider sample, a grey one, one with the
  // colour multiplied by the alpha.
  let wide = image.convert(@moonimage.PixelFormat::Rgb16)
  println(
    "as sixteen-bit colour: \{wide.format.bytes()} bytes a pixel, \{wide.pixels.length()} in all",
  )
  let grey = image.convert(@moonimage.PixelFormat::Gray8)
  println("as grey: \{grey.format.bytes()} byte a pixel")

  // The operations that move pixels without reading them.
  let turned = image.rotate(quarters=1)
  println("turned a quarter: \{turned.width} by \{turned.height}")
  let cropped = image.crop(8, 8, 32, 24) catch {
    error => abort("the rectangle fits: \{error}")
  }
  println("cropped: \{cropped.width} by \{cropped.height}")
  let small = image.scale(32, 24, sampling=@moonimage.Sampling::Lanczos) catch {
    error => abort("the size is allowed: \{error}")
  }
  println("scaled down with Lanczos: \{small.width} by \{small.height}")

  // Every format the library writes, and how large each one makes this picture.
  for
    format in [
      @moonimage.Format::Png,
      @moonimage.Format::Qoi,
      @moonimage.Format::Bmp,
      @moonimage.Format::Tga,
      @moonimage.Format::Gif,
      @moonimage.Format::Jpeg,
      @moonimage.Format::Webp,
    ] {
    let file = @moonimage.encode(image, format)
    let back = @moonimage.decode(file) catch {
      error => abort("what was written is read: \{error}")
    }
    println(
      "\{format}: \{file.length()} bytes, \{back.width} by \{back.height}, \{back.format.bytes()} bytes a pixel",
    )
  }

  // WebP is two codecs under one container, and this library writes only the
  // lossless one. The lossy one it reads, which is what most WebP on the web is;
  // the file below was written by `cwebp -q 75` from a 16 by 16 gradient, and is
  // here as the only way to show a decode without an encoder for it.
  let lossy : Bytes = b"RIFFR\x00\x00\x00WEBPVP8 F\x00\x00\x00\xf0\x01\x00\x9d\x01*\x10\x00\x10\x00\x02\x004%\xb0" +
    b"\x02t\x01\x0f\x0c\x12\xf2\xca\x80\x00\xfe\xfc\x03\xcb\xf2}\x12\xe9p\xe1\x0b\x86=\xa6\xed1" +
    b"\xff\xc9\x8at\xfe\xf9\xf0\x851x\x14D3\x97\xff\xfc\x8b\xddO\xff\xa7>\xf7\x0b\xfec\x00\x00\x00"
  let from_lossy = @moonimage.decode(lossy) catch {
    error => abort("the lossy file is read: \{error}")
  }
  println(
    "a lossy WebP of \{lossy.length()} bytes: \{from_lossy.width} by \{from_lossy.height}, \{from_lossy.format.bytes()} bytes a pixel",
  )

  // A picture that says what it is: the text goes into a PNG and comes back out.
  let annotated = @moonimage.Image::of(
    image.width,
    image.height,
    image.format,
    image.pixels,
    metadata=@moonimage.Metadata::{
      gamma: Some(0.45455),
      chromaticities: Some(@moonimage.Chromaticities::srgb()),
      intent: Some(@moonimage.Intent::Perceptual),
      icc: None,
      texts: [@moonimage.Text::Latin(keyword="Title", text="a gradient")],
    },
  ) catch {
    error => abort("the annotated image is well formed: \{error}")
  }
  let file = @moonimage.encode(annotated, @moonimage.Format::Png)
  let read_back = @moonimage.decode(file) catch {
    error => abort("the file is read: \{error}")
  }
  println("gamma came back as \{read_back.metadata.gamma.unwrap_or(0.0)}")
  println("the note came back as \{read_back.metadata.texts[0].text()}")

  // Animation, which three of the formats have.
  let dot = paint(8, 8)
  let animation = @moonimage.Animation::new(
    64,
    48,
    [
      @moonimage.Frame::new(image, delay=100),
      @moonimage.Frame::new(
        dot,
        x=16,
        y=16,
        delay=50,
        dispose=@moonimage.Dispose::Background,
      ),
    ],
    loops=2,
  )
  for
    format in [
      @moonimage.Format::Png,
      @moonimage.Format::Gif,
      @moonimage.Format::Webp,
    ] {
    let file = @moonimage.encode_animation(animation, format)
    let back = @moonimage.decode_animation(file) catch {
      error => abort("the animation is read: \{error}")
    }
    println(
      "\{format} animation: \{file.length()} bytes, \{back.frames.length()} frames",
    )
  }
}
