// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Frames, and how each one replaces the one before.
//
// Three formats animate, and they agree on the shape even where they disagree on
// the arithmetic: a canvas, a rectangle per frame, a delay, a rule for what to
// do with the pixels underneath, and a rule for what to leave behind when the
// frame is over. APNG, GIF and WebP each spell those two rules differently but
// mean the same four cases.
//
// A frame keeps its own rectangle rather than a full canvas, because that is
// what the file holds and because a sixty-frame animation of a small moving
// sprite stores sixty small rectangles rather than sixty canvases. `compose`
// turns them into the full pictures a viewer shows.

///|
/// What to do with the frame's rectangle once the frame has been shown.
pub(all) enum Dispose {
  /// Leave it: the next frame draws over it.
  Keep
  /// Clear it to transparent black.
  Background
  /// Put back whatever was under it before it was drawn.
  Previous
} derive(Eq, Debug)

///|
pub extend Dispose with Eq::{equal, not_equal}

///|
pub extend Dispose with Debug::{to_repr}

///|
/// How a frame's pixels meet what is already on the canvas.
pub(all) enum Blend {
  /// Replace, alpha and all.
  Source
  /// Composite, the usual `over`.
  Over
} derive(Eq, Debug)

///|
pub extend Blend with Eq::{equal, not_equal}

///|
pub extend Blend with Debug::{to_repr}

///|
/// One frame: a picture, where it goes, and how long it stays.
pub(all) struct Frame {
  /// The pixels of this frame, already in a pixel format.
  image : Image
  /// Where the frame's top-left corner sits on the canvas.
  x : Int32
  /// Where the frame's top-left corner sits on the canvas.
  y : Int32
  /// How long the frame is shown, in milliseconds.
  delay : Int32
  /// What to do with the rectangle afterwards.
  dispose : Dispose
  /// How to lay the frame over what is there.
  blend : Blend
}

///|
/// A frame that covers the canvas, shown for a tenth of a second, drawn over
/// what is there.
pub fn Frame::new(
  image : Image,
  x? : Int32,
  y? : Int32,
  delay? : Int32,
  dispose? : Dispose,
  blend? : Blend,
) -> Frame {
  {
    image,
    x: x.unwrap_or(0),
    y: y.unwrap_or(0),
    delay: delay.unwrap_or(100),
    dispose: dispose.unwrap_or(Keep),
    blend: blend.unwrap_or(Over),
  }
}

///|
/// A sequence of frames over one canvas.
pub(all) struct Animation {
  /// The canvas width every frame is placed on.
  width : Int32
  /// The canvas height every frame is placed on.
  height : Int32
  /// How many times the animation plays. 0 means forever, which is what an
  /// animation without a repeat count means in all three formats.
  loops : Int32
  /// The frames, in order.
  frames : Array[Frame]
  /// Metadata that belongs to the animation as a whole.
  metadata : Metadata
}

///|
/// An animation over a canvas, with no frames yet unless given some.
pub fn Animation::new(
  width : Int32,
  height : Int32,
  frames : Array[Frame],
  loops? : Int32,
  metadata? : Metadata,
) -> Animation {
  {
    width,
    height,
    loops: loops.unwrap_or(0),
    frames,
    metadata: metadata.unwrap_or(Metadata::default()),
  }
}

///|
/// Every frame as a full canvas, in order, with each rule applied as it goes.
///
/// The result is what a viewer shows: the same length as `frames`, each one the
/// whole canvas. This is the expensive way to watch an animation and the only
/// way to see it out of context, which is what a test does.
///
/// The canvas is sixteen-bit, so that an eight-bit animation and a sixteen-bit
/// one come out of the same code without either losing its precision.
pub fn Animation::compose(self : Animation) -> Array[Image] {
  let width = self.width
  let height = self.height
  let canvas : FixedArray[Byte] = FixedArray::make(width * height * 8, b'\x00')
  let pictures : Array[Image] = []
  for frame in self.frames {
    let x0 = clamp(frame.x, 0, width)
    let y0 = clamp(frame.y, 0, height)
    let x1 = clamp(frame.x + frame.image.width, 0, width)
    let y1 = clamp(frame.y + frame.image.height, 0, height)
    let saved = if frame.dispose == Previous {
      copy_rect(canvas, width, x0, y0, x1, y1)
    } else {
      FixedArray::make(0, b'\x00')
    }
    draw(canvas, width, frame, x0, y0, x1, y1)
    pictures.push(
      assemble(width, height, Rgba16, canvas.copy(), false, self.metadata),
    )
    match frame.dispose {
      Keep => ()
      Background => clear_rect(canvas, width, x0, y0, x1, y1)
      Previous => restore_rect(canvas, width, x0, y0, x1, y1, saved)
    }
  }
  pictures
}

///|
fn clamp(value : Int32, low : Int32, high : Int32) -> Int32 {
  if value < low {
    low
  } else if value > high {
    high
  } else {
    value
  }
}

///|
/// Composite one frame onto the canvas, in the rectangle that overlaps it.
fn draw(
  canvas : FixedArray[Byte],
  width : Int32,
  frame : Frame,
  x0 : Int32,
  y0 : Int32,
  x1 : Int32,
  y1 : Int32,
) -> Unit {
  if x1 <= x0 || y1 <= y0 {
    return
  }
  let picture = if frame.image.premultiplied {
    frame.image.to_straight()
  } else {
    frame.image
  }
  let bpp = picture.format.bytes()
  for y in y0..<y1 {
    for x in x0..<x1 {
      let offset = (y - frame.y) * picture.stride + (x - frame.x) * bpp
      let source = read_pixel(picture.pixels, offset, picture.format)
      let at = (y * width + x) * 8
      let blended = if frame.blend == Source {
        source
      } else {
        over(source, canvas_pixel(canvas, at))
      }
      write_pixel(canvas, at, Rgba16, blended)
    }
  }
}

///|
/// A pixel of the sixteen-bit canvas, which is the only format `compose` keeps
/// its working copy in.
fn canvas_pixel(canvas : FixedArray[Byte], at : Int32) -> Pixel {
  {
    r: word_of(canvas, at).to_double() / 65535.0,
    g: word_of(canvas, at + 2).to_double() / 65535.0,
    b: word_of(canvas, at + 4).to_double() / 65535.0,
    a: word_of(canvas, at + 6).to_double() / 65535.0,
  }
}

///|
/// Source over destination, straight alpha, in the units `Pixel` uses.
fn over(source : Pixel, target : Pixel) -> Pixel {
  let sa = source.a
  if sa >= 1.0 {
    return source
  }
  if sa <= 0.0 {
    return target
  }
  let da = target.a
  let out = sa + da * (1.0 - sa)
  if out <= 0.0 {
    return { r: 0.0, g: 0.0, b: 0.0, a: 0.0, }
  }
  {
    r: (source.r * sa + target.r * da * (1.0 - sa)) / out,
    g: (source.g * sa + target.g * da * (1.0 - sa)) / out,
    b: (source.b * sa + target.b * da * (1.0 - sa)) / out,
    a: out,
  }
}

///|
fn clear_rect(
  canvas : FixedArray[Byte],
  width : Int32,
  x0 : Int32,
  y0 : Int32,
  x1 : Int32,
  y1 : Int32,
) -> Unit {
  for y in y0..<y1 {
    for x in x0..<x1 {
      let at = (y * width + x) * 8
      for k in 0..<8 {
        canvas[at + k] = 0
      }
    }
  }
}

///|
fn copy_rect(
  canvas : FixedArray[Byte],
  width : Int32,
  x0 : Int32,
  y0 : Int32,
  x1 : Int32,
  y1 : Int32,
) -> FixedArray[Byte] {
  let columns = if x1 > x0 { x1 - x0 } else { 0 }
  let rows = if y1 > y0 { y1 - y0 } else { 0 }
  let saved : FixedArray[Byte] = FixedArray::make(columns * rows * 8, b'\x00')
  for row in 0..<rows {
    for column in 0..<columns {
      let from = ((y0 + row) * width + x0 + column) * 8
      let to = (row * columns + column) * 8
      for k in 0..<8 {
        saved[to + k] = canvas[from + k]
      }
    }
  }
  saved
}

///|
fn restore_rect(
  canvas : FixedArray[Byte],
  width : Int32,
  x0 : Int32,
  y0 : Int32,
  x1 : Int32,
  y1 : Int32,
  saved : FixedArray[Byte],
) -> Unit {
  let columns = if x1 > x0 { x1 - x0 } else { 0 }
  let rows = if y1 > y0 { y1 - y0 } else { 0 }
  for row in 0..<rows {
    for column in 0..<columns {
      let to = ((y0 + row) * width + x0 + column) * 8
      let from = (row * columns + column) * 8
      for k in 0..<8 {
        canvas[to + k] = saved[from + k]
      }
    }
  }
}
