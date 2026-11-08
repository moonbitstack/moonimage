// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Changing how a picture looks without moving anything.
//
// Four knobs, each of which is one line of arithmetic on a sample, and each of
// which is defined here rather than borrowed so that the same call means the
// same thing in every version. Alpha is never touched by a colour adjustment:
// making a picture brighter does not make it more opaque.
//
// Everything works on samples through `Pixel`, so an eight-bit image, a
// sixteen-bit one and a float one go through the same code and only the last
// quantisation differs.

///|
/// The image with every colour channel multiplied by `factor`.
///
/// One is unchanged, zero is black, and two doubles: this is the linear part of
/// exposure, done on the encoded samples rather than on light, which is what a
/// brightness slider in an editor does.
pub fn Image::brightness(self : Image, factor : Double) -> Image {
  self.map_pixels(pixel => {
    ..pixel,
    r: clamp_unit(pixel.r * factor),
    g: clamp_unit(pixel.g * factor),
    b: clamp_unit(pixel.b * factor),
  })
}

///|
/// The image with its contrast scaled about mid-grey.
///
/// One is unchanged, zero is flat grey, and above one pushes the samples away
/// from the middle: `(sample − 0.5) × factor + 0.5`, clamped.
pub fn Image::contrast(self : Image, factor : Double) -> Image {
  self.map_pixels(pixel => {
    ..pixel,
    r: clamp_unit((pixel.r - 0.5) * factor + 0.5),
    g: clamp_unit((pixel.g - 0.5) * factor + 0.5),
    b: clamp_unit((pixel.b - 0.5) * factor + 0.5),
  })
}

///|
/// The image with every hue turned by `degrees`, clockwise.
///
/// Saturation and lightness survive, which is what makes this different from
/// swapping channels; a grey pixel has no hue and comes back as it was.
pub fn Image::hue_rotate(self : Image, degrees : Double) -> Image {
  if degrees == 0.0 {
    return self
  }
  self.map_pixels(pixel => pixel.rotate_hue(degrees))
}

///|
/// The image with every sample replaced by one minus itself.
///
/// Alpha is left alone, so inverting a transparent picture keeps it
/// transparent.
pub fn Image::invert(self : Image) -> Image {
  self.map_pixels(pixel => {
    ..pixel,
    r: 1.0 - pixel.r,
    g: 1.0 - pixel.g,
    b: 1.0 - pixel.b,
  })
}

///|
/// Every pixel through a function, in the image's own format.
fn Image::map_pixels(self : Image, change : (Pixel) -> Pixel) -> Image {
  let bytes = self.format.bytes()
  let stride = self.width * bytes
  let buffer : FixedArray[Byte] = FixedArray::make(
    if self.height == 0 {
      0
    } else {
      stride * self.height
    },
    b'\x00',
  )
  for y in 0..<self.height {
    let source_row = y * self.stride
    let target_row = y * stride
    for x in 0..<self.width {
      let pixel = read_pixel(self.pixels, source_row + x * bytes, self.format)
      write_pixel(buffer, target_row + x * bytes, self.format, change(pixel))
    }
  }
  assemble(
    self.width,
    self.height,
    self.format,
    buffer,
    self.premultiplied,
    self.metadata,
  )
}
