// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Turning a picture by an angle that is not a right one.
//
// A quarter turn is a permutation and is done by `rotate`: every sample keeps
// its exact value. Any other angle has to ask where each output pixel came
// from, and the answer almost never lands on a sample, so the picture is
// resampled. The sampling is bilinear because the alternative — leaving the
// destination transparent wherever the source had no exact pixel — produces the
// staircase that a rotation is expected not to have.
//
// The inverse map is used, not the forward one. Walking the destination and
// pulling from the source visits every output pixel exactly once; walking the
// source and pushing forward leaves holes wherever the picture was stretched.

///|
/// The image turned clockwise by `degrees`.
///
/// `expand` grows the canvas to the rectangle the turned picture needs, which
/// is what a caller rotating a photograph wants; without it the picture is
/// turned inside the canvas it already had, and the corners are cut off, which
/// is what a caller animating a rotation wants.
///
/// A multiple of ninety degrees is exact and is handed to `rotate`; nothing is
/// resampled and no sample changes.
pub fn Image::rotate_by(
  self : Image,
  degrees : Double,
  expand? : Bool,
) -> Image raise Refused {
  let expand = expand.unwrap_or(false)
  let quarters = degrees / 90.0
  if absolute(quarters - quarters.floor()) < 1.0e-9 {
    let turned = self.rotate(quarters=quarters.floor().to_int())
    if !expand {
      return turned
    }
    // A quarter turn already swapped the canvas; expanding it further can only
    // add room, and a turned picture fits its own canvas exactly.
    return turned
  }
  let radians = degrees * pi / 180.0
  let cos = @math.cos(radians)
  let sin = @math.sin(radians)
  let source_width = self.width.to_double()
  let source_height = self.height.to_double()
  let (width, height) = if expand {
    let wide = absolute(source_width * cos) + absolute(source_height * sin)
    let tall = absolute(source_width * sin) + absolute(source_height * cos)
    (wide.ceil().to_int(), tall.ceil().to_int())
  } else {
    (self.width, self.height)
  }
  Limits::default().check(width, height)
  let source = self.working_copy()
  let pixels : FixedArray[Double] = FixedArray::make(width * height * 4, 0.0)
  let from_x = source_width / 2.0
  let from_y = source_height / 2.0
  let to_x = width.to_double() / 2.0
  let to_y = height.to_double() / 2.0
  for y in 0..<height {
    let down = y.to_double() + 0.5 - to_y
    for x in 0..<width {
      let across = x.to_double() + 0.5 - to_x
      let at_x = from_x + across * cos + down * sin - 0.5
      let at_y = from_y - across * sin + down * cos - 0.5
      let at = (y * width + x) * 4
      let (r, g, b, a) = sample_bilinear(
        source,
        self.width,
        self.height,
        at_x,
        at_y,
      )
      pixels[at] = r
      pixels[at + 1] = g
      pixels[at + 2] = b
      pixels[at + 3] = a
    }
  }
  self.collect(pixels, width, height)
}

///|
/// The premultiplied samples around a continuous position, weighted bilinearly.
///
/// Positions off the edge read the edge, so a turn of a picture that is not a
/// square does not lay a transparent frame around it where the corners used to
/// be.
fn sample_bilinear(
  source : FixedArray[Double],
  width : Int32,
  height : Int32,
  x : Double,
  y : Double,
) -> (Double, Double, Double, Double) {
  let left = x.floor().to_int()
  let top = y.floor().to_int()
  let across = x - left.to_double()
  let down = y - top.to_double()
  let (x0, x1) = (clamp_index(left, width), clamp_index(left + 1, width))
  let (y0, y1) = (clamp_index(top, height), clamp_index(top + 1, height))
  let top_left = (y0 * width + x0) * 4
  let top_right = (y0 * width + x1) * 4
  let bottom_left = (y1 * width + x0) * 4
  let bottom_right = (y1 * width + x1) * 4
  let weights = [
    (1.0 - across) * (1.0 - down),
    across * (1.0 - down),
    (1.0 - across) * down,
    across * down,
  ]
  let corners = [top_left, top_right, bottom_left, bottom_right]
  let mut out = (0.0, 0.0, 0.0, 0.0)
  for k in 0..<4 {
    let at = corners[k]
    let weight = weights[k]
    out = (
      out.0 + source[at] * weight,
      out.1 + source[at + 1] * weight,
      out.2 + source[at + 2] * weight,
      out.3 + source[at + 3] * weight,
    )
  }
  (clamp_unit(out.0), clamp_unit(out.1), clamp_unit(out.2), clamp_unit(out.3))
}

///|
fn clamp_index(index : Int32, limit : Int32) -> Int32 {
  if index < 0 {
    0
  } else if index >= limit {
    limit - 1
  } else {
    index
  }
}

///|
let pi : Double = 3.141592653589793
