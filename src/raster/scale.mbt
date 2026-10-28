// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Making an image a different size.
//
// Three filters, because the three answer different questions. Nearest is what
// a pixel artist wants: a pixel becomes a square, and no colour that was not in
// the original appears. Bilinear is what a photograph wants when it is being
// scaled a little: cheap, and smooth enough that the result does not crawl.
// Lanczos is what it wants when it is being scaled a lot or viewed still: six
// taps per axis, sharp edges, and a small amount of ringing that is the price of
// the sharpness.
//
// Alpha is resampled premultiplied even when the image is not stored that way.
// A transparent pixel usually has an arbitrary colour behind its alpha, and
// averaging that colour into its neighbours is how a sprite gets a dark fringe.

///|
/// How a scaler decides what an unknown pixel is worth.
pub(all) enum Sampling {
  /// The nearest pixel, and nothing else: no new colours.
  Nearest
  /// A weighted average of the four nearest, weights linear in distance.
  Bilinear
  /// A weighted average of the six nearest per axis, weights from the Lanczos
  /// window with a = 3.
  Lanczos
} derive(Eq, Debug)

///|
pub extend Sampling with Eq::{equal, not_equal}

///|
pub extend Sampling with Debug::{to_repr}

///|
/// The image at a new size.
///
/// Raises when either dimension is not positive, and when the result would be
/// larger than `Limits::default()` — a scaler is easy to point at a huge size by
/// accident.
pub fn Image::scale(
  self : Image,
  width : Int32,
  height : Int32,
  sampling? : Sampling,
) -> Image raise Refused {
  if width <= 0 || height <= 0 {
    raise Unexpected(
      at=0,
      got="a size with no pixels",
      want="a width and a height above zero",
    )
  }
  Limits::default().check(width, height)
  let sampling = sampling.unwrap_or(Bilinear)
  if width == self.width && height == self.height {
    return self
  }
  match sampling {
    Nearest => self.scale_nearest(width, height)
    _ => self.scale_weighted(width, height, sampling)
  }
}

///|
/// Nearest neighbour, copied byte by byte: no arithmetic, so a palette stays a
/// palette.
fn Image::scale_nearest(self : Image, width : Int32, height : Int32) -> Image {
  let pixel = self.format.bytes()
  let stride = width * pixel
  let buffer : FixedArray[Byte] = FixedArray::make(stride * height, b'\x00')
  for y in 0..<height {
    let source_y = y * self.height / height
    let source_row = source_y * self.stride
    let target_row = y * stride
    for x in 0..<width {
      let source_x = x * self.width / width
      let from = source_row + source_x * pixel
      let to = target_row + x * pixel
      for k in 0..<pixel {
        buffer[to + k] = self.pixels[from + k]
      }
    }
  }
  assemble(
    width,
    height,
    self.format,
    buffer,
    self.premultiplied,
    self.metadata,
  )
}

///|
/// Bilinear or Lanczos, one axis at a time.
///
/// Two passes, because both filters are separable: a two-dimensional Lanczos
/// over six taps is thirty-six samples per pixel, and two one-dimensional ones
/// are twelve.
///
/// The working copy is `Double`, not `Float` and not an eight-bit image. A
/// filter that averages 200 and 255 lands on 227.5, and 227.5 is exactly the
/// value that a narrower working type rounds down: one step of brightness lost
/// on every boundary, which is visible as banding in a gradient.
fn Image::scale_weighted(
  self : Image,
  width : Int32,
  height : Int32,
  sampling : Sampling,
) -> Image {
  let source = self.working_copy()
  let across = resample(source, self.width, self.height, width, true, sampling)
  let down = resample(across, width, self.height, height, false, sampling)
  let pixel = self.format.bytes()
  let stride = width * pixel
  let buffer : FixedArray[Byte] = FixedArray::make(stride * height, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let at = (y * width + x) * 4
      let alpha = down[at + 3]
      let scale = if self.premultiplied || alpha <= 0.0 {
        1.0
      } else {
        1.0 / alpha
      }
      write_pixel(buffer, y * stride + x * pixel, self.format, {
        r: down[at] * scale,
        g: down[at + 1] * scale,
        b: down[at + 2] * scale,
        a: alpha,
      })
    }
  }
  assemble(
    width,
    height,
    self.format,
    buffer,
    self.premultiplied,
    self.metadata,
  )
}

///|
/// Four numbers per pixel, premultiplied, which is what a filter may average.
fn Image::working_copy(self : Image) -> FixedArray[Double] {
  let pixels : FixedArray[Double] = FixedArray::make(
    self.width * self.height * 4,
    0.0,
  )
  let bpp = self.format.bytes()
  let multiplied = self.premultiplied || !self.format.has_alpha()
  for y in 0..<self.height {
    for x in 0..<self.width {
      let pixel = read_pixel(
        self.pixels,
        y * self.stride + x * bpp,
        self.format,
      )
      let at = (y * self.width + x) * 4
      let alpha = if self.format.has_alpha() { pixel.a } else { 1.0 }
      let weight = if multiplied { 1.0 } else { alpha }
      pixels[at] = pixel.r * weight
      pixels[at + 1] = pixel.g * weight
      pixels[at + 2] = pixel.b * weight
      pixels[at + 3] = alpha
    }
  }
  pixels
}

///|
/// One axis of a separable filter: the image becomes `length` wide, or `length`
/// tall, and the other dimension is untouched.
fn resample(
  source : FixedArray[Double],
  width : Int32,
  height : Int32,
  length : Int32,
  horizontal : Bool,
  sampling : Sampling,
) -> FixedArray[Double] {
  let out_width = if horizontal { length } else { width }
  let out_height = if horizontal { height } else { length }
  let taps = axis_weights(
    if horizontal {
      width
    } else {
      height
    },
    length,
    sampling,
  )
  let pixels : FixedArray[Double] = FixedArray::make(
    out_width * out_height * 4,
    0.0,
  )
  for y in 0..<out_height {
    for x in 0..<out_width {
      let weights = if horizontal { taps[x] } else { taps[y] }
      let mut r = 0.0
      let mut g = 0.0
      let mut b = 0.0
      let mut a = 0.0
      for tap in weights {
        let (index, weight) = tap
        let at = if horizontal {
          (y * width + index) * 4
        } else {
          (index * width + x) * 4
        }
        r = r + source[at] * weight
        g = g + source[at + 1] * weight
        b = b + source[at + 2] * weight
        a = a + source[at + 3] * weight
      }
      let to = (y * out_width + x) * 4
      pixels[to] = clamp_unit(r)
      pixels[to + 1] = clamp_unit(g)
      pixels[to + 2] = clamp_unit(b)
      pixels[to + 3] = clamp_unit(a)
    }
  }
  pixels
}

///|
/// A sample held to 0–1: a filter with negative lobes can overshoot, and a
/// channel outside the range is not a colour.
fn clamp_unit(value : Double) -> Double {
  if value < 0.0 {
    0.0
  } else if value > 1.0 {
    1.0
  } else {
    value
  }
}

///|
/// The taps each output position reads, and how much of each.
///
/// Positions that fall outside the image are clamped to its edge, and the weights
/// are renormalised afterwards: a filter that sums to less than one at the
/// border darkens it, which is the visible edge artefact of a naive scaler.
fn axis_weights(
  source : Int32,
  target : Int32,
  sampling : Sampling,
) -> Array[Array[(Int32, Double)]] {
  let ratio = source.to_double() / target.to_double()
  let taps : Array[Array[(Int32, Double)]] = []
  for i in 0..<target {
    let center = (i.to_double() + 0.5) * ratio - 0.5
    let weights : Array[(Int32, Double)] = []
    if sampling == Bilinear {
      let left = center.floor().to_int()
      let fraction = center - left.to_double()
      push_weight(weights, left, 1.0 - fraction, source)
      push_weight(weights, left + 1, fraction, source)
    } else {
      let first = center.floor().to_int() - 2
      for k in 0..<6 {
        let index = first + k
        push_weight(weights, index, lanczos(center - index.to_double()), source)
      }
    }
    let total = sum_weights(weights)
    let normalised : Array[(Int32, Double)] = []
    for tap in weights {
      let (index, weight) = tap
      normalised.push((index, if total == 0.0 { 0.0 } else { weight / total }))
    }
    taps.push(normalised)
  }
  taps
}

///|
fn push_weight(
  taps : Array[(Int32, Double)],
  index : Int32,
  weight : Double,
  source : Int32,
) -> Unit {
  let clamped = if index < 0 {
    0
  } else if index >= source {
    source - 1
  } else {
    index
  }
  taps.push((clamped, weight))
}

///|
fn sum_weights(taps : Array[(Int32, Double)]) -> Double {
  let mut total = 0.0
  for tap in taps {
    total = total + tap.1
  }
  total
}

///|
/// The Lanczos window with a = 3, in one dimension.
fn lanczos(x : Double) -> Double {
  let distance = if x < 0.0 { -x } else { x }
  if distance < 1.0e-9 {
    1.0
  } else if distance >= 3.0 {
    0.0
  } else {
    let pi = 3.141592653589793
    let px = pi * distance
    3.0 * @math.sin(px) * @math.sin(px / 3.0) / (px * px)
  }
}
