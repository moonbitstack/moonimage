// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing GIF.
//
// The hard part is not the file, it is the palette: 256 colours is not enough for
// a photograph, and choosing which 256 is a small optimisation problem. An image
// that already has few enough colours is stored with those exact colours; one
// that does not goes through median cut — split the colours along their widest
// axis at the median, repeatedly, and average what is in each box — and then,
// optionally, Floyd–Steinberg dithering, which trades a fixed pattern of noise
// for the banding a gradient would otherwise show.
//
// LZW then compresses the indices. The width of a code grows as the dictionary
// fills and resets with a clear code, so the encoder and the decoder have to
// agree on exactly when.

///|
/// The image as a single-frame GIF.
pub fn encode(image : @raster.Image, options? : EncodeOptions) -> Bytes {
  let options = options.unwrap_or(EncodeOptions::default())
  write_animation(image, [], options, 0)
}

///|
/// The animation as an animated GIF.
pub fn encode_animation(
  animation : @raster.Animation,
  options? : EncodeOptions,
) -> Bytes {
  let options = options.unwrap_or(EncodeOptions::default())
  write_animation(
    animation.frames[0].image,
    animation.frames,
    options,
    animation.loops,
  )
}

///|
/// One canvas, and the frames that follow it if this is an animation.
fn write_animation(
  canvas : @raster.Image,
  frames : Array[@raster.Frame],
  options : EncodeOptions,
  loops : Int32,
) -> Bytes {
  let first = prepare(canvas, options, 100)
  let writer = @wire.Writer::new()
  writer.bytes(b"GIF89a")
  writer.u16_le(canvas.width)
  writer.u16_le(canvas.height)
  let global_bits = palette_bits(first.palette.length())
  writer.u8(0x80 | ((global_bits - 1) << 4) | (global_bits - 1))
  writer.u8(0)
  writer.u8(0)
  write_palette(writer, first.palette, global_bits)
  if !frames.is_empty() {
    // The looping extension: eleven bytes of application name, then a sub-block
    // that says how many times to go round. Zero means forever.
    writer.u8(0x21)
    writer.u8(0xFF)
    writer.u8(11)
    writer.bytes(b"NETSCAPE2.0")
    writer.u8(3)
    writer.u8(1)
    writer.u16_le(loops)
    writer.u8(0)
  }
  write_frame(writer, first, canvas.width, canvas.height, 0, 0, 0, true)
  if !frames.is_empty() {
    for index in 1..<frames.length() {
      let frame = frames[index]
      let prepared = prepare(frame.image, options, frame.delay)
      write_frame(
        writer,
        prepared,
        frame.image.width,
        frame.image.height,
        frame.x,
        frame.y,
        disposal_of(frame.dispose),
        false,
      )
    }
  }
  writer.u8(0x3B)
  writer.to_bytes()
}

///|
fn disposal_of(dispose : @raster.Dispose) -> Int32 {
  match dispose {
    @raster.Dispose::Keep => 1
    @raster.Dispose::Background => 2
    @raster.Dispose::Previous => 3
  }
}

///|
/// One frame: its control extension, its rectangle, its palette and its indices.
fn write_frame(
  writer : @wire.Writer,
  prepared : Prepared,
  width : Int32,
  height : Int32,
  x : Int32,
  y : Int32,
  disposal : Int32,
  use_global : Bool,
) -> Unit {
  let transparent = match prepared.transparent {
    Some(_) => 1
    None => 0
  }
  writer.u8(0x21)
  writer.u8(0xF9)
  writer.u8(4)
  writer.u8((disposal << 2) | transparent)
  writer.u16_le(prepared.delay / 10)
  writer.u8(
    match prepared.transparent {
      Some(index) => index
      None => 0
    },
  )
  writer.u8(0)
  writer.u8(0x2C)
  writer.u16_le(x)
  writer.u16_le(y)
  writer.u16_le(width)
  writer.u16_le(height)
  if use_global {
    writer.u8(0)
  } else {
    let bits = palette_bits(prepared.palette.length())
    writer.u8(0x80 | (bits - 1))
    write_palette(writer, prepared.palette, bits)
  }
  let bits = palette_bits(prepared.palette.length())
  let minimum = if bits < 2 { 2 } else { bits }
  writer.u8(minimum)
  for chunk in compress(prepared.indices, minimum) {
    writer.u8(chunk.length())
    writer.bytes(chunk)
  }
  writer.u8(0)
}

///|
fn write_palette(
  writer : @wire.Writer,
  palette : Array[(Int32, Int32, Int32)],
  bits : Int32,
) -> Unit {
  let entries = 1 << bits
  for index in 0..<entries {
    if index < palette.length() {
      let (red, green, blue) = palette[index]
      writer.u8(red)
      writer.u8(green)
      writer.u8(blue)
    } else {
      writer.u8(0)
      writer.u8(0)
      writer.u8(0)
    }
  }
}

///|
/// How many bits a table of this many entries needs, at least one.
fn palette_bits(count : Int32) -> Int32 {
  let mut bits = 1
  while 1 << bits < count && bits < 8 {
    bits = bits + 1
  }
  bits
}

///|
/// One image ready to be written: its palette, the index of every pixel, and
/// whether one of those indices means transparent.
priv struct Prepared {
  palette : Array[(Int32, Int32, Int32)]
  indices : Array[Int32]
  transparent : Int32?
  delay : Int32
}

///|
/// Turn an image into indices, choosing a palette if it has too many colours.
fn prepare(
  image : @raster.Image,
  options : EncodeOptions,
  delay : Int32,
) -> Prepared {
  let source = image.convert(@raster.PixelFormat::Rgba8)
  let width = source.width
  let height = source.height
  let colours = @hashmap.HashMap::HashMap([], capacity=16)
  let mut transparent_pixels = 0
  for index in 0..<(width * height) {
    let at = index * 4
    let alpha = source.pixels[at + 3].to_int()
    if options.transparent && alpha < 128 {
      transparent_pixels = transparent_pixels + 1
    } else {
      let packed = (source.pixels[at].to_int() << 16) |
        (source.pixels[at + 1].to_int() << 8) |
        source.pixels[at + 2].to_int()
      colours.set(packed, colours.get_or_default(packed, 0) + 1)
    }
  }
  let keys : Array[Int32] = []
  colours.each(fn(key, _) { keys.push(key) })
  keys.sort()
  let any_transparent = transparent_pixels > 0
  let limit = if any_transparent { 255 } else { 256 }
  let chosen = if keys.length() <= limit {
    let exact : Array[(Int32, Int32, Int32)] = []
    for key in keys {
      exact.push(((key >> 16) & 0xFF, (key >> 8) & 0xFF, key & 0xFF))
    }
    exact
  } else {
    quantise(keys, colours, limit)
  }
  let palette : Array[(Int32, Int32, Int32)] = []
  if any_transparent {
    palette.push((0, 0, 0))
  }
  for colour in chosen {
    palette.push(colour)
  }
  let offset = if any_transparent { 1 } else { 0 }
  let indices = map_pixels(source, palette, offset, options.dither)
  {
    palette,
    indices,
    transparent: if any_transparent {
      Some(0)
    } else {
      None
    },
    delay,
  }
}

///|
/// Every pixel as an index, with the error of each choice pushed into the pixels
/// that come after it when dithering is on.
fn map_pixels(
  source : @raster.Image,
  palette : Array[(Int32, Int32, Int32)],
  offset : Int32,
  dither : Bool,
) -> Array[Int32] {
  let width = source.width
  let height = source.height
  let indices : Array[Int32] = []
  if !dither {
    for index in 0..<(width * height) {
      let at = index * 4
      if palette.length() == 0 || source.pixels[at + 3].to_int() < 128 {
        indices.push(0)
      } else {
        indices.push(
          nearest(
            palette,
            source.pixels[at].to_int(),
            source.pixels[at + 1].to_int(),
            source.pixels[at + 2].to_int(),
            offset,
          ),
        )
      }
    }
    return indices
  }
  let mut current : Array[Double] = Array::make(width * 3 + 6, 0.0)
  let mut next : Array[Double] = Array::make(width * 3 + 6, 0.0)
  for y in 0..<height {
    for index in 0..<next.length() {
      next[index] = 0.0
    }
    for x in 0..<width {
      let at = (y * width + x) * 4
      let alpha = source.pixels[at + 3].to_int()
      if alpha < 128 && offset > 0 {
        indices.push(0)
        continue
      }
      let red = clamp_double(
        source.pixels[at].to_int().to_double() + current[x * 3 + 3],
      )
      let green = clamp_double(
        source.pixels[at + 1].to_int().to_double() + current[x * 3 + 4],
      )
      let blue = clamp_double(
        source.pixels[at + 2].to_int().to_double() + current[x * 3 + 5],
      )
      let chosen = nearest(
        palette,
        red.to_int(),
        green.to_int(),
        blue.to_int(),
        offset,
      )
      indices.push(chosen)
      let (pr, pg, pb) = palette[chosen]
      let er = red - pr.to_double()
      let eg = green - pg.to_double()
      let eb = blue - pb.to_double()
      spread_error(current, next, x, 3, er, eg, eb)
    }
    let swap = current
    current = next
    next = swap
  }
  indices
}

///|
fn clamp_double(value : Double) -> Double {
  if value < 0.0 {
    0.0
  } else if value > 255.0 {
    255.0
  } else {
    value
  }
}

///|
/// Floyd–Steinberg: seven sixteenths to the right, three to the lower left, five
/// below and one to the lower right.
fn spread_error(
  current : Array[Double],
  next : Array[Double],
  x : Int32,
  stride : Int32,
  red : Double,
  green : Double,
  blue : Double,
) -> Unit {
  let channels = [red, green, blue]
  for channel in 0..<3 {
    let error = channels[channel]
    let base = x * stride + channel
    current[base + stride] = current[base + stride] + error * 7.0 / 16.0
    next[base + stride - 3] = next[base + stride - 3] + error * 3.0 / 16.0
    next[base + stride] = next[base + stride] + error * 5.0 / 16.0
    next[base + stride + 3] = next[base + stride + 3] + error * 1.0 / 16.0
  }
}

///|
/// The palette entry closest to a colour, in squared distance. Linear search: the
/// table is at most 256 entries and the alternative is a k-d tree for a problem
/// that is not worth it.
fn nearest(
  palette : Array[(Int32, Int32, Int32)],
  red : Int32,
  green : Int32,
  blue : Int32,
  offset : Int32,
) -> Int32 {
  let mut best = offset
  let mut best_distance = -1
  let mut index = offset
  while index < palette.length() {
    let (r, g, b) = palette[index]
    let dr = r - red
    let dg = g - green
    let db = b - blue
    let distance = dr * dr + dg * dg + db * db
    if best_distance < 0 || distance < best_distance {
      best = index
      best_distance = distance
    }
    index = index + 1
  }
  best
}

///|
/// Median cut: split the colours along their widest axis at the median, again and
/// again, until there are as many boxes as entries, and average what is in each.
fn quantise(
  keys : Array[Int32],
  counts : @hashmap.HashMap[Int32, Int32],
  limit : Int32,
) -> Array[(Int32, Int32, Int32)] {
  let boxes : Array[(Int32, Int32)] = [(0, keys.length())]
  while boxes.length() < limit {
    let mut widest = -1
    let mut widest_range = 0
    for index in 0..<boxes.length() {
      let (start, end) = boxes[index]
      if end - start < 2 {
        continue
      }
      let range = axis_range(keys, start, end)
      if range > widest_range {
        widest_range = range
        widest = index
      }
    }
    if widest < 0 {
      break
    }
    let (start, end) = boxes[widest]
    let channel = widest_channel(keys, start, end)
    sort_slice(keys, start, end, channel)
    let middle = start + (end - start) / 2
    boxes[widest] = (start, middle)
    boxes.push((middle, end))
  }
  let palette : Array[(Int32, Int32, Int32)] = []
  for box in boxes {
    let (start, end) = box
    let mut red = 0
    let mut green = 0
    let mut blue = 0
    let mut weight = 0
    for index in start..<end {
      let key = keys[index]
      let count = counts.get_or_default(key, 1)
      red = red + ((key >> 16) & 0xFF) * count
      green = green + ((key >> 8) & 0xFF) * count
      blue = blue + (key & 0xFF) * count
      weight = weight + count
    }
    if weight == 0 {
      palette.push((0, 0, 0))
    } else {
      palette.push((red / weight, green / weight, blue / weight))
    }
  }
  palette
}

///|
fn channel_of(key : Int32, channel : Int32) -> Int32 {
  match channel {
    0 => (key >> 16) & 0xFF
    1 => (key >> 8) & 0xFF
    _ => key & 0xFF
  }
}

///|
fn widest_channel(keys : Array[Int32], start : Int32, end : Int32) -> Int32 {
  let mut widest = 0
  let mut widest_range = -1
  for channel in 0..<3 {
    let mut low = 255
    let mut high = 0
    for index in start..<end {
      let value = channel_of(keys[index], channel)
      if value < low {
        low = value
      }
      if value > high {
        high = value
      }
    }
    if high - low > widest_range {
      widest_range = high - low
      widest = channel
    }
  }
  widest
}

///|
fn axis_range(keys : Array[Int32], start : Int32, end : Int32) -> Int32 {
  let channel = widest_channel(keys, start, end)
  let mut low = 255
  let mut high = 0
  for index in start..<end {
    let value = channel_of(keys[index], channel)
    if value < low {
      low = value
    }
    if value > high {
      high = value
    }
  }
  high - low
}

///|
/// Sort part of an array by one channel, by copying it out and back: the sort
/// functions want a whole array.
fn sort_slice(
  keys : Array[Int32],
  start : Int32,
  end : Int32,
  channel : Int32,
) -> Unit {
  let slice : Array[Int32] = []
  for index in start..<end {
    slice.push(keys[index])
  }
  slice.sort_by(fn(a, b) { channel_of(a, channel) - channel_of(b, channel) })
  for index in 0..<slice.length() {
    keys[start + index] = slice[index]
  }
}

///|
/// LZW, as GIF speaks it: a dictionary of strings, codes of a width that grows as
/// it fills, and a clear code when it is full.
fn compress(indices : Array[Int32], minimum : Int32) -> Array[Bytes] {
  let clear = 1 << minimum
  let end = clear + 1
  let writer = BitWriter::new()
  let keys : FixedArray[Int32] = FixedArray::make(8192, -1)
  let values : FixedArray[Int32] = FixedArray::make(8192, 0)
  let mut width = minimum + 1
  let mut next = end + 1
  writer.write(clear, width)
  if indices.is_empty() {
    writer.write(end, width)
    return writer.to_chunks()
  }
  let mut prefix = indices[0]
  for position in 1..<indices.length() {
    let suffix = indices[position]
    let key = prefix * 256 + suffix
    let slot = find_slot(keys, key)
    if keys[slot] == key {
      prefix = values[slot]
    } else {
      writer.write(prefix, width)
      if next < 4096 {
        keys[slot] = key
        values[slot] = next
        next = next + 1
        if next > 1 << width && width < 12 {
          width = width + 1
        }
      } else {
        writer.write(clear, width)
        for index in 0..<8192 {
          keys[index] = -1
        }
        width = minimum + 1
        next = end + 1
      }
      prefix = suffix
    }
  }
  writer.write(prefix, width)
  writer.write(end, width)
  writer.to_chunks()
}

///|
fn find_slot(keys : FixedArray[Int32], key : Int32) -> Int32 {
  let mut slot = (key * 40_503) & 8191
  while keys[slot] != -1 && keys[slot] != key {
    slot = (slot + 1) & 8191
  }
  slot
}

///|
/// Codes packed least significant bit first, cut into the sub-blocks a GIF uses.
priv struct BitWriter {
  buffer : @buffer.Buffer
  mut bits : Int32
  mut count : Int32
}

///|
fn BitWriter::new() -> BitWriter {
  { buffer: @buffer.Buffer::Buffer(), bits: 0, count: 0, }
}

///|
fn BitWriter::write(self : BitWriter, value : Int32, width : Int32) -> Unit {
  self.bits = self.bits | (value << self.count)
  self.count = self.count + width
  while self.count >= 8 {
    self.buffer.write_byte((self.bits & 0xFF).to_byte())
    self.bits = self.bits >> 8
    self.count = self.count - 8
  }
}

///|
fn BitWriter::to_chunks(self : BitWriter) -> Array[Bytes] {
  if self.count > 0 {
    self.buffer.write_byte((self.bits & 0xFF).to_byte())
    self.bits = 0
    self.count = 0
  }
  let data = self.buffer.to_bytes()
  let chunks : Array[Bytes] = []
  let mut offset = 0
  while offset < data.length() {
    let take = if offset + 255 > data.length() {
      data.length() - offset
    } else {
      255
    }
    chunks.push(data.clamped_view(start=offset, end=offset + take).to_owned())
    offset = offset + take
  }
  chunks
}
