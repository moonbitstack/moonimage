// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// WebP: two codecs in one container, and a third for animation.
//
// https://developers.google.com/speed/webp/docs/riff_container
// https://datatracker.ietf.org/doc/html/rfc9649
//
// The container is RIFF, which means a chunk list and a size to skip it by. The
// payload is either VP8, the intra frame of a video codec, or VP8L, a lossless
// one built on LZ77 with a colour cache and four optional transforms.
//
// Both are read, because a WebP that arrived from anywhere may be either; only
// VP8L is written, because a lossy encoder is a rate-distortion search and this
// library's job is to be correct rather than to win a size comparison. Animation
// is read and written through the extended container, which is a canvas and a
// list of frames, each a still image with its own disposal and blending rule.

///|
/// The image in a WebP file.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  ignore((bytes, limits))
  raise @raster.Unsupported(at=0, got="NOT IMPLEMENTED")
}

///|
/// Every frame of an animated WebP, with the rectangle, delay, disposal and
/// blending each frame declares.
pub fn decode_animation(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Animation raise @raster.Refused {
  ignore((bytes, limits))
  raise @raster.Unsupported(at=0, got="NOT IMPLEMENTED")
}

///|
/// The image as a lossless WebP.
pub fn encode(image : @raster.Image) -> Bytes {
  ignore(image)
  abort("moonimage: not implemented yet")
}

///|
/// The animation as an animated WebP.
pub fn encode_animation(animation : @raster.Animation) -> Bytes {
  ignore(animation)
  abort("moonimage: not implemented yet")
}
