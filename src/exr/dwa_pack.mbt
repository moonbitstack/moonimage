// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Writing a picture as frequencies.
//
// The reader of the two DWA compressions is in `dwa.mbt`; this is the half that
// turns a chunk into one. A block of eight by eight samples of a channel that
// carries light is put on the curve a display has, converted to a luminance and
// two differences when it travels with the other two channels of a colour,
// transformed, and quantized until every coefficient sits on the coarsest grid
// the level allows. What is left over — alpha, a mask, a depth — is run-length
// coded, because a transform would change what those channels mean.
//
// The tolerance is not written in the file: a reader only has to know what the
// coefficients are, not how finely they were rounded. That is what makes the
// quantizer this writer's own business, and it is why the numbers below can be
// the largest grid within the tolerance rather than the smallest set of bits,
// which is what the format's own writer looks for.

///|
/// The level the two compressions are written at. Forty-five is the value the
/// format's own writer uses: the tolerance of a coefficient is this number over
/// a hundred thousand, times the weight of its frequency.
const DWA_LEVEL : Double = 45.0

///|
/// The quality a chunk is written at, as the tables the quantizer needs: the
/// curve from linear light to the domain a coefficient lives in, and how coarse
/// a grid each of the sixty-four coefficients may be rounded to.
priv struct DwaCurve {
  /// The curve, over every half: what a sample looks like before it is
  /// transformed.
  nonlinear : FixedArray[Int32]
  /// Half the width of the grid a luminance coefficient is rounded to.
  luma : FixedArray[Float]
  /// The same for the two differences of a colour, which the eye is less
  /// sensitive to and which may therefore be rounded more.
  chroma : FixedArray[Float]
}

///|
/// The weights of the luminance quantizer: how much error each frequency may
/// carry, in the order a block reads its coefficients. They are the table a
/// JPEG encoder uses, which is a statement about eyes rather than about this
/// format.
fn dwa_luma_weights() -> FixedArray[Int32] {
  [
    16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24,
    40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103,
    77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72,
    92, 95, 98, 112, 100, 103, 99,
  ]
}

///|
/// The weights of the two differences of a colour, which are coarser: the eye
/// resolves a change of hue less finely than a change of brightness.
fn dwa_chroma_weights() -> FixedArray[Int32] {
  [
    17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99,
    99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99,
  ]
}

///|
/// The largest power of two that is not above a tolerance: the grid a
/// coefficient is rounded to is twice this, so that rounding never moves it
/// further than the tolerance allows.
fn dwa_step(tolerance : Float) -> Float {
  if tolerance <= 0.0F {
    return 0.0F
  }
  let mut step = 1.0F
  while step > tolerance {
    step = step * 0.5F
  }
  step
}

///|
/// The grid of each of the sixty-four frequencies, from a table of weights.
///
/// A weight is divided by the smallest weight of its table, which is how the
/// format's own writer reads the same table: the quotient says how much more
/// error a frequency can carry than the one the table is scaled against.
fn dwa_grids(
  weights : FixedArray[Int32],
  smallest : Int32,
) -> FixedArray[Float] {
  let base = DWA_LEVEL / 100000.0
  let out : FixedArray[Float] = FixedArray::make(64, 0.0F)
  for i in 0..<64 {
    let tolerance = base * weights[i].to_double() / smallest.to_double()
    out[i] = dwa_step(Float::from_double(tolerance))
  }
  out
}

///|
/// The curve from linear light to the domain a coefficient lives in.
///
/// Up to one it is the two-and-a-fifth root, which is what a display does; above
/// one, where a root would leave the range, it is the logarithm of the same
/// base, which keeps a picture of a light source from clipping. It is the
/// inverse of the curve the reader applies, and both are built from the same two
/// formulas.
fn dwa_nonlinear_step(bits : Int32) -> Int32 {
  if bits == 0 || (bits & 0x7C00) == 0x7C00 {
    return 0
  }
  let value = @raster.half_to_float(bits).to_double()
  let sign = if value < 0.0 { -1.0 } else { 1.0 }
  let magnitude = if value < 0.0 { -value } else { value }
  let mapped = if magnitude <= 1.0 {
    @math.pow(magnitude, 1.0 / 2.2)
  } else {
    @math.ln(magnitude) / 2.2 + 1.0
  }
  @raster.float_to_half(Float::from_double(sign * mapped))
}

///|
/// The tables a chunk is written with, built once for a file rather than once
/// for each of its chunks: the curve is sixty-five thousand entries, and half of
/// them are exponentials.
fn dwa_curve() -> DwaCurve {
  let nonlinear : FixedArray[Int32] = FixedArray::make(65536, 0)
  for bits in 0..<65536 {
    nonlinear[bits] = dwa_nonlinear_step(bits)
  }
  {
    nonlinear,
    luma: dwa_grids(dwa_luma_weights(), 10),
    chroma: dwa_grids(dwa_chroma_weights(), 17),
  }
}

///|
/// The rules a chunk is written with: what happens to a channel whose suffix is
/// one of the names the format knows, and which of a colour triplet it is.
///
/// They are the rules the reader of the format assumes when a block is older
/// than the second version, written down so that a later version can add to
/// them.
fn dwa_default_rules() -> Array[DwaRule] {
  let rules : Array[DwaRule] = []
  for (suffix, colour) in [("R", 0), ("G", 1), ("B", 2)] {
    for kind in [1, 2] {
      rules.push({
        suffix,
        scheme: DWA_TRANSFORMED,
        colour,
        insensitive: false,
        kind,
      })
    }
  }
  for suffix in ["Y", "BY", "RY"] {
    for kind in [1, 2] {
      rules.push({
        suffix,
        scheme: DWA_TRANSFORMED,
        colour: -1,
        insensitive: false,
        kind,
      })
    }
  }
  for kind in [0, 1, 2] {
    rules.push({
      suffix: "A",
      scheme: DWA_RUNS,
      colour: -1,
      insensitive: false,
      kind,
    })
  }
  rules
}

///|
/// The suffix of a channel name: what follows its last dot, which is the part a
/// rule is matched against.
fn dwa_suffix_of(name : String) -> String {
  let dot = dwa_last_dot(name)
  if dot < 0 {
    name
  } else {
    name[dot + 1:].to_owned()
  }
}

///|
/// A chunk of DWA blocks, as the bytes the file holds.
fn dwa_pack(
  raw : Bytes,
  channels : Array[Channel],
  width : Int32,
  lines : Int32,
  curve : DwaCurve,
) -> Bytes {
  let rules = dwa_default_rules()
  let (order, groups) = dwa_classify(channels, rules, width)
  let row_size = dwa_row_size(channels, width)
  // Where each channel's samples start within a scanline, which the rules do not
  // say and the order the channels are written in does.
  let bases : FixedArray[Int32] = FixedArray::make(channels.length(), 0)
  for channel in order {
    bases[channel.index] = channel.base
  }
  let blocks_across = (width + 7) / 8
  let blocks_down = (lines + 7) / 8
  let blocks_total = blocks_across * blocks_down
  let ac : Array[Int32] = []
  let dc : Array[Int32] = []
  let unknown = @wire.Writer::new()
  let runs = @wire.Writer::new()
  let mut unknown_raw = 0
  let mut runs_raw = 0
  let taken : FixedArray[Bool] = FixedArray::make(channels.length(), false)
  // The three channels of a colour are transformed together, and their
  // coefficients come before the ones of a channel that stands alone.
  for group in groups {
    dwa_encode_unit(
      raw,
      row_size,
      width,
      lines,
      [group[0], group[1], group[2]],
      channels,
      bases,
      curve,
      blocks_across,
      blocks_down,
      blocks_total,
      ac,
      dc,
    )
    for i in 0..<3 {
      taken[group[i]] = true
    }
  }
  for channel in order {
    match channel.scheme {
      DWA_TRANSFORMED =>
        if !taken[channel.index] {
          dwa_encode_unit(
            raw,
            row_size,
            width,
            lines,
            [channel.index],
            channels,
            bases,
            curve,
            blocks_across,
            blocks_down,
            blocks_total,
            ac,
            dc,
          )
          taken[channel.index] = true
        }
      DWA_RUNS => {
        // The bytes of a sample are split by significance: every first byte of
        // a run of pixels, then every second. A run of neighbouring samples
        // shares its high bytes far more often than its low ones, which is what
        // makes the split worth doing.
        let base = channel.base
        for byte in 0..<channel.sample {
          for line in 0..<lines {
            for x in 0..<width {
              let at = line * row_size + base + x * channel.sample + byte
              runs.u8(raw[at].to_int())
              runs_raw = runs_raw + 1
            }
          }
        }
      }
      _ => {
        let base = channel.base
        for line in 0..<lines {
          for x in 0..<width {
            for byte in 0..<channel.sample {
              let at = line * row_size + base + x * channel.sample + byte
              unknown.u8(raw[at].to_int())
              unknown_raw = unknown_raw + 1
            }
          }
        }
      }
    }
  }
  let unknown_bytes = unknown.to_bytes()
  let runs_bytes = runs.to_bytes()
  let ac_bytes = dwa_words_out(ac)
  let dc_bytes = dwa_words_out(dc)
  let unknown_packed = if unknown_raw > 0 {
    @zlib.zlib(unknown_bytes, level=9)
  } else {
    b""
  }
  let ac_packed = if ac.length() > 0 {
    @zlib.zlib(ac_bytes, level=9)
  } else {
    b""
  }
  let dc_packed = if dc.length() > 0 {
    @zlib.zlib(dwa_deconstruct(dc_bytes), level=9)
  } else {
    b""
  }
  let rle = if runs_raw > 0 { dwa_runs_pack(runs_bytes[:]) } else { b"" }
  let runs_packed = if runs_raw > 0 { @zlib.zlib(rle, level=9) } else { b"" }
  let runs_unpacked = rle.length()
  let rule_table = dwa_rules_out(rules, channels)
  let writer = @wire.Writer::new()
  dwa_u64(writer, 2)
  dwa_u64(writer, unknown_raw)
  dwa_u64(writer, unknown_packed.length())
  dwa_u64(writer, ac_packed.length())
  dwa_u64(writer, dc_packed.length())
  dwa_u64(writer, runs_packed.length())
  dwa_u64(writer, runs_unpacked)
  dwa_u64(writer, runs_raw)
  dwa_u64(writer, ac.length())
  dwa_u64(writer, dc.length())
  // Deflate, which every reader of the second version can undo; the older
  // Huffman code of the same coefficients is a thing this writer does not need.
  dwa_u64(writer, DWA_DEFLATE)
  // The length of the table counts itself, which is how a reader knows where the
  // first stream begins.
  writer.u16_le(rule_table.length() + 2)
  writer.bytes(rule_table)
  writer.bytes(unknown_packed)
  writer.bytes(ac_packed)
  writer.bytes(dc_packed)
  writer.bytes(runs_packed)
  writer.to_bytes()
}

///|
/// The coefficients of one channel, or of three that share a colour, as blocks.
///
/// The averages go to their own stream, one plane per channel and then one
/// block after another; the coefficients above them go to a second stream, one
/// block at a time with the channels of a colour inside a block.
fn dwa_encode_unit(
  raw : Bytes,
  row_size : Int32,
  width : Int32,
  lines : Int32,
  members : Array[Int32],
  channels : Array[Channel],
  bases : FixedArray[Int32],
  curve : DwaCurve,
  blocks_across : Int32,
  blocks_down : Int32,
  blocks_total : Int32,
  ac : Array[Int32],
  dc : Array[Int32],
) -> Unit {
  let components = members.length()
  let unit_dc : FixedArray[Int32] = FixedArray::make(
    blocks_total * components,
    0,
  )
  let block : Array[FixedArray[Float]] = []
  for _ in 0..<components {
    block.push(FixedArray::make(64, 0.0F))
  }
  let zig = dwa_zigzag_order()
  for by in 0..<blocks_down {
    for bx in 0..<blocks_across {
      for component in 0..<components {
        let channel = channels[members[component]]
        let values = block[component]
        for y in 0..<8 {
          let mut vy = by * 8 + y
          if vy >= lines {
            vy = lines - (vy - (lines - 1))
          }
          if vy < 0 {
            vy = lines - 1
          }
          for x in 0..<8 {
            let mut vx = bx * 8 + x
            if vx >= width {
              vx = width - (vx - (width - 1))
            }
            if vx < 0 {
              vx = width - 1
            }
            let bits = dwa_sample(
              raw,
              row_size,
              bases[members[component]],
              channel,
              vy,
              vx,
            )
            // A colour is always put on the curve: the three are converted to a
            // luminance and two differences, and a difference of two curved
            // values is not the curve of a difference.
            let mapped = if components == 3 || !channel.linear {
              curve.nonlinear[bits]
            } else {
              bits
            }
            values[y * 8 + x] = @raster.half_to_float(mapped)
          }
        }
      }
      if components == 3 {
        dwa_forward_colour(block[0], block[1], block[2])
      }
      for component in 0..<components {
        dwa_transform(block[component])
        let index = by * blocks_across + bx
        let zigzag : FixedArray[Int32] = FixedArray::make(64, 0)
        let grids = if component == 0 { curve.luma } else { curve.chroma }
        for i in 0..<64 {
          zigzag[zig[i]] = dwa_quantize(block[component][i], grids[i])
        }
        unit_dc[component * blocks_total + index] = zigzag[0]
        dwa_runs_of_block(zigzag, ac)
      }
    }
  }
  for value in unit_dc {
    dc.push(value)
  }
}

///|
/// One sample of a channel of the chunk, as half-float bits.
fn dwa_sample(
  raw : Bytes,
  row_size : Int32,
  base : Int32,
  channel : Channel,
  line : Int32,
  x : Int32,
) -> Int32 {
  let at = line * row_size + base + x * channel.sample
  if channel.sample == 2 {
    raw[at].to_int() | (raw[at + 1].to_int() << 8)
  } else {
    // A float goes through the transform as a half, clamped to the range a half
    // can hold rather than turned into an infinity the quantizer would read as
    // damage.
    let value = @raster.float_at(raw, at)
    let clamped = if value > 65504.0F {
      65504.0F
    } else if value < -65504.0F {
      -65504.0F
    } else {
      value
    }
    @raster.float_to_half(clamped)
  }
}

///|
/// The luminance and the two differences a colour travels as.
///
/// The first channel keeps the luminance, the second the difference of blue from
/// it, the third the difference of red: that is the order the reader puts them
/// back in.
fn dwa_forward_colour(
  first : FixedArray[Float],
  second : FixedArray[Float],
  third : FixedArray[Float],
) -> Unit {
  for i in 0..<64 {
    let red = first[i]
    let green = second[i]
    let blue = third[i]
    first[i] = 0.2126F * red + 0.7152F * green + 0.0722F * blue
    second[i] = -0.1146F * red - 0.3854F * green + 0.5F * blue
    third[i] = 0.5F * red - 0.4542F * green - 0.0458F * blue
  }
}

///|
/// The forward cosine transform of a block, in place: the rows first, then the
/// columns, which is what makes it separable.
///
/// The arithmetic is the one the inverse undoes, with the same constants in the
/// same order. The constants are half the cosines the format's portable path
/// computes; its vectorized path carries values that differ in their last bit,
/// so the two were never the same transform to begin with.
fn dwa_transform(data : FixedArray[Float]) -> Unit {
  for row in 0..<8 {
    dwa_transform_line(data, row * 8, 1)
  }
  for column in 0..<8 {
    dwa_transform_line(data, column, 8)
  }
}

///|
/// One pass of the transform: eight values a stride apart, replaced by their
/// eight frequencies.
fn dwa_transform_line(
  data : FixedArray[Float],
  base : Int32,
  stride : Int32,
) -> Unit {
  let at = fn(i : Int32) -> Int32 { base + i * stride }
  let a0 = data[at(0)] + data[at(7)]
  let a1 = data[at(1)] + data[at(2)]
  let a2 = data[at(1)] - data[at(2)]
  let a3 = data[at(3)] + data[at(4)]
  let a4 = data[at(3)] - data[at(4)]
  let a5 = data[at(5)] + data[at(6)]
  let a6 = data[at(5)] - data[at(6)]
  let a7 = data[at(0)] - data[at(7)]
  let mut k0 = DWA_QUARTER * (a0 + a3)
  let mut k1 = DWA_QUARTER * (a1 + a5)
  let even0 = 0.5F * (k0 + k1)
  let even4 = 0.5F * (k0 - k1)
  let mut rot_x = a2 - a6
  let mut rot_y = a0 - a3
  let even2 = DWA_F * rot_x + DWA_C * rot_y
  let even6 = DWA_F * rot_y - DWA_C * rot_x
  k0 = DWA_QUARTER * (a1 - a5)
  k1 = -DWA_QUARTER * (a2 + a6)
  rot_x = a7 - k0
  rot_y = a4 + k1
  let odd3 = DWA_D * rot_x - DWA_E * rot_y
  let odd5 = DWA_E * rot_x + DWA_D * rot_y
  rot_x = a7 + k0
  rot_y = k1 - a4
  let odd1 = DWA_B * rot_x - DWA_G * rot_y
  let odd7 = DWA_G * rot_x + DWA_B * rot_y
  data[at(0)] = even0
  data[at(1)] = odd1
  data[at(2)] = even2
  data[at(3)] = odd3
  data[at(4)] = even4
  data[at(5)] = odd5
  data[at(6)] = even6
  data[at(7)] = odd7
}

///|
/// Half the cosine of a quarter turn, unhalved: the constant the transform
/// multiplies the sums by before taking half of them.
const DWA_QUARTER : Float = 0.70710678F

///|
/// A coefficient rounded to the coarsest half-float grid within the tolerance of
/// its frequency.
///
/// A grid twice the step means rounding moves the coefficient by at most one
/// step, and the step never exceeds the tolerance. A coefficient smaller than
/// the step becomes nought, which is what a run of noughts in the stream is made
/// of.
fn dwa_quantize(value : Float, step : Float) -> Int32 {
  let bits = @raster.float_to_half(value)
  if step <= 0.0F || (bits & 0x7C00) == 0x7C00 {
    return bits
  }
  let span = step * 2.0F
  let scaled = value / span
  let rounded = if scaled < 0.0F {
    Float::from_double(-(-scaled + 0.5F).to_int().to_double())
  } else {
    Float::from_double((scaled + 0.5F).to_int().to_double())
  }
  @raster.float_to_half(rounded * span)
}

///|
/// The coefficients above the first of a block, with a run of noughts written as
/// one word: the high byte of the word is two hundred and fifty-five, and the
/// low byte is how many noughts there are. The word that means a run of noughts
/// to the end of the block is written as itself, which is how a reader tells it
/// from a run of two hundred and fifty-five.
fn dwa_runs_of_block(zigzag : FixedArray[Int32], ac : Array[Int32]) -> Unit {
  let mut at = 1
  while at < 64 {
    if zigzag[at] != 0 {
      ac.push(zigzag[at])
      at = at + 1
      continue
    }
    let mut run = 1
    while at + run < 64 && zigzag[at + run] == 0 {
      run = run + 1
    }
    if run == 1 {
      ac.push(0)
    } else if at + run == 64 {
      ac.push(0xFF00)
    } else {
      ac.push(0xFF00 | run)
    }
    at = at + run
  }
}

///|
/// The coefficients as the little-endian words the streams hold.
fn dwa_words_out(words : Array[Int32]) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(words.length() * 2, b'\x00')
  for i in 0..<words.length() {
    out[i * 2] = (words[i] & 0xFF).to_byte()
    out[i * 2 + 1] = ((words[i] >> 8) & 0xFF).to_byte()
  }
  Bytes::from_array(out.clamped_view())
}

///|
/// The rule table at the head of the block: a length, then one rule for each
/// suffix that describes a channel of this chunk, in the order the default rules
/// carry them.
///
/// A rule is a name, a nought, a byte that says which of a colour triplet the
/// channel is and how it is compressed, and the type of its samples.
fn dwa_rules_out(rules : Array[DwaRule], channels : Array[Channel]) -> Bytes {
  let body = @wire.Writer::new()
  for rule in rules {
    let mut used = false
    for channel in channels {
      if dwa_rule_matches(rule, dwa_suffix_of(channel.name), channel.kind) {
        used = true
      }
    }
    if !used {
      continue
    }
    body.bytes(@utf8.encode(rule.suffix))
    body.u8(0)
    let tag = ((rule.colour + 1) << 4) |
      (rule.scheme << 2) |
      (if rule.insensitive { 1 } else { 0 })
    body.u8(tag)
    body.u8(rule.kind)
  }
  body.to_bytes()
}

///|
/// The run-length code of the alpha of a chunk, in the shape the reader's
/// expander undoes: a count of nought to one hundred and twenty-seven is that
/// many repeats of the byte after it, and a count of one hundred and twenty-eight
/// to two hundred and fifty-five is a literal run of the bytes after it, of the
/// length the count lacks to two hundred and fifty-six.
fn dwa_runs_pack(data : BytesView) -> Bytes {
  let out = @wire.Writer::new()
  let end = data.length()
  let mut at = 0
  while at < end {
    let mut run = 1
    while at + run < end && data[at + run] == data[at] && run < 128 {
      run = run + 1
    }
    if run >= 3 {
      out.u8(run - 1)
      out.u8(data[at].to_int())
      at = at + run
      continue
    }
    // A literal run: the bytes up to the next three of a kind, and no longer
    // than the count can say.
    let mut take = 0
    let mut cursor = at
    while cursor < end && take < 127 {
      let mut ahead = 1
      while cursor + ahead < end &&
            data[cursor + ahead] == data[cursor] &&
            ahead < 3 {
        ahead = ahead + 1
      }
      if ahead >= 3 {
        break
      }
      cursor = cursor + 1
      take = take + 1
    }
    if take == 0 {
      take = 1
      cursor = at + 1
    }
    out.u8(256 - take)
    for i in 0..<take {
      out.u8(data[at + i].to_int())
    }
    at = at + take
  }
  out.to_bytes()
}

///|
/// One of the eleven counters of the head: a sixty-four-bit number, which no
/// chunk of a picture is large enough to need.
fn dwa_u64(writer : @wire.Writer, value : Int32) -> Unit {
  writer.u32_le(value)
  writer.u32_le(0)
}

///|
/// The averages of a chunk, split into two halves and differenced: the even
/// bytes first, then the odd ones, then each byte as its difference from the one
/// before it. Two neighbouring averages are close, so a table of small numbers
/// is what a coder makes of them.
fn dwa_deconstruct(words : Bytes) -> Bytes {
  let want = words.length()
  let half = (want + 1) / 2
  let split : FixedArray[Byte] = FixedArray::make(want, b'\x00')
  for i in 0..<want {
    if i % 2 == 0 {
      split[i / 2] = words[i]
    } else if half + i / 2 < want {
      split[half + i / 2] = words[i]
    }
  }
  let out : FixedArray[Byte] = FixedArray::make(want, b'\x00')
  out[0] = split[0]
  for i in 1..<want {
    let value = split[i].to_int() - split[i - 1].to_int() + 128
    out[i] = (value & 0xFF).to_byte()
  }
  Bytes::from_array(out.clamped_view())
}
