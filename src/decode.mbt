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
  type Kernel,
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
/// Without `format` the picture comes back in the layout the file itself holds,
/// which is what a second decode or a comparison against the original wants.
/// With it, the picture comes back in the layout a caller is drawing with: a
/// canvas wants `Rgba8`, a GPU upload of a normal map wants `Rgb8`, and a block
/// texture's own layout is neither. That is one conversion, and none at all when
/// the file already holds the format asked for.
///
/// The limits default to `Limits::default()`; a caller reading untrusted files
/// should pass `Limits::strict()` or a tighter record.
pub fn decode(
  bytes : BytesView,
  format? : @raster.PixelFormat,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  // An AVIF is a HEIF container of AV1 still pictures. Naming it is worth the
  // four bytes it costs even though there is no AV1 decoder here: "unknown
  // format" would send a caller looking for a typo in the file.
  if bytes.length() >= 12 &&
    bytes[4:8].equal_to_bytes(b"ftyp") &&
    (bytes[8:12].equal_to_bytes(b"avif") || bytes[8:12].equal_to_bytes(b"avis")) {
    raise @raster.Unsupported(at=4, got="an AVIF, which needs an AV1 decoder")
  }
  let image = match @raster.Format::of(bytes) {
    Png => @png.decode(bytes, limits~)
    Qoi => @qoi.decode(bytes, limits~)
    Bmp => @bmp.decode(bytes, limits~)
    Tga => @tga.decode(bytes, limits~)
    Jpeg => @jpeg.decode(bytes, limits~)
    Gif => @gif.decode(bytes, limits~)
    Webp => @webp.decode(bytes, limits~)
    Tiff => @tiff.decode(bytes, limits~)
    Ico => @ico.decode(bytes, limits~)
    Cur => @ico.decode(bytes, limits~)
    Pnm => @pnm.decode(bytes, limits~)
    Hdr => @hdr.decode(bytes, limits~)
    Exr => @exr.decode(bytes, limits~)
    Farbfeld => @farbfeld.decode(bytes, limits~)
    Dds => @dds.decode(bytes, limits~)
  }
  match format {
    Some(target) => image.convert(target)
    None => image
  }
}

///|
/// Every frame in these bytes, whichever format they are.
///
/// A format that does not animate comes back as an animation of one frame over
/// the whole canvas, so a caller that only draws animations does not need to
/// branch. `format` is applied to every frame, for the same reason it exists on
/// `decode`: a canvas draws in one layout and a file may hold several. A TIFF comes back as one frame a page, and an icon as one frame a
/// size, because both are a sequence of pictures that a caller walking a
/// sequence wants to see.
pub fn decode_animation(
  bytes : BytesView,
  format? : @raster.PixelFormat,
  limits? : @raster.Limits,
) -> @raster.Animation raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  let animation = match @raster.Format::of(bytes) {
    Png => @png.decode_animation(bytes, limits~)
    Gif => @gif.decode_animation(bytes, limits~)
    Webp => @webp.decode_animation(bytes, limits~)
    Tiff => pages_of(@tiff.decode_pages(bytes, limits~))
    Ico | Cur => {
      let entries = @ico.decode_all(bytes, limits~)
      let frames : Array[@raster.Frame] = []
      for entry in entries {
        frames.push(@raster.Frame::new(entry.image, delay=0))
      }
      if frames.is_empty() {
        raise @raster.Unexpected(
          at=0,
          got="an icon with no pictures",
          want="at least one",
        )
      }
      let widest = widest(frames)
      @raster.Animation::new(
        widest.0,
        widest.1,
        frames,
        metadata=frames[0].image.metadata,
      )
    }
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
  match format {
    Some(target) =>
      {
        ..animation,
        frames: animation.frames.map(frame => {
          ..frame,
          image: frame.image.convert(target),
        }),
      }
    None => animation
  }
}

///|
/// Pages as frames over the widest canvas, which is what a viewer of a multi-page
/// file draws.
fn pages_of(
  pages : Array[@raster.Image],
) -> @raster.Animation raise @raster.Refused {
  let frames : Array[@raster.Frame] = []
  for page in pages {
    frames.push(@raster.Frame::new(page, delay=0))
  }
  if frames.is_empty() {
    raise @raster.Unexpected(
      at=0,
      got="a file with no pages",
      want="at least one",
    )
  }
  let size = widest(frames)
  @raster.Animation::new(
    size.0,
    size.1,
    frames,
    metadata=frames[0].image.metadata,
  )
}

///|
/// The largest width and height any frame takes.
fn widest(frames : Array[@raster.Frame]) -> (Int32, Int32) {
  let mut width = 0
  let mut height = 0
  for frame in frames {
    if frame.image.width > width {
      width = frame.image.width
    }
    if frame.image.height > height {
      height = frame.image.height
    }
  }
  (width, height)
}

///|
/// The image as bytes of the named format, with that format's defaults.
///
/// A caller that wants to choose how it is written calls the format's own
/// package, which takes its options record.
///
/// `Dds` is written as a surface of plain samples. A block-compressed texture is
/// written by that package's own call, which takes the block format.
pub fn encode(
  image : @raster.Image,
  format : @raster.Format,
) -> Bytes raise @raster.Refused {
  match format {
    Png => @png.encode(image)
    Qoi => @qoi.encode(image)
    Bmp => @bmp.encode(image)
    Tga => @tga.encode(image)
    Jpeg => @jpeg.encode(image)
    Gif => @gif.encode(image)
    Webp => @webp.encode(image)
    Tiff => @tiff.encode(image)
    Ico => @ico.encode(image)
    Cur => @ico.encode(image, options=@ico.EncodeOptions::cursor(0, 0))
    Pnm => @pnm.encode(image)
    Hdr => @hdr.encode(image)
    Exr => @exr.encode(image)
    Farbfeld => @farbfeld.encode(image)
    Dds => @dds.encode(image)
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
    Tiff =>
      @tiff.encode_pages(
        animation
        .compose()
        .map(frame => { ..frame, metadata: animation.metadata, }),
      )
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
