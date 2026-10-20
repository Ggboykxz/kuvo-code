#!/usr/bin/env node
// Builds the conversation view: React and TypeScript in, one bundle and one page out.
// The result goes to windows/harness/ui-build, which the harness serves (and the packed
// executable carries inside itself). The hand-written page still sits in
// windows/harness/ui and is served when there is no build — the migration's fallback.
//
//   cd windows/app && npm install && npm run build
//   cd windows/app && npm run watch     (rebuilds on every change)

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { build, context } from "esbuild";

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, "..", "harness", "ui-build");
const legacy = path.join(here, "..", "harness", "ui");

const options = {
  entryPoints: [path.join(here, "src", "main.tsx")],
  bundle: true,
  format: "iife",
  target: ["chrome110"],
  outfile: path.join(out, "app.js"),
  minify: true,
  sourcemap: false,
  define: { "process.env.NODE_ENV": '"production"' },
  logLevel: "error",
  // KaTeX brings its own fonts; they are copied beside the page, and the page's own
  // stylesheet says where they are.
  assetNames: "[name]",
  loader: { ".svg": "dataurl", ".png": "dataurl", ".woff2": "file", ".woff": "file", ".ttf": "file" },
};

/// The page and the stylesheet the page wears: the design the app is bound to (DESIGN.md
/// beside them) lives with the harness for now, and comes over when the migration ends.
///
/// The stylesheet is compiled by Tailwind, so the AI Elements' components — written in
/// Tailwind's utilities — carry their classes, and the Mac's own rules ride in the layer
/// below them. The hand-written page (ui/) still wears the plain stylesheet.
function copyAssets() {
  fs.mkdirSync(out, { recursive: true });
  fs.copyFileSync(path.join(here, "src", "index.html"), path.join(out, "index.html"));
  // The app's icon: the page's favicon (the same drawing the Mac build ships).
  const icon = path.join(here, "src", "icon.png");
  if (fs.existsSync(icon)) fs.copyFileSync(icon, path.join(out, "icon.png"));
  compileStyles();
  const vendor = path.join(legacy, "vendor");
  if (fs.existsSync(vendor)) {
    fs.mkdirSync(path.join(out, "vendor"), { recursive: true });
    for (const entry of fs.readdirSync(vendor)) {
      fs.copyFileSync(path.join(vendor, entry), path.join(out, "vendor", entry));
    }
  }
}

/// The stylesheet the built page wears: the Mac's binding with Tailwind's utilities for the
/// AI Elements' components folded in. Tailwind's own CLI does it, from this app's copy.
function compileStyles() {
  const entry = path.join(here, "src", "tailwind.css");
  if (!fs.existsSync(entry)) {
    fs.copyFileSync(path.join(legacy, "style.css"), path.join(out, "style.css"));
    return;
  }
  const cli = path.join(here, "node_modules", "@tailwindcss", "cli", "dist", "index.mjs");
  execFileSync(process.execPath, [cli, "-i", entry, "-o", path.join(out, "style.css"), "--minify"], {
    stdio: "inherit",
    cwd: here,
  });
}

if (process.argv.includes("--watch")) {
  copyAssets();
  const ctx = await context(options);
  await ctx.watch();
  console.log("watching — the page is rebuilt on every change");
} else {
  fs.rmSync(out, { recursive: true, force: true });
  copyAssets();
  await build(options);
  const size = fs.statSync(path.join(out, "app.js")).size;
  console.log(`ok: the page is built (${Math.round(size / 1024)} kB) in ${path.relative(process.cwd(), out)}`);
}
