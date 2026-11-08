// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Pixels handed to the colour package, and colour handed back.
//
// This library keeps a pixel as four samples and does not know what a colour
// space is beyond the one the file declared. Turning a hue, blending in a
// perceptual space or asking what a colour is called are therefore not its
// business: they belong to the colour library, which owns the spaces and the
// conversions between them. These two functions are the whole of the seam.

///|
/// The pixel as a colour in sRGB, alpha included.
pub fn Pixel::to_color(self : Pixel) -> @moonrgba.Color {
  @moonrgba.Color::srgb(self.r, self.g, self.b, alpha=self.a)
}

///|
/// The colour as a pixel, converted to sRGB first.
///
/// A colour outside sRGB is brought into it rather than clipped in whatever
/// space it arrived in, and the conversion keeps the alpha it was given.
pub fn Pixel::of_color(color : @moonrgba.Color) -> Pixel {
  let rgb = color.to_srgb()
  { r: rgb.x, g: rgb.y, b: rgb.z, a: color.alpha, }
}

///|
/// The pixel with its hue turned, in degrees.
///
/// Done in HSL so that the hue is what moves: lightness and saturation come out
/// as they went in, which is not true of a hue rotation done by mixing channel
/// matrices. A grey pixel has no hue to turn and comes back unchanged.
pub fn Pixel::rotate_hue(self : Pixel, degrees : Double) -> Pixel {
  if self.r == self.g && self.g == self.b {
    return self
  }
  let hsl = self.to_color().to_hsl()
  let turned = hsl.x + degrees
  let hue = turned - 360.0 * (turned / 360.0).floor()
  Pixel::of_color(@moonrgba.Color::hsl(hue, hsl.y, hsl.z, alpha=self.a))
}
