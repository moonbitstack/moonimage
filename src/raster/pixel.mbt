// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// One pixel, the formats it can be kept in, and the arithmetic between them.
//
// The library keeps pixels in the format the file used, because converting on
// the way in throws away precision a caller may have wanted, and converting on
// the way out costs a pass over the whole image. Everything that has to know
// what a pixel *is* — a scaler, a colour mix — reads through `Pixel`, which is
// four samples in 0–1, and writes back through the same door.
//
// Eight-bit formats hold 0–255, sixteen-bit 0–65535, and `RgbaF32` holds the
// sample as a float with no scaling at all. Alpha is straight, not premultiplied,
// unless the image says otherwise.

///|
/// How the samples of an image are laid out.
///
/// The names are the usual ones: `Gray8` is one byte per pixel, `Rgba8` four,
/// `Rgba16` eight with each channel big-endian, `RgbaF32` four floats.
pub(all) enum PixelFormat {
  /// One sample, 8 bits.
  Gray8
  /// Grey and alpha, 8 bits each.
  GrayAlpha8
  /// Three samples, 8 bits each, red first.
  Rgb8
  /// Four samples, 8 bits each, red first, alpha last.
  Rgba8
  /// One sample, 16 bits, big-endian.
  Gray16
  /// Grey and alpha, 16 bits each.
  GrayAlpha16
  /// Three samples, 16 bits each, big-endian.
  Rgb16
  /// Four samples, 16 bits each, big-endian.
  Rgba16
  /// Four samples as `Float`, 0–1, little-endian.
  RgbaF32
} derive(Eq, Debug)

///|
pub extend PixelFormat with Eq::{equal, not_equal}

///|
pub extend PixelFormat with Debug::{to_repr}

///|
/// The layout spelled the way the type spells it: `Rgba8`, `Gray16`.
///
/// A log line and an error message both want to say which layout was in play,
/// and neither wants a sentence about it.
pub impl Show for PixelFormat with fn output(self, logger) {
  logger.write_string(
    match self {
      Gray8 => "Gray8"
      GrayAlpha8 => "GrayAlpha8"
      Rgb8 => "Rgb8"
      Rgba8 => "Rgba8"
      Gray16 => "Gray16"
      GrayAlpha16 => "GrayAlpha16"
      Rgb16 => "Rgb16"
      Rgba16 => "Rgba16"
      RgbaF32 => "RgbaF32"
    },
  )
}

///|
pub extend PixelFormat with Show::{to_string, output}

///|
/// How many samples a pixel of this format has.
pub fn PixelFormat::channels(self : PixelFormat) -> Int32 {
  match self {
    Gray8 | Gray16 => 1
    GrayAlpha8 | GrayAlpha16 => 2
    Rgb8 | Rgb16 => 3
    Rgba8 | Rgba16 | RgbaF32 => 4
  }
}

///|
/// How many bytes a pixel of this format takes.
pub fn PixelFormat::bytes(self : PixelFormat) -> Int32 {
  match self {
    Gray8 => 1
    GrayAlpha8 => 2
    Rgb8 => 3
    Rgba8 => 4
    Gray16 => 2
    GrayAlpha16 => 4
    Rgb16 => 6
    Rgba16 => 8
    RgbaF32 => 16
  }
}

///|
/// How many bits one sample takes. For `RgbaF32` this is 32, which says how wide
/// the sample is, not that it is an integer.
pub fn PixelFormat::bits(self : PixelFormat) -> Int32 {
  match self {
    Gray8 | GrayAlpha8 | Rgb8 | Rgba8 => 8
    Gray16 | GrayAlpha16 | Rgb16 | Rgba16 => 16
    RgbaF32 => 32
  }
}

///|
/// Whether the image carries colour at all.
pub fn PixelFormat::is_gray(self : PixelFormat) -> Bool {
  match self {
    Gray8 | GrayAlpha8 | Gray16 | GrayAlpha16 => true
    _ => false
  }
}

///|
/// Whether the image carries alpha.
pub fn PixelFormat::has_alpha(self : PixelFormat) -> Bool {
  match self {
    GrayAlpha8 | Rgba8 | GrayAlpha16 | Rgba16 | RgbaF32 => true
    _ => false
  }
}

///|
/// Whether the samples are floats rather than integers.
pub fn PixelFormat::is_float(self : PixelFormat) -> Bool {
  self == RgbaF32
}

///|
/// One pixel, in the units every operation in the library works in: four
/// samples from 0 to 1, alpha straight.
///
/// A grey pixel has `r`, `g` and `b` equal, which is why there is no grey
/// variant: a reader that has to branch on whether a pixel is grey is a reader
/// that will forget to inflate one of the three channels.
pub(all) struct Pixel {
  r : Double
  g : Double
  b : Double
  a : Double
} derive(Eq, Debug)

///|
pub extend Pixel with Eq::{equal, not_equal}

///|
pub extend Pixel with Debug::{to_repr}

///|
/// A pixel from the eight-bit values an editor shows.
pub fn Pixel::of_rgba8(r : Int32, g : Int32, b : Int32, a? : Int32) -> Pixel {
  {
    r: byte_to_unit(r),
    g: byte_to_unit(g),
    b: byte_to_unit(b),
    a: byte_to_unit(a.unwrap_or(255)),
  }
}

///|
/// The pixel as bytes an editor shows: rounded, clamped, alpha last.
pub fn Pixel::rgba8(self : Pixel) -> (Int32, Int32, Int32, Int32) {
  (
    unit_to_byte(self.r),
    unit_to_byte(self.g),
    unit_to_byte(self.b),
    unit_to_byte(self.a),
  )
}

///|
/// The pixel as sixteen-bit samples, which is what a PNG stores when its bit
/// depth is sixteen.
pub fn Pixel::rgba16(self : Pixel) -> (Int32, Int32, Int32, Int32) {
  (
    unit_to_word(self.r),
    unit_to_word(self.g),
    unit_to_word(self.b),
    unit_to_word(self.a),
  )
}

///|
/// A sample from 0 to 1 as a byte. Rounding, not truncation: 0.5 is 128, and a
/// round trip through `Rgba8` then back is the identity for every byte.
fn unit_to_byte(x : Double) -> Int32 {
  if x <= 0.0 {
    0
  } else if x >= 1.0 {
    255
  } else {
    // The epsilon is there for the exact halves. A filter that averages 200 and
    // 255 reaches 0.892156862745098…, whose product with 255 is a hair under
    // 227.5 in binary, and without it the answer would be 227 rather than 228.
    (x * 255.0 + 0.5 + 1.0e-9).to_int()
  }
}

///|
fn byte_to_unit(x : Int32) -> Double {
  x.to_double() / 255.0
}

///|
fn unit_to_word(x : Double) -> Int32 {
  if x <= 0.0 {
    0
  } else if x >= 1.0 {
    65535
  } else {
    (x * 65535.0 + 0.5 + 1.0e-9).to_int()
  }
}

///|
/// The pixel stored at `offset` in `data`, in this format.
///
/// Not public: a caller reads pixels through `Image::pixel`, which checks the
/// coordinates once instead of every sample.
fn read_pixel(data : BytesView, offset : Int32, format : PixelFormat) -> Pixel {
  match format {
    Gray8 => {
      let v = byte_to_unit(data[offset].to_int())
      { r: v, g: v, b: v, a: 1.0, }
    }
    GrayAlpha8 => {
      let v = byte_to_unit(data[offset].to_int())
      { r: v, g: v, b: v, a: byte_to_unit(data[offset + 1].to_int()), }
    }
    Rgb8 =>
      {
        r: byte_to_unit(data[offset].to_int()),
        g: byte_to_unit(data[offset + 1].to_int()),
        b: byte_to_unit(data[offset + 2].to_int()),
        a: 1.0,
      }
    Rgba8 =>
      {
        r: byte_to_unit(data[offset].to_int()),
        g: byte_to_unit(data[offset + 1].to_int()),
        b: byte_to_unit(data[offset + 2].to_int()),
        a: byte_to_unit(data[offset + 3].to_int()),
      }
    Gray16 => {
      let v = word_at(data, offset).to_double() / 65535.0
      { r: v, g: v, b: v, a: 1.0, }
    }
    GrayAlpha16 => {
      let v = word_at(data, offset).to_double() / 65535.0
      { r: v, g: v, b: v, a: word_at(data, offset + 2).to_double() / 65535.0, }
    }
    Rgb16 =>
      {
        r: word_at(data, offset).to_double() / 65535.0,
        g: word_at(data, offset + 2).to_double() / 65535.0,
        b: word_at(data, offset + 4).to_double() / 65535.0,
        a: 1.0,
      }
    Rgba16 =>
      {
        r: word_at(data, offset).to_double() / 65535.0,
        g: word_at(data, offset + 2).to_double() / 65535.0,
        b: word_at(data, offset + 4).to_double() / 65535.0,
        a: word_at(data, offset + 6).to_double() / 65535.0,
      }
    RgbaF32 =>
      {
        r: float_at(data, offset).to_double(),
        g: float_at(data, offset + 4).to_double(),
        b: float_at(data, offset + 8).to_double(),
        a: float_at(data, offset + 12).to_double(),
      }
  }
}

///|
/// A big-endian sixteen-bit sample.
fn word_at(data : BytesView, offset : Int32) -> Int32 {
  data[offset].to_int() * 256 + data[offset + 1].to_int()
}

///|
/// A little-endian float, the layout a GPU buffer wants.
fn float_at(data : BytesView, offset : Int32) -> Float {
  let bits = data[offset].to_int() +
    data[offset + 1].to_int() * 256 +
    data[offset + 2].to_int() * 65536 +
    data[offset + 3].to_int() * 16777216
  Float::reinterpret_from_uint(bits.reinterpret_as_uint())
}

///|
/// Store `pixel` at `offset` in `data`, in this format.
fn write_pixel(
  data : FixedArray[Byte],
  offset : Int32,
  format : PixelFormat,
  pixel : Pixel,
) -> Unit {
  match format {
    Gray8 => data[offset] = unit_to_byte(gray_of(pixel)).to_byte()
    GrayAlpha8 => {
      data[offset] = unit_to_byte(gray_of(pixel)).to_byte()
      data[offset + 1] = unit_to_byte(pixel.a).to_byte()
    }
    Rgb8 => {
      data[offset] = unit_to_byte(pixel.r).to_byte()
      data[offset + 1] = unit_to_byte(pixel.g).to_byte()
      data[offset + 2] = unit_to_byte(pixel.b).to_byte()
    }
    Rgba8 => {
      data[offset] = unit_to_byte(pixel.r).to_byte()
      data[offset + 1] = unit_to_byte(pixel.g).to_byte()
      data[offset + 2] = unit_to_byte(pixel.b).to_byte()
      data[offset + 3] = unit_to_byte(pixel.a).to_byte()
    }
    Gray16 => put_word(data, offset, unit_to_word(gray_of(pixel)))
    GrayAlpha16 => {
      put_word(data, offset, unit_to_word(gray_of(pixel)))
      put_word(data, offset + 2, unit_to_word(pixel.a))
    }
    Rgb16 => {
      put_word(data, offset, unit_to_word(pixel.r))
      put_word(data, offset + 2, unit_to_word(pixel.g))
      put_word(data, offset + 4, unit_to_word(pixel.b))
    }
    Rgba16 => {
      put_word(data, offset, unit_to_word(pixel.r))
      put_word(data, offset + 2, unit_to_word(pixel.g))
      put_word(data, offset + 4, unit_to_word(pixel.b))
      put_word(data, offset + 6, unit_to_word(pixel.a))
    }
    RgbaF32 => {
      put_float(data, offset, unit_to_float(pixel.r))
      put_float(data, offset + 4, unit_to_float(pixel.g))
      put_float(data, offset + 8, unit_to_float(pixel.b))
      put_float(data, offset + 12, unit_to_float(pixel.a))
    }
  }
}

///|
fn put_word(data : FixedArray[Byte], offset : Int32, value : Int32) -> Unit {
  data[offset] = ((value >> 8) & 0xFF).to_byte()
  data[offset + 1] = (value & 0xFF).to_byte()
}

///|
fn put_float(data : FixedArray[Byte], offset : Int32, value : Float) -> Unit {
  let bits = value.reinterpret_as_uint().reinterpret_as_int()
  data[offset] = (bits & 0xFF).to_byte()
  data[offset + 1] = ((bits >> 8) & 0xFF).to_byte()
  data[offset + 2] = ((bits >> 16) & 0xFF).to_byte()
  data[offset + 3] = ((bits >> 24) & 0xFF).to_byte()
}

///|
/// The grey a colour becomes when a format has one channel.
///
/// The weights are the ones television settled on, which is what every other
/// converter uses for eight-bit sRGB, and they sum to one so that a grey pixel
/// stays the grey it was.
fn gray_of(pixel : Pixel) -> Double {
  0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b
}

///|
/// A sample from 0 to 1 as a float, clamped: a float image is where a filter
/// can overshoot, and a channel outside 0–1 is not a colour.
fn unit_to_float(x : Double) -> Float {
  if x <= 0.0 {
    0.0F
  } else if x >= 1.0 {
    1.0F
  } else {
    Float::from_double(x)
  }
}

///|
/// A little-endian float in a buffer being built.
fn float_in(data : FixedArray[Byte], offset : Int32) -> Float {
  let bits = data[offset].to_int() +
    data[offset + 1].to_int() * 256 +
    data[offset + 2].to_int() * 65536 +
    data[offset + 3].to_int() * 16777216
  Float::reinterpret_from_uint(bits.reinterpret_as_uint())
}
