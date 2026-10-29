// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// What the homepage asks of the library, in three calls.
//
// A page cannot hold a `Refused` and cannot see a `PixelFormat`, so everything
// crossing back is either bytes the browser can draw or a JSON string it can
// read. The report is written by hand rather than through a JSON encoder
// because there is one shape and eight fields.

///|
/// The name a pixel layout goes by on the page.
fn layout_name(format : @raster.PixelFormat) -> String {
  match format {
    Gray8 => "grey, 8 bits"
    GrayAlpha8 => "grey and alpha, 8 bits each"
    Rgb8 => "red, green, blue, 8 bits each"
    Rgba8 => "red, green, blue, alpha, 8 bits each"
    Gray16 => "grey, 16 bits"
    GrayAlpha16 => "grey and alpha, 16 bits each"
    Rgb16 => "red, green, blue, 16 bits each"
    Rgba16 => "red, green, blue, alpha, 16 bits each"
    RgbaF32 => "red, green, blue, alpha, 32-bit floats"
  }
}

///|
/// The format with this name, or nothing. The page names the formats it offers
/// to write; anything else is a mistake in the page rather than a file.
fn named(name : String) -> @raster.Format? {
  match name {
    "png" => Some(@raster.Format::Png)
    "qoi" => Some(@raster.Format::Qoi)
    "bmp" => Some(@raster.Format::Bmp)
    "tga" => Some(@raster.Format::Tga)
    "jpeg" => Some(@raster.Format::Jpeg)
    "gif" => Some(@raster.Format::Gif)
    "webp" => Some(@raster.Format::Webp)
    _ => None
  }
}

///|
/// A string as a JSON string: the quote and the backslash escaped, a control
/// character written as an escape rather than as itself.
fn quoted(text : String) -> String {
  let mut out = ""
  for code in text.iter() {
    let value = code.to_int()
    if value == 0x22 {
      out = out + "\\\""
    } else if value == 0x5C {
      out = out + "\\\\"
    } else if value < 0x20 {
      out = out + "\\u00" + digit(value >> 4) + digit(value & 0xF)
    } else {
      out = out + "\{code}"
    }
  }
  out
}

///|
/// One hexadecimal digit, taken from the alphabet itself.
fn digit(value : Int32) -> String {
  "0123456789abcdef"[value:value + 1].to_owned()
}

///|
/// What a file is: the format, the size, the layout the pixels come back in,
/// and how many bytes it took. A file this library will not read says why in
/// one line instead.
fn describe(file : Bytes) -> String {
  try {
    let format = @raster.Format::of(file)
    let image = @moonimage.decode(file)
    "{\"ok\":true,\"format\":\"\{format}\",\"extension\":\"\{format.extension()}\",\"mime\":\"\{format.mime()}\",\"width\":\{image.width},\"height\":\{image.height},\"layout\":\"\{layout_name(image.format)}\",\"bytes\":\{file.length()}}"
  } catch {
    error => "{\"ok\":false,\"error\":\"\{quoted(error.to_string())}\"}"
  }
}

///|
/// The picture as four bytes a pixel, ready for a canvas.
///
/// A canvas does not take any of the eight layouts the library holds, only
/// their common form — red, green, blue, alpha, one byte each — so the
/// conversion happens here rather than in the page.
fn preview(file : Bytes) -> Bytes {
  @moonimage.decode(file).convert(@raster.PixelFormat::Rgba8).pixels catch {
    _ => b""
  }
}

///|
/// The picture written in another format: read the file, then write the pixels.
///
/// Nothing comes back for a format this library does not write, or for a file
/// it cannot read; `describe` has the reason.
fn convert(file : Bytes, format : String) -> Bytes {
  let target = match named(format) {
    Some(value) => value
    None => return b""
  }
  @moonimage.encode(@moonimage.decode(file), target) catch {
    _ => b""
  }
}

///|
fn main {
  publish(describe, preview, convert)
}
