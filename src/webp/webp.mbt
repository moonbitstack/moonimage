// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// WebP: a RIFF container holding one of two codecs, or an animation of them.
//
// https://developers.google.com/speed/webp/docs/riff_container
// https://datatracker.ietf.org/doc/html/rfc9649
//
// The container is read: the chunk list, the extended header, the animation
// declaration and the per-frame records. What is not read yet is the codec
// inside — VP8L, a lossless one built on LZ77 with a colour cache and four
// transforms, and VP8, which is the intra frame of a video codec. Both raise
// `Unsupported`, and so does writing, because a writer without its reader is
// half a codec and saying so is better than producing a file nobody here can
// check.

///|
/// The image in a WebP file.
///
/// Raises `Unsupported` until the codecs inside are read.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let animation = decode_animation(bytes, limits?)
  animation.frames[0].image
}

///|
/// Every frame of an animated WebP.
///
/// Raises `Unsupported` until the codecs inside are read.
pub fn decode_animation(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Animation raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  let chunks = read_riff(bytes)
  let mut width = 0
  let mut height = 0
  let mut loops = 0
  let mut frames = 0
  for chunk in chunks {
    let (name, payload) = chunk
    match name {
      "VP8L" => raise @raster.Unsupported(at=0, got="VP8L, the lossless codec")
      "VP8 " => raise @raster.Unsupported(at=0, got="VP8, the lossy codec")
      "VP8X" => {
        if payload.length() < 10 {
          raise @raster.Truncated(at=0, want=10 - payload.length())
        }
        width = be24(payload, 4) + 1
        height = be24(payload, 7) + 1
        limits.check(width, height)
      }
      "ANIM" => {
        if payload.length() < 6 {
          raise @raster.Truncated(at=0, want=6 - payload.length())
        }
        loops = payload[4].to_int() + payload[5].to_int() * 256
      }
      "ANMF" => frames = frames + 1
      _ => ()
    }
  }
  let _ = (width, height, loops)
  if frames == 0 {
    raise @raster.Unexpected(
      at=0,
      got="no image data",
      want="a VP8L or VP8X chunk",
    )
  }
  raise @raster.Unsupported(
    at=0,
    got="a WebP frame, whose codec this library does not read",
  )
}

///|
/// The image as a lossless WebP.
///
/// Not written yet: the writer is the other half of the codec.
pub fn encode(image : @raster.Image) -> Bytes raise @raster.Refused {
  ignore(image)
  raise @raster.Unsupported(
    at=0,
    got="WebP, which this library does not write yet",
  )
}

///|
/// The animation as an animated WebP.
///
/// Not written yet: the writer is the other half of the codec.
pub fn encode_animation(
  animation : @raster.Animation,
) -> Bytes raise @raster.Refused {
  ignore(animation)
  raise @raster.Unsupported(
    at=0,
    got="animated WebP, which this library does not write yet",
  )
}

///|
/// The chunks of a RIFF file, each as a view of its payload.
fn read_riff(
  bytes : BytesView,
) -> Array[(String, BytesView)] raise @raster.Refused {
  if bytes.length() < 12 || !bytes[0:4].equal_to_bytes(b"RIFF") {
    raise @raster.Unknown(at=0, got=@raster.hex(bytes, 0, 4))
  }
  if !bytes[8:12].equal_to_bytes(b"WEBP") {
    raise @raster.Unknown(at=8, got=@raster.hex(bytes, 8, 4))
  }
  let chunks : Array[(String, BytesView)] = []
  let cursor = @wire.Cursor::new(bytes)
  cursor.seek(12)
  while cursor.left() >= 8 {
    let name = ascii(cursor.bytes(4))
    let size = cursor.u32_le()
    if size > cursor.left() {
      raise @raster.Truncated(at=cursor.at(), want=size - cursor.left())
    }
    chunks.push((name, cursor.bytes(size)))
    if size % 2 == 1 && cursor.left() > 0 {
      ignore(cursor.u8())
    }
  }
  chunks
}

///|
fn ascii(bytes : BytesView) -> String {
  let characters : Array[Char] = []
  for index in 0..<bytes.length() {
    characters.push(bytes[index].to_int().unsafe_to_char())
  }
  String::from_array(characters.clamped_view())
}

///|
fn be24(data : BytesView, at : Int32) -> Int32 {
  data[at].to_int() +
  data[at + 1].to_int() * 256 +
  data[at + 2].to_int() * 65_536
}
