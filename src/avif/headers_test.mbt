// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The AVIF reader's container and headers, held to libavif's own metadata.

///|
test "the primary item and its headers are the ones the container declares" {
  for case in avif_header_cases {
    let (
      name,
      file,
      width,
      height,
      profile,
      bits,
      ss_hor,
      ss_ver,
      primaries,
      transfer,
      matrix,
      full_range,
      quantizer,
      tile_at,
    ) = case
    let item = @avif.read_item(file) catch {
      error => abort("\{name}: the container: \{error}")
    }
    assert_eq(item.width, width)
    assert_eq(item.height, height)
    assert_eq(item.bits, bits)
    assert_eq(item.config.profile, profile)
    assert_eq(item.primaries, primaries)
    assert_eq(item.transfer, transfer)
    assert_eq(item.matrix, matrix)
    assert_eq(item.full_range, full_range == 1)
    assert_eq(item.config.chroma_subsampling_x, ss_hor == 1)
    assert_eq(item.config.chroma_subsampling_y, ss_ver == 1)
    let headers = @avif.read_headers(item) catch {
      error => abort("\{name}: the headers: \{error}")
    }
    assert_eq(headers.sequence.width, width)
    assert_eq(headers.sequence.height, height)
    assert_eq(headers.sequence.profile, profile)
    assert_eq(headers.sequence.hbd, 0)
    assert_eq(headers.sequence.color_range, full_range == 1)
    assert_eq(headers.sequence.primaries, primaries)
    assert_eq(headers.sequence.transfer, transfer)
    assert_eq(headers.sequence.matrix, matrix)
    assert_eq(headers.sequence.ss_hor, ss_hor)
    assert_eq(headers.sequence.ss_ver, ss_ver)
    assert_eq(headers.frame.yac, quantizer)
    assert_eq(headers.frame.tile_at, tile_at)
    assert_true(headers.frame.tile_length > 0)
    assert_eq(headers.tile.length(), headers.frame.tile_length)
  }
}

///|
test "a still AVIF is one frame with one tile" {
  for case in avif_header_cases {
    let name = case.0
    let file = case.1
    let item = @avif.read_item(file) catch {
      error => abort("\{name}: \{error}")
    }
    let headers = @avif.read_headers(item) catch {
      error => abort("\{name}: \{error}")
    }
    assert_true(headers.sequence.still)
    assert_true(headers.sequence.reduced)
    assert_eq(headers.frame.cols, 1)
    assert_eq(headers.frame.rows, 1)
    assert_eq(headers.frame.n_bytes, 0)
  }
}

///|
test "a file that is not an AVIF is refused by name" {
  let refused = try {
    ignore(@avif.read_item(b"\x00\x00\x00\x10ftypjpeg\x00\x00\x00\x00"))
    false
  } catch {
    @raster.Refused::Unknown(..) => true
    _ => false
  }
  assert_true(refused)
}
