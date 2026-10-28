// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Chunks: the only structure PNG has.
//
// A chunk is a length, a four-letter type, that many bytes, and a CRC over the
// type and the bytes. The length is what makes a decoder able to skip a chunk it
// does not understand, which is how PNG grew without breaking: an ancillary
// chunk is one whose first letter is lower case, and skipping it is allowed.
//
// The CRC is over the type as well as the data, and covers one chunk rather than
// the file, so a damaged chunk is found where it is rather than at the end.

///|
/// The four bytes that start every PNG, chosen so that a file mangled by a text
/// transfer cannot be mistaken for one.
let signature : Bytes = b"\x89PNG\r\n\x1a\n"

///|
/// A chunk's type, its payload, and where it started, which is what a refusal
/// needs to point at.
priv struct Chunk {
  kind : String
  data : BytesView
  at : Int32
}

///|
/// Read one chunk, checking its CRC.
fn read_chunk(
  cursor : @wire.Cursor,
  check_crc : Bool,
) -> Chunk raise @raster.Refused {
  let at = cursor.at()
  let length = cursor.u32_be()
  let kind = latin1(cursor.bytes(4))
  let data = cursor.bytes(length)
  let stored = cursor.bits_be()
  if check_crc {
    let computed = crc32_of_chunk(kind, data)
    if computed != stored {
      raise @raster.Checksum(
        at=at + 8 + length,
        got=hex_word(stored),
        want=hex_word(computed),
      )
    }
  }
  { kind, data, at, }
}

///|
/// The CRC of a chunk: over the four type bytes and then the payload, which is
/// where a reader that hashes only the payload goes wrong.
fn crc32_of_chunk(kind : String, data : BytesView) -> UInt32 {
  let mut value = 0xFFFF_FFFFU
  for index in 0..<4 {
    value = crc_step(value, kind[index].to_int() & 0xFF)
  }
  for index in 0..<data.length() {
    value = crc_step(value, data[index].to_int())
  }
  value ^ 0xFFFF_FFFFU
}

///|
/// The CRC-32 the format uses: the reflected polynomial 0xEDB88320, one byte at
/// a time, without a table.
///
/// A table would be faster and is what a decoder that spends its time here
/// would use; this one spends its time in the deflate stream, and eight shifts
/// per byte is not where the milliseconds are.
fn crc_step(value : UInt32, byte : Int32) -> UInt32 {
  // Unsigned, because the shift in a CRC is a logical one: a signed shift would
  // drag the top bit down and produce a different checksum for half the inputs.
  let mut crc = value ^ byte.reinterpret_as_uint()
  for _ in 0..<8 {
    crc = if (crc & 1U) != 0U { (crc >> 1) ^ 0xEDB8_8320U } else { crc >> 1 }
  }
  crc
}

///|
/// A thirty-two-bit number as eight hexadecimal digits, for a refusal's `got`
/// and `want`.
fn hex_word(value : UInt32) -> String {
  let digits = "0123456789abcdef"
  let mut out = ""
  for index in 0..<8 {
    let shift = (7 - index) * 4
    let nibble = ((value >> shift) & 0xFU).reinterpret_as_int()
    out = out + digits[nibble:nibble + 1].to_owned()
  }
  out
}

///|
/// Bytes as Latin-1, which is what a chunk type and a `tEXt` keyword are.
///
/// Not UTF-8: the format predates it, and a keyword of `café` is four bytes
/// rather than five.
fn latin1(bytes : BytesView) -> String {
  let characters : Array[Char] = []
  for index in 0..<bytes.length() {
    characters.push(bytes[index].to_int().unsafe_to_char())
  }
  String::from_array(characters.clamped_view())
}

///|
/// Bytes as UTF-8, which is what an `iTXt` chunk carries.
fn utf8_text(bytes : BytesView) -> String {
  @utf8.decode_lossy(bytes)
}
