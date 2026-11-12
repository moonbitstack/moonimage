// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Every inverse transform is held to the reference decoder's own output.

///|
/// FNV-1a over four little-endian bytes of each table entry, the digest the
/// generator computed before it wrote the tables. A moved row, a wrong scan
/// order or a hand-edited shift all change it.
fn table_digest(data : FixedArray[Int32]) -> String {
  let mut value : UInt64 = 0xCBF29CE484222325
  for i in 0..<data.length() {
    let word = data[i]
    for shift in [0, 8, 16, 24] {
      let byte = (word >> shift) & 0xFF
      value = (value ^ byte.to_uint64()) * 0x100000001B3
    }
  }
  let digits = "0123456789abcdef"
  let mut out = ""
  for place in 0..<16 {
    let nibble = ((value >> ((15 - place) * 4)) & 0xF).to_int()
    out = out + digits[nibble:nibble + 1].to_owned()
  }
  out
}

///|
test "every transform table is the one in the reference decoder" {
  let all : FixedArray[Int32] = []
  for row in [
    itx_dims,
    itx_shift,
    itx_available,
    itx_1d_types,
    itx_scans,
    itx_lnz,
  ] {
    for i in 0..<row.length() {
      all.push(row[i])
    }
  }
  assert_eq(table_digest(all), itx_table_digest)
  assert_eq(itx_table_digest, itx_table_digest_expected)
}

///|
test "the scan offsets walk the tables without a gap" {
  for i in 0..<(itx_scan_offsets.length() - 1) {
    assert_true(itx_scan_offsets[i] < itx_scan_offsets[i + 1])
  }
  assert_eq(itx_scan_offsets[itx_scan_offsets.length() - 1], itx_scans.length())
  assert_eq(itx_scans.length(), itx_lnz.length())
}

///|
test "every one-dimensional transform matches the reference" {
  for i in 0..<(itx_1d_cases.length() / 4) {
    let size = itx_1d_cases[i * 4]
    let kind = itx_1d_cases[i * 4 + 1]
    let n = itx_1d_cases[i * 4 + 2]
    let at = itx_1d_cases[i * 4 + 3]
    let c : FixedArray[Int32] = FixedArray::make(n, 0)
    for k in 0..<n {
      c[k] = itx_1d_values[at + k]
    }
    itx_1d(kind, size, c, 0, 1, -32768, 32767)
    for k in 0..<n {
      let want = itx_1d_values[at + n + k]
      if c[k] != want {
        abort(
          "1D case \{i} (size \{size}, kind \{kind}) at \{k}: got \{c[k]}, want \{want}",
        )
      }
    }
  }
}

///|
test "the Walsh-Hadamard transform matches the reference" {
  for i in 0..<(itx_wht_values.length() / 8) {
    let at = i * 8
    let c : FixedArray[Int32] = FixedArray::make(4, 0)
    for k in 0..<4 {
      c[k] = itx_wht_values[at + k]
    }
    wht4(c, 0, 1)
    for k in 0..<4 {
      let want = itx_wht_values[at + 4 + k]
      if c[k] != want {
        abort("WHT case \{i} at \{k}: got \{c[k]}, want \{want}")
      }
    }
  }
}

///|
test "every two-dimensional transform matches the reference" {
  let count = itx_2d_cases.length() / 7
  for i in 0..<count {
    let tx = itx_2d_cases[i * 7]
    let txtp = itx_2d_cases[i * 7 + 1]
    let eob = itx_2d_cases[i * 7 + 2]
    let w = itx_2d_cases[i * 7 + 3]
    let h = itx_2d_cases[i * 7 + 4]
    let coeff_at = itx_2d_cases[i * 7 + 5]
    let pixel_at = itx_2d_cases[i * 7 + 6]
    let coeff_end = if i + 1 < count {
      itx_2d_cases[(i + 1) * 7 + 5]
    } else {
      itx_2d_coeff.length()
    }
    let coeff : FixedArray[Int32] = FixedArray::make(64 * 64, 0)
    for k in 0..<((coeff_end - coeff_at) / 2) {
      coeff[itx_2d_coeff[coeff_at + 2 * k]] = itx_2d_coeff[coeff_at + 2 * k + 1]
    }
    let dst : FixedArray[Int32] = FixedArray::make(w * h, 0)
    for y in 0..<h {
      for x in 0..<w {
        dst[y * w + x] = (x * 37 + y * 11 + 13) & 255
      }
    }
    inv_txfm_add(dst, 0, w, coeff, eob, tx, txtp)
    for k in 0..<(w * h) {
      let want = itx_2d_pixels[pixel_at + k]
      if dst[k] != want {
        abort(
          "2D case \{i} (tx \{tx}, txtp \{txtp}, eob \{eob}, \{w}x\{h}) at \{k}: got \{dst[k]}, want \{want}",
        )
      }
    }
  }
}
