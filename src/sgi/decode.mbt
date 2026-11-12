// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Reading an SGI: five hundred and twelve bytes of header, then each channel of
// the picture in turn, one row after another.
//
// Two things in the header surprise a reader that expects another format. The
// rows are counted from the bottom, so the first row in the file is the last row
// of the picture. And the magic and the storage byte can disagree: Pillow writes
// files marked as run-length coded that are stored plain, so the storage byte is
// what decides.
//
// Run-length rows are refused by name. They are read by every decoder that
// predates this one, and this library has no reference that both writes and
// reads them to hold a transcription against; refusing is better than a decoder
// that produces a picture nobody has checked.

///|
/// The magic of a file that may hold runs, and of one written plain.
let magic_rle : Int32 = 474

///|
let magic_plain : Int32 = 473

///|
/// Where the samples begin.
const HEADER_BYTES : Int32 = 512

///|
fn be16(bytes : BytesView, at : Int32) -> Int32 {
  (bytes[at].to_int() << 8) | bytes[at + 1].to_int()
}

///|
/// The image in these bytes.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  if bytes.length() < HEADER_BYTES {
    raise @raster.Truncated(at=0, want=HEADER_BYTES)
  }
  let magic = be16(bytes, 0)
  if magic != magic_rle && magic != magic_plain {
    raise @raster.Unknown(at=0, got=@raster.hex(bytes, 0, 4))
  }
  let storage = bytes[2].to_int()
  if storage == 1 {
    raise @raster.Unsupported(at=2, got="SGI run-length rows")
  }
  if storage != 0 {
    raise @raster.Unsupported(at=2, got="SGI storage \{storage}")
  }
  let depth = bytes[3].to_int()
  if depth != 1 && depth != 2 {
    raise @raster.Unsupported(at=3, got="\{depth} bytes a sample")
  }
  let width = be16(bytes, 6)
  let height = be16(bytes, 8)
  let channels = be16(bytes, 10)
  if width <= 0 || height <= 0 {
    raise @raster.Unexpected(
      at=6,
      got="\{width} by \{height}",
      want="a size with pixels in it",
    )
  }
  if channels < 1 || channels > 4 {
    raise @raster.Unsupported(at=10, got="\{channels} channels")
  }
  limits.check(width, height)
  let needed = width * height * channels * depth
  if needed.to_int64() > limits.bytes.to_int64() {
    raise @raster.OverLimit(limit=limits.bytes, got=needed)
  }
  let at = HEADER_BYTES
  if bytes.length() - at < needed {
    raise @raster.Truncated(
      at=bytes.length(),
      want=needed - (bytes.length() - at),
    )
  }
  let samples : FixedArray[Byte] = FixedArray::make(needed, b'\x00')
  for i in 0..<needed {
    samples[i] = bytes[at + i]
  }
  if depth == 2 {
    // Two bytes a channel, big-endian, which is the layout the rest of this
    // library calls sixteen bits.
    let pixels : FixedArray[Byte] = FixedArray::make(
      width * height * 4 * 2,
      b'\x00',
    )
    for y in 0..<height {
      let stored = height - 1 - y
      for x in 0..<width {
        for channel in 0..<3 {
          let source = if channels >= 3 {
            (channel * height + stored) * width + x
          } else {
            stored * width + x
          }
          let target = (y * width + x) * 8 + channel * 2
          pixels[target] = samples[source * 2]
          pixels[target + 1] = samples[source * 2 + 1]
        }
        let alpha = (y * width + x) * 8 + 6
        if channels == 4 {
          let source = (3 * height + stored) * width + x
          pixels[alpha] = samples[source * 2]
          pixels[alpha + 1] = samples[source * 2 + 1]
        } else {
          pixels[alpha] = b'\xFF'
          pixels[alpha + 1] = b'\xFF'
        }
      }
    }
    return @raster.Image::of(
      width,
      height,
      @raster.PixelFormat::Rgba16,
      Bytes::from_array(pixels.clamped_view()),
    )
  }
  let pixels : FixedArray[Byte] = FixedArray::make(width * height * 4, b'\xFF')
  for y in 0..<height {
    let stored = height - 1 - y
    for x in 0..<width {
      let target = (y * width + x) * 4
      for channel in 0..<3 {
        let source = if channels >= 3 {
          (channel * height + stored) * width + x
        } else {
          stored * width + x
        }
        pixels[target + channel] = samples[source]
      }
      if channels == 4 {
        pixels[target + 3] = samples[(3 * height + stored) * width + x]
      }
    }
  }
  @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(pixels.clamped_view()),
  )
}
