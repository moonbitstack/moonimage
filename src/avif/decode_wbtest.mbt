// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The decoder held to another decoder, whole planes at a time.
//
// AV1 is normative, so there is one right answer for a bitstream and it is not
// this library's opinion. Each sample below was decoded by libdav1d through
// ffmpeg and the three planes hashed; a decoder that is one sample out anywhere
// changes the hash.

///|
/// FNV-1a over the samples, luma first and then each chroma plane, which is the
/// digest the fixture generator computed from the bytes another decoder wrote.
/// One sample is one byte at eight bits, so hashing samples and hashing the
/// file come to the same number.
fn sample_digest(planes : FrameBuffer) -> String {
  let mut value = 0xCBF29CE484222325UL
  fn feed(plane : Plane, w : Int32, h : Int32) -> Unit {
    for y in 0..<h {
      for x in 0..<w {
        value = (value ^ plane.get(x, y).to_uint64()) * 0x100000001B3UL
      }
    }
  }
  feed(planes.y, planes.width, planes.height)
  if !planes.monochrome {
    let cw = (planes.width + planes.ss_hor) >> planes.ss_hor
    let ch = (planes.height + planes.ss_ver) >> planes.ss_ver
    feed(planes.u, cw, ch)
    feed(planes.v, cw, ch)
  }
  let digits = "0123456789abcdef"
  let mut out = ""
  for place in 0..<16 {
    let nibble = ((value >> ((15 - place) * 4)) & 0xFUL).to_int()
    out = out + digits[nibble:nibble + 1].to_owned()
  }
  out
}

///|
test "AVIF decodes to the samples the reference produced" {
  let bad = StringBuilder()
  let mut failures = 0
  for sample in avif_samples {
    let (name, width, height, bytes, expected) = sample
    let planes = decode_planes(bytes) catch {
      error => {
        failures = failures + 1
        bad.write_string("\n  \{name}: refused — \{error}")
        continue
      }
    }
    let size_ok = planes.width == width && planes.height == height
    let got = sample_digest(planes)
    if !size_ok || got != expected {
      failures = failures + 1
      bad.write_string(
        "\n  \{name}: \{planes.width}x\{planes.height} \{got}, want \{width}x\{height} \{expected}",
      )
    }
  }
  if failures > 0 {
    abort(
      "\{failures} of \{avif_samples.length()} samples differ from the reference:" +
      bad.to_string(),
    )
  }
}

///|
test "an AVIF larger than the limits is refused before it is decoded" {
  // The planes are allocated from the sequence header, so the shape is the one
  // thing a caller reading uploads wants checked before anything is written.
  let (_, _, _, bytes, _) = avif_samples[0]
  let tight = @raster.Limits::{ width: 8, height: 8, pixels: 64, bytes: 4096, }
  let refused = try {
    ignore(decode_planes(bytes, limits=tight))
    false
  } catch {
    @raster.Refused::OverLimit(..) => true
    _ => false
  }
  assert_true(refused)
}
