// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// farbfeld: eight bytes of signature, two sizes, and then the samples.
//
// The format exists to be the simplest thing that can hold a picture: no
// compression, no palette, no chunk order to get wrong, sixteen bits per
// channel so that a photograph survives a round trip, and big-endian because
// the format was written down once and never revised.
//
// Reading is therefore a header and a copy, and writing is the same in
// reverse. What the format is good for is the thing it was designed for: an
// intermediate that any program can produce and any other can read without
// linking a codec.

///|
/// The eight bytes every farbfeld starts with.
let signature : Bytes = b"farbfeld"

///|
/// The image in these bytes.
///
/// The format has no metadata, no animation and no options, so there is nothing
/// to configure and nothing to refuse beyond a header that is not one and a
/// file that stops in the middle of the samples.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  if bytes.length() < 16 || !bytes.has_prefix(signature) {
    raise @raster.Unknown(at=0, got=@raster.hex(bytes, 0, 8))
  }
  let cursor = @wire.Cursor::new(bytes)
  cursor.skip(8)
  let width = cursor.u32_be()
  let height = cursor.u32_be()
  limits.check(width, height)
  let needed = width.to_int64() * height.to_int64() * 8L
  if needed > limits.bytes.to_int64() {
    raise @raster.OverLimit(limit=limits.bytes, got=2_147_483_647)
  }
  if cursor.left().to_int64() < needed {
    raise @raster.Truncated(
      at=cursor.at(),
      want=(needed - cursor.left().to_int64()).to_int(),
    )
  }
  let samples = cursor.bytes(needed.to_int())
  let pixels : FixedArray[Byte] = FixedArray::make(needed.to_int(), b'\x00')
  for i in 0..<samples.length() {
    pixels[i] = samples[i]
  }
  @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::Rgba16,
    Bytes::from_array(pixels.clamped_view()),
  )
}

///|
/// The image as farbfeld bytes.
///
/// Sixteen bits per channel whatever the image was: an eight-bit picture
/// widens, and the widening is exact, so a round trip through farbfeld is the
/// identity for every picture the library can write.
pub fn encode(image : @raster.Image) -> Bytes {
  let wide = image.convert(@raster.PixelFormat::Rgba16)
  let writer = @wire.Writer::new()
  writer.bytes(signature)
  writer.u32_be(wide.width)
  writer.u32_be(wide.height)
  writer.bytes(wide.pixels)
  writer.to_bytes()
}
