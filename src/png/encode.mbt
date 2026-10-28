// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing PNG.
//
// Two decisions decide how large the file is: which filter each row uses, and
// how hard deflate works. The filter is the one that matters more for a picture
// and the one a writer is free to choose per row, so the default tries all five
// and keeps whichever leaves the smallest sum of absolute differences — the
// heuristic the specification itself suggests, which is close enough to optimal
// that the extra passes over the row pay for themselves.
//
// The colour type follows the image's pixel format rather than a choice: a grey
// image is written grey, an image with alpha is written with alpha, and sixteen
// bits stay sixteen bits.

///|
/// The image as a PNG.
pub fn encode(image : @raster.Image, options? : EncodeOptions) -> Bytes {
  let options = options.unwrap_or(EncodeOptions::default())
  encode_frames(image, [], options, 0)
}

///|
/// The animation as an APNG.
pub fn encode_animation(
  animation : @raster.Animation,
  options? : EncodeOptions,
) -> Bytes {
  let options = options.unwrap_or(EncodeOptions::default())
  encode_frames(
    animation.frames[0].image,
    animation.frames,
    options,
    animation.loops,
  )
}

///|
/// One image, and the frames that follow it if the file is an animation.
fn encode_frames(
  image : @raster.Image,
  frames : Array[@raster.Frame],
  options : EncodeOptions,
  plays : Int32,
) -> Bytes {
  let source = if image.format == @raster.PixelFormat::RgbaF32 {
    image.convert(@raster.PixelFormat::Rgba16)
  } else {
    image
  }
  let (color, depth) = layout_of(source.format)
  let writer = @wire.Writer::new()
  writer.bytes(signature)
  let header = @wire.Writer::new()
  header.u32_be(source.width)
  header.u32_be(source.height)
  header.u8(depth)
  header.u8(color)
  header.u8(0)
  header.u8(0)
  header.u8(if options.interlace { 1 } else { 0 })
  write_chunk(writer, "IHDR", header.to_bytes())
  if options.metadata {
    write_metadata(writer, source.metadata)
  }
  if !frames.is_empty() {
    let animation = @wire.Writer::new()
    animation.u32_be(frames.length())
    animation.u32_be(plays)
    write_chunk(writer, "acTL", animation.to_bytes())
  }
  // Frame zero: a frame control chunk with sequence number zero, then the image
  // data itself, which is what a PNG reader that knows nothing about animation
  // will show.
  let mut sequence = 0
  if !frames.is_empty() {
    let first = frames[0]
    write_chunk(
      writer,
      "fcTL",
      frame_control(sequence, first, source.width, source.height),
    )
    sequence = sequence + 1
  }
  write_image_data(writer, source, color, depth, options)
  if !frames.is_empty() {
    for index in 1..<frames.length() {
      let frame = frames[index]
      let picture = if frame.image.format == source.format {
        frame.image
      } else {
        frame.image.convert(source.format)
      }
      write_chunk(
        writer,
        "fcTL",
        frame_control(sequence, frame, picture.width, picture.height),
      )
      sequence = sequence + 1
      let _ = (color, depth)
      let data = image_bytes(picture, options)
      // fdAT carries the same bytes as IDAT with a sequence number in front, so
      // the compressor's output is split across chunks of a readable size.
      let mut offset = 0
      while offset < data.length() {
        let take = if offset + 8_000 > data.length() {
          data.length() - offset
        } else {
          8_000
        }
        let chunk = @wire.Writer::new()
        chunk.u32_be(sequence)
        chunk.bytes(data.clamped_view(start=offset, end=offset + take))
        write_chunk(writer, "fdAT", chunk.to_bytes())
        sequence = sequence + 1
        offset = offset + take
      }
    }
  }
  write_chunk(writer, "IEND", Bytes::new(0))
  writer.to_bytes()
}

///|
/// The colour type and bit depth a pixel format is written as.
fn layout_of(format : @raster.PixelFormat) -> (Int32, Int32) {
  match format {
    @raster.PixelFormat::Gray8 => (0, 8)
    @raster.PixelFormat::GrayAlpha8 => (4, 8)
    @raster.PixelFormat::Rgb8 => (2, 8)
    @raster.PixelFormat::Rgba8 => (6, 8)
    @raster.PixelFormat::Gray16 => (0, 16)
    @raster.PixelFormat::GrayAlpha16 => (4, 16)
    @raster.PixelFormat::Rgb16 => (2, 16)
    @raster.PixelFormat::Rgba16 => (6, 16)
    @raster.PixelFormat::RgbaF32 => (6, 16)
  }
}

///|
/// The image data: the compressed, filtered scanlines, split across as many IDAT
/// chunks as it takes to keep each one a size a decoder likes.
fn write_image_data(
  writer : @wire.Writer,
  image : @raster.Image,
  color : Int32,
  depth : Int32,
  options : EncodeOptions,
) -> Unit {
  let _ = (color, depth)
  let data = image_bytes(image, options)
  let mut offset = 0
  while offset < data.length() {
    let take = if offset + 8_000 > data.length() {
      data.length() - offset
    } else {
      8_000
    }
    write_chunk(
      writer,
      "IDAT",
      data.clamped_view(start=offset, end=offset + take),
    )
    offset = offset + take
  }
}

///|
/// Filter and compress the image. Interlacing, when asked for, turns the image
/// into seven smaller ones and compresses their rows in order.
fn image_bytes(image : @raster.Image, options : EncodeOptions) -> Bytes {
  let channels = channels_of(colour_type_of(image.format))
  let bits = channels * depth_of(image.format)
  let bytes_per_pixel = if bits < 8 { 1 } else { bits / 8 }
  let raw = @buffer.Buffer::Buffer()
  if options.interlace {
    for pass in 0..<7 {
      let (x0, y0, dx, dy) = pass_of(pass)
      let width = pass_size(image.width, x0, dx)
      let height = pass_size(image.height, y0, dy)
      if width == 0 || height == 0 {
        continue
      }
      filter_pass(
        raw,
        image,
        width,
        height,
        x0,
        y0,
        dx,
        dy,
        bytes_per_pixel,
        options.filter,
      )
    }
  } else {
    filter_pass(
      raw,
      image,
      image.width,
      image.height,
      0,
      0,
      1,
      1,
      bytes_per_pixel,
      options.filter,
    )
  }
  @zlib.zlib(raw.to_bytes(), level=options.level)
}

///|
fn depth_of(format : @raster.PixelFormat) -> Int32 {
  match format {
    @raster.PixelFormat::Gray16
    | @raster.PixelFormat::GrayAlpha16
    | @raster.PixelFormat::Rgb16
    | @raster.PixelFormat::Rgba16 => 16
    _ => 8
  }
}

///|
fn colour_type_of(format : @raster.PixelFormat) -> Int32 {
  let (color, _) = layout_of(format)
  color
}

///|
/// Filter one pass: gather its sub-image rows, filter each against the one
/// before, and append them.
fn filter_pass(
  raw : @buffer.Buffer,
  image : @raster.Image,
  width : Int32,
  height : Int32,
  x0 : Int32,
  y0 : Int32,
  dx : Int32,
  dy : Int32,
  bytes_per_pixel : Int32,
  filter : Filter,
) -> Unit {
  let pixel = image.format.bytes()
  let row_bytes = width * pixel
  let mut previous = Bytes::new(row_bytes)
  for row in 0..<height {
    let current = FixedArray::make(row_bytes, b'\x00')
    let source_row = (y0 + row * dy) * image.stride
    for column in 0..<width {
      let from = source_row + (x0 + column * dx) * pixel
      for k in 0..<pixel {
        current[column * pixel + k] = image.pixels[from + k]
      }
    }
    let line = Bytes::from_array(current.clamped_view())
    let (kind, filtered) = choose_filter(
      line, previous, bytes_per_pixel, filter,
    )
    raw.write_byte(kind.to_byte())
    raw.write_bytesview(filtered)
    previous = line
  }
}

///|
/// The filter to use for a row, and the row as it comes out.
fn choose_filter(
  row : Bytes,
  previous : Bytes,
  bytes_per_pixel : Int32,
  filter : Filter,
) -> (Int32, Bytes) {
  match filter {
    Filter::Adaptive => {
      let mut best = 0
      let mut best_score = -1
      let mut best_bytes = Bytes::new(0)
      for candidate in 0..<5 {
        let filtered = apply_filter(candidate, row, previous, bytes_per_pixel)
        let score = score_of(filtered)
        if best_score < 0 || score < best_score {
          best = candidate
          best_score = score
          best_bytes = filtered
        }
      }
      (best, best_bytes)
    }
    Filter::None => (0, apply_filter(0, row, previous, bytes_per_pixel))
    Filter::Sub => (1, apply_filter(1, row, previous, bytes_per_pixel))
    Filter::Up => (2, apply_filter(2, row, previous, bytes_per_pixel))
    Filter::Average => (3, apply_filter(3, row, previous, bytes_per_pixel))
    Filter::Paeth => (4, apply_filter(4, row, previous, bytes_per_pixel))
  }
}

///|
/// One of the five filters, applied to a row.
fn apply_filter(
  kind : Int32,
  row : Bytes,
  previous : Bytes,
  bytes_per_pixel : Int32,
) -> Bytes {
  let out = FixedArray::make(row.length(), b'\x00')
  for index in 0..<row.length() {
    let value = row[index].to_int()
    let left = if index >= bytes_per_pixel {
      row[index - bytes_per_pixel].to_int()
    } else {
      0
    }
    let up = if previous.length() > index {
      previous[index].to_int()
    } else {
      0
    }
    let corner = if index >= bytes_per_pixel &&
      previous.length() > index - bytes_per_pixel {
      previous[index - bytes_per_pixel].to_int()
    } else {
      0
    }
    let filtered = match kind {
      0 => value
      1 => value - left
      2 => value - up
      3 => value - (left + up) / 2
      _ => value - paeth(left, up, corner)
    }
    out[index] = (filtered & 0xFF).to_byte()
  }
  Bytes::from_array(out.clamped_view())
}

///|
/// How well a filtered row compresses, as far as can be told without compressing
/// it: the sum of the absolute values, read as signed bytes.
fn score_of(row : Bytes) -> Int32 {
  let mut total = 0
  for index in 0..<row.length() {
    let value = row[index].to_int()
    total = total + (if value < 128 { value } else { 256 - value })
  }
  total
}

///|
/// A chunk: its length, its type, its data, and the CRC over type and data.
fn write_chunk(writer : @wire.Writer, kind : String, data : BytesView) -> Unit {
  writer.u32_be(data.length())
  let kind_bytes = @buffer.Buffer::Buffer()
  for character in kind {
    kind_bytes.write_byte((character.to_int() & 0xFF).to_byte())
  }
  let tag = kind_bytes.to_bytes()
  writer.bytes(tag)
  writer.bytes(data)
  let mut crc = 0xFFFF_FFFFU
  for index in 0..<4 {
    crc = crc_step(crc, tag[index].to_int())
  }
  for index in 0..<data.length() {
    crc = crc_step(crc, data[index].to_int())
  }
  writer.u32_be((crc ^ 0xFFFF_FFFFU).reinterpret_as_int())
}

///|
/// A frame's control chunk: where it goes, how long it stays, and what to do with
/// the rectangle afterwards.
fn frame_control(
  sequence : Int32,
  frame : @raster.Frame,
  width : Int32,
  height : Int32,
) -> Bytes {
  let chunk = @wire.Writer::new()
  chunk.u32_be(sequence)
  chunk.u32_be(width)
  chunk.u32_be(height)
  chunk.u32_be(frame.x)
  chunk.u32_be(frame.y)
  // Milliseconds over a thousand: exact for any delay a file can hold, and what
  // every writer that does not care about the old hundredths writes.
  chunk.u16_be(if frame.delay > 65_535 { 65_535 } else { frame.delay })
  chunk.u16_be(1000)
  chunk.u8(
    match frame.dispose {
      @raster.Dispose::Keep => 0
      @raster.Dispose::Background => 1
      @raster.Dispose::Previous => 2
    },
  )
  chunk.u8(if frame.blend == @raster.Blend::Source { 0 } else { 1 })
  chunk.to_bytes()
}

///|
/// The chunks that carry what the file says about itself.
fn write_metadata(writer : @wire.Writer, metadata : @raster.Metadata) -> Unit {
  match metadata.gamma {
    Some(gamma) => {
      let chunk = @wire.Writer::new()
      chunk.u32_be((gamma * 100_000.0 + 0.5).to_int())
      write_chunk(writer, "gAMA", chunk.to_bytes())
    }
    None => ()
  }
  match metadata.chromaticities {
    Some(colour) => {
      let chunk = @wire.Writer::new()
      for
        value in [
          colour.white_x,
          colour.white_y,
          colour.red_x,
          colour.red_y,
          colour.green_x,
          colour.green_y,
          colour.blue_x,
          colour.blue_y,
        ] {
        chunk.u32_be((value * 100_000.0 + 0.5).to_int())
      }
      write_chunk(writer, "cHRM", chunk.to_bytes())
    }
    None => ()
  }
  match metadata.intent {
    Some(intent) => {
      let chunk = @wire.Writer::new()
      chunk.u8(intent.code())
      write_chunk(writer, "sRGB", chunk.to_bytes())
    }
    None => ()
  }
  match metadata.icc {
    Some(icc) => {
      let chunk = @wire.Writer::new()
      chunk.bytes(to_latin1(icc.name))
      chunk.u8(0)
      chunk.u8(0)
      chunk.bytes(@zlib.zlib(icc.profile))
      write_chunk(writer, "iCCP", chunk.to_bytes())
    }
    None => ()
  }
  for text in metadata.texts {
    match text {
      @raster.Text::Latin(keyword~, text~) => {
        let chunk = @wire.Writer::new()
        chunk.bytes(to_latin1(keyword))
        chunk.u8(0)
        chunk.bytes(to_latin1(text))
        write_chunk(writer, "tEXt", chunk.to_bytes())
      }
      @raster.Text::Compressed(keyword~, text~) => {
        let chunk = @wire.Writer::new()
        chunk.bytes(to_latin1(keyword))
        chunk.u8(0)
        chunk.u8(0)
        chunk.bytes(@zlib.zlib(to_latin1(text)))
        write_chunk(writer, "zTXt", chunk.to_bytes())
      }
      @raster.Text::International(keyword~, language~, translated~, text~) => {
        let chunk = @wire.Writer::new()
        chunk.bytes(to_latin1(keyword))
        chunk.u8(0)
        chunk.u8(0)
        chunk.u8(0)
        chunk.bytes(to_latin1(language))
        chunk.u8(0)
        chunk.bytes(to_utf8(translated))
        chunk.u8(0)
        chunk.bytes(to_utf8(text))
        write_chunk(writer, "iTXt", chunk.to_bytes())
      }
    }
  }
}

///|
/// A string as Latin-1. A character outside it becomes a question mark, which is
/// what a `tEXt` chunk has room for; a caller with more to say writes an `iTXt`.
fn to_latin1(text : String) -> Bytes {
  let builder = @buffer.Buffer::Buffer()
  for character in text {
    let code = character.to_int()
    builder.write_byte((if code > 0xFF { 0x3F } else { code }).to_byte())
  }
  builder.to_bytes()
}

///|
/// A string as UTF-8, which is what an `iTXt` chunk carries.
fn to_utf8(text : String) -> Bytes {
  @utf8.encode(text)
}
