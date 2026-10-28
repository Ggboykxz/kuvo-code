// The terminal's decisions, without a browser or ConPTY: the address the page opens, the
// folder and grid it asks for, the text Add to Message sends, and the build's own list of
// files. The real shell is proved separately on Windows (electron/terminal.test.js).

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { terminalSelectionBlock, terminalSocketUrl } from "./app/src/terminal.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const {
  reasonBytes,
  shellCandidates,
  terminalEnvironment,
  terminalRequest,
  usableDirectory,
} = require("./electron/terminal.js");

test("the page's terminal address carries the project, width and height", () => {
  const address = terminalSocketUrl(43117, "C:\\Users\\Ada Lovelace\\my project", 121, 39);
  const parsed = new URL(address);
  assert.equal(parsed.protocol, "ws:");
  assert.equal(parsed.hostname, "127.0.0.1");
  assert.equal(parsed.port, "43117");
  assert.equal(parsed.searchParams.get("cwd"), "C:\\Users\\Ada Lovelace\\my project");
  assert.equal(parsed.searchParams.get("cols"), "121");
  assert.equal(parsed.searchParams.get("rows"), "39");
});

test("the address leaves out a project it does not have and keeps the grid sane", () => {
  const parsed = new URL(terminalSocketUrl(9, "", 1, 9999));
  assert.equal(parsed.searchParams.has("cwd"), false);
  assert.equal(parsed.searchParams.get("cols"), "2");
  assert.equal(parsed.searchParams.get("rows"), "500");
});

test("Add to Message sends a code block with the terminal's trailing spaces removed", () => {
  assert.equal(terminalSelectionBlock("  first  \nsecond\t\n\n"), "```\n  first\nsecond\n```");
  assert.equal(terminalSelectionBlock("\r\n\r\n"), "");
});

test("a terminal request starts in the folder it was given, at the grid it was given", () => {
  const request = terminalRequest(`/?cwd=${encodeURIComponent(here)}&cols=100&rows=30`, os.homedir());
  assert.equal(request.directory, here);
  assert.equal(request.cols, 100);
  assert.equal(request.rows, 30);
});

test("a deleted project falls back to a folder that exists", () => {
  const missing = path.join(os.tmpdir(), `kuvo-terminal-missing-${process.pid}`);
  assert.equal(usableDirectory(missing, here), here);
  assert.equal(terminalRequest(`/?cwd=${encodeURIComponent(missing)}`, here).directory, here);
  const clamped = terminalRequest("/?cols=0&rows=9999", here);
  assert.equal(clamped.cols, 2);
  assert.equal(clamped.rows, 500);
});

test("Windows always has Windows PowerShell, and cmd as its last resort", () => {
  const shells = shellCandidates("win32", { SystemRoot: "C:\\Windows", ComSpec: "C:\\Windows\\System32\\cmd.exe" });
  assert.ok(shells.some(shell => /WindowsPowerShell[\\/]v1\.0[\\/]powershell\.exe$/i.test(shell.command)));
  assert.equal(shells.at(-1).command, "C:\\Windows\\System32\\cmd.exe");
});

test("the shell is told it is a color terminal", () => {
  const environment = terminalEnvironment({ TERM: "dumb", COLORTERM: "0", TERM_PROGRAM: "old" });
  assert.equal(environment.TERM, "xterm-256color");
  assert.equal(environment.COLORTERM, "truecolor");
  assert.equal(environment.TERM_PROGRAM, "KuvoCode");
});

test("a close reason fits the WebSocket limit", () => {
  const reason = reasonBytes(`The terminal could not start: ${"é".repeat(200)}`);
  assert.ok(Buffer.byteLength(reason, "utf8") <= 120);
  assert.equal(reason.startsWith("The terminal could not start:"), true);
});

test("the packaged shell carries the terminal and ssh modules", () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(here, "electron", "package.json"), "utf8"));
  assert.ok(manifest.build.files.includes("terminal.js"), "terminal.js must be in electron-builder's files");
  assert.ok(manifest.build.files.includes("ssh.js"), "ssh.js must be in electron-builder's files");
  assert.equal(manifest.scripts["test:terminal"], "node --test terminal.test.js ssh.test.js");
});

test("the page keeps its shell across tabs and reads addon-fit's real shape", () => {
  const overlays = fs.readFileSync(path.join(here, "app", "src", "Overlays.tsx"), "utf8");
  // The old guard marked the container ready and then never connected again.
  assert.doesNotMatch(overlays, /dataset\.ready/);
  // addon-fit's browser build is `{ FitAddon }`, not the class itself.
  assert.match(overlays, /fitNamespace\?\.FitAddon/);
  assert.match(overlays, /terminalSocketUrl\(/);
  assert.match(overlays, /ResizeObserver/);
  const shell = fs.readFileSync(path.join(here, "electron", "main.js"), "utf8");
  assert.match(shell, /startPtyServer\(/);
  assert.match(shell, /cwd: \(\) => terminalCwd/);
});
