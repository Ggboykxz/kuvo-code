// Downloading the installer, and starting it.
//
// Two things this must survive, because they are how an update fails on a real machine:
//
// - A name of its own for every attempt. The installer is an .exe, and Windows holds it
//   while it runs: a second attempt at the same version used to write over a file the
//   first installer still had open, and the write failed.
// - The body streamed to disk. The installer is about 110 MB; reading it whole into the
//   main process's memory to write it out again is the wrong shape for a background job.
//
// The bytes are checked before anything runs: the length the server promised, a floor for
// what an installer can be, and the "MZ" every Windows program starts with. A half-written
// file is removed rather than left for Windows to try.

const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");
const { Readable, Transform } = require("stream");
const { pipeline } = require("stream/promises");

// An installer is about 110 MB. Anything under this is a page, an error, or half a file.
const MINIMUM_BYTES = 40 * 1024 * 1024;

/// The file's own name, if it is one we are willing to run: an .exe, with no path in it.
function safeName(name) {
  const base = String(name ?? "").split(/[\\/]/).pop() ?? "";
  if (!base || !/\.exe$/i.test(base) || base.includes("..")) return null;
  return base;
}

/// Download `url` into `directory`, under a name no other attempt is using. Resolves with
/// the file's path; rejects — and leaves nothing behind — when the bytes are not an installer.
async function downloadInstaller({
  url,
  name,
  directory,
  fetch: doFetch = fetch,
  onProgress = () => {},
  minimumBytes = MINIMUM_BYTES,
}) {
  const base = safeName(name);
  if (!base) throw new Error("that download's name isn't allowed.");
  await fs.promises.mkdir(directory, { recursive: true });
  const target = path.join(directory, `${base.replace(/\.exe$/i, "")}-${process.pid}-${Date.now()}.exe`);

  const response = await doFetch(url, { headers: { "user-agent": "Kuvo-Code" }, redirect: "follow" });
  if (!response.ok) throw new Error(`the download failed (${response.status})`);
  const total = Number(response.headers.get("content-length") ?? 0);
  let written = 0;

  try {
    const body = response.body
      ? Readable.fromWeb(response.body)
      : Readable.from(Buffer.from(await response.arrayBuffer()));
    const counter = new Transform({
      transform(chunk, _encoding, done) {
        written += chunk.length;
        onProgress(written, total);
        done(null, chunk);
      },
    });
    await pipeline(body, counter, fs.createWriteStream(target, { flags: "wx" }));

    if (total && written !== total) throw new Error(`the download stopped at ${written} of ${total} bytes`);
    if (written < minimumBytes) throw new Error(`the download is only ${written} bytes, not an installer`);
    const handle = await fs.promises.open(target, "r");
    try {
      const header = Buffer.alloc(2);
      await handle.read(header, 0, 2, 0);
      if (header.toString("latin1") !== "MZ") throw new Error("the download is not a Windows program");
    } finally {
      await handle.close();
    }
    return target;
  } catch (error) {
    await fs.promises.rm(target, { force: true });
    throw error;
  }
}

/// Start the installer on its own, so this process can go away and let it replace the files.
/// Rejects when it could not be started at all; the caller decides what to try next.
function launchInstaller({ path: file, args = [], spawn: doSpawn = spawn }) {
  return new Promise((resolve, reject) => {
    let child;
    try {
      child = doSpawn(file, args, { detached: true, stdio: "ignore", windowsHide: false });
    } catch (error) {
      reject(error);
      return;
    }
    child.once("error", reject);
    child.once("spawn", () => {
      child.unref();
      resolve();
    });
  });
}

/// Installers an earlier attempt left behind: older than a day, and not the one in hand.
async function sweepInstallers(directory, { keep = null, maxAgeMs = 24 * 60 * 60 * 1000, now = Date.now() } = {}) {
  let names = [];
  try {
    names = await fs.promises.readdir(directory);
  } catch {
    return [];
  }
  const removed = [];
  for (const name of names) {
    if (!/^Kuvo-Code-Setup-.*\.exe$/i.test(name)) continue;
    const file = path.join(directory, name);
    if (keep && path.resolve(file) === path.resolve(keep)) continue;
    try {
      const stat = await fs.promises.stat(file);
      if (now - stat.mtimeMs < maxAgeMs) continue;
      await fs.promises.rm(file, { force: true });
      removed.push(file);
    } catch {}
  }
  return removed;
}

module.exports = { MINIMUM_BYTES, safeName, downloadInstaller, launchInstaller, sweepInstallers };
