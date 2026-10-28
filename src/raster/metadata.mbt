// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// What the file said about itself, kept so that writing it back says the same.
//
// A PNG can carry the gamma it was authored for, the primaries of the display
// it was checked on, an ICC profile, and any number of text notes. None of that
// changes a pixel, and none of it is interpreted here: colour management is not
// this library's business. It is read, carried, and written out again, because a
// decoder that drops it turns an image that was correct on one screen into one
// that is wrong on all of them.
//
// The same record travels with every format that has somewhere to put it. Where
// a format has no room, the field is simply not written.

///|
/// What a column of pixels was meant to be seen in.
pub(all) enum Intent {
  /// For a picture.
  Perceptual
  /// For a colour that should come out as it went in.
  Relative
  /// For a diagram, where saturation matters more than hue.
  Saturation
  /// For comparing against a proof.
  Absolute
} derive(Eq, Debug)

///|
pub extend Intent with Eq::{equal, not_equal}

///|
pub extend Intent with Debug::{to_repr}

///|
/// The number a file writes for this intent, which is how PNG's `sRGB` chunk
/// numbers them.
pub fn Intent::code(self : Intent) -> Int32 {
  match self {
    Perceptual => 0
    Relative => 1
    Saturation => 2
    Absolute => 3
  }
}

///|
/// The intent a number stands for, or `None` if it is not one of the four.
pub fn Intent::of(code : Int32) -> Intent? {
  match code {
    0 => Some(Perceptual)
    1 => Some(Relative)
    2 => Some(Saturation)
    3 => Some(Absolute)
    _ => None
  }
}

///|
/// The white point and the three primaries, as chromaticity coordinates.
///
/// Eight numbers rather than a matrix: this is what a file writes, and a matrix
/// would be a conversion, which this library does not do.
pub(all) struct Chromaticities {
  white_x : Double
  white_y : Double
  red_x : Double
  red_y : Double
  green_x : Double
  green_y : Double
  blue_x : Double
  blue_y : Double
} derive(Eq, Debug)

///|
pub extend Chromaticities with Eq::{equal, not_equal}

///|
pub extend Chromaticities with Debug::{to_repr}

///|
/// The primaries of sRGB, which is what almost every file means when it says
/// nothing.
pub fn Chromaticities::srgb() -> Chromaticities {
  {
    white_x: 0.3127,
    white_y: 0.3290,
    red_x: 0.6400,
    red_y: 0.3300,
    green_x: 0.3000,
    green_y: 0.6000,
    blue_x: 0.1500,
    blue_y: 0.0600,
  }
}

///|
/// An embedded ICC profile, kept by name and bytes. Not applied: a caller that
/// wants colour management hands these bytes to something that does it.
pub(all) struct Icc {
  name : String
  profile : Bytes
} derive(Eq, Debug)

///|
pub extend Icc with Eq::{equal, not_equal}

///|
pub extend Icc with Debug::{to_repr}

///|
/// A text note, in the flavour of the chunk it came from, so that writing the
/// image back produces the same kind of chunk.
pub(all) enum Text {
  /// `tEXt`: Latin-1, one keyword and one line.
  Latin(keyword~ : String, text~ : String)
  /// `zTXt`: the same, deflated.
  Compressed(keyword~ : String, text~ : String)
  /// `iTXt`: UTF-8, with a language tag and a translated keyword.
  International(
    keyword~ : String,
    language~ : String,
    translated~ : String,
    text~ : String
  )
} derive(Eq, Debug)

///|
pub extend Text with Eq::{equal, not_equal}

///|
pub extend Text with Debug::{to_repr}

///|
/// The keyword a note is filed under.
pub fn Text::keyword(self : Text) -> String {
  match self {
    Latin(keyword~, ..)
    | Compressed(keyword~, ..)
    | International(keyword~, ..) => keyword
  }
}

///|
/// What the note says.
pub fn Text::text(self : Text) -> String {
  match self {
    Latin(text~, ..) | Compressed(text~, ..) | International(text~, ..) => text
  }
}

///|
/// Everything the file said about itself besides its pixels.
pub(all) struct Metadata {
  /// The file gamma: the exponent the samples were encoded with, so that 0.45455
  /// means what sRGB means.
  gamma : Double?
  /// The primaries the image was authored for.
  chromaticities : Chromaticities?
  /// The rendering intent, which only means anything next to an sRGB or ICC tag.
  intent : Intent?
  /// The embedded profile, if there was one.
  icc : Icc?
  /// The text notes, in the order the file had them.
  texts : Array[Text]
} derive(Eq, Debug)

///|
pub extend Metadata with Eq::{equal, not_equal}

///|
pub extend Metadata with Debug::{to_repr}

///|
/// No metadata at all, which is what an image built in memory has.
pub fn Metadata::default() -> Metadata {
  { gamma: None, chromaticities: None, intent: None, icc: None, texts: [], }
}

///|
/// Whether there is nothing to write.
pub fn Metadata::is_empty(self : Metadata) -> Bool {
  self.gamma is None &&
  self.chromaticities is None &&
  self.intent is None &&
  self.icc is None &&
  self.texts.is_empty()
}
