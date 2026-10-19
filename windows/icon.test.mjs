// The app's icon, checked so it cannot go missing again: the macOS build ships an .icns,
// Windows wants an .ico (the executable) and a PNG (the tray, the window, the page's
// favicon). Both come out of the .icns — windows/tools/make-icon.py — so they are the same
// drawing, and here they are checked to be one.
//
//   node --test windows/icon.test.mjs

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, "..");
const read = (...parts) => fs.readFileSync(path.join(root, ...parts));
const exists = (...parts) => fs.existsSync(path.join(root, ...parts));

const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function pngSize(buffer) {
  assert.deepEqual(buffer.subarray(0, 8), PNG, "not a PNG");
  return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20) };
}

test("the executable's icon is an .ico holding PNGs Windows can read", () => {
  const ico = read("windows", "electron", "build", "icon.ico");
  assert.equal(ico.readUInt16LE(0), 0, "the reserved word");
  assert.equal(ico.readUInt16LE(2), 1, "the type is an icon");
  const count = ico.readUInt16LE(4);
  assert.ok(count >= 1, "it holds at least one image");

  const sizes = [];
  for (let index = 0; index < count; index += 1) {
    const entry = 6 + index * 16;
    const width = ico.readUInt8(entry) || 256;
    const height = ico.readUInt8(entry + 1) || 256;
    const size = ico.readUInt32LE(entry + 8);
    const offset = ico.readUInt32LE(entry + 12);
    const blob = ico.subarray(offset, offset + size);
    assert.deepEqual(blob.subarray(0, 8), PNG, `the ${width}px image is a PNG`);
    assert.equal(pngSize(blob).width, width, `the ${width}px image says ${width}`);
    assert.equal(pngSize(blob).height, height, `the ${width}px image says ${height}`);
    sizes.push(width);
  }
  assert.ok(sizes.includes(256), `it holds a 256px image (${sizes.join(", ")})`);
});

test("the tray and the page wear the same drawing", () => {
  const page = read("windows", "app", "src", "icon.png");
  const shell = read("windows", "electron", "build", "icon.png");
  assert.ok(page.equals(shell), "the page and the shell hold the same PNG");
  const { width, height } = pngSize(page);
  assert.equal(width, 256);
  assert.equal(height, 256);
});

test("the shell is built with the icon and carries the PNG", () => {
  const build = JSON.parse(read("windows", "electron", "package.json").toString()).build;
  assert.equal(build.win.icon, "build/icon.ico", "the executable takes the .ico");
  assert.ok(build.files.includes("build/icon.png"), "the PNG travels inside the app");
  const main = read("windows", "electron", "main.js").toString();
  assert.match(main, /build.*icon\.png/, "the shell reads the icon from the file");
});

test("the page carries the icon and the build copies it", () => {
  const html = read("windows", "app", "src", "index.html").toString();
  assert.match(html, /<link rel="icon" href="\/icon\.png">/, "the page asks for the icon");
  const build = read("windows", "app", "build.mjs").toString();
  assert.match(build, /icon\.png/, "the build copies the icon beside the page");
  assert.ok(exists("windows", "app", "src", "icon.png"), "the icon is in the source");
});

test("the icon is in the repository, not ignored like a build artefact", () => {
  const ignored = read(".gitignore").toString();
  assert.match(ignored, /!windows\/electron\/build\/icon\.ico/, "the .ico is kept");
  assert.match(ignored, /!windows\/electron\/build\/icon\.png/, "the PNG is kept");
});
