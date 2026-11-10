// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The command the conformance scripts drive: write the canonical picture in one
// format, or read a file and lay its pixels out for something else to read.
//
// It exists so that another implementation — Pillow, or the Rust `image` crate —
// can be held against this one on real files, which a test cannot do: a test
// runs on four backends and three of them have no file system.
//
//   moon run src/tools/samples -- write png out.png
//   moon run src/tools/samples -- decode out.png pixels.rgba
//   moon run src/tools/samples -- decode32 out.exr floats.bin
//
// `write` always draws the same picture, so a caller knows what the pixels
// should be without reading anything back.

///|
fn main {
  let arguments = @env.args()
  if arguments.length() < 4 {
    println(usage())
    return
  }
  let outcome = match arguments[1] {
    "write" => write(arguments[2], arguments[3])
    "decode" => decode(arguments[2], arguments[3], false)
    "decode32" => decode(arguments[2], arguments[3], true)
    "decode16" => decode(arguments[2], arguments[3], false, sixteen=true)
    _ => Err("no such command: \{arguments[1]}")
  }
  match outcome {
    Ok(message) => println(message)
    Err(message) => {
      println("error: \{message}")
      abort(message)
    }
  }
}

///|
fn usage() -> String {
  "usage: samples write <format> <path>\n" +
  "       samples decode <path> <out>\n" +
  "       samples decode32 <path> <out>\n" +
  "       samples decode16 <path> <out>\n" +
  "formats: " +
  formats().map(fn(one) { one.0 }).join(", ")
}

///|
/// The picture every comparison is made on: a gradient that changes in every
/// direction, a hard edge from the modulo, and an alpha that is never zero, so
/// that a format which drops it is caught rather than read as transparent.
fn picture() -> @moonimage.Image {
  let width = 37
  let height = 23
  let out : FixedArray[Byte] = FixedArray::make(width * height * 4, b'\xFF')
  for y in 0..<height {
    for x in 0..<width {
      let at = (y * width + x) * 4
      out[at] = ((x * 7 + y * 3) & 255).to_byte()
      out[at + 1] = ((x * 5 + y * 11) & 255).to_byte()
      out[at + 2] = ((x * 3 + y * 13) & 255).to_byte()
      out[at + 3] = (255 - (x * 3 + y * 5) % 64).to_byte()
    }
  }
  @moonimage.Image::of(
    width,
    height,
    @moonimage.PixelFormat::Rgba8,
    Bytes::from_array(out.clamped_view()),
  ) catch {
    error => abort("\{error}")
  }
}

///|
/// The formats this command writes, and the names the scripts use for them.
fn formats() -> Array[(String, @moonimage.Format)] {
  [
    ("png", @moonimage.Format::Png),
    ("qoi", @moonimage.Format::Qoi),
    ("bmp", @moonimage.Format::Bmp),
    ("tga", @moonimage.Format::Tga),
    ("jpeg", @moonimage.Format::Jpeg),
    ("gif", @moonimage.Format::Gif),
    ("webp", @moonimage.Format::Webp),
    ("tiff", @moonimage.Format::Tiff),
    ("ico", @moonimage.Format::Ico),
    ("pnm", @moonimage.Format::Pnm),
    ("hdr", @moonimage.Format::Hdr),
    ("exr", @moonimage.Format::Exr),
  ]
}

///|
/// The format a script's name stands for.
fn name_of(format : String) -> @moonimage.Format? {
  for entry in formats() {
    if entry.0 == format {
      return Some(entry.1)
    }
  }
  None
}

///|
fn write(format : String, path : String) -> Result[String, String] {
  let image = picture()
  let bytes = if format == "farbfeld" {
    @farbfeld.encode(image)
  } else if format == "pnm" {
    // PPM rather than the PAM a picture with alpha would otherwise get, because
    // PAM is the one shape of the four that other readers do not all know.
    @pnm.encode(image, options=@pnm.EncodeOptions::{
      kind: @pnm.Kind::Rgb,
      maxval: 0,
      ascii: false,
    })
  } else if format == "exr-piz" {
    @exr.encode(image, options=@exr.EncodeOptions::{
      compression: @exr.Compression::Piz,
      half: true,
    })
  } else if format == "exr-piz-float" {
    @exr.encode(image, options=@exr.EncodeOptions::{
      compression: @exr.Compression::Piz,
      half: false,
    })
  } else if format == "exr-pxr24" {
    @exr.encode(image, options=@exr.EncodeOptions::{
      compression: @exr.Compression::Pxr24,
      half: false,
    })
  } else if format == "exr-rle" {
    @exr.encode(image, options=@exr.EncodeOptions::{
      compression: @exr.Compression::Rle,
      half: true,
    })
  } else {
    let named = match name_of(format) {
      Some(found) => found
      None => return Err("no such format: \{format}")
    }
    @moonimage.encode(image, named) catch {
      error => return Err("\{format}: \{error}")
    }
  }
  @fs.write_bytes_to_file(path, bytes) catch {
    error => return Err("writing \{path}: \{@debug.Debug::to_repr(error)}")
  }
  Ok("\{format} \{image.width}x\{image.height} \{bytes.length()} bytes")
}

///|
fn decode(
  path : String,
  out : String,
  floats : Bool,
  sixteen~ : Bool = false,
) -> Result[String, String] {
  let bytes = @fs.read_file_to_bytes(path) catch {
    error => return Err("reading \{path}: \{@debug.Debug::to_repr(error)}")
  }
  let image = @moonimage.decode(bytes) catch {
    error => return Err("\{path}: \{error}")
  }
  let pixels = if floats {
    image.convert(@moonimage.PixelFormat::RgbaF32).pixels
  } else if sixteen {
    image.convert(@moonimage.PixelFormat::Rgba16).pixels
  } else {
    image.convert(@moonimage.PixelFormat::Rgba8).pixels
  }
  @fs.write_bytes_to_file(out, pixels) catch {
    error => return Err("writing \{out}: \{@debug.Debug::to_repr(error)}")
  }
  Ok("\{image.width} \{image.height} \{image.format}")
}
