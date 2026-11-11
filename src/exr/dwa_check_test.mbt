// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The two compressions that store a picture as frequencies, held against the
// reader they were written by.
//
// A digest cannot be the check here. The forward and inverse transforms are done
// in single precision, and the format's own implementation carries two sets of
// constants — one computed, one written into its vectorized path — that already
// disagree with each other in the last bit. Two readings of the same file
// therefore differ by a step of a half at a few samples, and what is worth
// holding to is that they differ by no more than that.

///|
/// How far one reading of a frequency-domain file may be from another. A step of
/// a half around a tenth is about one part in a thousand; this is two of them,
/// which is what the measured difference comes to and twice what it needs to be.
const DWA_TOLERANCE : Double = 0.001953125

///|
test "each DWA sample decodes to the pixels the format's own reader sees" {
  for sample in dwa_samples {
    let (name, file, packed) = sample
    let image = @exr.decode(file) catch { error => abort("\{name}: \{error}") }
    let count = image.width * image.height
    let expected = @zlib.unzlib(packed[:], limit=count * 16) catch {
      _ => abort("\{name}: the pixels it was written with do not inflate")
    }
    if expected.length() != count * 16 {
      abort("\{name}: \{expected.length()} bytes of pixels, want \{count * 16}")
    }
    let mut worst = 0.0
    for i in 0..<count {
      for channel in 0..<4 {
        let at = i * 16 + channel * 4
        let difference = (@raster.float_at(image.pixels, at).to_double() -
        @raster.float_at(expected, at).to_double()).abs()
        if difference > worst {
          worst = difference
        }
      }
    }
    if worst > DWA_TOLERANCE {
      abort("\{name}: differs from the reference by \{worst}")
    }
  }
}
