// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Putting a picture the way up the camera meant it.
//
// A camera rotates nothing when it is held sideways: it writes the sensor's
// picture and records which way it was held, in a tag numbered one to eight.
// The eight values are not eight rotations — four of them are mirrored first —
// so applying one is a rotation and possibly a flip, in the order the tag says.
//
// The number is taken rather than a type, because the same eight numbers are
// written by a JPEG's APP1 block and by a TIFF's tag 274, and neither of those
// packages may depend on the other to name them.

///|
/// The image turned the way EXIF orientation `code` says.
///
/// One is the picture as stored and comes back unchanged. A number outside one
/// to eight is refused rather than guessed at: a caller that got the tag wrong
/// wants to hear about it.
pub fn Image::orient(self : Image, code : Int32) -> Image raise Refused {
  match code {
    1 => self
    2 => self.flip_horizontal()
    3 => self.rotate(quarters=2)
    4 => self.flip_vertical()
    5 => self.rotate(quarters=1).flip_horizontal()
    6 => self.rotate(quarters=1)
    7 => self.rotate(quarters=3).flip_horizontal()
    8 => self.rotate(quarters=3)
    _ => raise Unexpected(at=0, got="orientation \{code}", want="one to eight")
  }
}

///|
/// The image the right way up, given the orientation tag a file carried.
///
/// `None` is a file that said nothing, which is the same as saying one: a
/// picture without a tag is a picture as stored.
pub fn Image::upright(self : Image, code : Int32?) -> Image raise Refused {
  match code {
    Some(number) => self.orient(number)
    None => self
  }
}
