// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The AV1 multi-symbol arithmetic decoder.
//
// A tile's syntax is a stream of symbols, each drawn from a cumulative
// distribution of up to fifteen probabilities in Q15. The coder keeps a window
// of bits in `dif` and an interval width in `rng`; every symbol narrows the
// interval, and renormalisation shifts both back up while pulling more bytes
// from the tile. Read a symbol and the distribution adapts: the entries before
// the one that was read move towards 32768 and the rest towards zero, at a rate
// that slows as the count grows.
//
// The arithmetic follows the reference decoder exactly, including its rounding
// constants (EC_MIN_PROB, EC_PROB_SHIFT), because a difference of one in a
// split changes which symbol comes out and everything after it.

///|
/// The window is sixty-four bits, the probability scale fifteen.
let ec_min_prob : Int32 = 4

///|
let ec_prob_shift : Int32 = 6

///|
let ec_win_size : Int32 = 64

///|
pub(all) struct Msac {
  data : BytesView
  mut pos : Int32
  mut dif : UInt64
  mut rng : Int32
  mut cnt : Int32
  allow_update : Bool
}

///|
pub fn Msac::new(data : BytesView, allow_update? : Bool) -> Msac {
  let coder = {
    data,
    pos: 0,
    dif: 0UL,
    rng: 0x8000,
    cnt: -15,
    allow_update: allow_update.unwrap_or(true),
  }
  coder.refill()
  coder
}

///|
/// Fill the window from the tile. Past the end the remaining bits read as ones,
/// which is what a decoder that asks for a byte or two beyond the last symbol
/// sees; the encoder is allowed not to have written them.
pub fn Msac::refill(self : Msac) -> Unit {
  let mut c = ec_win_size - self.cnt - 24
  let mut dif = self.dif
  while true {
    if self.pos >= self.data.length() {
      // ~(~0xff << c): the low c + 8 bits of the window.
      let mask = if c + 8 >= ec_win_size {
        0xFFFFFFFFFFFFFFFFUL
      } else {
        (1UL << (c + 8)) - 1UL
      }
      dif = dif | mask
      break
    }
    let byte = self.data[self.pos].to_int() ^ 0xFF
    dif = dif | (byte.to_uint64() << c)
    self.pos = self.pos + 1
    c = c - 8
    if c < 0 {
      break
    }
  }
  self.dif = dif
  self.cnt = ec_win_size - c - 24
}

///|
/// The position of the highest set bit: `ulog2` in the reference.
pub fn floor_log2(value : Int32) -> Int32 {
  let mut left = value
  let mut bits = -1
  while left > 0 {
    bits = bits + 1
    left = left >> 1
  }
  bits
}

///|
/// How far a range has to be shifted to put it back in [32768, 65536).
pub fn norm_shift(range : Int32) -> Int32 {
  15 - floor_log2(range)
}

///|
/// Renormalise after a symbol: both ends of the interval move up by the same
/// shift, and a refill follows when the window has fewer bits left than that.
pub fn Msac::norm(self : Msac, dif : UInt64, range : Int32) -> Unit {
  let d = norm_shift(range)
  self.dif = dif << d
  self.rng = range << d
  let old = self.cnt
  self.cnt = old - d
  // The reference compares these as unsigned. At the end of a tile `cnt` can
  // go negative, and a negative count is a huge unsigned number: no refill.
  // Comparing them as signed would refill once more and OR ones into the low
  // bits of the window, which is exactly the "redundant refills at eob" the
  // unsigned compare exists to avoid.
  if old >= 0 && old < d {
    self.refill()
  }
}

///|
/// One bit at even odds.
pub fn Msac::bool_equi(self : Msac) -> Int32 {
  let r = self.rng
  let dif = self.dif
  let mut v = ((r >> 8) << 7) + ec_min_prob
  let vw = v.to_uint64() << (ec_win_size - 16)
  let taken = if dif >= vw { 1 } else { 0 }
  let dif = if taken == 1 { dif - vw } else { dif }
  v = v + taken * (r - 2 * v)
  self.norm(dif, v)
  1 - taken
}

///|
/// One bit at `probability/32768` of being one.
pub fn Msac::bool(self : Msac, probability : Int32) -> Int32 {
  let r = self.rng
  let dif = self.dif
  let mut v = (((r >> 8) * (probability >> ec_prob_shift)) >>
    (7 - ec_prob_shift)) + ec_min_prob
  let vw = v.to_uint64() << (ec_win_size - 16)
  let taken = if dif >= vw { 1 } else { 0 }
  let dif = if taken == 1 { dif - vw } else { dif }
  v = v + taken * (r - 2 * v)
  self.norm(dif, v)
  1 - taken
}

///|
/// `bits` bits, most significant first.
pub fn Msac::bools(self : Msac, count : Int32) -> Int32 {
  let mut value = 0
  for _ in 0..<count {
    value = (value << 1) | self.bool_equi()
  }
  value
}

///|
/// A symbol from the CDF beginning at `at`, with `n_symbols` alternatives. The
/// entry at `at + n_symbols` is the adaptation count, not a probability.
pub fn Msac::symbol(
  self : Msac,
  cdfs : FixedArray[Int32],
  at : Int32,
  n_symbols : Int32,
) -> Int32 {
  let c = (self.dif >> (ec_win_size - 16)).to_int()
  let r = self.rng >> 8
  let mut v = self.rng
  let mut u = self.rng
  let mut value = -1
  while true {
    value = value + 1
    u = v
    v = (r * (cdfs[at + value] >> ec_prob_shift)) >> (7 - ec_prob_shift)
    v = v + ec_min_prob * (n_symbols - value)
    if c >= v {
      break
    }
  }
  let window = v.to_uint64() << (ec_win_size - 16)
  self.norm(self.dif - window, u - v)
  if self.allow_update {
    let count = cdfs[at + n_symbols]
    let rate = 4 + (count >> 4) + (if n_symbols > 2 { 1 } else { 0 })
    for i in 0..<value {
      cdfs[at + i] = cdfs[at + i] + ((32768 - cdfs[at + i]) >> rate)
    }
    for i in value..<n_symbols {
      cdfs[at + i] = cdfs[at + i] - (cdfs[at + i] >> rate)
    }
    cdfs[at + n_symbols] = count + (if count < 32 { 1 } else { 0 })
  }
  value
}

///|
/// A two-symbol CDF, specialised in the reference and here alike.
pub fn Msac::bool_adapt(self : Msac, cdfs : FixedArray[Int32], at : Int32) -> Int32 {
  let bit = self.bool(cdfs[at])
  if self.allow_update {
    let count = cdfs[at + 1]
    let rate = 4 + (count >> 4)
    if bit == 1 {
      cdfs[at] = cdfs[at] + ((32768 - cdfs[at]) >> rate)
    } else {
      cdfs[at] = cdfs[at] - (cdfs[at] >> rate)
    }
    cdfs[at + 1] = count + (if count < 32 { 1 } else { 0 })
  }
  bit
}

///|
/// A coefficient above the base range: up to four three-symbol reads.
pub fn Msac::hi_tok(self : Msac, cdfs : FixedArray[Int32], at : Int32) -> Int32 {
  let mut extra = self.symbol(cdfs, at, 3)
  let mut token = 3 + extra
  if extra == 3 {
    extra = self.symbol(cdfs, at, 3)
    token = 6 + extra
    if extra == 3 {
      extra = self.symbol(cdfs, at, 3)
      token = 9 + extra
      if extra == 3 {
        token = 12 + self.symbol(cdfs, at, 3)
      }
    }
  }
  token
}

///|
/// A number from nought to `n - 1`, with no probability table at all.
pub fn Msac::uniform(self : Msac, n : Int32) -> Int32 {
  let bits = floor_log2(n)
  let shift = (1 << (bits + 1)) - n
  let value = self.bools(bits)
  if value < shift {
    value
  } else {
    (value << 1) - shift + self.bool_equi()
  }
}

///|
/// `inv_recenter`, the reflection a subexponential code uses around a reference.
pub fn inv_recenter(reference : Int32, value : Int32) -> Int32 {
  if value > (reference << 1) {
    value
  } else if (value & 1) == 0 {
    (value >> 1) + reference
  } else {
    reference - ((value + 1) >> 1)
  }
}

///|
/// A small number around a reference, with `n >> k == 8`.
pub fn Msac::subexp(self : Msac, reference : Int32, n : Int32, k : Int32) -> Int32 {
  let mut width = k
  let mut a = 0
  if self.bool_equi() == 1 {
    if self.bool_equi() == 1 {
      width = width + self.bool_equi() + 1
    }
    a = 1 << width
  }
  let value = self.bools(width) + a
  if reference * 2 <= n {
    inv_recenter(reference, value)
  } else {
    n - 1 - inv_recenter(n - 1 - reference, value)
  }
}

///|
/// The arithmetic state as the reference harness prints it, for the vector
/// test. Nothing in the decoder reads this.
pub fn Msac::debug_state(self : Msac) -> String {
  let digits = "0123456789abcdef"
  let mut out = ""
  for place in 0..<16 {
    let nibble = ((self.dif >> ((15 - place) * 4)) & 0xFUL).to_int()
    out = out + digits[nibble:nibble + 1].to_owned()
  }
  out + ":" + self.rng.to_string() + ":" + self.cnt.to_string() + ":" +
  self.pos.to_string()
}
