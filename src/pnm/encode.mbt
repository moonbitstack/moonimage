// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing the portable anymap.
//
// Four shapes to choose from and two spellings each, so the caller says which
// shape it wants and whether it wants the samples as digits. Left alone, the
// shape follows the image: a grey picture becomes a PGM, a colour one a PPM,
// and one with alpha a PAM, because none of the other three can hold an alpha
// channel and dropping it silently would be a lie about the picture.
//
// The samples are written at the full range of the layout they are in — 255 for
// eight-bit, 65535 for sixteen — unless the caller asks for another maximum,
// which is the one case where every sample is rescaled.

///|
/// Which of the family to write.
#derive(Eq, Debug)
pub(all) enum Kind {
  /// PBM: one bit per pixel, and no greys at all.
  Bitmap
  /// PGM: one sample per pixel.
  Gray
  /// PPM: three samples per pixel.
  Rgb
  /// PAM: a header, then one to four samples, so alpha survives.
  Any
}

///|
pub extend Kind with Eq::{equal, not_equal}

///|
pub extend Kind with Debug::{to_repr}

///|
/// How to write the file.
pub(all) struct EncodeOptions {
  /// Which of the four shapes.
  kind : Kind
  /// The largest sample, one to 65535.
  maxval : Int32
  /// Whether the samples are decimal digits rather than bytes. PAM has no
  /// digits, so `Any` ignores this.
  ascii : Bool
}

///|
/// The shape the image asks for, at the full range of its layout.
pub fn EncodeOptions::default() -> EncodeOptions {
  { kind: Any, maxval: 0, ascii: false, }
}

///|
/// The plainest file the picture allows: a bit map where one bit is enough.
pub fn EncodeOptions::compact() -> EncodeOptions {
  { kind: Bitmap, maxval: 1, ascii: false, }
}

///|
/// The image as a portable anymap.
pub fn encode(image : @raster.Image, options? : EncodeOptions) -> Bytes {
  let options = options.unwrap_or(EncodeOptions::default())
  let kind = match options.kind {
    Bitmap => if image.format.is_gray() { Bitmap } else { Gray }
    Gray => Gray
    Rgb => if image.format.is_gray() { Gray } else { Rgb }
    Any => Any
  }
  let wide = if options.maxval == 0 {
    image.format.bits() > 8
  } else {
    options.maxval > 255
  }
  let maxval = if options.maxval == 0 {
    if wide {
      65535
    } else {
      255
    }
  } else if options.maxval > 65535 {
    65535
  } else {
    options.maxval
  }
  match kind {
    Bitmap => write_bitmap(image, maxval, options.ascii)
    Gray => write_gray(image, maxval, options.ascii)
    Rgb => write_rgb(image, maxval, options.ascii)
    _ => write_any(image, maxval)
  }
}

///|
/// P4, or P1 when the caller wants digits.
fn write_bitmap(image : @raster.Image, maxval : Int32, ascii : Bool) -> Bytes {
  let writer = @wire.Writer::new()
  let grey = image.convert(
    if maxval > 255 {
      @raster.PixelFormat::Gray16
    } else {
      @raster.PixelFormat::Gray8
    },
  )
  if ascii {
    writer.bytes(b"P1\n")
    heading(writer, grey.width, grey.height)
    for y in 0..<grey.height {
      for x in 0..<grey.width {
        let value = if is_black(grey, x, y) { 1 } else { 0 }
        writer.u8(0x30 + value)
        if x + 1 < grey.width {
          writer.u8(0x20)
        }
      }
      writer.u8(0x0A)
    }
    return writer.to_bytes()
  }
  writer.bytes(b"P4\n")
  heading(writer, grey.width, grey.height)
  let stride = (grey.width + 7) / 8
  for y in 0..<grey.height {
    for column in 0..<stride {
      let mut packed = 0
      for bit in 0..<8 {
        let x = column * 8 + bit
        if x < grey.width && is_black(grey, x, y) {
          packed = packed | (0x80 >> bit)
        }
      }
      writer.u8(packed)
    }
  }
  writer.to_bytes()
}

///|
/// Whether this pixel of a grey image is on the black side of the middle.
fn is_black(image : @raster.Image, x : Int32, y : Int32) -> Bool {
  let pixel = image.pixel(x, y) catch {
    _ => abort("the coordinate is inside the image")
  }
  pixel.r + pixel.g + pixel.b < 1.5
}

///|
/// P5, or P2 when the caller wants digits.
fn write_gray(image : @raster.Image, maxval : Int32, ascii : Bool) -> Bytes {
  let writer = @wire.Writer::new()
  let shape = if maxval > 255 {
    @raster.PixelFormat::Gray16
  } else {
    @raster.PixelFormat::Gray8
  }
  let grey = image.convert(shape)
  let bytes = shape.bytes()
  if ascii {
    writer.bytes(b"P2\n")
    heading(writer, grey.width, grey.height)
    writer.u8(0x0A)
    number(writer, maxval)
    writer.u8(0x0A)
    for y in 0..<grey.height {
      for x in 0..<grey.width {
        let at = y * grey.stride + x * bytes
        let raw = if bytes == 1 {
          grey.pixels[at].to_int()
        } else {
          grey.pixels[at].to_int() * 256 + grey.pixels[at + 1].to_int()
        }
        number(
          writer,
          rescale(raw, if bytes == 1 { 255 } else { 65535 }, maxval),
        )
        writer.u8(if x + 1 < grey.width { 0x20 } else { 0x0A })
      }
    }
    return writer.to_bytes()
  }
  writer.bytes(b"P5\n")
  heading(writer, grey.width, grey.height)
  writer.u8(0x0A)
  number(writer, maxval)
  writer.u8(0x0A)
  samples(writer, grey, 1, bytes, maxval)
  writer.to_bytes()
}

///|
/// P6, or P3 when the caller wants digits.
fn write_rgb(image : @raster.Image, maxval : Int32, ascii : Bool) -> Bytes {
  let writer = @wire.Writer::new()
  let shape = if maxval > 255 {
    @raster.PixelFormat::Rgb16
  } else {
    @raster.PixelFormat::Rgb8
  }
  let colour = image.convert(shape)
  let bytes = shape.bytes()
  if ascii {
    writer.bytes(b"P3\n")
    heading(writer, colour.width, colour.height)
    writer.u8(0x0A)
    number(writer, maxval)
    writer.u8(0x0A)
    let top = if bytes == 3 { 255 } else { 65535 }
    for y in 0..<colour.height {
      for x in 0..<colour.width {
        for channel in 0..<3 {
          let at = y * colour.stride + x * bytes + channel * (bytes / 3)
          let raw = if bytes == 3 {
            colour.pixels[at].to_int()
          } else {
            colour.pixels[at].to_int() * 256 + colour.pixels[at + 1].to_int()
          }
          number(writer, rescale(raw, top, maxval))
          let last = x + 1 == colour.width && channel == 2
          writer.u8(if last { 0x0A } else { 0x20 })
        }
      }
    }
    return writer.to_bytes()
  }
  writer.bytes(b"P6\n")
  heading(writer, colour.width, colour.height)
  writer.u8(0x0A)
  number(writer, maxval)
  writer.u8(0x0A)
  samples(writer, colour, 3, bytes / 3, maxval)
  writer.to_bytes()
}

///|
/// P7, which is the only one that can hold alpha.
fn write_any(image : @raster.Image, maxval : Int32) -> Bytes {
  let writer = @wire.Writer::new()
  let wide = maxval > 255
  let shape = match (image.format.channels(), wide) {
    (1, false) => @raster.PixelFormat::Gray8
    (1, true) => @raster.PixelFormat::Gray16
    (2, false) => @raster.PixelFormat::GrayAlpha8
    (2, true) => @raster.PixelFormat::GrayAlpha16
    (3, false) => @raster.PixelFormat::Rgb8
    (3, true) => @raster.PixelFormat::Rgb16
    (_, false) => @raster.PixelFormat::Rgba8
    _ => @raster.PixelFormat::Rgba16
  }
  let body = image.convert(shape)
  let channels = shape.channels()
  let bytes = shape.bytes() / channels
  writer.bytes(b"P7\n")
  writer.bytes(b"WIDTH ")
  number(writer, body.width)
  writer.u8(0x0A)
  writer.bytes(b"HEIGHT ")
  number(writer, body.height)
  writer.u8(0x0A)
  writer.bytes(b"DEPTH ")
  number(writer, channels)
  writer.u8(0x0A)
  writer.bytes(b"MAXVAL ")
  number(writer, maxval)
  writer.u8(0x0A)
  writer.bytes(tuple_name(channels, image.format.is_gray()))
  writer.u8(0x0A)
  writer.bytes(b"ENDHDR\n")
  samples(writer, body, channels, bytes, maxval)
  writer.to_bytes()
}

///|
/// The `TUPLTYPE` line PAM wants, which is a name for what the samples mean.
fn tuple_name(channels : Int32, gray : Bool) -> Bytes {
  match (channels, gray) {
    (1, true) => b"TUPLTYPE BLACKANDWHITE"
    (2, _) => b"TUPLTYPE GRAYSCALE_ALPHA"
    (3, _) => b"TUPLTYPE RGB"
    _ => b"TUPLTYPE RGB_ALPHA"
  }
}

///|
/// A whole picture's samples, one after another, rescaled if asked.
fn samples(
  writer : @wire.Writer,
  image : @raster.Image,
  channels : Int32,
  bytes : Int32,
  maxval : Int32,
) -> Unit {
  let top = if bytes == 1 { 255 } else { 65535 }
  for y in 0..<image.height {
    for x in 0..<image.width {
      for channel in 0..<channels {
        let at = y * image.stride + (x * channels + channel) * bytes
        if bytes == 1 {
          let raw = image.pixels[at].to_int()
          writer.u8(if maxval == 255 { raw } else { rescale(raw, top, maxval) })
        } else {
          let raw = image.pixels[at].to_int() * 256 +
            image.pixels[at + 1].to_int()
          let value = if maxval == 65535 {
            raw
          } else {
            rescale(raw, top, maxval)
          }
          writer.u8((value >> 8) & 0xFF)
          writer.u8(value & 0xFF)
        }
      }
    }
  }
}

///|
/// Two sizes on one line, separated by one space.
fn heading(writer : @wire.Writer, width : Int32, height : Int32) -> Unit {
  number(writer, width)
  writer.u8(0x20)
  number(writer, height)
}

///|
fn number(writer : @wire.Writer, value : Int32) -> Unit {
  if value == 0 {
    writer.u8(0x30)
    return
  }
  let digits : Array[Byte] = []
  let mut rest = value
  while rest > 0 {
    digits.push((0x30 + rest % 10).to_byte())
    rest = rest / 10
  }
  for i in 0..<digits.length() {
    writer.u8(digits[digits.length() - 1 - i].to_int())
  }
}

///|
/// A sample out of `top` as one out of `maxval`, rounded.
fn rescale(value : Int32, top : Int32, maxval : Int32) -> Int32 {
  if top == maxval {
    return value
  }
  (value.to_int64() * maxval.to_int64() + top.to_int64() / 2L).to_int() / top
}
