// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0
//
// The workbench page's own script. It reads the plate once, writes it in every
// format the library writes and reads each one back, then runs one operation at
// a time on the same picture.
//
// Nothing here knows how a format is put together, or what a Gaussian is. Every
// byte count, every pixel and every size comes out of the four calls `demo.js`
// puts on the page — describe, preview, convert and operate — so a wrong number
// is a wrong library rather than a wrong page.

const FORMATS = [
  { key: "png", name: "PNG" },
  { key: "qoi", name: "QOI" },
  { key: "bmp", name: "BMP" },
  { key: "tga", name: "TGA" },
  { key: "jpeg", name: "JPEG" },
  { key: "gif", name: "GIF" },
  { key: "webp", name: "WebP" },
  { key: "tiff", name: "TIFF" },
  { key: "ico", name: "ICO" },
  { key: "pnm", name: "PNM" },
  { key: "farbfeld", name: "farbfeld" },
  { key: "hdr", name: "HDR" },
  { key: "exr", name: "OpenEXR" },
];

const table = document.getElementById("roundtrip");
const canvas = document.getElementById("plate-canvas");
const opCanvas = document.getElementById("op-canvas");
const readout = {
  format: document.getElementById("r-format"),
  size: document.getElementById("r-size"),
  layout: document.getElementById("r-layout"),
  bytes: document.getElementById("r-bytes"),
};
const opReadout = {
  name: document.getElementById("o-name"),
  size: document.getElementById("o-size"),
};

let plate = null;

function grouped(value) {
  return value.toLocaleString("en-US");
}

function draw(target, pixels, width, height) {
  if (!pixels || pixels.length === 0) {
    return;
  }
  if (target.width !== width || target.height !== height) {
    target.width = width;
    target.height = height;
  }
  const context = target.getContext("2d");
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

// The widest difference between two runs of samples, which is what tells an
// exact round trip from one the format rounded.
function widestGap(one, other) {
  if (one.length !== other.length) {
    return 255;
  }
  let worst = 0;
  for (let index = 0; index < one.length; index += 1) {
    const gap = Math.abs(one[index] - other[index]);
    if (gap > worst) {
      worst = gap;
    }
  }
  return worst;
}

function verdict(gap) {
  if (gap === 0) {
    return ["exact", "exact"];
  }
  if (gap <= 1) {
    return ["within a step", "near"];
  }
  return ["lossy, by " + gap, "lossy"];
}

function showcase(file) {
  const report = JSON.parse(moonimage.describe(file));
  const body = table.tBodies[0];
  if (!report.ok) {
    body.replaceChildren(row([[report.error, "lossy"]]));
    return;
  }

  const pixels = moonimage.preview(file);
  draw(canvas, pixels, report.width, report.height);
  readout.format.textContent = report.format.toUpperCase();
  readout.size.textContent = report.width + " × " + report.height;
  readout.layout.textContent = report.layout;
  readout.bytes.textContent = grouped(report.bytes) + " bytes";

  body.replaceChildren(
    row([
      [report.format.toUpperCase(), ""],
      [grouped(report.bytes), ""],
      ["the file on disk", ""],
      ["—", ""],
    ], "source"),
  );

  for (const format of FORMATS) {
    const encoded = moonimage.convert(file, format.key);
    if (!encoded || encoded.length === 0) {
      body.append(row([[format.name, ""], ["—", ""], ["not written", "lossy"], ["—", ""]]));
      continue;
    }
    const round = moonimage.preview(encoded);
    const read = JSON.parse(moonimage.describe(encoded));
    const [words, kind] = verdict(widestGap(round, pixels));
    const line = row([
      [format.name, ""],
      [grouped(encoded.length), ""],
      [read.ok ? read.format.toUpperCase() + ", " + read.layout : "unreadable", ""],
      [words, kind],
    ]);
    line.tabIndex = 0;
    line.title = "Show the plate as " + format.name + " holds it";
    const show = () => {
      draw(canvas, round, report.width, report.height);
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
}

function operate(name, amount) {
  if (!plate) {
    return;
  }
  moonimage.operate(plate, name, amount);
  const result = moonimage.result;
  if (!result) {
    return;
  }
  draw(opCanvas, result.pixels, result.width, result.height);
  opReadout.name.textContent = name;
  opReadout.size.textContent = result.width + " × " + result.height;
}

async function start() {
  if (typeof moonimage === "undefined") {
    table.tBodies[0].replaceChildren(row([["the demo did not load; open this page over http", "lossy"]]));
    return;
  }
  try {
    const response = await fetch("plate.png");
    if (!response.ok) {
      throw new Error("plate.png: " + response.status);
    }
    plate = new Uint8Array(await response.arrayBuffer());
    showcase(plate);
    draw(opCanvas, moonimage.preview(plate), 1200, 800);
    opReadout.name.textContent = "none";
    opReadout.size.textContent = "1200 × 800";
  } catch (error) {
    table.tBodies[0].replaceChildren(row([[String(error), "lossy"]]));
    return;
  }

  for (const chip of document.querySelectorAll(".chip")) {
    chip.addEventListener("click", () => {
      const amount = Number(chip.dataset.amount || "0");
      for (const other of document.querySelectorAll(".chip")) {
        other.removeAttribute("aria-current");
      }
      chip.setAttribute("aria-current", "true");
      operate(chip.dataset.op, amount);
    });
  }

  const angle = document.getElementById("angle");
  const angleOut = document.getElementById("angle-out");
  angle.addEventListener("input", () => {
    angleOut.textContent = angle.value + "°";
    operate("rotate-angle", Number(angle.value));
  });
}

start();
