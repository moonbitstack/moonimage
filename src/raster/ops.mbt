// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Moving pixels around without looking at what they are.
//
// A flip, a quarter turn and a crop are the three operations a caller needs to
// fix an image that arrived the wrong way up, and all three are the same kind of
// work: copy a pixel from here to there. Because the format is never consulted,
// a 16-bit image and a grey one go through the same code, and no precision is
// lost on the way.

///|
/// The image reflected left to right.
pub fn Image::flip_horizontal(self : Image) -> Image {
  let pixel = self.format.bytes()
  let stride = self.width * pixel
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
      let from = source_row + (self.width - 1 - x) * pixel
      let to = target_row + x * pixel
      for k in 0..<pixel {
        buffer[to + k] = self.pixels[from + k]
      }
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
/// The image reflected top to bottom.
pub fn Image::flip_vertical(self : Image) -> Image {
  let row_bytes = self.width * self.format.bytes()
  let buffer : FixedArray[Byte] = FixedArray::make(
    if self.height == 0 {
      0
    } else {
      row_bytes * self.height
    },
    b'\x00',
  )
  for y in 0..<self.height {
    let source_row = (self.height - 1 - y) * self.stride
    let target_row = y * row_bytes
    for k in 0..<row_bytes {
      buffer[target_row + k] = self.pixels[source_row + k]
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
/// The image turned a quarter turn clockwise, `quarters` times.
///
/// Negative counts turn anticlockwise, and anything beyond four wraps: this is
/// a total function because a rotation is.
pub fn Image::rotate(self : Image, quarters? : Int32) -> Image {
  let turns = (quarters.unwrap_or(1) % 4 + 4) % 4
  if turns == 0 {
    return self
  }
  let pixel = self.format.bytes()
  let width = self.width
  let height = self.height
  let (out_width, out_height) = if turns == 2 {
    (width, height)
  } else {
    (height, width)
  }
  let stride = out_width * pixel
  let buffer : FixedArray[Byte] = FixedArray::make(
    if out_height == 0 {
      0
    } else {
      stride * out_height
    },
    b'\x00',
  )
  for y in 0..<out_height {
    for x in 0..<out_width {
      let (source_x, source_y) = match turns {
        1 => (y, height - 1 - x)
        2 => (width - 1 - x, height - 1 - y)
        _ => (width - 1 - y, x)
      }
      let from = source_y * self.stride + source_x * pixel
      let to = y * stride + x * pixel
      for k in 0..<pixel {
        buffer[to + k] = self.pixels[from + k]
      }
    }
  }
  assemble(
    out_width,
    out_height,
    self.format,
    buffer,
    self.premultiplied,
    self.metadata,
  )
}

///|
/// The rectangle at (`x`, `y`) of the given size, as an image of its own.
///
/// Raises when the rectangle does not fit: a crop is a claim about the image,
/// and a crop that reaches outside it is a bug in the caller.
pub fn Image::crop(
  self : Image,
  x : Int32,
  y : Int32,
  width : Int32,
  height : Int32,
) -> Image raise Refused {
  if x < 0 || y < 0 || width < 0 || height < 0 {
    raise Unexpected(
      at=0,
      got="a rectangle outside the image",
      want="x, y, width and height at least zero",
    )
  }
  if x + width > self.width {
    raise OverLimit(limit=self.width, got=x + width)
  }
  if y + height > self.height {
    raise OverLimit(limit=self.height, got=y + height)
  }
  let pixel = self.format.bytes()
  let stride = width * pixel
  let buffer : FixedArray[Byte] = FixedArray::make(
    if height == 0 {
      0
    } else {
      stride * height
    },
    b'\x00',
  )
  for row in 0..<height {
    let source_row = (y + row) * self.stride + x * pixel
    let target_row = row * stride
    for k in 0..<stride {
      buffer[target_row + k] = self.pixels[source_row + k]
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
