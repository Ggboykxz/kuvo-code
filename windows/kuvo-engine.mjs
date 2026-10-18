#!/usr/bin/env node
// The opencode engine for a Windows harness (and anywhere else this is run): installs the
// pinned build, checks it against npm's checksum before unpacking, and starts it the way the
// Mac app does — `opencode serve --stdio --port 0`, `{"url": …}` as the first line of stdout,
// and stdin closing as the signal to shut down. What Packages/OpenCodeKit does for the Mac,
// in Node, so a Windows client starts from the same contract.
//
//   node windows/kuvo-engine.mjs install    download and install the pinned build
//   node windows/kuvo-engine.mjs launch     install if needed, start it, print {url, password}
//   node windows/kuvo-engine.mjs e2e        install, start, call it, stop: a real check
//   node windows/kuvo-engine.mjs path       print where the binary would be
//
// KUVO_ENGINE_ROOT       where builds live (default: per-platform data folder, see releases.mjs)
// KUVO_OPENCODE_BINARY   use this binary instead of installing one

import { spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";
import { VERSION, dataRoot, normalizeMachine, releaseFor } from "./releases.mjs";

// ---- Where things live ----

export function engineRoot() {
  return process.env.KUVO_ENGINE_ROOT ?? path.join(dataRoot(), "engine");
}

/// The engine's own folders, as EngineFolders makes them on the Mac: its database, settings,
/// state and caches in one root, its workspace the default project, its scratch files away
/// from the shared temporary folder. A sibling of the install root, the way the Mac app keeps
/// `engine/` and `opencode/` side by side.
export function engineFolders(root = path.join(dataRoot(), "opencode"), temporary = path.join(os.tmpdir(), "kuvo-engine")) {
  return {
    root,
    workspace: path.join(root, "workspace"),
    temporary,
  };
}

/// The environment ServerProcess hands the engine, with Windows' own names for the temporary
/// folder beside TMPDIR.
export function engineEnvironment(folders, password, platform = process.platform) {
  const environment = {
    XDG_DATA_HOME: path.join(folders.root, "data"),
    XDG_CONFIG_HOME: path.join(folders.root, "config"),
    XDG_STATE_HOME: path.join(folders.root, "state"),
    XDG_CACHE_HOME: path.join(folders.root, "cache"),
    // What MCP servers it runs with npx or bunx download, in its own cache too.
    npm_config_cache: path.join(folders.root, "cache", "npm"),
    BUN_INSTALL: path.join(folders.root, "cache", "bun"),
    // Temporary files of its own and of what it runs, rather than the machine's shared folder.
    TMPDIR: folders.temporary + path.sep,
    OPENCODE_PASSWORD: password,
    // Tells the server it's driven by a desktop GUI, as opencode's own desktop app sends.
    OPENCODE_CLIENT: "desktop",
  };
  if (platform === "win32") {
    environment.TEMP = folders.temporary;
    environment.TMP = folders.temporary;
  }
  return environment;
}

function prepareFolders(folders) {
  for (const folder of [folders.workspace, folders.temporary, path.join(folders.root, "data"), path.join(folders.root, "config"), path.join(folders.root, "state"), path.join(folders.root, "cache")]) {
    fs.mkdirSync(folder, { recursive: true });
  }
}

// ---- Installing the pinned build ----

/// npm's `dist.integrity` for a file: `sha512-<base64>`, read in chunks so a 100 MB download
/// isn't held in memory twice.
export function integrityOf(file) {
  const hash = crypto.createHash("sha512");
  const handle = fs.openSync(file, "r");
  try {
    const buffer = Buffer.alloc(1 << 20);
    for (let read; (read = fs.readSync(handle, buffer, 0, buffer.length)) > 0;) hash.update(buffer.subarray(0, read));
  } finally {
    fs.closeSync(handle);
  }
  return `sha512-${hash.digest("base64")}`;
}

export function checkIntegrity(file, expected) {
  if (integrityOf(file) !== expected) throw new Error("The downloaded engine didn't match its checksum.");
}

export function binaryPath(root = engineRoot(), release = releaseFor()) {
  if (!release) throw new Error(`No pinned engine for ${process.platform}-${normalizeMachine(process.arch)}.`);
  return path.join(root, VERSION, release.binary);
}

/// The installed binary, if it's there. macOS re-checks opencode's signature on every launch;
/// Windows builds have none to check, so the checksum at download time is the whole story.
export function installed(root = engineRoot(), release = releaseFor()) {
  if (!release) return null;
  const binary = binaryPath(root, release);
  return fs.existsSync(binary) ? binary : null;
}

async function downloadRelease(release, doFetch) {
  const file = path.join(os.tmpdir(), `kuvo-engine-${crypto.randomBytes(6).toString("hex")}.tgz`);
  const response = await doFetch(release.tarball);
  if (!response.ok) throw new Error(`The engine download failed (HTTP ${response.status}).`);
  await pipeline(Readable.fromWeb(response.body), fs.createWriteStream(file));
  return file;
}

/// `tar` unpacks: Windows 10 and later ship it, as do macOS and the Linux machines.
export function untar(archive, directory) {
  const result = spawnSync("tar", ["-xzf", archive, "-C", directory], { encoding: "utf8", windowsHide: true });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`The engine couldn't be unpacked. ${result.stderr ?? ""}`.trim());
}

/// Downloads, verifies and unpacks into `<root>/<version>/<binary>`; an install already there
/// is left alone. Unpacking happens beside the final place and only the binary moves in, so a
/// crash never leaves a half-written one where `installed` would find it.
export async function install({ root = engineRoot(), release = releaseFor(), fetch: doFetch = fetch, log = () => {} } = {}) {
  if (!release) throw new Error(`No pinned engine for ${process.platform}-${normalizeMachine(process.arch)}.`);
  const present = installed(root, release);
  if (present) return present;

  log(`Downloading opencode ${VERSION} for ${normalizeMachine(process.arch)}…`);
  const download = await downloadRelease(release, doFetch);
  const staging = path.join(root, `.staging-${crypto.randomUUID()}`);
  try {
    checkIntegrity(download, release.integrity);
    fs.mkdirSync(staging, { recursive: true });
    untar(download, staging);
    const unpacked = path.join(staging, "package", "bin", release.binary);
    if (!fs.existsSync(unpacked)) throw new Error(`The engine package didn't hold ${release.binary}.`);

    const destination = path.dirname(binaryPath(root, release));
    fs.rmSync(destination, { recursive: true, force: true });
    fs.mkdirSync(destination, { recursive: true });
    const binary = path.join(destination, release.binary);
    fs.renameSync(unpacked, binary);
    if (process.platform !== "win32") fs.chmodSync(binary, 0o755);
    for (const entry of fs.readdirSync(root)) {
      if (entry !== VERSION && !entry.startsWith(".")) fs.rmSync(path.join(root, entry), { recursive: true, force: true });
    }
    return binary;
  } finally {
    fs.rmSync(download, { force: true });
    fs.rmSync(staging, { recursive: true, force: true });
  }
}

// ---- Starting it ----

const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

/// The last few kilobytes of a stream, for error reports.
class Tail {
  #text = "";
  append(chunk) {
    this.#text = (this.#text + chunk.toString()).slice(-16 * 1024);
  }
  get text() {
    return this.#text;
  }
}

/// The first line of stdout, parsed: `{"url": …}` once the server is listening.
function readHandshake(child, timeout, tail, kill) {
  return new Promise((resolve, reject) => {
    let line = "";
    const timer = setTimeout(() => {
      kill();
      reject(new Error("The engine took too long to start."));
    }, timeout);
    const settle = (error, value) => {
      clearTimeout(timer);
      child.stdout.off("data", onData);
      child.off("exit", onExit);
      error ? reject(error) : resolve(value);
    };
    const onData = chunk => {
      const newline = chunk.indexOf(0x0a);
      if (newline < 0) {
        line += chunk.toString();
        return;
      }
      line += chunk.subarray(0, newline).toString();
      let handshake;
      try {
        handshake = JSON.parse(line);
      } catch {
        return settle(new Error(`The engine said something unexpected when starting: ${line}`));
      }
      if (typeof handshake?.url !== "string") return settle(new Error(`The engine said something unexpected when starting: ${line}`));
      settle(null, handshake);
    };
    const onExit = code => setTimeout(() => settle(new Error(`The engine stopped (exit code ${code}).${tail.text === "" ? "" : `\n\n${tail.text}`}`)), 100);
    child.stdout.on("data", onData);
    child.once("exit", onExit);
  });
}

/// Starts `serve --stdio --port 0` and waits until it's listening. Closing stdin stops it,
/// after a five-second grace, so it can't outlive whoever started it; the returned `stop`
/// resolves once the process has gone.
export async function launch({ binary, folders = engineFolders(), timeout = 60_000, args = ["serve", "--stdio", "--port", "0"], environment = process.env, log = () => {} } = {}) {
  if (!binary) throw new Error("launch needs a binary (install one first).");
  prepareFolders(folders);
  const password = crypto.randomBytes(32).toString("base64url");

  const childEnvironment = { ...environment };
  delete childEnvironment.OPENCODE_SERVER_PASSWORD;
  Object.assign(childEnvironment, engineEnvironment(folders, password, process.platform));

  const child = spawn(binary, args, {
    cwd: folders.workspace,
    env: childEnvironment,
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });
  const tail = new Tail();
  child.stderr.on("data", chunk => tail.append(chunk));
  const exited = new Promise(resolve => {
    if (child.exitCode !== null) return resolve(child.exitCode);
    child.once("exit", resolve);
  });
  const kill = () => {
    child.kill();
  };

  let handshake;
  try {
    // A binary that isn't there fails here, at once, rather than at the handshake timeout.
    await new Promise((resolve, reject) => {
      child.once("spawn", resolve);
      child.once("error", reject);
    });
    handshake = await readHandshake(child, timeout, tail, kill);
  } catch (error) {
    kill();
    throw error;
  }
  // Keep draining stdout so the server never blocks on a full pipe.
  child.stdout.resume();
  log(`opencode ${VERSION} listening at ${handshake.url}`);

  let stopped = false;
  const stop = async () => {
    if (stopped) return;
    stopped = true;
    try {
      child.stdin.end();
    } catch {}
    const gone = await Promise.race([exited.then(() => true), sleep(5_000).then(() => false)]);
    if (!gone) {
      kill();
      await Promise.race([exited, sleep(2_000)]);
    }
  };
  return { url: handshake.url, password, handshake, process: child, stop, recentOutput: () => tail.text };
}

// ---- End to end ----

/// What CI and the first run of a client use: install the pinned build, start it, ask it for
/// its info with the password it printed, check it turned away a caller without one, stop it.
export async function e2e({ log = console.log } = {}) {
  const release = releaseFor();
  if (!release) throw new Error(`No pinned engine for ${process.platform}-${normalizeMachine(process.arch)}.`);
  const binary = process.env.KUVO_OPENCODE_BINARY ?? await install({ release, log });
  const engine = await launch({ binary, log });
  try {
    const url = new URL("api/info", engine.url.endsWith("/") ? engine.url : `${engine.url}/`);
    const authorization = `Basic ${Buffer.from(`opencode:${engine.password}`).toString("base64")}`;
    const answered = await fetch(url, { headers: { authorization } });
    if (!answered.ok) throw new Error(`The engine refused its own password (HTTP ${answered.status}).`);
    const info = await answered.json();
    const refused = await fetch(url);
    if (refused.ok) throw new Error("The engine answered without a password.");
    log(`ok: opencode ${info.version ?? VERSION} at ${engine.url}, and it wants the password`);
    return { url: engine.url, info };
  } finally {
    await engine.stop();
  }
}

// ---- Command line ----

const main = process.argv[1] && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url));
if (main) {
  const [command] = process.argv.slice(2);
  try {
    if (command === "install") {
      console.log(await install({ log: message => console.error(message) }));
    } else if (command === "path") {
      console.log(binaryPath());
    } else if (command === "launch") {
      const binary = process.env.KUVO_OPENCODE_BINARY ?? await install({ log: message => console.error(message) });
      const engine = await launch({ binary });
      console.log(JSON.stringify({ url: engine.url, password: engine.password }));
      // Keep it running until whoever started this has gone: stdin closing is the signal.
      process.stdin.resume();
      process.stdin.on("end", async () => {
        await engine.stop();
        process.exit(0);
      });
    } else if (command === "e2e") {
      await e2e({ log: message => console.error(message) });
    } else {
      console.error("Usage: kuvo-engine.mjs install | launch | e2e | path");
      process.exit(2);
    }
  } catch (error) {
    console.error(error.message ?? error);
    process.exit(1);
  }
}
