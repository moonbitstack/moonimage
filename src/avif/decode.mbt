// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// A still AVIF, end to end: the container's primary item, the OBU headers over
// its one frame, the tile the frame's syntax describes, and the loop filters
// that tidy the result.
//
// What a decoder owes a caller is the samples the encoder meant, and for a still
// picture that means exactly what every other conformant decoder produces — an
// AV1 bitstream has one answer, not a range. So the pipeline is not "close
// enough": each stage is the reference's arithmetic, and the test compares whole
// planes with the bytes another decoder produced from the same file.

///|
/// Decode the primary item of an AVIF file into planes.
///
/// Seven streams are reproduced sample for sample against libdav1d, and the
/// fixture in `decode_wbtest.mbt` checks each whole plane. All of them are
/// eight-bit 4:2:0 that fit in one tile, which is what a still picture written
/// by libavif at its defaults is; `Format::Avif` routes a file here, so the
/// entry point in the package root reads one as readily as it reads a PNG.
pub fn decode_planes(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> FrameBuffer raise @raster.Refused {
  let item = read_item(bytes)
  let headers = read_headers(item)
  decode_frame(headers, limits?)
}

///|
/// Everything the frame header asks for that this decoder does not do is named
/// here, at the one place that would otherwise carry on and produce a picture
/// that looks plausible and is wrong.
fn check_supported(seq : Sequence, frame : Frame) -> Unit raise @raster.Refused {
  // Every stream this decoder is held to is 4:2:0. The code paths for the other
  // two layouts are written — the subsampling is a number everywhere — but they
  // are not held to a stream, and a decoder that returns a plausible wrong
  // picture is worse than one that says no.
  if seq.ss_hor != 1 || seq.ss_ver != 1 {
    raise @raster.Unsupported(at=0, got="an AVIF that is not 4:2:0")
  }
  if seq.hbd != 0 {
    raise @raster.Unsupported(at=0, got="an AVIF above eight bits a sample")
  }
  if seq.super_res {
    raise @raster.Unsupported(at=0, got="an AVIF with super resolution")
  }
  if frame.segmentation {
    raise @raster.Unsupported(at=0, got="an AVIF with segmentation")
  }
  if frame.allow_intrabc {
    raise @raster.Unsupported(at=0, got="an AVIF with intra block copy")
  }
  if seq.film_grain {
    // A grain synthesis model changes the picture after decoding, and a still
    // AVIF that carries one is asking for a film grain pass this library does
    // not have.
    raise @raster.Unsupported(at=0, got="an AVIF with film grain")
  }
}

///|
/// Decode the one frame of a still image.
pub fn decode_frame(
  headers : Headers,
  limits? : @raster.Limits,
) -> FrameBuffer raise @raster.Refused {
  let seq = headers.sequence
  let frame = headers.frame
  check_supported(seq, frame)
  // Three planes of sixteen-bit samples are what the decoder allocates before
  // it reads a single coefficient, so the shape is checked first.
  let limits = limits.unwrap_or(@raster.Limits::default())
  limits.check(seq.width, seq.height)
  limits.check_bytes(seq.width * seq.height * 6)
  if frame.cols * frame.rows != 1 {
    raise @raster.Unsupported(at=0, got="an AVIF split into more than one tile")
  }
  let fb = FrameBuffer::new(
    seq.width,
    seq.height,
    seq.ss_hor,
    seq.ss_ver,
    seq.monochrome,
  )
  let cdf = FixedArray::make(cdf_all.length(), 0)
  for i in 0..<cdf_all.length() {
    cdf[i] = cdf_all[i]
  }
  let tile = Tile::new(
    headers.tile,
    fb,
    seq,
    frame,
    cdf,
    !frame.disable_cdf_update,
  )
  decode_tile(tile)
  deblock(tile)
  cdef_filter(tile)
  fb
}

///|
/// Walk the superblocks of the one tile.
fn decode_tile(tile : Tile) -> Unit raise @raster.Refused {
  let step = if tile.seq.sb128 { 32 } else { 16 }
  let root = if tile.seq.sb128 { 0 } else { 1 }
  let mut sby = 0
  while sby < tile.bh {
    tile.left.reset()
    let mut sbx = 0
    while sbx < tile.bw {
      for i in 0..<4 {
        tile.cdef_idx[i] = -1
      }
      tile.bx = sbx
      tile.by = sby
      decode_sb(tile, root)
      sbx = sbx + step
    }
    sby = sby + step
  }
}

///|
/// The picture as eight-bit RGBA, which is what the rest of this library hands
/// back.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  let item = read_item(bytes)
  let planes = decode_planes(bytes, limits?)
  let matrix = if item.matrix != 0 { item.matrix } else { 6 }
  let full = item.full_range
  let width = planes.width
  let height = planes.height
  let pixels : FixedArray[Byte] = FixedArray::make(width * height * 4, b'\xff')
  let coefficients = colour_matrix(matrix)
  for y in 0..<height {
    for x in 0..<width {
      let yy = planes.y.get(x, y)
      let cx = x >> planes.ss_hor
      let cy = y >> planes.ss_ver
      let u = if planes.monochrome { 128 } else { planes.u.get(cx, cy) }
      let v = if planes.monochrome { 128 } else { planes.v.get(cx, cy) }
      let (r, g, b) = to_rgb(yy, u, v, coefficients, full)
      let at = (y * width + x) * 4
      pixels[at] = r.to_byte()
      pixels[at + 1] = g.to_byte()
      pixels[at + 2] = b.to_byte()
    }
  }
  @raster.Image::of(
    width,
    height,
    @raster.PixelFormat::Rgba8,
    Bytes::from_array(pixels),
  )
}
