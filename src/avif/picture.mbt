// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The sample planes of a decoded picture, and the room around them that
// prediction and filtering read into.
//
// A block at the edge of the frame still has a full size: a sixty-four by
// sixty-four transform that starts thirty pixels from the right edge writes
// thirty-four columns past the visible picture, and the intra predictor above it
// reads one row above the first row of the frame. So a plane is allocated with
// the visible size rounded up to a whole superblock, and a border on every side,
// and every access goes through an origin so that the caller can use the
// coordinates of the picture and not of the allocation.

///|
/// How much room a plane keeps around the picture.
let plane_pad : Int32 = 16

///|
/// A plane of samples, with the index of its top-left pixel.
pub(all) struct Plane {
  data : FixedArray[Int32]
  stride : Int32
  width : Int32
  height : Int32
  origin : Int32
}

///|
/// A plane with room for blocks that stick out of the picture.
pub fn Plane::allocate(width : Int32, height : Int32) -> Plane {
  let round = 128
  let across = (width + round - 1) / round * round + 2 * plane_pad
  let down = (height + round - 1) / round * round + 2 * plane_pad
  {
    data: FixedArray::make(across * down, 0),
    stride: across,
    width,
    height,
    origin: plane_pad * across + plane_pad,
  }
}

///|
fn Plane::at(self : Plane, x : Int32, y : Int32) -> Int32 {
  self.origin + y * self.stride + x
}

///|
fn Plane::get(self : Plane, x : Int32, y : Int32) -> Int32 {
  self.data[self.at(x, y)]
}

///|
fn Plane::set(self : Plane, x : Int32, y : Int32, value : Int32) -> Unit {
  self.data[self.at(x, y)] = value
}

///|
/// The three planes of a picture, and the shape of its chroma.
pub(all) struct FrameBuffer {
  y : Plane
  u : Plane
  v : Plane
  width : Int32
  height : Int32
  ss_hor : Int32
  ss_ver : Int32
  monochrome : Bool
}

///|
pub fn FrameBuffer::new(
  width : Int32,
  height : Int32,
  ss_hor : Int32,
  ss_ver : Int32,
  monochrome : Bool,
) -> FrameBuffer {
  let cw = (width + ss_hor) >> ss_hor
  let ch = (height + ss_ver) >> ss_ver
  {
    y: Plane::allocate(width, height),
    u: Plane::allocate(cw, ch),
    v: Plane::allocate(cw, ch),
    width,
    height,
    ss_hor,
    ss_ver,
    monochrome,
  }
}

///|
/// A column inside the picture, or the nearest one that is.
fn clamp_x(plane : Plane, x : Int32) -> Int32 {
  if x < 0 {
    0
  } else if x >= plane.width {
    plane.width - 1
  } else {
    x
  }
}

///|
fn clamp_y(plane : Plane, y : Int32) -> Int32 {
  if y < 0 {
    0
  } else if y >= plane.height {
    plane.height - 1
  } else {
    y
  }
}
