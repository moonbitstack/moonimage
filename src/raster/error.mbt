// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// What a reader says when the bytes are not the image they claim to be.
//
// One error type for the whole library, so a caller has a single handler
// whichever format it was handed, and one set of field names, so a caller can
// read where the trouble is without matching on the variant. The names are the
// organisation's: `at` is the offset, `got` what was found, `want` what would
// have been accepted, `limit` the ceiling the caller set.

///|
/// A refusal to read bytes as an image, or to write an image as bytes.
///
/// The variants separate the three questions a caller asks: is this the wrong
/// kind of file (`Unknown`), is the file damaged (`Unexpected`, `Truncated`,
/// `Checksum`), or is the caller asking for more than it allowed (`OverLimit`).
/// `Unsupported` is the fourth: a part of a format this library does not read.
pub(all) suberror Refused {
  /// The bytes at `at` are not allowed here; `want` says what is.
  Unexpected(at~ : Int32, got~ : String, want~ : String)
  /// Nothing at `at` is an image this library reads.
  Unknown(at~ : Int32, got~ : String)
  /// A part of the format this library does not read.
  Unsupported(at~ : Int32, got~ : String)
  /// The bytes end `want` short of where the format needs them.
  Truncated(at~ : Int32, want~ : Int32)
  /// A size or a length past what the caller's `Limits` allow.
  OverLimit(limit~ : Int32, got~ : Int32)
  /// A checksum that does not match the bytes it covers.
  Checksum(at~ : Int32, got~ : String, want~ : String)
} derive(Eq, Debug)

///|
pub extend Refused with Eq::{equal, not_equal}

///|
pub extend Refused with Debug::{to_repr}

///|
/// The message names the offset and the two values, which is what a bug report
/// needs; the variants are there for callers that branch instead of printing.
pub impl Show for Refused with fn output(self, logger) {
  logger.write_string(
    match self {
      Unexpected(at~, got~, want~) => "at \{at}: got \{got}, want \{want}"
      Unknown(at~, got~) =>
        "at \{at}: \{got} is not a format this library reads"
      Unsupported(at~, got~) => "at \{at}: \{got} is not supported"
      Truncated(at~, want~) => "at \{at}: \{want} bytes wanted"
      OverLimit(limit~, got~) => "over limit: \{got} beyond \{limit}"
      Checksum(at~, got~, want~) => "at \{at}: checksum \{got}, want \{want}"
    },
  )
}

///|
pub extend Refused with Show::{to_string, output}
