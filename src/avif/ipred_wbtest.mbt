// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Intra prediction, against every block the reference predicted.

///|
/// One case: the edges as the reference saw them, and the block it produced.
test "ipred: every mode, size and angle matches the reference" {
  let count = ipred_cases.length() / 7
  for i in 0..<count {
    let mode = ipred_cases[i * 7]
    let width = ipred_cases[i * 7 + 1]
    let height = ipred_cases[i * 7 + 2]
    let angle = ipred_cases[i * 7 + 3]
    let edge_at = ipred_cases[i * 7 + 5]
    let pixel_at = ipred_cases[i * 7 + 6]
    // A directional walk reaches width + height along either edge, so the
    // buffer has to be that long on both sides of the corner.
    let reach = width + height
    let edges : FixedArray[Byte] = FixedArray::make(2 * reach + 1, b'\x00')
    let corner = reach
    edges[corner] = ipred_edges_at(edge_at).to_byte()
    for k in 0..<reach {
      edges[corner + 1 + k] = ipred_edges_at(edge_at + 1 + k).to_byte()
      edges[corner - 1 - k] = ipred_edges_at(edge_at + 1 + reach + k).to_byte()
    }
    let dst : FixedArray[Byte] = FixedArray::make(width * height, b'\x00')
    predict(dst, width, edges, corner, width, height, mode, angle)
    for k in 0..<(width * height) {
      let want = ipred_pixels_at(pixel_at + k)
      if dst[k].to_int() != want {
        abort(
          "mode \{mode}, \{width}x\{height}, angle \{angle} at \{k}: got \{dst[k].to_int()}, want \{want}",
        )
      }
    }
  }
}
