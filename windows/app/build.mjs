#!/usr/bin/env node
// Copies the exported app into the folder the harness serves.
//
//   cd windows/app && npm install && npm run build
//   cd windows/app && npm run dev        (the app, against a harness on :4620)
//
// Next.js writes the static export (output: "export"), and this puts it where the
// harness looks for it: windows/harness/ui-build. The harness serves that folder — or
// the hand-written page beside it, when there is no build — and the packed executable
// carries it inside itself.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, "..", "harness", "ui-build");
const exported = path.join(here, "out");

if (!fs.existsSync(exported)) {
  console.error("no export to copy: run `next build` first (npm run build does both)");
  process.exit(1);
}

fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });

/// A folder, file by file.
const copy = (from, to) => {
  for (const entry of fs.readdirSync(from, { withFileTypes: true })) {
    const source = path.join(from, entry.name);
    const target = path.join(to, entry.name);
    if (entry.isDirectory()) {
      fs.mkdirSync(target, { recursive: true });
      copy(source, target);
    } else {
      fs.copyFileSync(source, target);
    }
  }
};

copy(exported, out);

// The app's icon: the page's favicon (the same drawing the Mac build ships).
const icon = path.join(here, "src", "icon.png");
if (fs.existsSync(icon)) fs.copyFileSync(icon, path.join(out, "icon.png"));

const size = fs.readdirSync(out, { recursive: true })
  .map(entry => path.join(out, entry))
  .filter(entry => fs.statSync(entry).isFile())
  .reduce((total, entry) => total + fs.statSync(entry).size, 0);
console.log(`ok: the page is built (${Math.round(size / 1024)} kB) in ${path.relative(process.cwd(), out)}`);
