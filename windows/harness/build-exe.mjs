#!/usr/bin/env node
// Builds the harness into one executable: this machine's own node runtime, the harness bundled
// into a single file, and the page's files carried inside it (server.mjs reads them back with
// node:sea). Nothing but the engine is needed on the machine that runs it.
//
//   cd windows/harness
//   npm install
//   npm run build:exe        # build/kuvo-windows-harness.exe on Windows
//
// It's Windows-only by accident: run on Windows it makes an .exe, run on Linux it makes the
// same thing for Linux — which is how the build itself is checked outside CI.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { inject } from "postject";

const here = path.dirname(fileURLToPath(import.meta.url));
const buildDir = path.join(here, "build");
const name = process.platform === "win32" ? "kuvo-windows-harness.exe" : "kuvo-windows-harness";
const target = path.join(buildDir, name);

fs.rmSync(buildDir, { recursive: true, force: true });
fs.mkdirSync(buildDir, { recursive: true });

// One file out of the server, the engine bootstrap and the client. The banner marks the
// environment before anything else runs: the two command-line guards step aside for it, since
// inside a binary "is this file what was started" has no answer.
await build({
  entryPoints: [path.join(here, "exe-entry.mjs")],
  bundle: true,
  platform: "node",
  format: "cjs",
  target: "node22",
  outfile: path.join(buildDir, "harness.cjs"),
  banner: { js: 'process.env.KUVO_BUNDLED = "1";' },
  logLevel: "error",
});
const bundle = fs.readFileSync(path.join(buildDir, "harness.cjs"), "utf8");
if (!bundle.includes('process.env.KUVO_BUNDLED = "1"')) {
  throw new Error("the banner is missing from the bundle: the command-line guards would run inside the binary");
}

// The blob: the bundle plus the page's files, which server.mjs asks for by name.
const blob = path.join(buildDir, "harness.blob");
const config = {
  main: path.join(buildDir, "harness.cjs"),
  output: blob,
  disableExperimentalSEAWarning: true,
  assets: {
    "index.html": path.join(here, "ui/index.html"),
    "app.js": path.join(here, "ui/app.js"),
    "style.css": path.join(here, "ui/style.css"),
    "transcript.mjs": path.join(here, "transcript.mjs"),
  },
};
const configPath = path.join(buildDir, "sea-config.json");
fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);
const prepared = spawnSync(process.execPath, ["--experimental-sea-config", configPath], { stdio: "inherit" });
if (prepared.status !== 0) throw new Error("the preparation blob wasn't written");

// An executable is this node, with the blob injected where its fuse says to look.
fs.copyFileSync(process.execPath, target);
if (process.platform === "win32") stripSignature(target);
await inject(target, "NODE_SEA_BLOB", fs.readFileSync(blob), {
  sentinelFuse: "NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2",
});
fs.rmSync(blob, { force: true });

console.log(`ok: ${path.relative(process.cwd(), target)} (${(fs.statSync(target).size / 1e6).toFixed(1)} MB)`);
console.log("ok: `node windows/harness/smoke-exe.mjs` proves it serves the page by itself");

/// Windows node.exe carries an Authenticode signature that the injection invalidates, so it's
/// removed first. signtool is in the Windows SDK — on PATH in CI, further down in a devbox.
function stripSignature(file) {
  const run = (command, args) => spawnSync(command, args, { stdio: "ignore" });
  let made = run("signtool", ["remove", "/s", file]);
  if (made.error) {
    const kits = path.join(process.env["ProgramFiles(x86)"] ?? "C:\\Program Files (x86)", "Windows Kits", "10", "bin");
    let signtool = null;
    try {
      signtool = fs.readdirSync(kits)
        .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }))
        .map(version => path.join(kits, version, "x64", "signtool.exe"))
        .filter(candidate => fs.existsSync(candidate))
        .pop() ?? null;
    } catch {
      signtool = null;
    }
    if (signtool) made = run(signtool, ["remove", "/s", file]);
  }
  if (made.error) console.error("note: no signtool here; injecting into the signed node.exe anyway");
}
