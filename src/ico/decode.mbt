// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Windows icons and cursors: one file holding the same picture at several
// sizes, each size picked by the shell for the place it is drawn in.
//
// The container is a directory of sixteen-byte entries followed by the pictures
// themselves, and a picture is either a whole PNG — which is what everything
// written since Vista is — or a device-independent bitmap with its file header
// cut off, followed by a one-bit mask whose rows are padded to four bytes. That
// second shape is why this package carries its own bitmap reader rather than
// calling the one next door: the height in that header is twice the picture's,
// the rows run bottom to top, and the mask is not part of any BMP file.
//
// A cursor is the same file with type two, and the two words a bitmap would use
// for its colour planes and bit depth are read as the hot spot instead.

///|
/// One picture of an icon, and where the pointer sits on it when it is a cursor.
pub(all) struct Entry {
  /// The picture.
  image : @raster.Image
  /// The column the pointer points at. Zero for an icon.
  hot_x : Int32
  /// The row the pointer points at. Zero for an icon.
  hot_y : Int32
}

///|
/// Whether this file holds icons or cursors.
#derive(Eq, Debug)
pub(all) enum Kind {
  /// An icon.
  Icon
  /// A cursor, which is an icon with a hot spot.
  Cursor
}

///|
pub extend Kind with Eq::{equal, not_equal}

///|
pub extend Kind with Debug::{to_repr}

///|
/// The largest picture in the file, which is the one a caller that asked for
/// "the icon" meant.
///
/// The largest is chosen by area rather than by order, because the directory is
/// allowed to be in any order and usually is.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let entries = decode_all(bytes, limits?)
  let mut best = 0
  for i in 1..<entries.length() {
    let here = entries[i].image
    let there = entries[best].image
    if here.width * here.height > there.width * there.height {
      best = i
    }
  }
  entries[best].image
}

///|
/// Every picture in the file, in the order the directory lists them.
pub fn decode_all(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> Array[Entry] raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  let cursor = @wire.Cursor::new(bytes)
  if bytes.length() < 6 {
    raise @raster.Truncated(at=0, want=6)
  }
  if bytes[0].to_int() != 0 || bytes[1].to_int() != 0 {
    raise @raster.Unknown(at=0, got=@raster.hex(bytes, 0, 6))
  }
  cursor.skip(2)
  let kind = match cursor.u16_le() {
    1 => Icon
    2 => Cursor
    other => raise @raster.Unknown(at=0, got="an icon type of \{other}")
  }
  let count = cursor.u16_le()
  if count <= 0 {
    raise @raster.Unexpected(
      at=4,
      got="a directory with no entries",
      want="at least one picture",
    )
  }
  let entries : Array[Entry] = []
  for index in 0..<count {
    let base = 6 + index * 16
    if base + 16 > bytes.length() {
      raise @raster.Truncated(at=base, want=base + 16 - bytes.length())
    }
    let width = wide_size(bytes[base].to_int())
    let height = wide_size(bytes[base + 1].to_int())
    let hot_x = cursor_field(bytes, base + 4)
    let hot_y = cursor_field(bytes, base + 6)
    let length = le32(bytes, base + 8)
    let at = le32(bytes, base + 12)
    if at < 0 ||
      length < 0 ||
      at.to_int64() + length.to_int64() > bytes.length().to_int64() {
      raise @raster.Truncated(at~, want=length)
    }
    let body = bytes.clamped_view(start=at, end=at + length)
    let image = if body.length() >= 8 && body.has_prefix(b"\x89PNG\r\n\x1a\n") {
      @png.decode(body, limits~)
    } else {
      decode_bitmap(body, width, height, limits)
    }
    entries.push({
      image,
      hot_x: if kind == Cursor {
        hot_x
      } else {
        0
      },
      hot_y: if kind == Cursor {
        hot_y
      } else {
        0
      },
    })
  }
  entries
}

///|
/// The size byte of a directory entry, where nought means 256.
fn wide_size(value : Int32) -> Int32 {
  if value == 0 {
    256
  } else {
    value
  }
}

///|
/// The two words after the size: a hot spot in a cursor, colour planes in an
/// icon, which is a fact about the file rather than a rule about reading it.
fn cursor_field(bytes : BytesView, at : Int32) -> Int32 {
  bytes[at].to_int() | (bytes[at + 1].to_int() << 8)
}

///|
/// A little-endian thirty-two-bit number, kept signed because one of the two
/// uses of it is an offset that a hostile file can set to anything.
fn le32(bytes : BytesView, at : Int32) -> Int32 {
  bytes[at].to_int() |
  (bytes[at + 1].to_int() << 8) |
  (bytes[at + 2].to_int() << 16) |
  (bytes[at + 3].to_int() << 24)
}

///|
/// One bitmap entry: a header without its file header, a palette, the colour
/// rows bottom to top, and then the mask.
fn decode_bitmap(
  body : BytesView,
  width : Int32,
  height : Int32,
  limits : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  if body.length() < 40 {
    raise @raster.Truncated(at=0, want=40)
  }
  let header = le32(body, 0)
  if header < 40 {
    raise @raster.Unsupported(at=0, got="a header of \{header} bytes")
  }
  let bpp = body[14].to_int() | (body[15].to_int() << 8)
  let compression = le32(body, 16)
  if compression != 0 {
    raise @raster.Unsupported(at=16, got="a compression of \{compression}")
  }
  if bpp != 1 && bpp != 4 && bpp != 8 && bpp != 24 && bpp != 32 {
    raise @raster.Unsupported(at=14, got="\{bpp} bits a pixel")
  }
  let used = le32(body, 32)
  let colours = if used == 0 { 1 << bpp } else { used }
  let palette_at = header
  let entries = if bpp <= 8 { colours } else { 0 }
  let palette_size = entries * 4
  if palette_at + palette_size > body.length() {
    raise @raster.Truncated(at=palette_at, want=palette_size)
  }
  let stride = (width * bpp + 31) / 32 * 4
  let mask_stride = (width + 31) / 32 * 4
  let pixels_at = palette_at + palette_size
  let colour_bytes = stride.to_int64() * height.to_int64()
  if pixels_at.to_int64() + colour_bytes > body.length().to_int64() {
    raise @raster.Truncated(at=pixels_at, want=colour_bytes.to_int())
  }
  let mask_at = pixels_at + colour_bytes.to_int()
  let has_mask = mask_at.to_int64() + mask_stride.to_int64() * height.to_int64() <=
    body.length().to_int64()
  limits.check(width, height)
  let out : FixedArray[Byte] = FixedArray::make(width * height * 4, b'\x00')
  let mut any_alpha = false
  for y in 0..<height {
    // The rows of a bitmap run bottom to top.
    let row = pixels_at + (height - 1 - y) * stride
    for x in 0..<width {
      let (r, g, b, a) = match bpp {
        32 => {
          let at = row + x * 4
          (body[at + 2], body[at + 1], body[at], body[at + 3])
        }
        24 => {
          let at = row + x * 3
          (body[at + 2], body[at + 1], body[at], b'\xFF')
        }
        8 => palette_colour(body, palette_at, body[row + x].to_int())
        4 => {
          let byte = body[row + x / 2].to_int()
          let index = if x % 2 == 0 { byte >> 4 } else { byte & 0xF }
          palette_colour(body, palette_at, index)
        }
        _ => {
          let byte = body[row + x / 8].to_int()
          let index = (byte >> (7 - x % 8)) & 1
          palette_colour(body, palette_at, index)
        }
      }
      if a.to_int() != 0 {
        any_alpha = true
      }
      let to = (y * width + x) * 4
      out[to] = r
      out[to + 1] = g
      out[to + 2] = b
      out[to + 3] = a
    }
  }
  // An icon written before alpha was honoured has a whole channel of noughts;
  // the mask is the only thing that says which pixels are transparent, so it is
  // used whenever the channel says nothing at all.
  if !any_alpha && has_mask {
    for y in 0..<height {
      let row = mask_at + (height - 1 - y) * mask_stride
      for x in 0..<width {
        let byte = body[row + x / 8].to_int()
        let clear = (byte >> (7 - x % 8)) & 1
        let to = (y * width + x) * 4
        if clear == 1 {
          out[to] = 0
          out[to + 1] = 0
          out[to + 2] = 0
          out[to + 3] = 0
        } else {
          out[to + 3] = 255
        }
      }
    }
  }
  @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(out.clamped_view()),
  )
}

///|
/// One palette entry, as four samples.
fn palette_colour(
  body : BytesView,
  palette_at : Int32,
  index : Int32,
) -> (Byte, Byte, Byte, Byte) {
  let at = palette_at + index * 4
  (body[at + 2], body[at + 1], body[at], b'\xFF')
}
