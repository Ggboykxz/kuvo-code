// The Windows engine bootstrap, checked on whatever platform runs the tests: the pinned table,
// the checksum, an install from a registry on this machine, and a server started and stopped
// the way the Mac app starts the real one. Run with:
//   node --test windows/kuvo-engine.test.mjs

import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { after, test } from "node:test";
import { VERSION, dataRoot, normalizeMachine, releaseFor } from "./releases.mjs";
import { binaryPath, checkIntegrity, engineEnvironment, engineFolders, installed, install, integrityOf, launch } from "./kuvo-engine.mjs";

const home = fs.mkdtempSync(path.join(os.tmpdir(), "kuvo-engine-test-"));
after(() => fs.rmSync(home, { recursive: true, force: true }));
let counter = 0;
const scratch = name => {
  const folder = path.join(home, `${name}-${counter++}`);
  fs.mkdirSync(folder, { recursive: true });
  return folder;
};

// ---- The pinned table ----

test("every pinned release points at the opencode package for its platform", () => {
  for (const [platform, machine, packageName, binary] of [
    ["win32", "x64", "cli-windows-x64", "opencode.exe"],
    ["win32", "arm64", "cli-windows-arm64", "opencode.exe"],
    ["linux", "x64", "cli-linux-x64", "opencode"],
    ["linux", "arm64", "cli-linux-arm64", "opencode"],
  ]) {
    const release = releaseFor(platform, machine);
    assert.ok(release, `${platform}-${machine}`);
    assert.match(release.tarball, new RegExp(`/@opencode/${packageName}/-/`));
    assert.match(release.tarball, new RegExp(`-${VERSION}\\.tgz$`));
    assert.match(release.integrity, /^sha512-[A-Za-z0-9+/]+=*$/);
    assert.equal(release.binary, binary);
  }
  // The Mac app installs the Mac engine; this table doesn't pretend to.
  assert.equal(releaseFor("darwin", "arm64"), null);
  assert.equal(releaseFor("aix", "x64"), null);
});

test("machine names arrive as uname spells them", () => {
  assert.equal(normalizeMachine("x86_64"), "x64");
  assert.equal(normalizeMachine("amd64"), "x64");
  assert.equal(normalizeMachine("aarch64"), "arm64");
  assert.equal(normalizeMachine("x64"), "x64");
  assert.equal(normalizeMachine("riscv64"), "riscv64");
});

test("data roots land where each platform keeps apps", () => {
  assert.equal(dataRoot("win32", { LOCALAPPDATA: "C:\\Users\\me\\AppData\\Local" }, "C:\\Users\\me"), path.join("C:\\Users\\me\\AppData\\Local", "KuvoCode"));
  assert.equal(dataRoot("darwin", {}, "/Users/me"), path.join("/Users/me", "Library", "Application Support", "run.kuvo.code"));
  assert.equal(dataRoot("linux", {}, "/home/me"), path.join("/home/me", ".kuvo-code"));
});

// ---- Checksums ----

test("a checksum read in chunks matches one over the whole file", () => {
  const file = path.join(scratch("checksum"), "blob");
  const bytes = crypto.randomBytes(3 << 20);
  fs.writeFileSync(file, bytes);
  const expected = `sha512-${crypto.createHash("sha512").update(bytes).digest("base64")}`;
  assert.equal(integrityOf(file), expected);
  checkIntegrity(file, expected);
  assert.throws(() => checkIntegrity(file, `sha512-${Buffer.alloc(64).toString("base64")}`), /checksum/);
});

// ---- Installing from a registry ----

/// A registry on this machine holding one tarball, laid out as npm publishes them.
async function fakeRegistry(tarball) {
  const asked = [];
  const server = http.createServer((request, response) => {
    asked.push(request.url);
    if (request.url !== "/cli-test.tgz") return response.writeHead(404).end();
    response.writeHead(200, { "content-type": "application/octet-stream" });
    response.end(fs.readFileSync(tarball));
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  return { asked, url: `http://127.0.0.1:${server.address().port}/cli-test.tgz`, close: () => new Promise(resolve => server.close(resolve)) };
}

function fakePackage(name, contents) {
  const folder = scratch(name);
  fs.mkdirSync(path.join(folder, "package", "bin"), { recursive: true });
  fs.writeFileSync(path.join(folder, "package", "package.json"), JSON.stringify({ name: "cli-test", version: VERSION }));
  fs.writeFileSync(path.join(folder, "package", "bin", "opencode"), contents);
  const tarball = path.join(folder, "cli-test.tgz");
  execFileSync("tar", ["-czf", tarball, "-C", folder, "package"], { windowsHide: true });
  return tarball;
}

test("an install unpacks the verified tarball into place and skips a second download", async t => {
  const tarball = fakePackage("install", "#!/bin/sh\necho real engine\n");
  const registry = await fakeRegistry(tarball);
  t.after(registry.close);
  const root = scratch("root");
  fs.mkdirSync(path.join(root, "0.0.1")); // an older version, removed as the Mac removes them
  const release = { tarball: registry.url, integrity: integrityOf(tarball), binary: "opencode" };

  assert.equal(installed(root, release), null);
  const binary = await install({ root, release });
  assert.equal(binary, binaryPath(root, release));
  assert.equal(fs.readFileSync(binary, "utf8"), "#!/bin/sh\necho real engine\n");
  if (process.platform !== "win32") assert.ok(fs.statSync(binary).mode & 0o100, "the binary is executable");
  assert.deepEqual(fs.readdirSync(root).sort(), [VERSION]);
  assert.equal(registry.asked.length, 1);

  // Already there: no second download, the same path.
  assert.equal(await install({ root, release }), binary);
  assert.equal(registry.asked.length, 1);
});

test("a tarball whose checksum doesn't match is refused, and nothing is left behind", async t => {
  const tarball = fakePackage("tampered", "#!/bin/sh\necho real engine\n");
  // The registry starts serving something else after the checksum was taken.
  const tampered = path.join(home, "tampered.tgz");
  const bytes = fs.readFileSync(tarball);
  bytes[Math.floor(bytes.length / 2)] ^= 0xff;
  fs.writeFileSync(tampered, bytes);
  const registry = await fakeRegistry(tampered);
  t.after(registry.close);
  const root = scratch("tampered-root");

  await assert.rejects(install({ root, release: { tarball: registry.url, integrity: integrityOf(tarball), binary: "opencode" } }), /checksum/);
  assert.deepEqual(fs.readdirSync(root), []);
});

test("a package without the binary is refused", async t => {
  const folder = scratch("empty-package");
  fs.mkdirSync(path.join(folder, "package"), { recursive: true });
  fs.writeFileSync(path.join(folder, "package", "package.json"), "{}");
  const tarball = path.join(folder, "cli-test.tgz");
  execFileSync("tar", ["-czf", tarball, "-C", folder, "package"], { windowsHide: true });
  const registry = await fakeRegistry(tarball);
  t.after(registry.close);
  const root = scratch("empty-root");
  await assert.rejects(install({ root, release: { tarball: registry.url, integrity: integrityOf(tarball), binary: "opencode" } }), /didn't hold/);
});

// ---- Starting it ----

/// A stand-in for the engine: says where it's listening, then lives until stdin closes.
function fakeServer(name, body) {
  const file = path.join(scratch(name), "server.mjs");
  fs.writeFileSync(file, body);
  return file;
}

test("the engine's folders and environment are the Mac app's, with Windows' temporary names", () => {
  const data = path.join(os.tmpdir(), "kuvo-opencode");
  const temporary = path.join(os.tmpdir(), "kuvo-engine-tmp");
  const folders = engineFolders(data, temporary);
  const environment = engineEnvironment(folders, "hunter2", "linux");
  assert.equal(environment.XDG_DATA_HOME, path.join(data, "data"));
  assert.equal(environment.XDG_CONFIG_HOME, path.join(data, "config"));
  assert.equal(environment.XDG_STATE_HOME, path.join(data, "state"));
  assert.equal(environment.XDG_CACHE_HOME, path.join(data, "cache"));
  assert.equal(environment.npm_config_cache, path.join(data, "cache", "npm"));
  assert.equal(environment.BUN_INSTALL, path.join(data, "cache", "bun"));
  assert.equal(environment.TMPDIR, temporary + path.sep);
  assert.equal(environment.OPENCODE_PASSWORD, "hunter2");
  assert.equal(environment.OPENCODE_CLIENT, "desktop");
  assert.equal(environment.TEMP, undefined);
  const windows = engineEnvironment(folders, "hunter2", "win32");
  assert.equal(windows.TEMP, temporary);
  assert.equal(windows.TMP, temporary);
});

test("a server that says where it's listening starts, and stops when stdin closes", async () => {
  const server = fakeServer("handshake", `
    console.log(JSON.stringify({
      url: "http://127.0.0.1:1234",
      xdg: process.env.XDG_DATA_HOME,
      tmp: process.env.TMPDIR,
      client: process.env.OPENCODE_CLIENT,
      secret: process.env.OPENCODE_PASSWORD,
      inherited: process.env.OPENCODE_SERVER_PASSWORD ?? null,
    }));
    process.stdin.resume();
    process.stdin.on("end", () => process.exit(0));
  `);
  const root = scratch("handshake-root");
  const folders = engineFolders(root, path.join(root, "tmp"));
  const engine = await launch({
    binary: process.execPath,
    args: [server],
    folders,
    environment: { ...process.env, OPENCODE_SERVER_PASSWORD: "a phone's old secret" },
  });
  assert.equal(engine.url, "http://127.0.0.1:1234");
  assert.match(engine.password, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(engine.handshake.xdg, path.join(root, "data"));
  assert.equal(engine.handshake.tmp, path.join(root, "tmp") + path.sep);
  assert.equal(engine.handshake.client, "desktop");
  assert.equal(engine.handshake.secret, engine.password);
  assert.equal(engine.handshake.inherited, null, "OPENCODE_SERVER_PASSWORD is not passed on");

  await engine.stop();
  assert.notEqual(engine.process.exitCode, null);
  await engine.stop(); // stopping twice is nothing
});

test("a server that stops while starting says why", async () => {
  const server = fakeServer("early-exit", `
    console.error("database is locked");
    process.exit(3);
  `);
  const root = scratch("early-exit-root");
  await assert.rejects(
    launch({ binary: process.execPath, args: [server], folders: engineFolders(root, path.join(root, "tmp")), timeout: 10_000 }),
    error => /exit code 3/.test(error.message) && /database is locked/.test(error.message),
  );
});

test("a server that never says where it's listening is given up on", async () => {
  const server = fakeServer("silent", `setTimeout(() => {}, 60_000);`);
  const root = scratch("silent-root");
  const started = Date.now();
  await assert.rejects(
    launch({ binary: process.execPath, args: [server], folders: engineFolders(root, path.join(root, "tmp")), timeout: 500 }),
    /took too long/,
  );
  assert.ok(Date.now() - started < 10_000);
});

test("a binary that isn't there fails at once, not after the timeout", async () => {
  const root = scratch("missing-root");
  await assert.rejects(
    launch({ binary: path.join(root, "nope.exe"), folders: engineFolders(root, path.join(root, "tmp")), timeout: 60_000 }),
    error => error.code === "ENOENT",
  );
});
