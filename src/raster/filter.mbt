// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Blurring, and the sharpening that is defined as its inverse.
//
// A blur is a convolution with a Gaussian, done as two one-dimensional passes
// because the kernel is separable. The radius is the standard deviation, in
// pixels, which is the number every other implementation means by "radius" and
// therefore the one that makes a comparison mean something: a kernel truncated
// at three sigma holds 99.7 percent of the weight, and what is left over is
// smaller than a step of an eight-bit sample at any radius above a third.
//
// The convolution runs on premultiplied samples. Blurring colour and alpha
// separately leaves the colour of a transparent pixel bleeding outward as the
// alpha falls away, which shows up as a grey halo around every sprite.

///|
/// How a blur is worked out.
#derive(Eq, Debug)
pub(all) enum Kernel {
  /// The kernel itself: every sample within three sigma, weighted by the
  /// Gaussian, convolved in two passes.
  Exact
  /// Three box passes per axis, whose sides are chosen so that the three
  /// together have the variance of the Gaussian asked for. This is what Pillow,
  /// Skia and most drawing systems do: a box pass is an addition and a
  /// subtraction per sample, and three of them are within a step of a sample of
  /// the kernel everywhere.
  Boxes
}

///|
pub extend Kernel with Eq::{equal, not_equal}

///|
pub extend Kernel with Debug::{to_repr}

///|
/// The image blurred with a Gaussian of standard deviation `radius`.
///
/// A radius of zero or less is the image itself, so a caller that computes the
/// radius from a size does not have to check for the case.
///
/// `kernel` chooses how the Gaussian is worked out. `Exact` convolves with the
/// kernel, which is what the number means; `Boxes` is the same blur by the
/// arithmetic the rest of the world uses, for a caller comparing against a
/// picture some other library made.
pub fn Image::blur(
  self : Image,
  radius : Double,
  kernel~ : Kernel = Exact,
) -> Image {
  if radius <= 0.0 || self.width == 0 || self.height == 0 {
    return self
  }
  match kernel {
    Boxes => self.blur_boxes(radius)
    Exact => {
      let weights = gaussian_weights(radius)
      let source = self.working_copy()
      let across = blur_axis(source, self.width, self.height, weights, true)
      let down = blur_axis(across, self.width, self.height, weights, false)
      self.collect(down, self.width, self.height)
    }
  }
}

///|
/// How many steps the picture's samples are stored in: two hundred and fifty-five
/// for eight bits, sixty-five thousand five hundred and thirty-five for sixteen,
/// and none at all for floats, which are the same before and after a pass.
fn Image::storage_levels(self : Image) -> Double {
  match self.format {
    Gray8 | GrayAlpha8 | Rgb8 | Rgba8 => 255.0
    Gray16 | GrayAlpha16 | Rgb16 | Rgba16 => 65535.0
    _ => 0.0
  }
}

///|
/// The three box passes each axis needs, in the widths that make their variance
/// the variance of the Gaussian asked for.
///
/// A box of side `2r + 1` has variance `((2r+1)^2 - 1) / 12`, so three of them
/// want a side of `sqrt(12 sigma^2 / 3 + 1)`; the fractional part is carried as
/// a weight rather than rounded away, which is what keeps the result within a
/// step of the kernel for radii between the integer widths.
fn Image::blur_boxes(self : Image, radius : Double) -> Image {
  let side = box_span(radius)
  let levels = self.storage_levels()
  let mut buffer = self.working_copy()
  for _ in 0..<3 {
    buffer = box_axis(buffer, self.width, self.height, side, true, levels)
  }
  for _ in 0..<3 {
    buffer = box_axis(buffer, self.width, self.height, side, false, levels)
  }
  self.collect(buffer, self.width, self.height)
}

///|
/// The width of one box, as a real number of samples: the integer part is how
/// many samples each side the pass reaches, and the fractional part is weight
/// given to the sample beyond it.
fn box_span(radius : Double) -> Double {
  let variance = radius * radius / 3.0
  let side = (12.0 * variance + 1.0).sqrt()
  let whole = ((side - 1.0) / 2.0).floor()
  let rest = (2.0 * whole + 1.0) *
    (whole * (whole + 1.0) - 3.0 * variance) /
    (6.0 * (variance - (whole + 1.0) * (whole + 1.0)))
  whole + rest
}

///|
/// One axis of three box passes: the image is `length` wide, or `length` tall,
/// and the other dimension is untouched.
///
/// The window is the `2r + 1` samples around the output one, read from the edge
/// when it reaches past it, plus the two samples beyond that at the weight the
/// fractional part of the width leaves over. Each pass is written back rounded
/// the way the picture is stored, because a pass whose result is held exactly
/// and rounded once at the end is not the same picture: the difference shows on
/// every edge.
fn box_axis(
  source : FixedArray[Double],
  width : Int32,
  height : Int32,
  side : Double,
  horizontal : Bool,
  levels : Double,
) -> FixedArray[Double] {
  let reach = side.floor().to_int()
  let steps = if horizontal { width } else { height }
  let lines = if horizontal { height } else { width }
  let stride = if horizontal { 4 } else { width * 4 }
  let weight = 1.0 / (side * 2.0 + 1.0)
  let spare = (1.0 - (reach * 2 + 1).to_double() * weight) / 2.0
  let total = (reach * 2 + 1).to_double() * weight + 2.0 * spare
  let pixels : FixedArray[Double] = FixedArray::make(width * height * 4, 0.0)
  for line in 0..<lines {
    let base = if horizontal { line * width * 4 } else { line * 4 }
    let window : FixedArray[Double] = FixedArray::make(4, 0.0)
    for offset in -reach..<=reach {
      let at = base + clamp_index(offset, steps) * stride
      for k in 0..<4 {
        window[k] = window[k] + source[at + k]
      }
    }
    for step in 0..<steps {
      let at = base + step * stride
      let before = base + clamp_index(step - reach - 1, steps) * stride
      let after = base + clamp_index(step + reach + 1, steps) * stride
      for k in 0..<4 {
        let value = (
            window[k] * weight +
            (source[before + k] + source[after + k]) * spare
          ) /
          total
        pixels[at + k] = round_levels(value, levels)
      }
      if step + 1 < steps {
        let leaving = base + clamp_index(step - reach, steps) * stride
        let entering = base + clamp_index(step + reach + 1, steps) * stride
        for k in 0..<4 {
          window[k] = window[k] + source[entering + k] - source[leaving + k]
        }
      }
    }
  }
  pixels
}

///|
/// A sample rounded to the step the picture stores it in, which is none at all
/// for a picture of floats.
fn round_levels(value : Double, levels : Double) -> Double {
  if levels == 0.0 {
    return value
  }
  let held = if value < 0.0 { 0.0 } else if value > 1.0 { 1.0 } else { value }
  (held * levels + 0.5).floor() / levels
}

///|
/// The weights of a one-dimensional Gaussian, symmetric, from `−n` to `n`.
///
/// The tail is cut at three sigma and the rest renormalised, so that the sum is
/// exactly one and a flat image stays exactly flat.
fn gaussian_weights(radius : Double) -> Array[Double] {
  let reach = (3.0 * radius).ceil().to_int()
  let weights : Array[Double] = []
  let mut total = 0.0
  for i in 0..<=(reach * 2) {
    let x = (i - reach).to_double()
    let weight = @math.exp(-(x * x) / (2.0 * radius * radius))
    weights.push(weight)
    total = total + weight
  }
  for i in 0..<weights.length() {
    weights[i] = weights[i] / total
  }
  weights
}

///|
/// One axis of a Gaussian blur, the other dimension untouched.
fn blur_axis(
  source : FixedArray[Double],
  width : Int32,
  height : Int32,
  weights : Array[Double],
  horizontal : Bool,
) -> FixedArray[Double] {
  let reach = (weights.length() - 1) / 2
  let pixels : FixedArray[Double] = FixedArray::make(width * height * 4, 0.0)
  let steps = if horizontal { width } else { height }
  let lines = if horizontal { height } else { width }
  let stride = if horizontal { 4 } else { width * 4 }
  for line in 0..<lines {
    for step in 0..<steps {
      let at = if horizontal {
        (line * width + step) * 4
      } else {
        (line + step * width) * 4
      }
      let mut r = 0.0
      let mut g = 0.0
      let mut b = 0.0
      let mut a = 0.0
      for k in 0..<weights.length() {
        let index = step + k - reach
        let clamped = if index < 0 {
          0
        } else if index >= steps {
          steps - 1
        } else {
          index
        }
        let from = at + (clamped - step) * stride
        r = r + source[from] * weights[k]
        g = g + source[from + 1] * weights[k]
        b = b + source[from + 2] * weights[k]
        a = a + source[from + 3] * weights[k]
      }
      pixels[at] = clamp_unit(r)
      pixels[at + 1] = clamp_unit(g)
      pixels[at + 2] = clamp_unit(b)
      pixels[at + 3] = clamp_unit(a)
    }
  }
  pixels
}

///|
/// The image sharpened by subtracting a blurred copy of itself.
///
/// `amount` is a percentage, a hundred being the difference added once: an edge
/// that the blur softened is pushed back out by the same distance it lost.
/// `threshold` is how much of a difference, in eight-bit steps, is worth
/// sharpening at all, so that the grain of a photograph is not sharpened into
/// noise. Sharpen with radius 1, amount 150 and threshold 3 is the usual
/// starting point.
pub fn Image::unsharp_mask(
  self : Image,
  radius? : Double,
  amount? : Double,
  threshold? : Int32,
) -> Image {
  let radius = radius.unwrap_or(1.0)
  let amount = amount.unwrap_or(100.0)
  let threshold = threshold.unwrap_or(0)
  if radius <= 0.0 || amount == 0.0 {
    return self
  }
  let soft = self.blur(radius)
  if soft.format != self.format ||
    soft.width != self.width ||
    soft.height != self.height {
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
  let strength = amount / 100.0
  let gate = threshold.to_double() / 255.0
  for y in 0..<self.height {
    let row = y * self.stride
    let soft_row = y * soft.stride
    let target_row = y * stride
    for x in 0..<self.width {
      let at = row + x * bytes
      let shape = read_pixel(self.pixels, at, self.format)
      let haze = read_pixel(soft.pixels, soft_row + x * bytes, self.format)
      let diff_r = shape.r - haze.r
      let diff_g = shape.g - haze.g
      let diff_b = shape.b - haze.b
      let loudest = peak(
        peak(absolute(diff_r), absolute(diff_g)),
        absolute(diff_b),
      )
      let sharpened = if loudest < gate {
        shape
      } else {
        {
          ..shape,
          r: clamp_unit(shape.r + diff_r * strength),
          g: clamp_unit(shape.g + diff_g * strength),
          b: clamp_unit(shape.b + diff_b * strength),
        }
      }
      write_pixel(buffer, target_row + x * bytes, self.format, sharpened)
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
fn absolute(value : Double) -> Double {
  if value < 0.0 {
    -value
  } else {
    value
  }
}

///|
fn peak(one : Double, other : Double) -> Double {
  if one > other {
    one
  } else {
    other
  }
}
