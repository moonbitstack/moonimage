// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Put the three entry points on the global object, where the page's own script
/// can reach them.
///
/// The JavaScript build of a package is a script, not a module: it runs its
/// `main` and hands nothing back. One assignment is all the page needs, and it
/// keeps the names the page calls in one place.
extern "js" fn publish(
  describe : (Bytes) -> String,
  preview : (Bytes) -> Bytes,
  convert : (Bytes, String) -> Bytes,
) = "(describe, preview, convert) => { globalThis.moonimage = { describe, preview, convert }; }"
