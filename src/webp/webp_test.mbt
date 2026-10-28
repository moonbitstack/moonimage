// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// WebP: the container, and the honest refusal of what is inside it.

///|
/// A RIFF file with the chunks given, so that the container can be tested
/// without a codec behind it.
fn riff(chunks : Array[(String, Bytes)]) -> Bytes {
  let body = @wire.Writer::new()
  body.bytes(b"WEBP")
  for chunk in chunks {
    body.bytes(@utf8.encode(chunk.0))
    body.u32_le(chunk.1.length())
    body.bytes(chunk.1)
    if chunk.1.length() % 2 == 1 {
      body.u8(0)
    }
  }
  let payload = body.to_bytes()
  let writer = @wire.Writer::new()
  writer.bytes(b"RIFF")
  writer.u32_le(payload.length())
  writer.bytes(payload)
  writer.to_bytes()
}

///|
fn refuses(file : Bytes) -> @raster.Refused? {
  try {
    ignore(@webp.decode(file))
    None
  } catch {
    error => Some(error)
  }
}

///|
test "webp: a file that is not RIFF/WebP is unknown" {
  assert_true(
    refuses(b"not a webp at all") is Some(@raster.Refused::Unknown(..)),
  )
  assert_true(
    refuses(b"RIFF\x00\x00\x00\x00NOPE") is Some(@raster.Refused::Unknown(..)),
  )
}

///|
/// The message a refusal carries, or an empty string.
fn reason(refused : @raster.Refused?) -> String {
  match refused {
    Some(error) => error.to_string()
    None => ""
  }
}

///|
test "webp: the container is walked, and the codec inside is refused by name" {
  let lossless = riff([("VP8L", b"\x2f\x00\x00\x00\x00")])
  assert_true(reason(refuses(lossless)).contains("VP8L"))
  let lossy = riff([("VP8 ", b"\x00\x00\x00")])
  assert_true(reason(refuses(lossy)).contains("VP8"))
}

///|
test "webp: an animation says it has frames, and the frames say nothing this reads" {
  let header = @wire.Writer::new()
  header.u8(0x02)
  header.zeros(3)
  header.u24_le(31)
  header.u24_le(15)
  let animation = riff([
    ("VP8X", header.to_bytes()),
    ("ANIM", b"\x00\x00\x00\x00\x00\x00"),
    ("ANMF", Bytes::make(16, b'\x00')),
  ])
  assert_true(reason(refuses(animation)).contains("codec"))
}

///|
test "webp: writing refuses rather than producing a file nothing can read" {
  let image = @raster.Image::new(2, 2, @raster.PixelFormat::Rgba8)
  let refused = try {
    ignore(@webp.encode(image))
    false
  } catch {
    @raster.Refused::Unsupported(..) => true
    _ => false
  }
  assert_true(refused)
  let animation = @raster.Animation::new(2, 2, [@raster.Frame::new(image)])
  let refused = try {
    ignore(@webp.encode_animation(animation))
    false
  } catch {
    @raster.Refused::Unsupported(..) => true
    _ => false
  }
  assert_true(refused)
}
