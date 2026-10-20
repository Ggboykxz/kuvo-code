#!/usr/bin/env node
// Proves the built executable is what it claims: it starts, serves the page and its scripts
// from inside itself, answers for the folder it was given, starts no engine before being
// asked, and stops when killed.
//
//   node windows/harness/smoke-exe.mjs [path to the executable]

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
// Absolute, because the executable is started from a folder of its own (see below).
const exe = path.resolve(process.argv[2] ?? path.join(here, "build", "kuvo-windows-harness.exe"));
if (!fs.existsSync(exe)) throw new Error(`there's no executable at ${exe}: build it first (npm run build:exe)`);

const project = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "kuvo-exe-")));
// Run it from somewhere without a ui/ folder beside the work: the page must come out of the
// binary itself, not from whatever source tree the builder was in when it made the exe.
const nowhere = fs.mkdtempSync(path.join(os.tmpdir(), "kuvo-exe-nowhere-"));
const child = spawn(exe, ["--project", project, "--port", "0"], { stdio: ["ignore", "pipe", "pipe"], cwd: nowhere });
let output = "";
child.stdout.on("data", chunk => { output += chunk; });
child.stderr.on("data", chunk => { process.stderr.write(chunk); });
// A failed start is an answer, not a crash: say what was missing.
child.on("error", error => { output += `\n${error.message}`; });

const wait = (ms) => new Promise(resolve => setTimeout(resolve, ms));

async function address() {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    const found = output.match(/at (http:\/\/\S+)/);
    if (found) return found[1];
    if (child.exitCode !== null) throw new Error(`it stopped before it was up (exit ${child.exitCode}); it said:\n${output}`);
    await wait(100);
  }
  throw new Error(`it didn't come up; it said:\n${output}`);
}

async function get(where) {
  const response = await fetch(where, { signal: AbortSignal.timeout(10_000) });
  assert.equal(response.status, 200, `${where} answered ${response.status}`);
  return response.text();
}

try {
  const url = await address();

  const page = await get(url);
  assert.match(page, /<title>Kuvo Code<\/title>/, "the page comes from inside the binary");
  // The page's own scripts: the build is Next.js's, so they are named after their contents
  // and live in its own folder.
  const scripts = [...page.matchAll(/<script[^>]+src="([^"]+)"/g)].map(match => match[1]);
  assert.ok(scripts.length > 0, "the page brings its scripts");
  const bodies = await Promise.all(scripts.map(src => get(new URL(src, url).href)));
  assert.ok(bodies.some(body => /EventSource/.test(body)), "the app's own code is served");
  assert.match(await get(`${url}transcript.mjs`), /export function apply/, "the reducer is served");
  assert.match(await get(`${url}vendor/xterm.min.js`), /xterm/i, "the terminal's script is served");
  // The shell loads the page with its own query string; that must be the same page.
  const withQuery = await get(`${url}?terminalPort=0&shell=1`);
  assert.match(withQuery, /<title>Kuvo Code<\/title>/, "the page comes with the shell's query string too");

  const state = JSON.parse(await get(`${url}api/state`));
  assert.equal(state.project, project, "it answers for the folder it was given");
  assert.equal(state.engine.status, "stopped", "no engine was started before anyone asked");

  console.log(`ok: ${path.basename(exe)} serves its page, its scripts and its state on its own`);
} finally {
  child.kill();
  await new Promise(resolve => child.once("exit", resolve));
  fs.rmSync(project, { recursive: true, force: true });
  fs.rmSync(nowhere, { recursive: true, force: true });
}
