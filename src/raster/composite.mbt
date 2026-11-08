// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Putting one picture on top of another.
//
// Compositing is one formula — source over destination, in straight alpha —
// and it is the same formula whether the two pictures are layers of a
// composition, a watermark on a photograph, or a frame of an animation on the
// canvas it was drawn for. The animation code calls this one rather than
// keeping a second copy of it.
//
// The result keeps the format of the destination, because that is the picture
// the caller is holding; the source is converted on the way in, which is the
// only place in the library where a conversion happens without being asked for
// and is worth it, since the alternative is refusing to composite two pictures
// that are both perfectly good pictures.

///|
/// This image with `source` laid over it, its top-left corner at (`x`, `y`).
///
/// A source larger than the destination is clipped rather than refused: a
/// watermark is usually placed by a corner rule, and a corner rule that lands
/// one pixel outside is not an error.
///
/// `opacity` scales the source's alpha before it is laid down, which is how a
/// watermark is made faint without being re-encoded.
pub fn Image::composite(
  self : Image,
  source : Image,
  x? : Int32,
  y? : Int32,
  opacity? : Double,
) -> Image {
  let x = x.unwrap_or(0)
  let y = y.unwrap_or(0)
  let opacity = clamp_unit(opacity.unwrap_or(1.0))
  if opacity <= 0.0 || source.width == 0 || source.height == 0 {
    return self
  }
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
  buffer.blit_from_bytesview(0, self.pixels)
  let top = picture_over(self, source, opacity)
  let left = within(x, 0, self.width)
  let right = within(x + top.width, 0, self.width)
  let upper = within(y, 0, self.height)
  let lower = within(y + top.height, 0, self.height)
  if right <= left || lower <= upper {
    return self
  }
  let source_bytes = top.format.bytes()
  for row in upper..<lower {
    for column in left..<right {
      let from = (row - y) * top.stride + (column - x) * source_bytes
      let under = self.pixel(column, row) catch {
        _ => abort("the rectangle is inside the image")
      }
      let above = read_pixel(top.pixels, from, top.format)
      write_pixel(
        buffer,
        row * stride + column * bytes,
        self.format,
        over(above, under),
      )
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

///|
/// The source in the destination's format and straight alpha, with the opacity
/// already folded in.
///
/// Both matter: `over` reads straight alpha, and the destination's format is
/// what the caller is going to keep.
fn picture_over(destination : Image, source : Image, opacity : Double) -> Image {
  let straight = if source.premultiplied {
    source.to_straight()
  } else {
    source
  }
  let matching = straight.convert(destination.format)
  if opacity >= 1.0 {
    return matching
  }
  matching.map_pixels(pixel => { ..pixel, a: pixel.a * opacity, })
}

///|
fn within(value : Int32, low : Int32, high : Int32) -> Int32 {
  if value < low {
    low
  } else if value > high {
    high
  } else {
    value
  }
}
