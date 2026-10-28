// Downloading the installer, checked here: the bytes, the name it gets, and what is left
// behind when a download is not an installer at all.
//
//   node --test windows/update-install.test.mjs

import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { after, before, test } from "node:test";

const require = createRequire(import.meta.url);
const { safeName, downloadInstaller, launchInstaller, sweepInstallers } = require("./electron/update-install.js");

const folder = fs.mkdtempSync(path.join(os.tmpdir(), "kuvo-update-"));
after(() => fs.rmSync(folder, { recursive: true, force: true }));

const INSTALLER = Buffer.concat([Buffer.from("MZ"), Buffer.alloc(64, 7)]);

let server;
let base;
before(async () => {
  server = http.createServer((request, response) => {
    if (request.url === "/good") {
      response.writeHead(200, { "content-type": "application/octet-stream", "content-length": String(INSTALLER.length) });
      response.end(INSTALLER);
      return;
    }
    if (request.url === "/short") {
      response.writeHead(200, { "content-type": "application/octet-stream", "content-length": "2" });
      response.end("MZ");
      return;
    }
    if (request.url === "/not-an-installer") {
      response.writeHead(200, { "content-type": "text/html", "content-length": "4" });
      response.end("<h1>");
      return;
    }
    if (request.url === "/cut-off") {
      // It promises a hundred bytes and sends two: the connection is what fails.
      response.writeHead(200, { "content-type": "application/octet-stream", "content-length": "100" });
      response.write("MZ");
      response.destroy();
      return;
    }
    response.writeHead(404, { "content-type": "text/plain" });
    response.end("not here");
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => new Promise(resolve => server.close(resolve)));

const download = (route, name = "Kuvo-Code-Setup-0.7.3.exe", minimumBytes = 2) =>
  downloadInstaller({ url: `${base}${route}`, name, directory: folder, minimumBytes });

const files = () => fs.readdirSync(folder).filter(name => name.endsWith(".exe"));

test("a name is a file's own, or it is not a name", () => {
  assert.equal(safeName("Kuvo-Code-Setup-0.7.3.exe"), "Kuvo-Code-Setup-0.7.3.exe");
  assert.equal(safeName("C:\\Temp\\Kuvo-Code-Setup-0.7.3.exe"), "Kuvo-Code-Setup-0.7.3.exe");
  assert.equal(safeName("../../evil.exe"), "evil.exe");
  assert.equal(safeName("..\\evil.exe"), "evil.exe");
  assert.equal(safeName("Kuvo-Code-Setup-0.7.3.msi"), null);
  assert.equal(safeName(""), null);
  assert.equal(safeName(null), null);
});

test("the installer is streamed to a file of its own, and every byte arrives", async () => {
  const seen = [];
  const file = await downloadInstaller({
    url: `${base}/good`,
    name: "Kuvo-Code-Setup-0.7.3.exe",
    directory: folder,
    minimumBytes: 2,
    onProgress: (written, total) => seen.push([written, total]),
  });
  assert.ok(fs.existsSync(file));
  assert.deepEqual(fs.readFileSync(file), INSTALLER);
  assert.ok(seen.length > 0, "the download reports how far it got");
  assert.equal(seen.at(-1)[0], INSTALLER.length);
  assert.equal(seen.at(-1)[1], INSTALLER.length);
  // The name is not the release's own: a second attempt must not collide with it.
  assert.notEqual(path.basename(file), "Kuvo-Code-Setup-0.7.3.exe");
  assert.match(path.basename(file), /^Kuvo-Code-Setup-0\.7\.3-\d+-\d+\.exe$/);
  fs.rmSync(file, { force: true });
});

test("two attempts at the same version get two files", async () => {
  const first = await download("/good");
  const second = await download("/good");
  assert.notEqual(first, second);
  fs.rmSync(first, { force: true });
  fs.rmSync(second, { force: true });
});

test("a download that is not there leaves nothing behind", async () => {
  const before = files().length;
  await assert.rejects(download("/missing"), /download failed \(404\)/);
  assert.equal(files().length, before);
});

test("a page is not an installer, and is removed", async () => {
  const before = files().length;
  await assert.rejects(download("/not-an-installer"), /not a Windows program|only 4 bytes/);
  assert.equal(files().length, before);
});

test("a file too small to be an installer is removed", async () => {
  const before = files().length;
  await assert.rejects(download("/short", "Kuvo-Code-Setup-0.7.3.exe", 10), /not an installer|only 2 bytes/);
  assert.equal(files().length, before);
});

test("a connection that stops early is an error, not a half installer", async () => {
  const before = files().length;
  await assert.rejects(download("/cut-off"));
  assert.equal(files().length, before);
});

test("the installer starts on its own, and a missing one says so", async () => {
  // Node is this machine's own executable: what matters is that a real process starts
  // detached and the promise resolves when it does.
  await launchInstaller({ path: process.execPath, args: ["-e", ""] });
  await assert.rejects(
    launchInstaller({ path: path.join(folder, "not-here.exe") }),
    /ENOENT|no such file/i,
  );
});

test("installers an earlier attempt left behind are swept, the one in hand is not", async () => {
  const room = fs.mkdtempSync(path.join(folder, "sweep-"));
  const old = path.join(room, "Kuvo-Code-Setup-0.7.1-1-1.exe");
  const fresh = path.join(room, "Kuvo-Code-Setup-0.7.2-2-2.exe");
  const keep = path.join(room, "Kuvo-Code-Setup-0.7.3-3-3.exe");
  const other = path.join(room, "notes.txt");
  for (const file of [old, fresh, keep, other]) fs.writeFileSync(file, "x");
  const day = 24 * 60 * 60 * 1000;
  const now = Date.now();
  fs.utimesSync(old, new Date(now - 2 * day), new Date(now - 2 * day));
  const removed = await sweepInstallers(room, { keep, now });
  assert.deepEqual(removed, [old]);
  assert.ok(fs.existsSync(fresh), "today's installer is still there");
  assert.ok(fs.existsSync(keep), "the one in hand is still there");
  assert.ok(fs.existsSync(other), "files that are not installers are left alone");
  fs.rmSync(room, { recursive: true, force: true });
});
