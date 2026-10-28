// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// WebP: a RIFF container holding one of two codecs, or an animation of them.
//
// https://developers.google.com/speed/webp/docs/riff_container
// https://datatracker.ietf.org/doc/html/rfc9649
//
// The container is a list of chunks with a header that says which of the two
// codecs each picture uses. Lossless pictures are VP8L, read in `vp8l.mbt`;
// lossy ones are VP8, the intra frame of a video codec, read in `vp8.mbt`. An
// animation is a canvas plus a run of `ANMF` records, each a rectangle with a
// delay and its own one-picture file inside.

///|
/// The image in a WebP file.
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
/// A still picture comes back as an animation of one frame covering the whole
/// canvas, which is what every other format here does and what lets a caller
/// hand any WebP to one code path.
pub fn decode_animation(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Animation raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  let chunks = read_riff(bytes)
  let frames : Array[@raster.Frame] = []
  let mut canvas_width = 0
  let mut canvas_height = 0
  let mut alpha : BytesView? = None
  let mut loops = 0
  for chunk in chunks {
    let (name, payload) = chunk
    match name {
      "VP8X" => {
        if payload.length() < 10 {
          raise @raster.Truncated(at=0, want=10 - payload.length())
        }
        canvas_width = be24(payload, 4) + 1
        canvas_height = be24(payload, 7) + 1
        limits.check(canvas_width, canvas_height)
      }
      "ANIM" => {
        if payload.length() < 6 {
          raise @raster.Truncated(at=0, want=6 - payload.length())
        }
        loops = payload[4].to_int() + payload[5].to_int() * 256
      }
      "ANMF" => frames.push(read_frame(payload, limits))
      "ALPH" => alpha = Some(payload)
      "VP8L" => {
        // A lossless picture carries its own alpha, so anything pending here
        // belonged to a chunk that was never followed by a lossy one.
        alpha = None
        frames.push(@raster.Frame::new(decode_lossless(payload, limits)))
      }
      "VP8 " => {
        let image = decode_lossy(payload, limits)
        let picture = match alpha {
          Some(plane) =>
            with_alpha(image, decode_alpha(plane, image.width, image.height, limits))
          None => image
        }
        alpha = None
        frames.push(@raster.Frame::new(picture))
      }
      _ => ()
    }
  }
  if frames.is_empty() {
    raise @raster.Unexpected(
      at=0,
      got="no image data",
      want="a VP8L or VP8 chunk",
    )
  }
  if canvas_width == 0 || canvas_height == 0 {
    canvas_width = frames[0].image.width
    canvas_height = frames[0].image.height
  }
  @raster.Animation::new(canvas_width, canvas_height, frames, loops~)
}

///|
/// One `ANMF` record: where the frame goes, how long it stays, what to do with
/// it afterwards, and the picture itself.
fn read_frame(
  payload : BytesView,
  limits : @raster.Limits,
) -> @raster.Frame raise @raster.Refused {
  if payload.length() < 16 {
    raise @raster.Truncated(at=0, want=16 - payload.length())
  }
  // The offsets are stored in units of two pixels, because a WebP frame that
  // lands on an odd pixel would not survive the chroma subsampling.
  let x = be24(payload, 0) * 2
  let y = be24(payload, 3) * 2
  let width = be24(payload, 6) + 1
  let height = be24(payload, 9) + 1
  let delay = be24(payload, 12)
  let flags = payload[15].to_int()
  limits.check(width, height)
  let inner = read_riff_body(payload, 16)
  let mut picture : @raster.Image? = None
  let mut alpha : BytesView? = None
  for chunk in inner {
    let (name, body) = chunk
    match name {
      "ALPH" => alpha = Some(body)
      "VP8L" => picture = Some(decode_lossless(body, limits))
      "VP8 " => {
        let image = decode_lossy(body, limits)
        picture = Some(
          match alpha {
            Some(plane) =>
              with_alpha(image, decode_alpha(plane, image.width, image.height, limits))
            None => image
          },
        )
      }
      _ => ()
    }
  }
  let image = match picture {
    Some(image) => image
    None =>
      raise @raster.Unexpected(
        at=0,
        got="a frame with no picture",
        want="a VP8L or VP8 chunk",
      )
  }
  if image.width != width || image.height != height {
    raise @raster.Unexpected(
      at=0,
      got="a frame \{image.width} by \{image.height}",
      want="\{width} by \{height}",
    )
  }
  @raster.Frame::new(
    image,
    x~,
    y~,
    delay~,
    dispose=if (flags & 0x01) != 0 {
      @raster.Dispose::Background
    } else {
      @raster.Dispose::Keep
    },
    blend=if (flags & 0x02) != 0 {
      @raster.Blend::Source
    } else {
      @raster.Blend::Over
    },
  )
}

///|
/// The image as a lossless WebP.
///
/// Every image can be written — the writer finds its own trees and never has to
/// refuse — so this is the one direction in the library that cannot fail.
pub fn encode(image : @raster.Image) -> Bytes {
  write_riff([("VP8L", encode_lossless(image))])
}

///|
/// The animation as an animated WebP.
pub fn encode_animation(
  animation : @raster.Animation,
) -> Bytes raise @raster.Refused {
  if animation.frames.is_empty() {
    raise @raster.Unexpected(
      at=0,
      got="an animation with no frames",
      want="at least one",
    )
  }
  let canvas_width = animation.width
  let canvas_height = animation.height
  let chunks : Array[(String, Bytes)] = []
  let header = @wire.Writer::new()
  // The animation bit, and nothing else: no alpha, no EXIF, no XMP.
  header.u8(0x02)
  header.zeros(3)
  header.u24_le(canvas_width - 1)
  header.u24_le(canvas_height - 1)
  chunks.push(("VP8X", header.to_bytes()))
  let loop_count = @wire.Writer::new()
  loop_count.u32_le(0)
  loop_count.u16_le(animation.loops)
  chunks.push(("ANIM", loop_count.to_bytes()))
  for frame in animation.frames {
    let record = @wire.Writer::new()
    record.u24_le(frame.x / 2)
    record.u24_le(frame.y / 2)
    record.u24_le(frame.image.width - 1)
    record.u24_le(frame.image.height - 1)
    record.u24_le(frame.delay)
    record.u8(
      (if frame.blend == @raster.Blend::Source { 0x02 } else { 0x00 }) |
      (if frame.dispose == @raster.Dispose::Background { 0x01 } else { 0x00 }),
    )
    record.bytes(encode_lossless(frame.image))
    chunks.push(("ANMF", record.to_bytes()))
  }
  write_riff(chunks)
}

///|
/// A RIFF file over the chunks given, each with its padding byte when its size
/// is odd.
fn write_riff(chunks : Array[(String, Bytes)]) -> Bytes {
  let body = @wire.Writer::new()
  body.bytes(b"WEBP")
  for chunk in chunks {
    let name = chunk.0
    let payload = chunk.1
    for index in 0..<4 {
      body.u8(name[index].to_int())
    }
    body.u32_le(payload.length())
    body.bytes(payload)
    if payload.length() % 2 == 1 {
      body.u8(0)
    }
  }
  let payload = body.to_bytes()
  let file = @wire.Writer::new()
  file.bytes(b"RIFF")
  file.u32_le(payload.length())
  file.bytes(payload)
  file.to_bytes()
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
  read_riff_body(bytes, 12)
}

///|
/// The chunk list starting at `from`, which is where a frame's records begin
/// inside its own `ANMF` payload.
fn read_riff_body(
  bytes : BytesView,
  from : Int32,
) -> Array[(String, BytesView)] raise @raster.Refused {
  let chunks : Array[(String, BytesView)] = []
  let cursor = @wire.Cursor::new(bytes)
  cursor.seek(from)
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
