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
pub fn Animation::compose(self : Animation) -> Array[Image] {
  ignore(self)
  abort("moonimage: not implemented yet")
}
