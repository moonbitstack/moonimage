// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Changing how pixels are spelled without changing what they say.
//
// A conversion here is one of five moves: widening 8 bits to 16 or to a float,
// narrowing back, adding an alpha channel, dropping one, and turning grey into
// equal parts red, green and blue. Nothing is gamma-corrected, because nothing
// here knows what gamma the image means; nothing is premultiplied, unless asked.
//
// Narrowing rounds rather than truncates. Truncation costs half a step of
// brightness on average, which over a photograph is a visible darkening, and
// costs nothing to avoid.

///|
/// The same image, in another sample format.
///
/// Colour is preserved as far as the target can hold it: a grey image becomes
/// grey, an image without alpha becomes opaque, and narrowing rounds to nearest.
pub fn Image::convert(self : Image, format : PixelFormat) -> Image {
  if self.format == format {
    return self
  }
  let stride = self.width * format.bytes()
  let buffer : FixedArray[Byte] = FixedArray::make(
    if self.height == 0 {
      0
    } else {
      stride * self.height
    },
    b'\x00',
  )
  let from = self.format.bytes()
  let to = format.bytes()
  for y in 0..<self.height {
    let source_row = y * self.stride
    let target_row = y * stride
    for x in 0..<self.width {
      let pixel = read_pixel(self.pixels, source_row + x * from, self.format)
      write_pixel(buffer, target_row + x * to, format, pixel)
    }
  }
  assemble(
    self.width,
    self.height,
    format,
    buffer,
    self.premultiplied,
    self.metadata,
  )
}

///|
/// The same image with colour multiplied by alpha.
///
/// Idempotent: an image that already says it is premultiplied comes back
/// unchanged, so a caller can ask without checking first.
pub fn Image::to_premultiplied(self : Image) -> Image {
  if self.premultiplied || !self.format.has_alpha() {
    return self
  }
  self.map_alpha(true)
}

///|
/// The same image with alpha divided back out.
///
/// The inverse of `to_premultiplied` up to rounding, which is why a round trip
/// is only exact for images whose colour is already premultiplied.
pub fn Image::to_straight(self : Image) -> Image {
  if !self.premultiplied {
    return self
  }
  self.map_alpha(false)
}

///|
/// Every colour channel multiplied by alpha, or divided by it, on a copy.
///
/// The arithmetic is done on samples, not through `Pixel`, because dividing by
/// alpha is the one case where rounding through a float can land on the wrong
/// side of a half: a byte that came out of `colour × alpha` divides back to the
/// byte it started as only when the two roundings agree.
fn Image::map_alpha(self : Image, multiply : Bool) -> Image {
  let buffer : FixedArray[Byte] = FixedArray::make(
    self.pixels.length(),
    b'\x00',
  )
  buffer.blit_from_bytesview(0, self.pixels)
  let bytes = self.format.bytes()
  for y in 0..<self.height {
    let row = y * self.stride
    for x in 0..<self.width {
      let at = row + x * bytes
      match self.format {
        GrayAlpha8 =>
          buffer[at] = scale_alpha_byte(
            buffer[at].to_int(),
            buffer[at + 1].to_int(),
            multiply,
          )
        Rgba8 => {
          let a = buffer[at + 3].to_int()
          buffer[at] = scale_alpha_byte(buffer[at].to_int(), a, multiply)
          buffer[at + 1] = scale_alpha_byte(
            buffer[at + 1].to_int(),
            a,
            multiply,
          )
          buffer[at + 2] = scale_alpha_byte(
            buffer[at + 2].to_int(),
            a,
            multiply,
          )
        }
        GrayAlpha16 =>
          put_word(
            buffer,
            at,
            scale_alpha_word(
              word_of(buffer, at),
              word_of(buffer, at + 2),
              multiply,
            ),
          )
        Rgba16 => {
          let a = word_of(buffer, at + 6)
          put_word(
            buffer,
            at,
            scale_alpha_word(word_of(buffer, at), a, multiply),
          )
          put_word(
            buffer,
            at + 2,
            scale_alpha_word(word_of(buffer, at + 2), a, multiply),
          )
          put_word(
            buffer,
            at + 4,
            scale_alpha_word(word_of(buffer, at + 4), a, multiply),
          )
        }
        RgbaF32 => {
          let a = float_in(buffer, at + 12).to_double()
          for channel in 0..<3 {
            let offset = at + channel * 4
            let value = float_in(buffer, offset).to_double()
            let scaled = if multiply {
              value * a
            } else if a > 0.0 {
              value / a
            } else {
              0.0
            }
            put_float(buffer, offset, unit_to_float(scaled))
          }
        }
        _ => ()
      }
    }
  }
  assemble(
    self.width,
    self.height,
    self.format,
    buffer,
    multiply,
    self.metadata,
  )
}

///|
fn word_of(data : FixedArray[Byte], offset : Int32) -> Int32 {
  data[offset].to_int() * 256 + data[offset + 1].to_int()
}

///|
/// `value × alpha / 255`, or the division back, rounded.
fn scale_alpha_byte(value : Int32, alpha : Int32, multiply : Bool) -> Byte {
  let result = if multiply {
    (value * alpha + 127) / 255
  } else if alpha == 0 {
    0
  } else {
    (value * 255 + alpha / 2) / alpha
  }
  (if result > 255 { 255 } else { result }).to_byte()
}

///|
/// The same for sixteen-bit samples.
fn scale_alpha_word(value : Int32, alpha : Int32, multiply : Bool) -> Int32 {
  let result = if multiply {
    (value * alpha + 32767) / 65535
  } else if alpha == 0 {
    0
  } else {
    (value * 65535 + alpha / 2) / alpha
  }
  if result > 65535 {
    65535
  } else {
    result
  }
}
