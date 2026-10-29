// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0
//
// The homepage's own script: it reads the plate with the library that
// `demo.js` puts on the page, then writes it back in every format and compares
// what comes out with what went in.
//
// Nothing here knows how a PNG is put together. Every number on the page comes
// from one of three calls — describe, preview, convert — so a wrong number is a
// wrong library rather than a wrong page.

const FORMATS = [
  { key: "png", name: "PNG" },
  { key: "qoi", name: "QOI" },
  { key: "bmp", name: "BMP" },
  { key: "tga", name: "TGA" },
  { key: "jpeg", name: "JPEG" },
  { key: "gif", name: "GIF" },
  { key: "webp", name: "WebP" },
];

const stage = document.getElementById("stage");
const canvas = document.getElementById("canvas");
const table = document.getElementById("formats");
const note = document.getElementById("format-note");
const readout = {
  format: document.getElementById("r-format"),
  size: document.getElementById("r-size"),
  layout: document.getElementById("r-layout"),
  bytes: document.getElementById("r-bytes"),
};

const NOTE_PLATE =
  "The row above the rule is the file on disk: a PNG drawn by a script at " +
  "1200 × 800. Every row below it is this library decoding that file, writing " +
  "the pixels in another format, and reading them back. <em>Exact</em> means " +
  "the samples came back identical; JPEG quantises, and GIF has two hundred " +
  "and fifty-six colours to spend.";

const NOTE_OTHER =
  "The row above the rule is the file as it arrived. Every row below it is " +
  "this library decoding that file, writing the pixels in another format, and " +
  "reading them back. <em>Exact</em> means the samples came back identical.";

function grouped(value) {
  return value.toLocaleString("en-US");
}

function draw(pixels, width, height) {
  if (!pixels || pixels.length === 0) {
    return;
  }
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width;
    canvas.height = height;
  }
  const context = canvas.getContext("2d");
  const frame = context.createImageData(width, height);
  frame.data.set(pixels.subarray(0, width * height * 4));
  context.putImageData(frame, 0, 0);
}

function cell(text, className) {
  const td = document.createElement("td");
  td.textContent = text;
  if (className) {
    td.className = className;
  }
  return td;
}

function row(cells, className) {
  const tr = document.createElement("tr");
  if (className) {
    tr.className = className;
  }
  for (const [text, name] of cells) {
    tr.append(cell(text, name));
  }
  return tr;
}

function message(text) {
  const tr = document.createElement("tr");
  const td = cell(text, "lossy");
  td.colSpan = 3;
  tr.append(td);
  table.tBodies[0].replaceChildren(tr);
}

function samePixels(a, b) {
  if (a.length !== b.length) {
    return false;
  }
  for (let index = 0; index < a.length; index += 1) {
    if (a[index] !== b[index]) {
      return false;
    }
  }
  return true;
}

/// Read one file, show it, and put every format it can be written in beside it.
function showcase(file, fromPlate) {
  const report = JSON.parse(moonimage.describe(file));
  if (!report.ok) {
    message(report.error);
    note.textContent = "That file is not one this library reads.";
    return;
  }

  const pixels = moonimage.preview(file);
  draw(pixels, report.width, report.height);

  readout.format.textContent = report.format.toUpperCase();
  readout.size.textContent = report.width + " × " + report.height;
  readout.layout.textContent = report.layout;
  readout.bytes.textContent = grouped(report.bytes) + " bytes";

  const body = table.tBodies[0];
  body.replaceChildren(
    row(
      [
        [report.format.toUpperCase(), ""],
        [grouped(report.bytes), ""],
        ["source", ""],
      ],
      "source",
    ),
  );

  for (const format of FORMATS) {
    const encoded = moonimage.convert(file, format.key);
    if (!encoded || encoded.length === 0) {
      continue;
    }
    const round = moonimage.preview(encoded);
    if (!round || round.length === 0) {
      continue;
    }
    const exact = samePixels(round, pixels);

    const line = row([
      [format.name, ""],
      [grouped(encoded.length), ""],
      [exact ? "exact" : "lossy", exact ? "exact" : "lossy"],
    ]);
    line.tabIndex = 0;
    line.title = "Show the picture as " + format.name + " holds it";

    // Clicking a row puts that format's pixels on the stage, which is the only
    // way to see what a lossy format actually costs.
    const show = () => {
      draw(round, report.width, report.height);
      readout.format.textContent = format.name;
      readout.bytes.textContent = grouped(encoded.length) + " bytes";
      for (const other of body.querySelectorAll("tr")) {
        other.removeAttribute("aria-current");
      }
      line.setAttribute("aria-current", "true");
    };
    line.addEventListener("click", show);
    line.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        show();
      }
    });
    body.append(line);
  }

  note.innerHTML = fromPlate ? NOTE_PLATE : NOTE_OTHER;
}

async function start() {
  if (typeof moonimage === "undefined") {
    message("the demo did not load; open this page over http");
    return;
  }
  try {
    const response = await fetch("plate.png");
    if (!response.ok) {
      throw new Error("plate.png: " + response.status);
    }
    showcase(new Uint8Array(await response.arrayBuffer()), true);
  } catch (error) {
    message("the plate could not be fetched");
    note.textContent = String(error);
  }
}

// A dropped file goes down the same road as the plate; there is no second path.
const panel = table.closest(".panel");
for (const target of [stage, panel]) {
  if (!target) {
    continue;
  }
  for (const event of ["dragenter", "dragover"]) {
    target.addEventListener(event, (moved) => {
      moved.preventDefault();
      stage.dataset.drop = "over";
    });
  }
  for (const event of ["dragleave", "drop"]) {
    target.addEventListener(event, (moved) => {
      moved.preventDefault();
      stage.dataset.drop = "idle";
    });
  }
  target.addEventListener("drop", async (moved) => {
    const file = moved.dataTransfer && moved.dataTransfer.files[0];
    if (!file) {
      return;
    }
    showcase(new Uint8Array(await file.arrayBuffer()), false);
  });
}

start();
