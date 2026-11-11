// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// DWA: a picture stored as the frequencies of its blocks.
//
// The compression an OpenEXR file uses when a photograph matters more than an
// exact pixel. A channel whose name says it is red, green, blue, luminance or a
// chroma difference is turned into frequencies by an eight-by-eight cosine
// transform, quantized, and coded; anything else — alpha, depth, a mask — is
// run-length coded or stored as it came, because the transform would change what
// those channels mean.
//
// Three questions have to be answered before any coefficient can be read, and
// the chunk answers all three itself: which channels go through the transform,
// which three of them go together as a colour, and how the scanlines of the
// chunk are split into blocks. Everything the reader needs is written at the
// head of the data block, so a reader of an older version can still read a file
// written by a newer one.
//
// The head is eleven counters, then one rule per channel suffix, then four
// streams: the coefficients above the first of each block, the first of each
// block, the run-length stream, and whatever was stored whole. The first two are
// entropy coded, the last two deflated.
//
// A block is eight by eight pixels, so the last block of a row or a column is
// partial. Its coefficients describe the whole eight by eight, and only the part
// inside the picture is kept.
//
// The transform is done in single precision, and the constants below are the
// ones the format's own portable path computes as half the cosine of an odd
// multiple of a sixteenth of a turn. Its vectorized path carries constants that
// differ in their last bit, so the two were never identical to begin with.
//
// https://openexr.com/en/latest/TechnicalIntroduction.html

///|
/// How many counters the head of a chunk holds.
const DWA_COUNTERS : Int32 = 11

///|
/// The counters, in the order the format writes them.
const DWA_VERSION : Int32 = 0

///|
const DWA_UNKNOWN_RAW : Int32 = 1

///|
const DWA_UNKNOWN_PACKED : Int32 = 2

///|
const DWA_AC_PACKED : Int32 = 3

///|
const DWA_DC_PACKED : Int32 = 4

///|
const DWA_RLE_PACKED : Int32 = 5

///|
const DWA_RLE_UNPACKED : Int32 = 6

///|
const DWA_RLE_RAW : Int32 = 7

///|
const DWA_AC_COUNT : Int32 = 8

///|
const DWA_DC_COUNT : Int32 = 9

///|
const DWA_AC_METHOD : Int32 = 10

///|
/// How a channel was compressed: stored whole, put through the transform, or
/// run-length coded.
const DWA_STORED : Int32 = 0

///|
const DWA_TRANSFORMED : Int32 = 1

///|
const DWA_RUNS : Int32 = 2

///|
/// How the coefficients above the first of each block were entropy coded.
const DWA_HUFFMAN : Int32 = 0

///|
const DWA_DEFLATE : Int32 = 1

///|
/// Half the cosine of a quarter turn.
const DWA_A : Float = 0.353553623F

///|
/// Half the cosine of a sixteenth of a turn.
const DWA_B : Float = 0.490392655F

///|
/// Half the cosine of an eighth of a turn.
const DWA_C : Float = 0.461939842F

///|
/// Half the cosine of three sixteenths of a turn.
const DWA_D : Float = 0.415734947F

///|
/// Half the cosine of five sixteenths of a turn.
const DWA_E : Float = 0.27778545F

///|
/// Half the cosine of three eighths of a turn.
const DWA_F : Float = 0.19134216F

///|
/// Half the cosine of seven sixteenths of a turn.
const DWA_G : Float = 0.0975457057F

///|
/// What the average of a block is worth, per axis.
const DWA_DC_SCALE : Float = 3.535536e-01F

///|
/// One rule from the head of the chunk: a channel name suffix, what happens to
/// such a channel, and which of a colour triplet it is.
priv struct DwaRule {
  suffix : String
  scheme : Int32
  /// Minus one for a channel that is not part of a colour, nought to two for
  /// one that is: red, green, blue.
  colour : Int32
  /// Whether the suffix is compared without case, which the first version of
  /// the format did: it matched `r` against `R`.
  insensitive : Bool
  /// What a sample of the channel is: nought for an unsigned integer, one for a
  /// half, two for a float.
  kind : Int32
}

///|
/// A channel of the chunk, with what the rules decided about it.
priv struct DwaChannel {
  /// Where the channel is in the file's channel list, which is the order the
  /// stand-alone streams are consumed in.
  index : Int32
  scheme : Int32
  /// The offset of the channel's first sample within a scanline, which comes
  /// after every channel before it in the file's list: a chunk is one channel
  /// after another, not one pixel after another.
  base : Int32
  sample : Int32
  /// Whether the samples are already perceptually uniform, in which case the
  /// curve is not applied to them.
  linear : Bool
}

///|
/// Where the next coefficient of each stream comes from.
priv struct DwaCursor {
  mut ac : Int32
  mut dc : Int32
}

///|
/// A chunk of DWA blocks, as the row-major bytes the rest of the reader wants.
fn dwa_unpack(
  body : BytesView,
  channels : Array[Channel],
  width : Int32,
  lines : Int32,
) -> Bytes raise @raster.Refused {
  let (counts, at, big) = dwa_head(body)
  let version = counts[DWA_VERSION]
  let rules = if version >= 2 {
    let size = dwa_word16(body, at, big)
    dwa_read_rules(body, at + 2, at + size)
  } else {
    dwa_legacy_rules()
  }
  let at = if version >= 2 { at + dwa_word16(body, at, big) } else { at }
  let packed = counts[DWA_UNKNOWN_PACKED] +
    counts[DWA_AC_PACKED] +
    counts[DWA_DC_PACKED] +
    counts[DWA_RLE_PACKED]
  if packed < 0 || at.to_int64() + packed.to_int64() > body.length().to_int64() {
    raise @raster.Truncated(at~, want=packed)
  }
  let window = body.clamped_view(start=at, end=body.length())
  let ac_at = counts[DWA_UNKNOWN_PACKED]
  let dc_at = ac_at + counts[DWA_AC_PACKED]
  let rle_at = dc_at + counts[DWA_DC_PACKED]
  let (order, groups) = dwa_classify(channels, rules, width)
  let row_size = dwa_row_size(channels, width)
  let plane_size = width * lines
  let planes : Array[FixedArray[Int32]] = []
  let decoded : Array[Bool] = []
  for _ in 0..<channels.length() {
    planes.push(FixedArray::make(0, 0))
    decoded.push(false)
  }
  let cursor : DwaCursor = { ac: 0, dc: 0, }
  let ac = dwa_ac_stream(window, counts, ac_at)
  let dc = dwa_dc_stream(window, counts, dc_at)
  let logs = dwa_curve_table(order)
  // A colour triplet is decoded with the curve; a channel on its own is decoded
  // with it unless the header calls the channel perceptually linear.
  for group in groups {
    let members : Array[Int32] = [group[0], group[1], group[2]]
    let flat : Array[FixedArray[Int32]] = []
    for _ in 0..<3 {
      flat.push(FixedArray::make(plane_size, 0))
    }
    dwa_decode_blocks(flat, width, lines, ac, dc, cursor, true, logs)
    for i in 0..<3 {
      planes[members[i]] = flat[i]
      decoded[members[i]] = true
    }
  }
  let out : FixedArray[Byte] = FixedArray::make(row_size * lines, b'\x00')
  let unknown = if counts[DWA_UNKNOWN_PACKED] > 0 {
    dwa_inflate(window, 0, counts[DWA_UNKNOWN_PACKED], counts[DWA_UNKNOWN_RAW])
  } else {
    b""
  }
  let runs = if counts[DWA_RLE_RAW] > 0 {
    let packed_runs = dwa_inflate(
      window,
      rle_at,
      counts[DWA_RLE_PACKED],
      counts[DWA_RLE_UNPACKED],
    )
    expand(packed_runs[:], counts[DWA_RLE_RAW]) catch {
      _ =>
        raise @raster.Unexpected(
          at=0,
          got="a run-length stream that does not decode",
          want="one that does",
        )
    }
  } else {
    b""
  }
  let mut unknown_offset = 0
  let mut runs_offset = 0
  for channel in order {
    match channel.scheme {
      DWA_TRANSFORMED => {
        if !decoded[channel.index] {
          let flat : Array[FixedArray[Int32]] = [
            FixedArray::make(plane_size, 0),
          ]
          dwa_decode_blocks(
            flat,
            width,
            lines,
            ac,
            dc,
            cursor,
            !channel.linear,
            logs,
          )
          planes[channel.index] = flat[0]
          decoded[channel.index] = true
        }
        dwa_write_plane(
          out,
          planes[channel.index],
          channel,
          width,
          lines,
          row_size,
        )
      }
      DWA_RUNS => {
        // The run-length stream holds a channel's bytes split by significance:
        // all of the first byte of every sample, then all of the second.
        let span = plane_size * channel.sample
        if runs_offset + span > runs.length() {
          raise @raster.Truncated(at=runs_offset, want=span)
        }
        for line in 0..<lines {
          let row = line * row_size + channel.base
          for x in 0..<width {
            for byte in 0..<channel.sample {
              out[row + x * channel.sample + byte] = runs[runs_offset +
                byte * plane_size +
                line * width +
                x]
            }
          }
        }
        runs_offset = runs_offset + span
      }
      _ => {
        let span = width * channel.sample
        if unknown_offset + span * lines > unknown.length() {
          raise @raster.Truncated(at=unknown_offset, want=span * lines)
        }
        for line in 0..<lines {
          let to = line * row_size + channel.base
          for i in 0..<span {
            out[to + i] = unknown[unknown_offset + line * span + i]
          }
        }
        unknown_offset = unknown_offset + span * lines
      }
    }
  }
  Bytes::from_array(out.clamped_view())
}

///|
/// The head of a chunk: eleven counters and where the rules begin.
///
/// The counters say how long each stream is, and the version of the block says
/// whether the rules follow them. They are a run of sixty-four-bit numbers that
/// the writer stores in the order its machine keeps them, which is what the
/// reference implementation does: on the machine this library is built for that
/// is little-endian, and a file from a big-endian writer has the same numbers
/// the other way round. Which of the two it is can be told from the numbers
/// themselves — a version above two, or streams longer than the chunk, are not
/// something a writer meant — so both are tried, smallest first.
fn dwa_head(
  body : BytesView,
) -> (FixedArray[Int32], Int32, Bool) raise @raster.Refused {
  let head = DWA_COUNTERS * 8
  if body.length() < head {
    raise @raster.Truncated(at=0, want=head)
  }
  match dwa_head_in(body, false) {
    Some(counts) => (counts, head, false)
    None =>
      match dwa_head_in(body, true) {
        Some(counts) => (counts, head, true)
        None =>
          raise @raster.Unexpected(
            at=0,
            got="a head whose streams do not fit the chunk",
            want="eleven counters a writer meant",
          )
      }
  }
}

///|
/// The counters read in one byte order, or nothing when they cannot be what a
/// writer wrote.
fn dwa_head_in(body : BytesView, big : Bool) -> FixedArray[Int32]? {
  let head = DWA_COUNTERS * 8
  let counts : FixedArray[Int32] = FixedArray::make(DWA_COUNTERS, 0)
  for i in 0..<DWA_COUNTERS {
    let at = i * 8
    let low = dwa_word32(body, at, big)
    let high = dwa_word32(body, at + 4, big)
    if high != 0 || low < 0 {
      return None
    }
    counts[i] = low
  }
  if counts[DWA_VERSION] > 2 {
    return None
  }
  let packed = counts[DWA_UNKNOWN_PACKED] +
    counts[DWA_AC_PACKED] +
    counts[DWA_DC_PACKED] +
    counts[DWA_RLE_PACKED]
  if packed < 0 ||
    head.to_int64() + packed.to_int64() > body.length().to_int64() {
    return None
  }
  // The rule table, when the version says there is one, has to fit too.
  if counts[DWA_VERSION] >= 2 {
    if head + 2 > body.length() {
      return None
    }
    let size = dwa_word16(body, head, big)
    if size < 2 || head + size > body.length() {
      return None
    }
    if head.to_int64() + size.to_int64() + packed.to_int64() >
      body.length().to_int64() {
      return None
    }
  }
  Some(counts)
}

///|
/// A thirty-two-bit number of the head, in the byte order the head was found in.
fn dwa_word32(body : BytesView, at : Int32, big : Bool) -> Int32 {
  if big {
    (body[at].to_int() << 24) |
    (body[at + 1].to_int() << 16) |
    (body[at + 2].to_int() << 8) |
    body[at + 3].to_int()
  } else {
    (body[at + 3].to_int() << 24) |
    (body[at + 2].to_int() << 16) |
    (body[at + 1].to_int() << 8) |
    body[at].to_int()
  }
}

///|
/// A sixteen-bit number of the head, in the byte order the head was found in.
fn dwa_word16(body : BytesView, at : Int32, big : Bool) -> Int32 {
  if big {
    (body[at].to_int() << 8) | body[at + 1].to_int()
  } else {
    (body[at + 1].to_int() << 8) | body[at].to_int()
  }
}

///|
/// The rules at the head of a version-two block: a suffix, a byte that says
/// which scheme and which of a colour triplet, and the sample type.
fn dwa_read_rules(
  body : BytesView,
  start : Int32,
  end : Int32,
) -> Array[DwaRule] raise @raster.Refused {
  let rules : Array[DwaRule] = []
  let mut at = start
  while at < end {
    let name = cstring(body, at)
    at = name.1
    if at + 2 > end {
      raise @raster.Truncated(at~, want=2)
    }
    let tag = body[at].to_int()
    let kind = body[at + 1].to_int()
    at = at + 2
    let colour = (tag >> 4) - 1
    if colour < -1 || colour > 2 {
      raise @raster.Unexpected(
        at=at - 2,
        got="a colour index of \{colour}",
        want="minus one to two",
      )
    }
    let scheme = (tag >> 2) & 3
    if scheme > 2 {
      raise @raster.Unexpected(
        at=at - 2,
        got="a scheme of \{scheme}",
        want="nought to two",
      )
    }
    if kind > 2 {
      raise @raster.Unexpected(
        at=at - 1,
        got="a sample type of \{kind}",
        want="nought to two",
      )
    }
    rules.push({
      suffix: name.0,
      scheme,
      colour,
      insensitive: (tag & 1) != 0,
      kind,
    })
  }
  rules
}

///|
/// The rules of a block older than the second version, in which they were not
/// written down and only red, green, blue, luminance, the two chroma
/// differences and alpha were understood.
fn dwa_legacy_rules() -> Array[DwaRule] {
  let rules : Array[DwaRule] = []
  for (suffix, colour) in [("r", 0), ("g", 1), ("b", 2)] {
    for kind in [1, 2] {
      rules.push({
        suffix,
        scheme: DWA_TRANSFORMED,
        colour,
        insensitive: true,
        kind,
      })
    }
  }
  for suffix in ["y", "by", "ry"] {
    for kind in [1, 2] {
      rules.push({
        suffix,
        scheme: DWA_TRANSFORMED,
        colour: -1,
        insensitive: true,
        kind,
      })
    }
  }
  for kind in [0, 1, 2] {
    rules.push({
      suffix: "a",
      scheme: DWA_RUNS,
      colour: -1,
      insensitive: true,
      kind,
    })
  }
  rules
}

///|
/// A string in lower case, for a rule that is compared without case.

///|
/// Whether a rule describes a channel.
fn dwa_rule_matches(rule : DwaRule, suffix : String, kind : Int32) -> Bool {
  rule.kind == kind &&
  (if rule.insensitive {
    suffix.to_lower() == rule.suffix
  } else {
    suffix == rule.suffix
  })
}

///|
/// The channels of the chunk, each with the scheme the rules gave it, and the
/// colour triplets among them.
///
/// A triplet is decoded before the channels that stand alone, and the
/// coefficients are consumed in that order, so this list is also the order the
/// streams are read in.
fn dwa_classify(
  channels : Array[Channel],
  rules : Array[DwaRule],
  width : Int32,
) -> (Array[DwaChannel], Array[FixedArray[Int32]]) {
  let order : Array[DwaChannel] = []
  let prefixes : Array[String] = []
  let members : Array[FixedArray[Int32]] = []
  let mut base = 0
  for index in 0..<channels.length() {
    let channel = channels[index]
    let dot = dwa_last_dot(channel.name)
    let suffix = if dot < 0 {
      channel.name
    } else {
      channel.name[dot + 1:].to_owned()
    }
    let prefix = if dot < 0 { "" } else { channel.name[:dot].to_owned() }
    let mut scheme = DWA_STORED
    let mut colour = -1
    for rule in rules {
      if dwa_rule_matches(rule, suffix, channel.kind) {
        scheme = rule.scheme
        if rule.colour >= 0 {
          colour = rule.colour
        }
      }
    }
    let mut group = -1
    for i in 0..<prefixes.length() {
      if prefixes[i] == prefix {
        group = i
      }
    }
    if group < 0 && colour >= 0 {
      prefixes.push(prefix)
      members.push(FixedArray::make(3, -1))
      group = prefixes.length() - 1
    }
    if group >= 0 && colour >= 0 {
      members[group][colour] = index
    }
    order.push({
      index,
      scheme,
      base,
      sample: channel.sample,
      linear: channel.linear,
    })
    base = base + width * channel.sample
  }
  let groups : Array[FixedArray[Int32]] = []
  for i in 0..<members.length() {
    let group = members[i]
    if group[0] >= 0 && group[1] >= 0 && group[2] >= 0 {
      groups.push(group)
    }
  }
  (order, groups)
}

///|
/// Where the last dot of a channel name is, or minus one. The layer of a channel
/// is the part before it, and the three channels of a colour share one.
fn dwa_last_dot(name : String) -> Int32 {
  let mut found = -1
  for i in 0..<name.length() {
    if name[i] == '.' {
      found = i
    }
  }
  found
}

///|
/// How many bytes one scanline of every channel takes.
fn dwa_row_size(channels : Array[Channel], width : Int32) -> Int32 {
  let mut total = 0
  for channel in channels {
    total = total + width * channel.sample
  }
  total
}

///|
/// The table that turns a coefficient back into a linear sample, built once for
/// the file rather than once for each chunk, and only when a channel needs it.
fn dwa_curve_table(order : Array[DwaChannel]) -> FixedArray[Int32] {
  let mut needed = false
  for channel in order {
    if channel.scheme == DWA_TRANSFORMED {
      needed = true
    }
  }
  if needed {
    dwa_linear_table()
  } else {
    []
  }
}

///|
/// `e` raised to two and a fifth, which is where the two halves of the curve
/// meet: below one it is a power, above it a logarithm of the same base, and at
/// one the two agree.
const DWA_LOG_BASE : Double = 9.025013291561939

///|
/// The curve that turns a sample back to linear light, over every half.
///
/// A value up to one comes back as its two-and-a-fifth power, which is the
/// curve a display has; above one, where a power would leave the range, it comes
/// back as a logarithm of the same base, which is what keeps a picture of a light
/// source from clipping. A value that is not finite becomes nought, and a
/// negative one keeps its sign.
///
/// Two of the sixty-five thousand entries come out of a double-precision power
/// one step from where the single-precision one of the format's own generator
/// put them, and they are written down rather than approximated.
fn dwa_linear_table() -> FixedArray[Int32] {
  let table : FixedArray[Int32] = FixedArray::make(65536, 0)
  for bits in 0..<65536 {
    if (bits & 0x7C00) == 0x7C00 {
      table[bits] = 0
      continue
    }
    let value = @raster.half_to_float(bits).to_double()
    let sign = if value < 0.0 { -1.0 } else { 1.0 }
    let magnitude = if value < 0.0 { -value } else { value }
    let mapped = if magnitude <= 1.0 {
      sign * @math.pow(magnitude, 2.2)
    } else {
      sign * @math.pow(DWA_LOG_BASE, magnitude - 1.0)
    }
    table[bits] = @raster.float_to_half(Float::from_double(mapped))
  }
  table[9464] = 0x099C
  table[42232] = 0x899C
  table
}

///|
/// A deflated stream of a chunk.
fn dwa_inflate(
  window : BytesView,
  at : Int32,
  packed : Int32,
  raw : Int32,
) -> Bytes raise @raster.Refused {
  if at + packed > window.length() {
    raise @raster.Truncated(at~, want=packed)
  }
  if packed == 0 {
    if raw == 0 {
      return b""
    }
    raise @raster.Truncated(at~, want=packed)
  }
  let inflated = @zlib.unzlib(
    window.clamped_view(start=at, end=at + packed),
    limit=raw,
  ) catch {
    _ =>
      raise @raster.Unexpected(
        at~,
        got="a deflate stream that does not inflate",
        want="the stream the counters describe",
      )
  }
  if inflated.length() != raw {
    raise @raster.Truncated(at~, want=raw - inflated.length())
  }
  inflated
}

///|
/// The coefficients above the first of every block, as sixteen-bit words.
fn dwa_ac_stream(
  window : BytesView,
  counts : FixedArray[Int32],
  at : Int32,
) -> FixedArray[Int32] raise @raster.Refused {
  let packed = counts[DWA_AC_PACKED]
  let count = counts[DWA_AC_COUNT]
  if packed == 0 || count == 0 {
    return []
  }
  if at + packed > window.length() {
    raise @raster.Truncated(at~, want=packed)
  }
  let view = window.clamped_view(start=at, end=at + packed)
  let out : FixedArray[Int32] = FixedArray::make(count, 0)
  match counts[DWA_AC_METHOD] {
    DWA_HUFFMAN => {
      let words = huffman_decode(view, count)
      for i in 0..<count {
        out[i] = words[i].reinterpret_as_int() & 0xFFFF
      }
    }
    DWA_DEFLATE => {
      let raw = @zlib.unzlib(view, limit=count * 2) catch {
        _ =>
          raise @raster.Unexpected(
            at~,
            got="a deflate stream that does not inflate",
            want="the coefficients the head describes",
          )
      }
      let words = dwa_words(raw[:], count)
      for i in 0..<count {
        out[i] = words[i]
      }
    }
    _ =>
      raise @raster.Unsupported(
        at~,
        got="coefficients coded a way this library does not read",
      )
  }
  out
}

///|
/// The first coefficient of every block, as sixteen-bit words.
fn dwa_dc_stream(
  window : BytesView,
  counts : FixedArray[Int32],
  at : Int32,
) -> FixedArray[Int32] raise @raster.Refused {
  let packed = counts[DWA_DC_PACKED]
  let count = counts[DWA_DC_COUNT]
  if packed == 0 || count == 0 {
    return []
  }
  if at + packed > window.length() {
    raise @raster.Truncated(at~, want=packed)
  }
  let raw = @zlib.unzlib(
    window.clamped_view(start=at, end=at + packed),
    limit=count * 2,
  ) catch {
    _ =>
      raise @raster.Unexpected(
        at~,
        got="a deflate stream that does not inflate",
        want="the coefficients the head describes",
      )
  }
  // The averages are deflated the way every deflate stream in this format is:
  // the bytes were split into two halves and differenced before the coder saw
  // them, which is what makes a run of small numbers out of a run of samples.
  dwa_words(reorder(raw, count * 2)[:], count)
}

///|
/// A run of little-endian sixteen-bit words, as numbers.
fn dwa_words(
  bytes : BytesView,
  count : Int32,
) -> FixedArray[Int32] raise @raster.Refused {
  if bytes.length() < count * 2 {
    raise @raster.Truncated(at=bytes.length(), want=count * 2 - bytes.length())
  }
  let out : FixedArray[Int32] = FixedArray::make(count, 0)
  for i in 0..<count {
    out[i] = le16(bytes, i * 2)
  }
  out
}

///|
/// The coefficients of one block, read back into halves: the first written, then
/// the ones that follow it in zig-zag order, with a run of zeroes written as a
/// single word.
///
/// Returns where the last coefficient that is not nought sits in zig-zag order,
/// which is how much of the block the inverse transform has to visit.
fn dwa_unrle(
  ac : FixedArray[Int32],
  cursor : DwaCursor,
  zig : FixedArray[Int32],
) -> Int32 raise @raster.Refused {
  let mut at = 1
  let mut last = 0
  while at < 64 {
    if cursor.ac >= ac.length() {
      raise @raster.Truncated(at=cursor.ac, want=1)
    }
    let word = ac[cursor.ac]
    cursor.ac = cursor.ac + 1
    if word == 0xFF00 {
      // The end of a block, written by the second version of the format and
      // every one after it.
      at = 64
    } else if word >> 8 == 0xFF {
      // A run: the low byte is how many coefficients are nought.
      at = at + (word & 0xFF)
    } else {
      last = at
      zig[at] = word
      at = at + 1
    }
  }
  last
}

///|
/// The eight-by-eight blocks of one channel, or of three that share a colour,
/// decoded into planes of half-float bits.
fn dwa_decode_blocks(
  planes : Array[FixedArray[Int32]],
  width : Int32,
  height : Int32,
  ac : FixedArray[Int32],
  dc : FixedArray[Int32],
  cursor : DwaCursor,
  curve : Bool,
  logs : FixedArray[Int32],
) -> Unit raise @raster.Refused {
  let components = planes.length()
  let blocks_across = (width + 7) / 8
  let blocks_down = (height + 7) / 8
  let zig : FixedArray[Int32] = FixedArray::make(64, 0)
  let block : FixedArray[Float] = FixedArray::make(64, 0.0F)
  let coefficients : Array[FixedArray[Float]] = []
  for _ in 0..<components {
    coefficients.push(FixedArray::make(64, 0.0F))
  }
  // The averages of a colour are three streams laid one after the other, so the
  // first average of the second channel is a whole plane of blocks past the
  // first of the first. The coefficients above them are one stream.
  let blocks_total = blocks_across * blocks_down
  let dc_base = cursor.dc
  cursor.dc = dc_base + blocks_total * components
  let mut by = 0
  while by < blocks_down {
    let rows = if by == blocks_down - 1 { height - by * 8 } else { 8 }
    let mut bx = 0
    while bx < blocks_across {
      let columns = if bx == blocks_across - 1 { width - bx * 8 } else { 8 }
      let block_index = by * blocks_across + bx
      let mut constant = true
      for component in 0..<components {
        for i in 0..<64 {
          zig[i] = 0
        }
        let slot = dc_base + component * blocks_total + block_index
        if slot >= dc.length() {
          raise @raster.Truncated(at=slot, want=1)
        }
        zig[0] = dc[slot]
        let last = dwa_unrle(ac, cursor, zig)
        if last == 0 {
          // Nothing but the average of the block. The inverse transform of a
          // block with one coefficient is a flat block, and this is its value.
          let value = @raster.half_to_float(zig[0]) *
            DWA_DC_SCALE *
            DWA_DC_SCALE
          for i in 0..<64 {
            coefficients[component][i] = value
          }
        } else {
          constant = false
          dwa_from_zigzag(zig, block)
          for i in 0..<64 {
            coefficients[component][i] = block[i]
          }
          dwa_inverse(coefficients[component], dwa_zeroed_rows(last))
        }
      }
      if components == 3 {
        if constant {
          dwa_undo_colour(coefficients[0], coefficients[1], coefficients[2], 0)
          for component in 0..<3 {
            let value = coefficients[component][0]
            for i in 0..<64 {
              coefficients[component][i] = value
            }
          }
        } else {
          for i in 0..<64 {
            dwa_undo_colour(
              coefficients[0],
              coefficients[1],
              coefficients[2],
              i,
            )
          }
        }
      }
      for component in 0..<components {
        let plane = planes[component]
        let values = coefficients[component]
        for dy in 0..<rows {
          let row = (by * 8 + dy) * width + bx * 8
          for dx in 0..<columns {
            let bits = @raster.float_to_half(values[dy * 8 + dx])
            plane[row + dx] = if curve { logs[bits] } else { bits }
          }
        }
      }
      bx = bx + 1
    }
    by = by + 1
  }
}

///|
/// How many of the last rows of a block are all nought, from where the last
/// coefficient that is not nought sits in zig-zag order.
///
/// The zig-zag order visits the low frequencies first, so a block whose last
/// coefficient is early has whole rows of nought at the bottom, and the inverse
/// transform does not have to visit them.
fn dwa_zeroed_rows(last : Int32) -> Int32 {
  if last < 2 {
    7
  } else if last < 3 {
    6
  } else if last < 9 {
    5
  } else if last < 10 {
    4
  } else if last < 20 {
    3
  } else if last < 21 {
    2
  } else if last < 35 {
    1
  } else {
    0
  }
}

///|
/// Where each coefficient of a zig-zag block sits in the block itself: the row
/// and the column of the block, left to right and top to bottom.
fn dwa_zigzag_order() -> FixedArray[Int32] {
  [
    0, 1, 5, 6, 14, 15, 27, 28, 2, 4, 7, 13, 16, 26, 29, 42, 3, 8, 12, 17, 25, 30,
    41, 43, 9, 11, 18, 24, 31, 40, 44, 53, 10, 19, 23, 32, 39, 45, 52, 54, 20, 22,
    33, 38, 46, 51, 55, 60, 21, 34, 37, 47, 50, 56, 59, 61, 35, 36, 48, 49, 57, 58,
    62, 63,
  ]
}

///|
/// A block in zig-zag order as a block in the order the inverse transform reads.
fn dwa_from_zigzag(zig : FixedArray[Int32], block : FixedArray[Float]) -> Unit {
  let order = dwa_zigzag_order()
  for i in 0..<64 {
    block[i] = @raster.half_to_float(zig[order[i]])
  }
}

///|
/// The inverse of the eight-by-eight cosine transform, in place, with the last
/// `zeroed` rows known to be nought and left unvisited.
fn dwa_inverse(data : FixedArray[Float], zeroed : Int32) -> Unit {
  let alpha : FixedArray[Float] = FixedArray::make(4, 0.0F)
  let beta : FixedArray[Float] = FixedArray::make(4, 0.0F)
  let theta : FixedArray[Float] = FixedArray::make(4, 0.0F)
  let gamma : FixedArray[Float] = FixedArray::make(4, 0.0F)
  let mut row = 0
  while row < 8 - zeroed {
    let base = row * 8
    alpha[0] = DWA_C * data[base + 2]
    alpha[1] = DWA_F * data[base + 2]
    alpha[2] = DWA_C * data[base + 6]
    alpha[3] = DWA_F * data[base + 6]
    beta[0] = DWA_B * data[base + 1] +
      DWA_D * data[base + 3] +
      DWA_E * data[base + 5] +
      DWA_G * data[base + 7]
    beta[1] = DWA_D * data[base + 1] -
      DWA_G * data[base + 3] -
      DWA_B * data[base + 5] -
      DWA_E * data[base + 7]
    beta[2] = DWA_E * data[base + 1] -
      DWA_B * data[base + 3] +
      DWA_G * data[base + 5] +
      DWA_D * data[base + 7]
    beta[3] = DWA_G * data[base + 1] -
      DWA_E * data[base + 3] +
      DWA_D * data[base + 5] -
      DWA_B * data[base + 7]
    theta[0] = DWA_A * (data[base] + data[base + 4])
    theta[3] = DWA_A * (data[base] - data[base + 4])
    theta[1] = alpha[0] + alpha[3]
    theta[2] = alpha[1] - alpha[2]
    gamma[0] = theta[0] + theta[1]
    gamma[1] = theta[3] + theta[2]
    gamma[2] = theta[3] - theta[2]
    gamma[3] = theta[0] - theta[1]
    data[base] = gamma[0] + beta[0]
    data[base + 1] = gamma[1] + beta[1]
    data[base + 2] = gamma[2] + beta[2]
    data[base + 3] = gamma[3] + beta[3]
    data[base + 4] = gamma[3] - beta[3]
    data[base + 5] = gamma[2] - beta[2]
    data[base + 6] = gamma[1] - beta[1]
    data[base + 7] = gamma[0] - beta[0]
    row = row + 1
  }
  for column in 0..<8 {
    alpha[0] = DWA_C * data[16 + column]
    alpha[1] = DWA_F * data[16 + column]
    alpha[2] = DWA_C * data[48 + column]
    alpha[3] = DWA_F * data[48 + column]
    beta[0] = DWA_B * data[8 + column] +
      DWA_D * data[24 + column] +
      DWA_E * data[40 + column] +
      DWA_G * data[56 + column]
    beta[1] = DWA_D * data[8 + column] -
      DWA_G * data[24 + column] -
      DWA_B * data[40 + column] -
      DWA_E * data[56 + column]
    beta[2] = DWA_E * data[8 + column] -
      DWA_B * data[24 + column] +
      DWA_G * data[40 + column] +
      DWA_D * data[56 + column]
    beta[3] = DWA_G * data[8 + column] -
      DWA_E * data[24 + column] +
      DWA_D * data[40 + column] -
      DWA_B * data[56 + column]
    theta[0] = DWA_A * (data[column] + data[32 + column])
    theta[3] = DWA_A * (data[column] - data[32 + column])
    theta[1] = alpha[0] + alpha[3]
    theta[2] = alpha[1] - alpha[2]
    gamma[0] = theta[0] + theta[1]
    gamma[1] = theta[3] + theta[2]
    gamma[2] = theta[3] - theta[2]
    gamma[3] = theta[0] - theta[1]
    data[column] = gamma[0] + beta[0]
    data[8 + column] = gamma[1] + beta[1]
    data[16 + column] = gamma[2] + beta[2]
    data[24 + column] = gamma[3] + beta[3]
    data[32 + column] = gamma[3] - beta[3]
    data[40 + column] = gamma[2] - beta[2]
    data[48 + column] = gamma[1] - beta[1]
    data[56 + column] = gamma[0] - beta[0]
  }
}

///|
/// One coefficient of a colour triplet back to red, green and blue.
///
/// The forward transform took the luminance and the two differences from it with
/// the coefficients of the same standard; this puts them back. Red and blue keep
/// the luminance and add one difference each, and green loses a little of both,
/// which is what makes the three sum back to what they were.
fn dwa_undo_colour(
  red : FixedArray[Float],
  green : FixedArray[Float],
  blue : FixedArray[Float],
  at : Int32,
) -> Unit {
  let luminance = red[at]
  // The two differences travel in the slots of the green and the blue channel,
  // not in the order a reader expects: the first is the difference of blue from
  // the luminance, the second of red.
  let blue_away = green[at]
  let red_away = blue[at]
  red[at] = luminance + 1.5747F * red_away
  green[at] = luminance - 0.1873F * blue_away - 0.4682F * red_away
  blue[at] = luminance + 1.8556F * blue_away
}

///|
/// A decoded plane of a channel written into the chunk's scanlines.
fn dwa_write_plane(
  out : FixedArray[Byte],
  plane : FixedArray[Int32],
  channel : DwaChannel,
  width : Int32,
  lines : Int32,
  row_size : Int32,
) -> Unit {
  for line in 0..<lines {
    for x in 0..<width {
      let at = line * row_size + channel.base + x * channel.sample
      let bits = plane[line * width + x]
      if channel.sample == 2 {
        out[at] = (bits & 0xFF).to_byte()
        out[at + 1] = ((bits >> 8) & 0xFF).to_byte()
      } else {
        // A float channel goes through the transform as halves, so what comes
        // back is a half converted up rather than the float that went in.
        let value = @raster.half_to_float(bits)
        let word = value.reinterpret_as_uint().reinterpret_as_int()
        out[at] = (word & 0xFF).to_byte()
        out[at + 1] = ((word >> 8) & 0xFF).to_byte()
        out[at + 2] = ((word >> 16) & 0xFF).to_byte()
        out[at + 3] = ((word >> 24) & 0xFF).to_byte()
      }
    }
  }
}
