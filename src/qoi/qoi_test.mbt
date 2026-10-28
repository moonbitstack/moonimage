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
