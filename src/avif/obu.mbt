// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The AV1 headers: OBU framing, the sequence header, and the uncompressed
// frame header of a reduced still picture.
//
// An AVIF still is one key frame. The sequence header says how large the
// picture's superblocks are and which tools the stream may use; the frame
// header says how the picture was quantised, tiled and filtered. Both are read
// a field at a time from a bit reader, most significant bit first, with a byte
// alignment at the end of each. Nothing here is predicted or guessed: a value
// that is not in the stream is the default the specification gives it.

///|
/// A bit reader over one OBU's payload.
priv struct Bits {
  data : BytesView
  mut pos : Int32
}

///|
fn Bits::new(data : BytesView) -> Bits {
  { data, pos: 0 }
}

///|
fn Bits::bit(self : Bits) -> Int32 {
  let byte = self.data[self.pos >> 3].to_int()
  let value = (byte >> (7 - (self.pos & 7))) & 1
  self.pos = self.pos + 1
  value
}

///|
fn Bits::bits(self : Bits, count : Int32) -> Int32 {
  let mut value = 0
  for _ in 0..<count {
    value = (value << 1) | self.bit()
  }
  value
}

///|
fn Bits::signed(self : Bits, count : Int32) -> Int32 {
  let value = self.bits(count)
  if (value & (1 << (count - 1))) != 0 {
    value - (1 << count)
  } else {
    value
  }
}

///|
/// Skip to the next byte boundary, and answer how many bytes were used.
fn Bits::align(self : Bits) -> Int32 {
  self.pos = ((self.pos + 7) >> 3) << 3
  self.pos >> 3
}

///|
/// What the sequence header says about every frame that follows it.
pub(all) struct Sequence {
  profile : Int32
  still : Bool
  reduced : Bool
  width : Int32
  height : Int32
  width_n_bits : Int32
  height_n_bits : Int32
  sb128 : Bool
  filter_intra : Bool
  intra_edge_filter : Bool
  super_res : Bool
  cdef : Bool
  restoration : Bool
  hbd : Int32
  monochrome : Bool
  color_range : Bool
  ss_hor : Int32
  ss_ver : Int32
  chroma_position : Int32
  primaries : Int32
  transfer : Int32
  matrix : Int32
  separate_uv_delta_q : Bool
  film_grain : Bool
}

///|
fn read_sequence(bits : Bits) -> Sequence raise @raster.Refused {
  let profile = bits.bits(3)
  let still = bits.bit() == 1
  let reduced = bits.bit() == 1
  if !still || !reduced {
    raise @raster.Unsupported(
      at=0,
      got="an AV1 stream with a full sequence header",
    )
  }
  let _major = bits.bits(3)
  let _minor = bits.bits(2)
  let width_n_bits = bits.bits(4) + 1
  let height_n_bits = bits.bits(4) + 1
  let width = bits.bits(width_n_bits) + 1
  let height = bits.bits(height_n_bits) + 1
  let sb128 = bits.bit() == 1
  let filter_intra = bits.bit() == 1
  let intra_edge_filter = bits.bit() == 1
  let super_res = bits.bit() == 1
  let cdef = bits.bit() == 1
  let restoration = bits.bit() == 1
  let mut hbd = bits.bit()
  if profile == 2 && hbd == 1 {
    hbd = hbd + bits.bit()
  }
  let monochrome = if profile != 1 { bits.bit() == 1 } else { false }
  let described = bits.bit() == 1
  let primaries = if described { bits.bits(8) } else { 0 }
  let transfer = if described { bits.bits(8) } else { 0 }
  let matrix = if described { bits.bits(8) } else { 0 }
  let mut color_range = false
  let mut ss_hor = 0
  let mut ss_ver = 0
  let mut chroma_position = 0
  if monochrome {
    color_range = bits.bit() == 1
    ss_hor = 1
    ss_ver = 1
  } else {
    color_range = bits.bit() == 1
    if profile == 0 {
      ss_hor = 1
      ss_ver = 1
    } else if profile == 1 {
      ss_hor = 0
      ss_ver = 0
    } else {
      if hbd == 2 {
        ss_hor = bits.bit()
        if ss_hor == 1 {
          ss_ver = bits.bit()
        }
      } else {
        ss_hor = 1
      }
    }
    if ss_hor == 1 && ss_ver == 1 {
      chroma_position = bits.bits(2)
    }
  }
  let separate_uv_delta_q = if monochrome { false } else { bits.bit() == 1 }
  let film_grain = bits.bit() == 1
  {
    profile,
    still,
    reduced,
    width,
    height,
    width_n_bits,
    height_n_bits,
    sb128,
    filter_intra,
    intra_edge_filter,
    super_res,
    cdef,
    restoration,
    hbd,
    monochrome,
    color_range,
    ss_hor,
    ss_ver,
    chroma_position,
    primaries,
    transfer,
    matrix,
    separate_uv_delta_q,
    film_grain,
  }
}

///|
/// What the frame header says about the one picture in a still AVIF.
pub(all) struct Frame {
  disable_cdf_update : Bool
  allow_intrabc : Bool
  uniform : Bool
  cols : Int32
  rows : Int32
  n_bytes : Int32
  yac : Int32
  ydc_delta : Int32
  udc_delta : Int32
  uac_delta : Int32
  vdc_delta : Int32
  vac_delta : Int32
  qm : Bool
  qm_y : Int32
  qm_u : Int32
  qm_v : Int32
  segmentation : Bool
  all_lossless : Bool
  lf_y0 : Int32
  lf_y1 : Int32
  lf_u : Int32
  lf_v : Int32
  sharpness : Int32
  cdef_damping : Int32
  cdef_bits : Int32
  txfm_mode : Int32
  reduced_txtp_set : Bool
  tile_at : Int32
  tile_length : Int32
}

///|
/// `tile_log2(sz, tgt)`: the smallest k with `sz << k >= tgt`.
fn tile_log2(size : Int32, target : Int32) -> Int32 {
  let mut k = 0
  while (size << k) < target {
    k = k + 1
  }
  k
}

///|
fn min_of(a : Int32, b : Int32) -> Int32 {
  if a < b { a } else { b }
}

///|
fn max_of(a : Int32, b : Int32) -> Int32 {
  if a > b { a } else { b }
}

///|
/// The frame header of a reduced still picture, and where its tile data begins.
fn read_frame(bits : Bits, seq : Sequence, length : Int32) -> Frame raise @raster.Refused {
  let disable_cdf_update = bits.bit() == 1
  let allow_screen_content = bits.bit() == 1
  if allow_screen_content {
    // force_integer_mv is adaptive here; a key frame sets it to one itself.
    ignore(bits.bit())
  }
  if seq.super_res {
    ignore(bits.bit())
  }
  let render = bits.bit() == 1
  if render {
    ignore(bits.bits(16))
    ignore(bits.bits(16))
  }
  let mut allow_intrabc = false
  if allow_screen_content {
    allow_intrabc = bits.bit() == 1
  }

  // Tiling. A still picture is usually one tile, but the number of tiles is in
  // the stream and the tile data cannot be found without reading it.
  let uniform = bits.bit() == 1
  if !uniform {
    raise @raster.Unsupported(at=0, got="a frame with non-uniform tiles")
  }
  let sbsz_log2 = 6 + (if seq.sb128 { 1 } else { 0 })
  let sbw = (seq.width + (64 << (if seq.sb128 { 1 } else { 0 })) - 1) >> sbsz_log2
  let sbh = (seq.height + (64 << (if seq.sb128 { 1 } else { 0 })) - 1) >> sbsz_log2
  let min_log2_cols = tile_log2(4096 >> sbsz_log2, sbw)
  let max_log2_cols = tile_log2(1, min_of(sbw, 64))
  let max_log2_rows = tile_log2(1, min_of(sbh, 64))
  let min_log2_tiles = max_of(
    tile_log2((4096 * 2304) >> (2 * sbsz_log2), sbw * sbh),
    min_log2_cols,
  )
  let mut log2_cols = min_log2_cols
  while log2_cols < max_log2_cols && bits.bit() == 1 {
    log2_cols = log2_cols + 1
  }
  let tile_w = 1 + ((sbw - 1) >> log2_cols)
  let cols = (sbw + tile_w - 1) / tile_w
  let min_log2_rows = max_of(min_log2_tiles - log2_cols, 0)
  let mut log2_rows = min_log2_rows
  while log2_rows < max_log2_rows && bits.bit() == 1 {
    log2_rows = log2_rows + 1
  }
  let tile_h = 1 + ((sbh - 1) >> log2_rows)
  let rows = (sbh + tile_h - 1) / tile_h
  let n_bytes = if log2_cols != 0 || log2_rows != 0 {
    ignore(bits.bits(log2_cols + log2_rows))
    bits.bits(2) + 1
  } else {
    0
  }

  // Quantiser.
  let yac = bits.bits(8)
  let ydc_delta = if bits.bit() == 1 { bits.signed(7) } else { 0 }
  let mut udc_delta = 0
  let mut uac_delta = 0
  let mut vdc_delta = 0
  let mut vac_delta = 0
  if !seq.monochrome {
    let diff_uv = if seq.separate_uv_delta_q { bits.bit() == 1 } else { false }
    udc_delta = if bits.bit() == 1 { bits.signed(7) } else { 0 }
    uac_delta = if bits.bit() == 1 { bits.signed(7) } else { 0 }
    if diff_uv {
      vdc_delta = if bits.bit() == 1 { bits.signed(7) } else { 0 }
      vac_delta = if bits.bit() == 1 { bits.signed(7) } else { 0 }
    } else {
      vdc_delta = udc_delta
      vac_delta = uac_delta
    }
  }
  let qm = bits.bit() == 1
  let mut qm_y = 0
  let mut qm_u = 0
  let mut qm_v = 0
  if qm {
    qm_y = bits.bits(4)
    qm_u = bits.bits(4)
    qm_v = if seq.separate_uv_delta_q { bits.bits(4) } else { qm_u }
  }

  // Segmentation.
  let segmentation = bits.bit() == 1
  if segmentation {
    // A key frame with error resilience has no primary reference, so the map
    // and the data are both updated and neither flag is in the stream.
    for _ in 0..<8 {
      if bits.bit() == 1 {
        ignore(bits.signed(9))
      }
      for _ in 0..<4 {
        if bits.bit() == 1 {
          ignore(bits.signed(7))
        }
      }
      if bits.bit() == 1 {
        ignore(bits.bits(3))
      }
      ignore(bits.bit())
      ignore(bits.bit())
    }
  }
  let all_lossless = yac == 0 && ydc_delta == 0 && udc_delta == 0 &&
    uac_delta == 0 && vdc_delta == 0 && vac_delta == 0

  // Per-superblock quantiser and loop-filter deltas.
  if yac != 0 {
    if bits.bit() == 1 {
      ignore(bits.bits(2))
      if !allow_intrabc && bits.bit() == 1 {
        ignore(bits.bits(2))
        ignore(bits.bit())
      }
    }
  }

  // Loop filter.
  let mut lf_y0 = 0
  let mut lf_y1 = 0
  let mut lf_u = 0
  let mut lf_v = 0
  let mut sharpness = 0
  if !all_lossless && !allow_intrabc {
    lf_y0 = bits.bits(6)
    lf_y1 = bits.bits(6)
    if !seq.monochrome && (lf_y0 != 0 || lf_y1 != 0) {
      lf_u = bits.bits(6)
      lf_v = bits.bits(6)
    }
    sharpness = bits.bits(3)
    if bits.bit() == 1 && bits.bit() == 1 {
      for _ in 0..<8 {
        if bits.bit() == 1 {
          ignore(bits.signed(7))
        }
      }
      for _ in 0..<2 {
        if bits.bit() == 1 {
          ignore(bits.signed(7))
        }
      }
    }
  }

  // CDEF.
  let mut cdef_damping = 0
  let mut cdef_bits = 0
  if !all_lossless && seq.cdef && !allow_intrabc {
    cdef_damping = bits.bits(2) + 3
    cdef_bits = bits.bits(2)
    for _ in 0..<(1 << cdef_bits) {
      ignore(bits.bits(6))
      if !seq.monochrome {
        ignore(bits.bits(6))
      }
    }
  }

  // Loop restoration. The sequence headers of these vectors have it off; a
  // stream that turns it on is refused rather than read with the wrong offsets.
  if seq.restoration && (!all_lossless || allow_intrabc) {
    raise @raster.Unsupported(at=0, got="a frame with loop restoration")
  }
  let txfm_mode = if all_lossless { 0 } else { bits.bit() }
  let reduced_txtp_set = bits.bit() == 1
  let _header_bytes = bits.align()
  if cols * rows > 1 {
    ignore(bits.bit()) // tile_start_and_end_present_flag
  }
  let tile_at = bits.align()
  {
    disable_cdf_update,
    allow_intrabc,
    uniform,
    cols,
    rows,
    n_bytes,
    yac,
    ydc_delta,
    udc_delta,
    uac_delta,
    vdc_delta,
    vac_delta,
    qm,
    qm_y,
    qm_u,
    qm_v,
    segmentation,
    all_lossless,
    lf_y0,
    lf_y1,
    lf_u,
    lf_v,
    sharpness,
    cdef_damping,
    cdef_bits,
    txfm_mode,
    reduced_txtp_set,
    tile_at,
    tile_length: length - tile_at,
  }
}

///|
/// One OBU: its type and where its payload is.
priv struct Obu {
  kind : Int32
  at : Int32
  length : Int32
}

///|
/// An unsigned LEB128, as the OBU size is written.
fn read_leb(bytes : BytesView, at : Int32) -> (Int32, Int32) {
  let mut value = 0
  let mut shift = 0
  let mut cursor = at
  while true {
    let byte = bytes[cursor].to_int()
    cursor = cursor + 1
    value = value | ((byte & 0x7F) << shift)
    shift = shift + 7
    if (byte & 0x80) == 0 {
      break
    }
  }
  (value, cursor)
}

///|
fn read_obus(bytes : BytesView) -> Array[Obu] {
  let out : Array[Obu] = []
  let mut at = 0
  while at < bytes.length() {
    let head = bytes[at].to_int()
    at = at + 1
    let kind = (head >> 3) & 0xF
    let extension = (head >> 2) & 1
    let has_size = (head >> 1) & 1
    if extension != 0 {
      at = at + 1
    }
    let length = if has_size != 0 {
      let (size, next) = read_leb(bytes, at)
      at = next
      size
    } else {
      bytes.length() - at
    }
    out.push({ kind, at, length })
    at = at + length
    if has_size == 0 {
      break
    }
  }
  out
}

///|
/// The picture's headers and the tile data they frame.
pub(all) struct Headers {
  sequence : Sequence
  frame : Frame
  tile : Bytes
}

///|
pub fn read_headers(item : Item) -> Headers raise @raster.Refused {
  let obus = read_obus(item.data)
  let mut sequence : Sequence? = None
  let mut headers : Headers? = None
  for obu in obus {
    let body = item.data.clamped_view(
      start=obu.at,
      end=obu.at + obu.length,
    )
    if obu.kind == 1 {
      sequence = Some(read_sequence(Bits::new(body)))
    } else if obu.kind == 6 {
      let seq = match sequence {
        Some(value) => value
        None =>
          raise @raster.Unexpected(
            at=0,
            got="a frame before a sequence header",
            want="one first",
          )
      }
      let bits = Bits::new(body)
      let frame = read_frame(bits, seq, obu.length)
      let tile = body.clamped_view(start=frame.tile_at, end=obu.length)
      headers = Some({ sequence: seq, frame, tile: tile.to_owned() })
    }
  }
  match headers {
    Some(value) => value
    None =>
      raise @raster.Unexpected(at=0, got="an AV1 stream with no frame", want="one")
  }
}
