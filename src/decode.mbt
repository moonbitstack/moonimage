// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// One entry point per direction, so that a caller handling a file of unknown
// type does not need a table of magic numbers of its own.
//
// The types live in `raster` and are re-exported here: an image is an image
// whichever format it came from, and the operations that move pixels around are
// the same ones, so a caller importing this package has everything except the
// per-format options — and those are only needed by the caller that has already
// decided which format it is writing.

///|
pub using @raster {
  type Animation,
  type Blend,
  type Chromaticities,
  type Dispose,
  type Format,
  type Frame,
  type Icc,
  type Image,
  type Intent,
  type Limits,
  type Metadata,
  type Pixel,
  type PixelFormat,
  type Refused,
  type Sampling,
  type Text,
}

///|
/// The image in these bytes, whichever format they are.
///
/// The limits default to `Limits::default()`; a caller reading untrusted files
/// should pass `Limits::strict()` or a tighter record.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  match @raster.Format::of(bytes) {
    Png => @png.decode(bytes, limits~)
    Qoi => @qoi.decode(bytes, limits~)
    Bmp => @bmp.decode(bytes, limits~)
    Tga => @tga.decode(bytes, limits~)
    Jpeg => @jpeg.decode(bytes, limits~)
    Gif => @gif.decode(bytes, limits~)
    Webp => @webp.decode(bytes, limits~)
  }
}

///|
/// Every frame in these bytes, whichever format they are.
///
/// A format that does not animate comes back as an animation of one frame over
/// the whole canvas, so a caller that only draws animations does not need to
/// branch.
pub fn decode_animation(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Animation raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  match @raster.Format::of(bytes) {
    Png => @png.decode_animation(bytes, limits~)
    Gif => @gif.decode_animation(bytes, limits~)
    Webp => @webp.decode_animation(bytes, limits~)
    _ => {
      let image = decode(bytes, limits~)
      @raster.Animation::new(
        image.width,
        image.height,
        [@raster.Frame::new(image)],
        metadata=image.metadata,
      )
    }
  }
}

///|
/// The image as bytes of the named format, with that format's defaults.
///
/// A caller that wants to choose how it is written calls the format's own
/// package, which takes its options record.
pub fn encode(image : @raster.Image, format : @raster.Format) -> Bytes {
  match format {
    Png => @png.encode(image)
    Qoi => @qoi.encode(image)
    Bmp => @bmp.encode(image)
    Tga => @tga.encode(image)
    Jpeg => @jpeg.encode(image)
    Gif => @gif.encode(image)
    Webp => @webp.encode(image)
  }
}

///|
/// The animation as bytes of the named format, with that format's defaults.
///
/// The formats that animate keep every frame; the ones that do not write the
/// first, which is what a viewer of a still image shows.
pub fn encode_animation(
  animation : @raster.Animation,
  format : @raster.Format,
) -> Bytes raise @raster.Refused {
  match format {
    Png => @png.encode_animation(animation)
    Gif => @gif.encode_animation(animation)
    Webp => @webp.encode_animation(animation)
    _ => {
      if animation.frames.is_empty() {
        raise @raster.Unexpected(
          at=0,
          got="an animation with no frames",
          want="at least one",
        )
      }
      let first = animation.frames[0]
      encode(first.image, format)
    }
  }
}
