// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// VP8, the lossy codec inside a WebP, which is the intra frame of a video
// codec: a boolean arithmetic coder over prediction modes and transform
// coefficients, with the picture rebuilt from the top left.

///|
/// The image in a VP8 payload: a frame header, then the compressed frame.
pub fn decode_lossy(
  payload : BytesView,
  limits : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  ignore((payload, limits))
  raise @raster.Unsupported(at=0, got="VP8, the lossy codec")
}
