// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// QOI against the format's own encoder.
//
// Two questions, asked of every fixture: does the file decode to the pixels
// qoi.h read from it, and does encoding those pixels produce the file again. The
// second is the harder one — it fails if a single opcode is chosen differently —
// and it is the reason the format is worth having a second implementation of.

///|
/// The digest the fixtures were generated with: FNV-1a, sixty-four bits, as
/// sixteen hexadecimal digits.
fn digest(bytes : BytesView) -> String {
  let mut value : UInt64 = 0xCBF29CE484222325
  for index in 0..<bytes.length() {
    value = (value ^ bytes[index].to_int().to_uint64()) * 0x100000001B3
  }
  let digits = "0123456789abcdef"
  let mut out = ""
  for index in 0..<16 {
    let shift = (15 - index) * 4
    let nibble = (value >> shift).to_int() & 0xF
    out = out + digits[nibble:nibble + 1].to_owned()
  }
  out
}

///|
fn read(bytes : Bytes) -> @raster.Image {
  @qoi.decode(bytes) catch {
    error => abort("the fixture should decode: \{error}")
  }
}

///|
fn refuses(bytes : Bytes) -> Bool {
  try {
    ignore(@qoi.decode(bytes))
    false
  } catch {
    _ => true
  }
}

///|
test "qoi: every fixture decodes to the pixels the reference read" {
  for entry in qoi_vectors {
    let (name, file, expected) = entry
    let image = read(file)
    assert_eq(
      digest(image.convert(@raster.PixelFormat::Rgba8).pixels),
      expected,
      msg=name,
    )
  }
}

///|
test "qoi: every fixture is reproduced byte for byte" {
  for entry in qoi_vectors {
    let (name, file, _) = entry
    assert_eq(@qoi.encode(read(file)), file, msg=name)
  }
}

///|
/// What one base64 digit stands for. The alphabet is `A-Z`, `a-z`, `0-9`, `+`,
/// `/`; a pad is never looked at, because the length is worked out first.
fn base64_digit(unit : Int32) -> Int32 {
  if unit >= 65 && unit <= 90 {
    unit - 65
  } else if unit >= 97 && unit <= 122 {
    unit - 71
  } else if unit >= 48 && unit <= 57 {
    unit + 4
  } else if unit == 43 {
    62
  } else {
    63
  }
}

///|
/// The bytes a base64 string carries.
///
/// The published test images are photographs and are stored this way so that the
/// fixture file is four and a half megabytes instead of ten. There is one place
/// that reads them, so one decoder is enough.
fn unbase64(text : String) -> Bytes {
  let units = text.code_units()
  let length = units.length()
  let mut padding = 0
  if length > 0 && units[length - 1].to_int() == 61 {
    padding = padding + 1
  }
  if length > 1 && units[length - 2].to_int() == 61 {
    padding = padding + 1
  }
  let count = length / 4 * 3 - padding
  let out : FixedArray[Byte] = FixedArray::make(count, b'\x00')
  let mut at = 0
  let mut write = 0
  while at + 4 <= length {
    let a = base64_digit(units[at].to_int())
    let b = base64_digit(units[at + 1].to_int())
    let c = base64_digit(units[at + 2].to_int())
    let d = base64_digit(units[at + 3].to_int())
    if write < count {
      out[write] = ((a << 2) | (b >> 4)).to_byte()
    }
    if write + 1 < count {
      out[write + 1] = (((b & 0xF) << 4) | (c >> 2)).to_byte()
    }
    if write + 2 < count {
      out[write + 2] = (((c & 0x3) << 6) | d).to_byte()
    }
    at = at + 4
    write = write + 3
  }
  Bytes::from_array(out.clamped_view())
}

///|
test "qoi: the published test images decode, and are written back" {
  for entry in qoi_published {
    let (name, parts, width, height, expected, canonical) = entry
    // The longest picture is two megabytes of base64, which the compiler will
    // not take as one top-level string, so it arrives in pieces.
    let mut encoded = ""
    for part in parts {
      encoded = encoded + part
    }
    let file = unbase64(encoded)
    let image = read(file)
    assert_eq(image.width, width, msg=name)
    assert_eq(image.height, height, msg=name)
    assert_eq(
      digest(image.convert(@raster.PixelFormat::Rgba8).pixels),
      expected,
      msg=name,
    )
    // Seven of the eight are the encoder's own output, so writing the pixels
    // has to give the very bytes that arrived. The eighth, `edgecase`, is a
    // valid encoding that the encoder no longer chooses for those pixels — same
    // length, different opcodes — so for it the comparison is with what the
    // encoder writes, which is recorded beside it.
    let written = @qoi.encode(image)
    if canonical == "" {
      assert_eq(written, file, msg=name)
    } else {
      assert_eq(written, unbase64(canonical), msg=name)
    }
  }
}

///|
test "qoi: a header with no pixels, or with no channels, is refused" {
  let file = qoi_vectors[0].1
  let empty : FixedArray[Byte] = FixedArray::make(file.length(), b'\x00')
  empty.blit_from_bytesview(0, file)
  // width and height zero
  empty[4] = b'\x00'
  empty[5] = b'\x00'
  empty[6] = b'\x00'
  empty[7] = b'\x00'
  assert_true(refuses(Bytes::from_array(empty.clamped_view())))
  // channels two
  let channels = FixedArray::make(file.length(), b'\x00')
  channels.blit_from_bytesview(0, file)
  channels[12] = b'\x02'
  assert_true(refuses(Bytes::from_array(channels.clamped_view())))
  // not a QOI file at all
  assert_true(refuses(b"not a qoi file"))
}

///|
test "qoi: a truncated file is refused, and so is one without its end marker" {
  let file = qoi_vectors[0].1
  assert_true(
    refuses(file.clamped_view(start=0, end=file.length() - 1).to_owned()),
  )
  assert_true(
    refuses(file.clamped_view(start=0, end=file.length() / 2).to_owned()),
  )
  assert_true(refuses(file.clamped_view(start=0, end=20).to_owned()))
}

///|
test "qoi: the limits are checked before the pixels are read" {
  let file = qoi_vectors[0].1
  let limits : @raster.Limits = { width: 2, height: 2, pixels: 4, bytes: 16, }
  let refused = try {
    ignore(@qoi.decode(file, limits~))
    false
  } catch {
    @raster.Refused::OverLimit(..) => true
    _ => false
  }
  assert_true(refused)
}
