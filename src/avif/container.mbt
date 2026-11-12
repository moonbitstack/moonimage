// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The AVIF container: an ISOBMFF file holding one AV1 item.
//
// A still AVIF is a `ftyp` that says the brand is avif, a `meta` that maps an
// item to the boxes describing it, and an `mdat` that holds the item's bytes.
// The mapping is worth doing properly: `iloc` says where the bytes are, `iinf`
// what they are, `iprp`/`ipma` which of the declared properties belong to the
// primary item, and `pitm` which item that is. A reader that assumes there is
// one item with one set of properties reads the first file it is given and then
// fails on a file with a thumbnail.

///|
/// A box: its four-character name and the span of its body.
priv struct Box {
  name : String
  at : Int32
  end : Int32
}

///|
fn be16(bytes : BytesView, at : Int32) -> Int32 {
  (bytes[at].to_int() << 8) | bytes[at + 1].to_int()
}

///|
fn be32(bytes : BytesView, at : Int32) -> Int32 {
  (be16(bytes, at) << 16) | be16(bytes, at + 2)
}

///|
/// An unsigned integer of `count` bytes, big-endian.
fn be_of(bytes : BytesView, at : Int32, count : Int32) -> Int32 {
  let mut value = 0
  for i in 0..<count {
    value = (value << 8) | bytes[at + i].to_int()
  }
  value
}

///|
/// The boxes directly inside a span.
fn boxes(
  bytes : BytesView,
  from : Int32,
  to : Int32,
) -> Array[Box] raise @raster.Refused {
  let out : Array[Box] = []
  let mut at = from
  while at + 8 <= to {
    let size = be32(bytes, at)
    let name = fourcc(bytes, at + 4)
    let mut head = 8
    let total = if size == 1 {
      head = 16
      be32(bytes, at + 12) // the low half of a 64-bit size; a still picture
    } else if size == 0 {
      to - at
    } else {
      size
    }
    if total < head || at.to_int64() + total.to_int64() > to.to_int64() {
      raise @raster.Truncated(at~, want=total)
    }
    let body = at + head
    if name == "uuid" {
      // A uuid box carries sixteen more bytes before its own children.
      out.push({ name, at: body + 16, end: at + total, })
    } else {
      out.push({ name, at: body, end: at + total, })
    }
    at = at + total
  }
  out
}

///|
fn fourcc(bytes : BytesView, at : Int32) -> String {
  let out = StringBuilder()
  for i in 0..<4 {
    out.write_char(bytes[at + i].to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
/// What the `av1C` property says about the AV1 stream inside the item.
pub(all) struct CodecConfig {
  profile : Int32
  level : Int32
  tier : Int32
  high_bitdepth : Bool
  twelve_bit : Bool
  monochrome : Bool
  chroma_subsampling_x : Bool
  chroma_subsampling_y : Bool
  chroma_sample_position : Int32
  delay_present : Bool
  delay : Int32
}

///|
fn read_codec_config(bytes : BytesView, at : Int32, end : Int32) -> CodecConfig {
  if at + 4 > end || (bytes[at].to_int() & 0x80) == 0 {
    abort("the av1C marker is missing")
  }
  let second = bytes[at + 1].to_int()
  let third = bytes[at + 2].to_int()
  let fourth = bytes[at + 3].to_int()
  {
    profile: second >> 5,
    level: second & 0x1F,
    tier: third >> 7,
    high_bitdepth: (third & 0x40) != 0,
    twelve_bit: (third & 0x20) != 0,
    monochrome: (third & 0x10) != 0,
    chroma_subsampling_x: (third & 0x08) != 0,
    chroma_subsampling_y: (third & 0x04) != 0,
    chroma_sample_position: third & 0x03,
    delay_present: (fourth & 0x10) != 0,
    delay: fourth & 0x0F,
  }
}

///|
/// The primary item: its AV1 bytes and the properties the container declares.
pub(all) struct Item {
  data : Bytes
  width : Int32
  height : Int32
  channels : Int32
  bits : Int32
  config : CodecConfig
  primaries : Int32
  transfer : Int32
  matrix : Int32
  full_range : Bool
}

///|
/// One extent of an item: where in the file its bytes begin and how long they
/// are.
priv struct Extent {
  id : Int32
  at : Int32
  length : Int32
}

///|
fn read_iloc(bytes : BytesView, at : Int32, end : Int32) -> Array[Extent] {
  let version = bytes[at].to_int()
  let offset_size = bytes[at + 4].to_int() >> 4
  let length_size = bytes[at + 4].to_int() & 0x0F
  let base_size = bytes[at + 5].to_int() >> 4
  let index_size = bytes[at + 5].to_int() & 0x0F
  let mut cursor = at + 6
  let count = if version < 2 {
    let value = be16(bytes, cursor)
    cursor = cursor + 2
    value
  } else {
    let value = be32(bytes, cursor)
    cursor = cursor + 4
    value
  }
  let out : Array[Extent] = []
  for _ in 0..<count {
    let id = if version < 2 {
      let value = be16(bytes, cursor)
      cursor = cursor + 2
      value
    } else {
      let value = be32(bytes, cursor)
      cursor = cursor + 4
      value
    }
    if version >= 1 {
      cursor = cursor + 2 // construction method
    }
    cursor = cursor + 2 // data reference index
    let base = be_of(bytes, cursor, base_size)
    cursor = cursor + base_size
    let extents = be16(bytes, cursor)
    cursor = cursor + 2
    for _ in 0..<extents {
      if version >= 1 && index_size > 0 {
        cursor = cursor + index_size
      }
      let offset = be_of(bytes, cursor, offset_size)
      cursor = cursor + offset_size
      let length = be_of(bytes, cursor, length_size)
      cursor = cursor + length_size
      out.push({ id, at: base + offset, length, })
    }
    if cursor > end {
      break
    }
  }
  out
}

///|
/// Which of the properties in `ipco` belong to the primary item.
fn read_ipma(
  bytes : BytesView,
  at : Int32,
  end : Int32,
  id : Int32,
) -> Array[Int32] {
  let version = bytes[at].to_int()
  let flags = be_of(bytes, at + 1, 3)
  let count = be32(bytes, at + 4)
  let mut cursor = at + 8
  let out : Array[Int32] = []
  for _ in 0..<count {
    let item = if version < 1 {
      let value = be16(bytes, cursor)
      cursor = cursor + 2
      value
    } else {
      let value = be32(bytes, cursor)
      cursor = cursor + 4
      value
    }
    let associations = bytes[cursor].to_int()
    cursor = cursor + 1
    let indices : Array[Int32] = []
    for _ in 0..<associations {
      let first = bytes[cursor].to_int()
      cursor = cursor + 1
      if (flags & 1) != 0 {
        let second = bytes[cursor].to_int()
        cursor = cursor + 1
        indices.push(((first & 0x3F) << 8) | second)
      } else {
        indices.push(first & 0x7F)
      }
    }
    if item == id {
      out.append(indices)
    }
    if cursor > end {
      break
    }
  }
  out
}

///|
fn wanted_property(indices : Array[Int32], index : Int32) -> Bool {
  if indices.is_empty() {
    return true
  }
  for value in indices {
    if value == index {
      return true
    }
  }
  false
}

///|
/// The primary AV1 item of an AVIF file.
pub fn read_item(bytes : BytesView) -> Item raise @raster.Refused {
  let top = boxes(bytes, 0, bytes.length())
  let mut compatible = false
  let mut meta : Box? = None
  for box in top {
    if box.name == "ftyp" {
      for brand in 0..<((box.end - box.at) / 4) {
        let word = fourcc(bytes, box.at + brand * 4)
        if word == "avif" || word == "avis" {
          compatible = true
        }
      }
    } else if box.name == "meta" {
      meta = Some(box)
    }
  }
  if !compatible {
    raise @raster.Unknown(at=0, got=@raster.hex(bytes, 0, 8))
  }
  let meta = match meta {
    Some(value) => value
    None =>
      raise @raster.Unexpected(
        at=0,
        got="an AVIF without a meta box",
        want="one",
      )
  }
  // A full box: four bytes of version and flags before its children.
  let children = boxes(bytes, meta.at + 4, meta.end)
  let mut primary = -1
  let mut iloc : Box? = None
  let mut ipco : Box? = None
  let mut ipma : Box? = None
  for child in children {
    if child.name == "pitm" {
      primary = be16(bytes, child.at + 4)
    } else if child.name == "iloc" {
      iloc = Some(child)
    } else if child.name == "iprp" {
      for nested in boxes(bytes, child.at, child.end) {
        if nested.name == "ipco" {
          ipco = Some(nested)
        } else if nested.name == "ipma" {
          ipma = Some(nested)
        }
      }
    }
  }
  if primary < 0 {
    raise @raster.Unexpected(
      at=0,
      got="an AVIF without a primary item",
      want="one",
    )
  }
  let location = match iloc {
    Some(value) => value
    None =>
      raise @raster.Unexpected(
        at=0,
        got="an AVIF without an iloc box",
        want="one",
      )
  }
  let mut at = -1
  let mut length = 0
  for extent in read_iloc(bytes, location.at, location.end) {
    if extent.id == primary {
      at = extent.at
      length = extent.length
    }
  }
  if at < 0 || at.to_int64() + length.to_int64() > bytes.length().to_int64() {
    raise @raster.Truncated(at~, want=length)
  }
  let mut width = 0
  let mut height = 0
  let mut channels = 0
  let mut bits = 0
  let mut config : CodecConfig? = None
  let mut primaries = 1
  let mut transfer = 13
  let mut matrix = 6
  let mut full_range = false
  let container = match ipco {
    Some(value) => boxes(bytes, value.at, value.end)
    None => []
  }
  let wanted = match ipma {
    Some(value) => read_ipma(bytes, value.at, value.end, primary)
    None => []
  }
  for i in 0..<container.length() {
    if !wanted_property(wanted, i + 1) {
      continue
    }
    let box = container[i]
    if box.name == "ispe" {
      width = be32(bytes, box.at + 4)
      height = be32(bytes, box.at + 8)
    } else if box.name == "pixi" {
      channels = bytes[box.at + 4].to_int()
      bits = bytes[box.at + 5].to_int()
    } else if box.name == "av1C" {
      config = Some(read_codec_config(bytes, box.at, box.end))
    } else if box.name == "colr" && fourcc(bytes, box.at) == "nclx" {
      primaries = be16(bytes, box.at + 4)
      transfer = be16(bytes, box.at + 6)
      matrix = be16(bytes, box.at + 8)
      full_range = (bytes[box.at + 10].to_int() & 0x80) != 0
    }
  }
  let config = match config {
    Some(value) => value
    None =>
      raise @raster.Unexpected(
        at=0,
        got="an AVIF item without av1C",
        want="one",
      )
  }
  {
    data: bytes[at:at + length].to_owned(),
    width,
    height,
    channels,
    bits,
    config,
    primaries,
    transfer,
    matrix,
    full_range,
  }
}
