// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The other implementation the conformance run holds this library to.
//
// It reads a picture with the `image` crate and writes the pixels out as
// straight eight-bit RGBA, row after row, which is the same layout the command
// in `src/tools/samples` writes. Nothing else happens here: the comparison is
// the caller's.
//
//   read_image <in> <out>      prints "<width> <height>" on success

use std::env;
use std::fs;
use std::process::ExitCode;

fn main() -> ExitCode {
    let arguments: Vec<String> = env::args().collect();
    if arguments.len() != 3 {
        eprintln!("usage: read_image <in> <out>");
        return ExitCode::FAILURE;
    }
    let picture = match image::open(&arguments[1]) {
        Ok(picture) => picture,
        Err(error) => {
            eprintln!("error: {}: {}", arguments[1], error);
            return ExitCode::FAILURE;
        }
    };
    let rgba = picture.to_rgba8();
    let (width, height) = rgba.dimensions();
    if let Err(error) = fs::write(&arguments[2], rgba.as_raw()) {
        eprintln!("error: {}: {}", arguments[2], error);
        return ExitCode::FAILURE;
    }
    println!("{} {}", width, height);
    ExitCode::SUCCESS
}
