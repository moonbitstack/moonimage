// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// EXIF, or as much of it as a picture needs: the orientation tag.
//
// A camera writes the picture the way its sensor is mounted and records which way
// that was, so a photograph taken in portrait is stored landscape with a note
// saying to turn it. The note lives in an APP1 segment in the oddest box in the
// format: a TIFF header, in either byte order, pointing at a directory of
// twelve-byte entries.
//
// Only the orientation is read here. Nothing else in EXIF changes a pixel, and
// the rest of it is a metadata problem rather than an image one.

///|
/// The orientation in the EXIF block of a JPEG, or `None` when there is no EXIF
/// or it says nothing this library understands.
///
/// A damaged EXIF block is not a damaged image: it comes back as `None` rather
/// than as a refusal, because a picture with a broken camera note is still a
/// picture.
pub fn exif_orientation(bytes : BytesView) -> Orientation? {
  let segment = find_exif(bytes)
  match segment {
    Some(body) => read_orientation(body)
    None => None
  }
}

///|
/// The body of the APP1 segment that holds EXIF, past the six-byte signature.
fn find_exif(bytes : BytesView) -> BytesView? {
  let mut position = 2
  while position + 4 <= bytes.length() {
    if bytes[position].to_int() != 0xFF {
      position = position + 1
      continue
    }
    let marker = bytes[position + 1].to_int()
    if marker == 0xDA || marker == 0xD9 {
      return None
    }
    let length = bytes[position + 2].to_int() * 256 +
      bytes[position + 3].to_int()
    if length < 2 || position + 2 + length > bytes.length() {
      return None
    }
    if marker == 0xE1 {
      let body = bytes.clamped_view(
        start=position + 4,
        end=position + 2 + length,
      )
      if body.length() > 6 && body[0:6].equal_to_bytes(b"Exif\x00\x00") {
        return Some(body.clamped_view(start=6, end=body.length()))
      }
    }
    position = position + 2 + length
  }
  None
}

///|
/// The orientation from a TIFF block, in either byte order.
fn read_orientation(tiff : BytesView) -> Orientation? {
  if tiff.length() < 8 {
    return None
  }
  let little = if tiff[0].to_int() == 0x49 && tiff[1].to_int() == 0x49 {
    true
  } else if tiff[0].to_int() == 0x4D && tiff[1].to_int() == 0x4D {
    false
  } else {
    return None
  }
  let offset = dword(tiff, 4, little)
  if offset + 2 > tiff.length() {
    return None
  }
  let count = word(tiff, offset, little)
  let mut index = 0
  while index < count {
    let entry = offset + 2 + index * 12
    if entry + 12 > tiff.length() {
      return None
    }
    let tag = word(tiff, entry, little)
    if tag == 0x0112 {
      let value = word(tiff, entry + 8, little)
      return Orientation::of(value)
    }
    index = index + 1
  }
  None
}

///|
/// A thirty-two-bit field, which is where the directory offset lives.
fn dword(data : BytesView, at : Int32, little : Bool) -> Int32 {
  if at + 3 >= data.length() {
    return 0
  }
  if little {
    data[at].to_int() +
    data[at + 1].to_int() * 256 +
    data[at + 2].to_int() * 65_536 +
    data[at + 3].to_int() * 16_777_216
  } else {
    data[at].to_int() * 16_777_216 +
    data[at + 1].to_int() * 65_536 +
    data[at + 2].to_int() * 256 +
    data[at + 3].to_int()
  }
}

///|
fn word(data : BytesView, at : Int32, little : Bool) -> Int32 {
  if at + 1 >= data.length() {
    return 0
  }
  if little {
    data[at].to_int() + data[at + 1].to_int() * 256
  } else {
    data[at].to_int() * 256 + data[at + 1].to_int()
  }
}

///|
/// The image turned the way the file says it should be seen.
fn apply_orientation(
  image : @raster.Image,
  orientation : Orientation,
) -> @raster.Image {
  match orientation {
    Normal => image
    FlipHorizontal => image.flip_horizontal()
    Rotate180 => image.rotate(quarters=2)
    FlipVertical => image.flip_vertical()
    Transpose => image.rotate(quarters=1).flip_horizontal()
    Rotate90 => image.rotate(quarters=1)
    Transverse => image.rotate(quarters=1).flip_vertical()
    Rotate270 => image.rotate(quarters=3)
  }
}
