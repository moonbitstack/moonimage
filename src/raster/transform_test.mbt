// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Turning by an angle that is not a right one, and putting a picture the way up
// a camera said it was.

///|
test "a quarter turn is exact and is handed to the permutation" {
  let image = sample()
  let turned = image.rotate_by(90.0) catch {
    error => abort("the angle is allowed: \{error}")
  }
  assert_eq(turned.width, 2)
  assert_eq(turned.height, 3)
  assert_eq(bytes_of(turned), bytes_of(image.rotate(quarters=1)))
}

///|
test "half a turn of a right angle is still a right angle" {
  let image = sample()
  for quarters in [1, 2, 3] {
    let angle = quarters.to_double() * 90.0
    let turned = image.rotate_by(angle) catch {
      error => abort("the angle is allowed: \{error}")
    }
    assert_eq(bytes_of(turned), bytes_of(image.rotate(quarters~)))
  }
}

///|
test "expanding lays the turned picture on a bigger canvas" {
  // Four wide and two tall, turned a quarter: two wide and four tall.
  let wide = image_of(
    4,
    2,
    @raster.PixelFormat::Rgba8,
    b"\x10\x00\x00\xff\x20\x00\x00\xff\x30\x00\x00\xff\x40\x00\x00\xff" +
    b"\x50\x00\x00\xff\x60\x00\x00\xff\x70\x00\x00\xff\x80\x00\x00\xff",
  )
  let turned = wide.rotate_by(90.0, expand=true) catch {
    error => abort("the angle is allowed: \{error}")
  }
  assert_eq(turned.width, 2)
  assert_eq(turned.height, 4)
  // Expanded, a square canvas would grow; a quarter turn of a rectangle needs
  // only the rectangle it already took.
  let square = image_of(
    2,
    2,
    @raster.PixelFormat::Rgba8,
    b"\x01\x00\x00\xff\x02\x00\x00\xff\x03\x00\x00\xff\x04\x00\x00\xff",
  )
  let diamond = square.rotate_by(45.0, expand=true) catch {
    error => abort("the angle is allowed: \{error}")
  }
  // A two by two square turned forty-five degrees needs a canvas of two root
  // two, rounded up to three.
  assert_eq(diamond.width, 3)
  assert_eq(diamond.height, 3)
}

///|
test "a small angle keeps every pixel near where it was" {
  let flat = image_of(
    4,
    4,
    @raster.PixelFormat::Gray8,
    b"\x40\x40\x40\x40\x40\x40\x40\x40\x40\x40\x40\x40\x40\x40\x40\x40",
  )
  let turned = flat.rotate_by(7.0) catch {
    error => abort("the angle is allowed: \{error}")
  }
  assert_eq(turned.width, 4)
  assert_eq(turned.height, 4)
  // A flat picture stays flat: resampling must not invent an edge.
  for y in 0..<4 {
    for x in 0..<4 {
      assert_eq(at(turned, x, y).0, 64)
    }
  }
}

///|
test "orientation one is the picture it already was" {
  let image = sample()
  assert_eq(
    bytes_of(image.orient(1) catch { _ => abort("one is allowed") }),
    bytes_of(image),
  )
}

///|
test "every orientation is a turn and maybe a flip" {
  let image = image_of(
    3,
    2,
    @raster.PixelFormat::Gray8,
    b"\x10\x20\x30\x40\x50\x60",
  )
  // 2 is a mirror, 3 a half turn, 4 an upside-down mirror.
  assert_eq(
    bytes_of(image.orient(2) catch { _ => abort("two") }),
    bytes_of(image.flip_horizontal()),
  )
  assert_eq(
    bytes_of(image.orient(3) catch { _ => abort("three") }),
    bytes_of(image.rotate(quarters=2)),
  )
  assert_eq(
    bytes_of(image.orient(4) catch { _ => abort("four") }),
    bytes_of(image.flip_vertical()),
  )
  // 5 and 7 mirror across the diagonals, so the canvas changes shape.
  let transposed = image.orient(5) catch { _ => abort("five is allowed") }
  assert_eq(transposed.width, 2)
  assert_eq(transposed.height, 3)
  let transverse = image.orient(7) catch { _ => abort("seven is allowed") }
  assert_eq(transverse.width, 2)
  assert_eq(transverse.height, 3)
  // 5 and 7 are different pictures, not the same one twice.
  assert_true(bytes_of(transposed) != bytes_of(transverse))
  // 6 and 8 are the two quarter turns.
  assert_eq(
    bytes_of(image.orient(6) catch { _ => abort("six") }),
    bytes_of(image.rotate(quarters=1)),
  )
  assert_eq(
    bytes_of(image.orient(8) catch { _ => abort("eight") }),
    bytes_of(image.rotate(quarters=3)),
  )
}

///|
test "a number that is not an orientation is refused" {
  let refused = try {
    ignore(sample().orient(9))
    false
  } catch {
    @raster.Refused::Unexpected(..) => true
    _ => false
  }
  assert_true(refused)
}
