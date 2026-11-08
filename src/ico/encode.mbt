// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing icons and cursors.
//
// Every picture is written as a PNG. The container has allowed it since Vista
// and the alternative — a bitmap plus a one-bit mask — cannot say "half
// transparent", so an icon of a rounded corner comes out with a sawtooth edge
// if it goes that way. A PNG entry costs the size of a small PNG and says
// exactly what the picture is.
//
// A size list rather than one picture, because that is what the format is for:
// the shell picks 16 for a menu, 32 for the desktop and 256 for a folder, and
// scaling at the moment of drawing is what makes an icon look wrong.

///|
/// How to write the file.
pub(all) struct EncodeOptions {
  /// Icons or cursors.
  kind : Kind
  /// The sizes to store, in pixels. Empty means the image's own size.
  sizes : Array[Int32]
  /// Where the pointer points, for a cursor.
  hot_x : Int32
  /// Where the pointer points, for a cursor.
  hot_y : Int32
}

///|
/// One entry at the image's own size, as an icon.
pub fn EncodeOptions::default() -> EncodeOptions {
  { kind: Icon, sizes: [], hot_x: 0, hot_y: 0, }
}

///|
/// The same, for a cursor, with the hot spot the caller names.
pub fn EncodeOptions::cursor(hot_x : Int32, hot_y : Int32) -> EncodeOptions {
  { kind: Cursor, sizes: [], hot_x, hot_y, }
}

///|
/// The image as an icon or a cursor.
pub fn encode(image : @raster.Image, options? : EncodeOptions) -> Bytes {
  let options = options.unwrap_or(EncodeOptions::default())
  encode_entries(
    [{ image, hot_x: options.hot_x, hot_y: options.hot_y, }],
    options.kind,
    options.sizes,
  )
}

///|
/// Several pictures in one file, at whatever sizes the caller names.
///
/// The sizes are applied to every entry, so a caller handing in a sixteen-pixel
/// picture and a two-hundred-and-fifty-six-pixel one gets both again at every
/// size it asked for rather than a file full of duplicates — a caller that
/// wants exactly what it handed in leaves the list empty.
pub fn encode_entries(
  entries : Array[Entry],
  kind : Kind,
  sizes : Array[Int32],
) -> Bytes {
  let pictures : Array[(Bytes, Int32, Int32, Int32, Int32)] = []
  for entry in entries {
    if sizes.is_empty() {
      pictures.push(
        (
          @png.encode(entry.image),
          entry.image.width,
          entry.image.height,
          entry.hot_x,
          entry.hot_y,
        ),
      )
    } else {
      for size in sizes {
        let scaled = entry.image.scale(size, size) catch { _ => entry.image }
        pictures.push(
          (
            @png.encode(scaled),
            scaled.width,
            scaled.height,
            entry.hot_x,
            entry.hot_y,
          ),
        )
      }
    }
  }
  let writer = @wire.Writer::new()
  writer.u16_le(0)
  writer.u16_le(if kind == Cursor { 2 } else { 1 })
  writer.u16_le(pictures.length())
  let mut offset = 6 + pictures.length() * 16
  for picture in pictures {
    let (body, width, height, hot_x, hot_y) = picture
    writer.u8(if width >= 256 { 0 } else { width })
    writer.u8(if height >= 256 { 0 } else { height })
    writer.u8(0)
    writer.u8(0)
    if kind == Cursor {
      writer.u16_le(hot_x)
      writer.u16_le(hot_y)
    } else {
      writer.u16_le(1)
      writer.u16_le(32)
    }
    writer.u32_le(body.length())
    writer.u32_le(offset)
    offset = offset + body.length()
  }
  for picture in pictures {
    writer.bytes(picture.0)
  }
  writer.to_bytes()
}
