// The bridge's platform edges, checked where they can be: which process is a bridge, and how
// one is started away from the command that made it. The command line and the platform are
// injected, so Windows' answers can be checked on whatever machine runs the tests.
// Run with `node --test Packages/KuvoLink/Tests/Bridge/*.test.js`.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";

// The bridge keeps its state in KUVO_HOME, so give it a folder of its own before loading it.
const home = fs.mkdtempSync(path.join(os.tmpdir(), "kuvo-link-platform-"));
process.env.KUVO_HOME = home;
after(() => fs.rmSync(home, { recursive: true, force: true }));
const link = await import("../../Sources/KuvoLink/Resources/kuvo-link.js");

test("a live pid whose command line says kuvo-link.js is the bridge", () => {
  assert.equal(link.isBridge(process.pid, "linux", () => null), false, "never this process");
  assert.equal(link.isBridge(0, "linux", () => null), false);
  // A pid that isn't running: alive() says no before the command line is even asked for.
  assert.equal(link.isBridge(2 ** 30, "linux", () => { throw new Error("shouldn't be asked"); }), false);
});

test("on Linux the command line in /proc decides", () => {
  const line = "/usr/bin/bun\0/machines/kuvo-ai/.kuvo-code/bin/kuvo-link.js\0run\0";
  assert.equal(link.isBridge(process.ppid, "linux", () => line), true);
  assert.equal(link.isBridge(process.ppid, "linux", () => "/usr/bin/other\0run\0"), false);
  // Nothing readable decides it, except where there's no /proc to have read at all — macOS,
  // where the old answer stands (yes); a Linux host has /proc and answers no.
  assert.equal(link.isBridge(process.ppid, "linux", () => { throw new Error("gone"); }), !fs.existsSync("/proc"));
  assert.equal(link.isBridge(process.ppid, "linux", () => null), !fs.existsSync("/proc"));
});

test("on Windows the process list decides, and an unreadable one is never a bridge", () => {
  const line = "C:\\Users\\me\\AppData\\Local\\KuvoCode\\bin\\kuvo-link.js run";
  assert.equal(link.isBridge(process.ppid, "win32", () => line), true);
  assert.equal(link.isBridge(process.ppid, "win32", () => "C:\\Windows\\System32\\whoami.exe"), false);
  // PowerShell blocked, CIM unreadable, process gone: nothing is stopped on a guess.
  assert.equal(link.isBridge(process.ppid, "win32", () => null), false);
  assert.equal(link.isBridge(process.ppid, "win32", () => { throw new Error("no powershell"); }), false);
});

test("the bridge starts detached, and hidden on Windows", () => {
  assert.deepEqual(link.bridgeSpawnOptions("linux"), { detached: true, stdio: "ignore", windowsHide: false });
  assert.deepEqual(link.bridgeSpawnOptions("win32"), { detached: true, stdio: "ignore", windowsHide: true });
});
