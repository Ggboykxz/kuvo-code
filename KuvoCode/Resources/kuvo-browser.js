// Kuvo Code's browser on a machine: a Chromium kept running there, which the agent browses with
// and the app shows live in its panel. The engine's own runtime runs it, so the machine needs
// nothing else:
//
//   BUN_BE_BUN=1 opencode kuvo-browser.js mcp       the agent's browser tools, for the engine
//   BUN_BE_BUN=1 opencode kuvo-browser.js connect   the app's live view, over SSH
//   BUN_BE_BUN=1 opencode kuvo-browser.js host      the keeper, started by either of the others
//
// The keeper drives Chromium over a pipe, never a port, and lets the others in through a socket
// in ~/.kuvo-code/run, a folder only this user can open. It relays Chrome's DevTools protocol to
// each, and keeps which page is in use, so the agent and the app follow each other. It stops
// Chromium after a while with nobody connected.
//
// The app writes this file to the machine, with the browsing scripts and tools filled in below.

import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";

const CONFIG = /*KUVO_CONFIG*/ { scripts: {}, tools: [], instructions: "", version: "dev" };

const K = process.env.KUVO_HOME || path.join(os.homedir(), ".kuvo-code");
const RUN = path.join(K, "run");
const SOCKET = path.join(RUN, "browser.sock");
const PIDFILE = path.join(RUN, "browser.pid");
const ERRORFILE = path.join(RUN, "browser.error");
const LOGFILE = path.join(RUN, "browser.log");
const BROWSER = path.join(K, "browser");
// The installed Chromium, with the libraries and fonts it needs.
const CURRENT = path.join(BROWSER, "current");
// Website data: cookies and sign-ins stay between starts.
const PROFILE = path.join(BROWSER, "profile");
const SCRIPT = process.argv[1];
// How long Chromium keeps running with nobody connected.
const IDLE = Number(process.env.KUVO_BROWSER_IDLE || 10 * 60) * 1000;

// Goes up with every change to the keeper (host mode): a newer one replaces one that's running
// (its pages close, its sign-ins stay), and an older one never replaces a newer.
const KEEPER = 4;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/// Calls `handle` with each line `stream` sends.
function lines(stream, handle, separator = "\n") {
  let buffer = "";
  stream.setEncoding("utf8");
  stream.on("data", (chunk) => {
    buffer += chunk;
    let end;
    while ((end = buffer.indexOf(separator)) >= 0) {
      const line = buffer.slice(0, end);
      buffer = buffer.slice(end + 1);
      if (line) handle(line);
    }
  });
}

/// Whether a keeper answers on the socket.
function reachable() {
  return new Promise((resolve) => {
    const socket = net.createConnection(SOCKET);
    const done = (value) => {
      clearTimeout(timer);
      socket.destroy();
      resolve(value);
    };
    const timer = setTimeout(() => done(false), 1500);
    socket.once("connect", () => done(true));
    socket.once("error", () => done(false));
  });
}

/// The running keeper's version, from its greeting (1 before keepers said).
function runningKeeper() {
  return new Promise((resolve) => {
    const socket = net.createConnection(SOCKET);
    let buffer = "";
    const done = (value) => {
      clearTimeout(timer);
      socket.destroy();
      resolve(value);
    };
    const timer = setTimeout(() => done(null), 2000);
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      buffer += chunk;
      const end = buffer.indexOf("\n");
      if (end < 0) return;
      try {
        done(JSON.parse(buffer.slice(0, end)).params?.keeper ?? 1);
      } catch {
        done(1);
      }
    });
    socket.once("error", () => done(null));
  });
}

/// Asks the running keeper to stop, and waits until it has.
async function stopKeeper() {
  await new Promise((resolve) => {
    const socket = net.createConnection(SOCKET);
    socket.once("connect", () => socket.end(JSON.stringify({ method: "Kuvo.stop" }) + "\n", resolve));
    socket.once("error", resolve);
  });
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline && (await reachable())) await sleep(200);
}

/// Starts the keeper if it isn't running (or an older one is), and waits for it: nil once it
/// answers, else what's wrong.
async function ensure() {
  if (await reachable()) {
    const running = await runningKeeper();
    if (running === null || running >= KEEPER) return null;
    await stopKeeper();
  }
  if (!fs.existsSync(path.join(CURRENT, "chrome-headless-shell"))) {
    return { kind: "missing", message: "The browser isn't on this machine yet. Kuvo Code puts it there when it connects to the machine; try again in a minute." };
  }
  fs.mkdirSync(RUN, { recursive: true, mode: 0o700 });
  fs.rmSync(ERRORFILE, { force: true });
  // In a session of its own, so it outlives whoever started it.
  const child = spawn(process.execPath, [SCRIPT, "host"], { detached: true, stdio: "ignore", env: { ...process.env, BUN_BE_BUN: "1" }, cwd: BROWSER });
  child.unref();
  const deadline = Date.now() + 45_000;
  while (Date.now() < deadline) {
    await sleep(150);
    if (await reachable()) return null;
    if (fs.existsSync(ERRORFILE)) {
      try {
        return JSON.parse(fs.readFileSync(ERRORFILE, "utf8"));
      } catch {}
    }
  }
  return { kind: "failed", message: "The browser took too long to start." };
}

// MARK: - The keeper

function alive(pid) {
  if (!pid || pid === process.pid) return false;
  try {
    process.kill(pid, 0);
  } catch {
    return false;
  }
  try {
    return fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").includes("kuvo-browser");
  } catch {
    return true;
  }
}

/// Becomes the one keeper, unless another is running. The record of who it is appears whole (a
/// link to a file already written), so another keeper never reads it half-written; one that's left
/// from a keeper that died is taken over, and if two start at that moment, the one whose record
/// stays keeps going.
async function claim() {
  const mine = `${PIDFILE}.${process.pid}`;
  fs.writeFileSync(mine, String(process.pid), { mode: 0o600 });
  try {
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        fs.linkSync(mine, PIDFILE);
        await sleep(100 + Math.random() * 200);
        return Number(fs.readFileSync(PIDFILE, "utf8")) === process.pid;
      } catch (error) {
        if (error.code !== "EEXIST") throw error;
        let holder = 0;
        try {
          holder = Number(fs.readFileSync(PIDFILE, "utf8"));
        } catch {}
        if (alive(holder)) return false;
        fs.rmSync(PIDFILE, { force: true });
      }
    }
    return false;
  } finally {
    fs.rmSync(mine, { force: true });
  }
}

function fail(kind, message) {
  fs.writeFileSync(ERRORFILE, JSON.stringify({ kind, message }), { mode: 0o600 });
  fs.rmSync(PIDFILE, { force: true });
  process.exit(1);
}

function chromiumVersion() {
  try {
    return fs.readFileSync(path.join(CURRENT, "chromium-version"), "utf8").trim();
  } catch {
    return "130.0.0.0";
  }
}

// What the browser says it is: Chromium on Linux. Sites serve a reduced page, or none, to one that
// says "HeadlessChrome" (x.com answers 403), and it says so in two places: the user agent, and
// the brand hints (Sec-CH-UA) pages send and read.
function userAgent() {
  const major = chromiumVersion().split(".")[0];
  const platform = process.arch === "arm64" ? "aarch64" : "x86_64";
  return `Mozilla/5.0 (X11; Linux ${platform}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${major}.0.0.0 Safari/537.36`;
}

function identity() {
  const version = chromiumVersion();
  const major = version.split(".")[0];
  return {
    userAgent: userAgent(),
    userAgentMetadata: {
      brands: [{ brand: "Chromium", version: major }, { brand: "Not-A.Brand", version: "24" }],
      fullVersionList: [{ brand: "Chromium", version }, { brand: "Not-A.Brand", version: "24.0.0.0" }],
      platform: "Linux",
      platformVersion: "",
      architecture: process.arch === "arm64" ? "arm" : "x86",
      bitness: "64",
      model: "",
      mobile: false,
    },
  };
}

/// Starts Chromium and waits until it answers on its pipe.
async function launchChrome(sandbox) {
  const args = [
    "--remote-debugging-pipe",
    `--user-data-dir=${PROFILE}`,
    "--window-size=1280,800",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-dev-shm-usage",
    "--hide-scrollbars",
    "--mute-audio",
    `--user-agent=${userAgent()}`,
    "about:blank",
  ];
  if (!sandbox) args.unshift("--no-sandbox");
  // The build's own folder rather than `current`, which an update moves: its path shows which
  // build a running browser uses, so the update leaves that one in place.
  const build = fs.realpathSync(CURRENT);
  const lib = path.join(build, "lib");
  // A home of its own, inside Kuvo Code's folder: what Chromium keeps there (its certificate store,
  // caches, downloads) never lands in the user's.
  const home = path.join(BROWSER, "home");
  fs.mkdirSync(home, { recursive: true, mode: 0o700 });
  // The build's fonts, and the machine's own if it has any, with fontconfig's cache in that home
  // (written with whole paths: a relative one lands wherever the browser happens to start).
  const fontsConfig = path.join(home, "fonts.conf");
  const xml = (text) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;");
  fs.writeFileSync(fontsConfig, [
    '<?xml version="1.0"?>',
    '<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">',
    "<fontconfig>",
    `  <dir>${xml(path.join(build, "fonts"))}</dir>`,
    '  <include ignore_missing="yes">/etc/fonts/fonts.conf</include>',
    `  <cachedir>${xml(path.join(home, ".cache", "fontconfig"))}</cachedir>`,
    "  <alias><family>sans-serif</family><prefer><family>Liberation Sans</family><family>DejaVu Sans</family></prefer></alias>",
    "  <alias><family>serif</family><prefer><family>Liberation Serif</family><family>DejaVu Sans</family></prefer></alias>",
    "  <alias><family>monospace</family><prefer><family>Liberation Mono</family><family>DejaVu Sans</family></prefer></alias>",
    "  <alias><family>emoji</family><prefer><family>Noto Color Emoji</family></prefer></alias>",
    "</fontconfig>",
    "",
  ].join("\n"));
  const env = {
    ...process.env,
    HOME: home,
    XDG_CONFIG_HOME: path.join(home, ".config"),
    XDG_CACHE_HOME: path.join(home, ".cache"),
    XDG_DATA_HOME: path.join(home, ".local", "share"),
    XDG_STATE_HOME: path.join(home, ".local", "state"),
    // Its own libraries and fonts, never the machine's: nothing has to be installed there.
    LD_LIBRARY_PATH: [lib, process.env.LD_LIBRARY_PATH].filter(Boolean).join(":"),
    FONTCONFIG_FILE: fontsConfig,
    GIO_MODULE_DIR: path.join(lib, "gio-modules"),
    GSETTINGS_BACKEND: "memory",
  };
  delete env.BUN_BE_BUN;
  const log = fs.openSync(LOGFILE, "a", 0o600);
  fs.writeSync(log, `--- ${new Date().toISOString()} starting${sandbox ? "" : " without the sandbox"}\n`);
  const chrome = spawn(path.join(build, "chrome-headless-shell"), args, { stdio: ["ignore", log, log, "pipe", "pipe"], env, cwd: home });
  fs.closeSync(log);
  let exited = null;
  chrome.on("exit", (code, signal) => (exited = { code, signal }));
  chrome.on("error", (error) => (exited = { code: -1, error }));
  const pipe = { input: chrome.stdio[3], output: chrome.stdio[4] };
  pipe.input.on("error", () => {});

  // Asks for its version; Chromium answers once it's up.
  const answered = new Promise((resolve) => {
    let buffer = "";
    const listen = (chunk) => {
      buffer += chunk;
      if (buffer.includes('"id":1,')) {
        pipe.output.off("data", listen);
        resolve(true);
      }
    };
    pipe.output.setEncoding("utf8");
    pipe.output.on("data", listen);
  });
  pipe.input.write(JSON.stringify({ id: 1, method: "Browser.getVersion" }) + "\0");
  const deadline = Date.now() + 30_000;
  let ready = false;
  answered.then(() => (ready = true));
  while (!ready && !exited && Date.now() < deadline) await sleep(50);
  if (ready) return { chrome, pipe };
  chrome.kill("SIGKILL");
  let output = "";
  try {
    output = fs.readFileSync(LOGFILE, "utf8");
  } catch {}
  return { output: output || (exited?.error ? String(exited.error.message) : ""), timedOut: !exited };
}

async function host() {
  fs.mkdirSync(RUN, { recursive: true, mode: 0o700 });
  fs.chmodSync(RUN, 0o700);
  if (!(await claim())) return;
  // A socket left behind by a keeper that's gone.
  if (await reachable()) {
    fs.rmSync(PIDFILE, { force: true });
    return;
  }
  fs.rmSync(SOCKET, { force: true });
  fs.mkdirSync(PROFILE, { recursive: true, mode: 0o700 });
  fs.writeFileSync(LOGFILE, "", { mode: 0o600 });

  // Sandboxed when the machine allows it (it needs user namespaces, which some distributions turn
  // off); as root, or where Chromium says it can't be, without. Anything else gets a second try.
  const isRoot = process.getuid && process.getuid() === 0;
  let sandbox = !isRoot;
  let started = await launchChrome(sandbox);
  if (!started.chrome && sandbox && /No usable sandbox|SUID sandbox|user namespace/i.test(started.output)) sandbox = false;
  if (!started.chrome) started = await launchChrome(sandbox);
  if (!started.chrome) {
    const lines = started.output.trim().split("\n").filter((line) => !/^\s*$/.test(line)).slice(-6).join("\n");
    if (/GLIBC_[0-9.]+' not found/.test(started.output)) {
      fail("unsupported", "This machine's C library (glibc) is too old for the browser.\n\n" + lines);
    }
    fail("failed", (started.timedOut ? "The browser didn't start in time." : "The browser stopped as it started.") + (lines ? "\n\n" + lines : ""));
  }
  const { chrome, pipe } = started;

  let next = 2;
  const pending = new Map();
  const owners = new Map();
  const clients = new Set();
  let active = null;
  // The pages there are, so the one in use is always one of them.
  const targets = new Set();
  // The keeper's own session with each page and worker, which says what the browser is before
  // it loads anything; the ones clients open come after it.
  const own = new Map();
  const browserIdentity = identity();
  let status = { working: false };
  let idle = null;
  // What agents ask the user for (a sign-in, a code, a step), by ID: who asked, and the ask. The
  // answer goes to the one who asked, and no one else.
  const asks = new Map();
  const closeAsk = (id) => {
    if (asks.delete(id)) broadcast({ method: "Kuvo.askClosed", params: { id } });
  };

  const send = (client, message) => {
    if (!client.closed) client.socket.write((typeof message === "string" ? message : JSON.stringify(message)) + "\n");
  };
  const broadcast = (message) => {
    const text = typeof message === "string" ? message : JSON.stringify(message);
    for (const client of clients) send(client, text);
  };
  const toChrome = (message) => pipe.input.write(JSON.stringify(message) + "\0");
  const internal = (method, params = {}) => {
    const id = next++;
    pending.set(id, { internal: true });
    toChrome({ id, method, params });
  };
  const setActive = (targetId, by) => {
    if (active === targetId) return;
    active = targetId;
    broadcast({ method: "Kuvo.activeChanged", params: { targetId, by } });
  };

  let stopping = false;
  const stop = async () => {
    if (stopping) return;
    stopping = true;
    try {
      toChrome({ id: next++, method: "Browser.close" });
    } catch {}
    const deadline = Date.now() + 3000;
    while (chrome.exitCode === null && chrome.signalCode === null && Date.now() < deadline) await sleep(50);
    chrome.kill("SIGKILL");
    cleanUp();
    process.exit(0);
  };
  const cleanUp = () => {
    fs.rmSync(SOCKET, { force: true });
    try {
      if (Number(fs.readFileSync(PIDFILE, "utf8")) === process.pid) fs.rmSync(PIDFILE, { force: true });
    } catch {}
  };
  const idleSoon = () => {
    clearTimeout(idle);
    idle = setTimeout(stop, IDLE);
  };

  chrome.on("exit", () => {
    for (const client of clients) client.socket.end();
    cleanUp();
    process.exit(0);
  });
  for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(signal, stop);

  lines(pipe.output, (text) => {
    let message;
    try {
      message = JSON.parse(text);
    } catch {
      return;
    }
    if (message.id !== undefined) {
      const request = pending.get(message.id);
      pending.delete(message.id);
      if (!request || request.internal) return;
      if (request.method === "Target.attachToTarget" && message.result?.sessionId) {
        owners.set(message.result.sessionId, request.client);
        request.client.sessions.add(message.result.sessionId);
      }
      message.id = request.id;
      send(request.client, message);
      return;
    }
    if (message.method === "Target.detachedFromTarget") {
      const owner = owners.get(message.params.sessionId);
      owner?.sessions.delete(message.params.sessionId);
      owners.delete(message.params.sessionId);
    }
    if (message.method === "Target.attachedToTarget" && !message.sessionId && !own.has(message.params.targetInfo.targetId)) {
      const { sessionId, targetInfo, waitingForDebugger } = message.params;
      own.set(targetInfo.targetId, sessionId);
      toChrome({ id: next++, method: "Network.setUserAgentOverride", params: browserIdentity, sessionId });
      if (waitingForDebugger) toChrome({ id: next++, method: "Runtime.runIfWaitingForDebugger", params: {}, sessionId });
      return;
    }
    if (message.method === "Target.detachedFromTarget" && [...own.values()].includes(message.params.sessionId)) return;
    if (message.method === "Target.targetCreated" && message.params.targetInfo.type === "page") targets.add(message.params.targetInfo.targetId);
    if (message.method === "Target.targetDestroyed") {
      targets.delete(message.params.targetId);
      own.delete(message.params.targetId);
      if (message.params.targetId === active) setActive(null, "browser");
    }
    const owner = message.sessionId ? owners.get(message.sessionId) : null;
    if (owner) send(owner, text);
    else if (!message.sessionId) broadcast(text);
  }, "\0");

  const server = net.createServer((socket) => {
    const client = { socket, sessions: new Set(), closed: false };
    clients.add(client);
    clearTimeout(idle);
    socket.on("error", () => {});
    socket.on("close", () => {
      client.closed = true;
      clients.delete(client);
      for (const sessionId of client.sessions) {
        owners.delete(sessionId);
        internal("Target.detachFromTarget", { sessionId });
      }
      for (const [id, ask] of asks) if (ask.client === client) closeAsk(id);
      if (!clients.size) idleSoon();
    });
    send(client, { method: "Kuvo.hello", params: { targetId: active, status, version: CONFIG.version, keeper: KEEPER, asks: [...asks.values()].map((ask) => ask.params) } });
    lines(socket, (text) => {
      let message;
      try {
        message = JSON.parse(text);
      } catch {
        return;
      }
      switch (message.method) {
        case "Kuvo.getActive":
          return send(client, { id: message.id, result: { targetId: active } });
        case "Kuvo.setActive": {
          // A page closed a moment ago isn't the one in use.
          const target = message.params?.targetId ?? null;
          if (target === null || targets.has(target)) setActive(target, message.params?.by ?? "user");
          return message.id !== undefined && send(client, { id: message.id, result: {} });
        }
        case "Kuvo.setStatus":
          status = message.params ?? { working: false };
          broadcast({ method: "Kuvo.status", params: status });
          return message.id !== undefined && send(client, { id: message.id, result: {} });
        case "Kuvo.stop":
          return stop();
        case "Kuvo.ask": {
          const params = message.params ?? {};
          if (!params.id) return;
          asks.set(params.id, { client, params });
          return broadcast({ method: "Kuvo.asked", params });
        }
        case "Kuvo.answer": {
          const ask = asks.get(message.params?.id);
          if (ask) {
            send(ask.client, { method: "Kuvo.answered", params: { id: message.params.id, answer: message.params.answer } });
            closeAsk(message.params.id);
          }
          return message.id !== undefined && send(client, { id: message.id, result: {} });
        }
        case "Kuvo.cancelAsk":
          return closeAsk(message.params?.id);
      }
      if (message.id === undefined || typeof message.method !== "string") return;
      const id = next++;
      pending.set(id, { client, id: message.id, method: message.method });
      const forward = { id, method: message.method, params: message.params ?? {} };
      if (message.sessionId) forward.sessionId = message.sessionId;
      toChrome(forward);
    });
  });
  server.on("error", (error) => fail("failed", "The browser couldn't listen for Kuvo Code: " + error.message));
  // Its own view of the pages there, whoever else asks for it, and a session with each, held
  // before it starts.
  internal("Target.setDiscoverTargets", { discover: true });
  internal("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: true, flatten: true });
  const mask = process.umask(0o077);
  server.listen(SOCKET, () => {
    process.umask(mask);
    fs.rmSync(ERRORFILE, { force: true });
    idleSoon();
  });
}

// MARK: - Talking to the keeper

/// One connection to the keeper, with requests matched to their answers.
class Connection {
  constructor(socket) {
    this.socket = socket;
    this.next = 1;
    this.waiting = new Map();
    this.handlers = new Set();
    this.closed = false;
    lines(socket, (text) => {
      let message;
      try {
        message = JSON.parse(text);
      } catch {
        return;
      }
      if (message.id !== undefined && this.waiting.has(message.id)) {
        const { resolve, reject, timer } = this.waiting.get(message.id);
        this.waiting.delete(message.id);
        clearTimeout(timer);
        if (message.error) reject(new Error(message.error.message || "The browser refused that."));
        else resolve(message.result ?? {});
      } else if (message.method) {
        for (const handler of this.handlers) handler(message);
      }
    });
    socket.on("error", () => {});
    socket.on("close", () => {
      this.closed = true;
      for (const { reject, timer } of this.waiting.values()) {
        clearTimeout(timer);
        reject(new Error("The browser stopped."));
      }
      this.waiting.clear();
      for (const handler of this.handlers) handler({ method: "Kuvo.closed" });
    });
  }

  static open() {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection(SOCKET);
      socket.once("connect", () => resolve(new Connection(socket)));
      socket.once("error", reject);
    });
  }

  send(method, params = {}, sessionId, timeout = 30_000) {
    if (this.closed) return Promise.reject(new Error("The browser stopped."));
    return new Promise((resolve, reject) => {
      const id = this.next++;
      const timer = setTimeout(() => {
        this.waiting.delete(id);
        reject(new Error(`The browser didn't answer (${method}).`));
      }, timeout);
      this.waiting.set(id, { resolve, reject, timer });
      const message = { id, method, params };
      if (sessionId) message.sessionId = sessionId;
      this.socket.write(JSON.stringify(message) + "\n");
    });
  }

  notify(method, params = {}) {
    if (!this.closed) this.socket.write(JSON.stringify({ method, params }) + "\n");
  }
}

// MARK: - The live view

async function connect() {
  const problem = await ensure();
  if (problem) {
    process.stdout.write(JSON.stringify({ method: "Kuvo.error", params: problem }) + "\n");
    return;
  }
  const socket = net.createConnection(SOCKET);
  socket.on("connect", () => {
    process.stdin.pipe(socket);
    socket.pipe(process.stdout);
  });
  socket.on("close", () => process.exit(0));
  socket.on("error", (error) => {
    process.stdout.write(JSON.stringify({ method: "Kuvo.error", params: { kind: "failed", message: error.message } }) + "\n");
    process.exit(1);
  });
  process.stdin.on("end", () => socket.end());
}

// MARK: - The agent's tools

class ToolError extends Error {}

let link = null;
let active = null;
const sessions = new Map();
// Dialogs a page opened while no tool was running, by session, and what the agent should hear
// about the ones answered.
const dialogs = new Map();
const notes = [];
let busy = false;
// Asks waiting for the user's answer, by ID.
const waiting = new Map();

async function browser() {
  if (link && !link.closed) return link;
  const problem = await ensure();
  if (problem) throw new ToolError(problem.message);
  link = await Connection.open();
  sessions.clear();
  link.handlers.add((message) => {
    switch (message.method) {
      case "Kuvo.hello":
        active = message.params.targetId;
        break;
      case "Kuvo.activeChanged":
        active = message.params.targetId;
        break;
      case "Target.detachedFromTarget":
        for (const [target, session] of sessions) if (session === message.params.sessionId) sessions.delete(target);
        break;
      case "Page.javascriptDialogOpening":
        // During a tool, at once: the page (and the script that opened it) waits on the answer.
        if (busy) answer(message.sessionId, message.params);
        else dialogs.set(message.sessionId, message.params);
        break;
      case "Page.javascriptDialogClosed":
        dialogs.delete(message.sessionId);
        break;
      case "Kuvo.answered":
        waiting.get(message.params.id)?.(message.params.answer ?? { type: "declined" });
        waiting.delete(message.params.id);
        break;
      case "Kuvo.closed":
        for (const resolve of waiting.values()) resolve({ type: "lost" });
        waiting.clear();
        break;
    }
  });
  await link.send("Target.setDiscoverTargets", { discover: true });
  active = (await link.send("Kuvo.getActive")).targetId ?? null;
  return link;
}

async function pages() {
  const { targetInfos } = await (await browser()).send("Target.getTargets");
  return targetInfos.filter((target) => target.type === "page");
}

/// The page in use: the one you or the agent last used, else the newest, else a new one.
async function page() {
  const c = await browser();
  const open = await pages();
  let target = open.find((info) => info.targetId === active)?.targetId ?? open.at(-1)?.targetId;
  if (!target) target = (await c.send("Target.createTarget", { url: "about:blank" })).targetId;
  return use(target);
}

async function use(target) {
  const c = await browser();
  let session = sessions.get(target);
  if (!session) {
    session = (await c.send("Target.attachToTarget", { targetId: target, flatten: true })).sessionId;
    sessions.set(target, session);
    await c.send("Page.enable", {}, session);
  }
  if (active !== target) {
    active = target;
    c.notify("Kuvo.setActive", { targetId: target, by: "agent" });
  }
  return { target, session };
}

async function evaluate(p, expression, timeout = 30_000) {
  const result = await link.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true, userGesture: true }, p.session, timeout);
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
  return result.result?.value;
}

/// Runs one of the browsing scripts (a function body) with `args` as its named arguments.
async function run(p, body, args = {}) {
  const expression = `(async function({${Object.keys(args).join(", ")}}) {\n${body}\n})(${JSON.stringify(args)})`;
  try {
    const value = await evaluate(p, expression);
    return typeof value === "string" ? value : "ok";
  } catch (error) {
    return "The page refused that: " + error.message;
  }
}

async function address(p) {
  try {
    return (await link.send("Target.getTargetInfo", { targetId: p.target })).targetInfo.url;
  } catch {
    return "";
  }
}

async function readyState(p) {
  try {
    return await evaluate(p, "document.readyState", 2000);
  } catch {
    return "loading";
  }
}

/// Waits for a navigation to start and finish, then a moment for the page to settle: until it has
/// loaded, or it's been readable for 2 s (a slow ad or tracker shouldn't hold it up), 10 s at most.
async function settle(p, expectNavigation) {
  if (expectNavigation) await sleep(250);
  const deadline = Date.now() + 10_000;
  let readable = null;
  while (Date.now() < deadline) {
    const state = await readyState(p);
    if (state === "complete") break;
    if (state === "interactive") {
      readable ??= Date.now();
      if (Date.now() - readable > 2000) break;
    } else {
      readable = null;
    }
    await sleep(150);
  }
  await sleep(expectNavigation ? 500 : 350);
}

/// A click may start a navigation a beat later, or open a page of its own: follow either.
async function settleAfterClick(p, before, pagesBefore) {
  const start = Date.now();
  while (Date.now() - start < 1000 && (await readyState(p)) !== "loading" && (await address(p)) === before) await sleep(100);
  const opened = (await pages()).find((info) => !pagesBefore.has(info.targetId));
  if (opened) {
    const next = await use(opened.targetId);
    await settle(next, true);
    return next;
  }
  await settle(p, (await readyState(p)) === "loading" || (await address(p)) !== before);
  return p;
}

const isEmpty = (url) => !url || url === "about:blank";

/// The page as text: title, address, scroll position, and its numbered elements.
async function snapshot(p) {
  p = p ?? (await page());
  if (isEmpty(await address(p))) return "The browser is empty. Use browser_navigate to open a page.";
  let result;
  try {
    result = await evaluate(p, `(async function() {\n${CONFIG.scripts.snapshot}\n})()`);
  } catch {}
  if (!result) return `Couldn't read the page at ${await address(p)}.`;
  const text = result.text || "";
  const body = text.length > 18_000 ? text.slice(0, 18_000) + "\n… (cut; scroll or use browser_text for more)" : text;
  return [
    `Page: ${result.title || ""}`,
    `URL: ${result.url || ""}`,
    `Scroll: ${result.above || 0} px above, ${result.below || 0} px below`,
    "Interactive elements are numbered like [3]; use the number with browser_click, browser_type and browser_select.",
    "",
    body || "(no visible content)",
  ].join("\n");
}

/// What you type in an address bar: an address, or words to search for.
function destination(input) {
  const text = String(input || "").trim();
  if (!text) return null;
  try {
    const url = new URL(text);
    if (["http:", "https:", "file:", "about:"].includes(url.protocol)) return url.href;
  } catch {}
  const looksLikeHost = !text.includes(" ") && (text.includes(".") || text.startsWith("localhost") || text.includes(":"));
  if (looksLikeHost) return (text.startsWith("localhost") || text.startsWith("127.") ? "http://" : "https://") + text;
  const search = process.env.KUVO_SEARCH || "https://www.google.com/search?q=%s";
  return search.replace("%s", encodeURIComponent(text));
}

async function navigate(p, url) {
  const target = destination(url);
  if (!target) return `Not an address or search: ${url}`;
  const result = await link.send("Page.navigate", { url: target }, p.session);
  if (result.errorText && result.errorText !== "net::ERR_ABORTED") {
    await settle(p, false);
    return `Couldn't open ${target}: ${result.errorText}\n\n` + (await snapshot(p));
  }
  await settle(p, true);
  return snapshot(p);
}

async function history(p, step) {
  const { currentIndex, entries } = await link.send("Page.getNavigationHistory", {}, p.session);
  const entry = entries[currentIndex + step];
  if (!entry) return step < 0 ? "There's no page to go back to." : "There's no page to go forward to.";
  await link.send("Page.navigateToHistoryEntry", { entryId: entry.id }, p.session);
  await settle(p, true);
  return snapshot(p);
}

/// What's in view, as a PNG at most 1280 pixels wide.
async function screenshot(p) {
  // What the user filled in stays out of the picture.
  await run(p, CONFIG.scripts.mask);
  try {
    return await capture(p);
  } finally {
    await run(p, CONFIG.scripts.unmask);
  }
}

async function capture(p) {
  const { cssVisualViewport: view } = await link.send("Page.getLayoutMetrics", {}, p.session);
  const ratio = (await evaluate(p, "window.devicePixelRatio").catch(() => 1)) || 1;
  const scale = Math.min(1, 1280 / Math.max(view.clientWidth, 1));
  const { data } = await link.send("Page.captureScreenshot", {
    format: "png",
    clip: { x: view.pageX, y: view.pageY, width: view.clientWidth, height: view.clientHeight, scale: scale / ratio },
  }, p.session);
  return data;
}

/// A dialog the page opened (an alert, a confirmation) holds the page up until it's answered: an
/// alert is accepted, anything else declined, as the panel's browser on the Mac does, and the
/// agent hears about it with the tool's result.
function answer(sessionId, dialog) {
  dialogs.delete(sessionId);
  const accept = dialog.type === "alert" || dialog.type === "beforeunload";
  link?.send("Page.handleJavaScriptDialog", { accept }, sessionId).catch(() => {});
  notes.push(`The page showed ${dialog.type === "alert" ? "an alert" : "a dialog"}: “${dialog.message}” (${accept ? "accepted" : "declined"}).`);
}

/// Asks the user, in Kuvo Code, and waits for the answer (15 minutes at most).
function askUser(params) {
  const id = crypto.randomUUID();
  link.notify("Kuvo.ask", { id, ...params });
  return new Promise((resolve) => {
    waiting.set(id, resolve);
    setTimeout(() => {
      if (!waiting.delete(id)) return;
      link?.notify("Kuvo.cancelAsk", { id });
      resolve({ type: "timedOut" });
    }, 900_000);
  });
}

/// The site a page is on, as the ask names it and Passwords keeps it: its host, or for a page
/// from a file, that it is one.
function hostOf(url) {
  try {
    const parsed = new URL(url);
    if (parsed.protocol === "file:") return "a file on this machine";
    return parsed.hostname || null;
  } catch {
    return null;
  }
}

/// Nil if the field is there and takes `wanted` ("password" or "text"), else why not.
async function checkField(p, index, wanted) {
  const kind = await run(p, CONFIG.scripts.find + CONFIG.scripts.fieldKind, { index });
  if (kind === "missing") return `There's no element [${index}] on the page now. Take a fresh browser_snapshot.`;
  if (wanted === "password" && kind !== "password") return `[${index}] isn't a password field: a password only goes into one.`;
  if (wanted === "text" && kind !== "text") return `[${index}] isn't a field for a username or email.`;
  if (wanted === "code" && kind !== "text" && kind !== "password") return `[${index}] isn't a field to type a code into.`;
  return null;
}

const noAnswer = (answer, what) =>
  answer.type === "timedOut" ? "The user didn't answer in time. Ask them in the chat how to go on."
    : answer.type === "lost" ? "The connection to the browser closed while the user was answering. Try again."
    : `The user didn't ${what}. Ask them in the chat how to go on.`;

const text = (value, isError = false) => ({ content: [{ type: "text", text: value }], isError });

async function tool(name, args) {
  const integer = (key) => (Number.isFinite(Number(args[key])) && args[key] !== "" && args[key] !== null ? Math.trunc(Number(args[key])) : null);
  const string = (key) => (typeof args[key] === "string" ? args[key] : null);
  const scripts = CONFIG.scripts;

  if (name === "browser_new_tab") {
    const c = await browser();
    const url = string("url");
    const { targetId } = await c.send("Target.createTarget", { url: "about:blank" });
    const p = await use(targetId);
    return text(url ? await navigate(p, url) : await snapshot(p));
  }

  let p = await page();
  // A dialog the page left waiting, first.
  for (const [sessionId, dialog] of dialogs) answer(sessionId, dialog);
  const note = () => (notes.length ? notes.splice(0).join("\n") + "\n\n" : "");
  const withNote = async (promise) => {
    const result = await promise;
    return text(note() + result);
  };

  switch (name) {
    case "browser_navigate": {
      const url = string("url");
      if (!url) return text("Missing url.", true);
      return withNote(navigate(p, url));
    }
    case "browser_snapshot":
      return withNote(snapshot(p));
    case "browser_click": {
      const index = integer("index");
      if (index === null) return text("Missing index.", true);
      const before = await address(p);
      const pagesBefore = new Set((await pages()).map((info) => info.targetId));
      const outcome = await run(p, scripts.find + scripts.click, { index });
      if (outcome !== "ok") return text(note() + outcome);
      p = await settleAfterClick(p, before, pagesBefore);
      return withNote(snapshot(p).then((page) => `Clicked [${index}].\n\n` + page));
    }
    case "browser_type": {
      const index = integer("index");
      const value = string("text");
      if (index === null || value === null) return text("Missing index or text.", true);
      const submit = args.submit === true;
      const outcome = await run(p, scripts.find + scripts.type, { index, text: value, submit, clear: args.clear !== false });
      if (outcome !== "ok") return text(note() + outcome);
      await settle(p, submit);
      return withNote(snapshot(p).then((page) => `Typed into [${index}]${submit ? " and submitted" : ""}.\n\n` + page));
    }
    case "browser_select": {
      const index = integer("index");
      const option = string("option");
      if (index === null || option === null) return text("Missing index or option.", true);
      const outcome = await run(p, scripts.find + scripts.select, { index, option });
      if (outcome !== "ok") return text(note() + outcome);
      await settle(p, false);
      return withNote(snapshot(p).then((page) => `Selected “${option}” in [${index}].\n\n` + page));
    }
    case "browser_scroll": {
      const pages = Number(args.pages) || 1;
      await run(p, "window.scrollBy({top: (down ? 1 : -1) * window.innerHeight * 0.85 * pages, behavior: 'instant'}); return 'ok';", { down: string("direction") !== "up", pages });
      await sleep(300);
      return withNote(snapshot(p));
    }
    case "browser_press": {
      const key = string("key");
      if (!key) return text("Missing key.", true);
      const outcome = await run(p, scripts.press, { key });
      if (outcome !== "ok") return text(note() + outcome);
      await settle(p, key === "Enter");
      return withNote(snapshot(p).then((page) => `Pressed ${key}.\n\n` + page));
    }
    case "browser_back":
      return withNote(history(p, -1));
    case "browser_forward":
      return withNote(history(p, 1));
    case "browser_text": {
      let value = "";
      try {
        value = (await evaluate(p, "document.body ? document.body.innerText : ''")) || "";
      } catch {}
      return withNote(Promise.resolve(value.length > 30_000 ? value.slice(0, 30_000) + "\n… (cut)" : value || "(no text)"));
    }
    case "browser_screenshot": {
      try {
        return { content: [{ type: "image", data: await screenshot(p), mimeType: "image/png" }] };
      } catch {
        return text("Couldn't capture the page.", true);
      }
    }
    case "browser_sign_in": {
      const username = integer("username");
      const password = integer("password");
      if (username === null && password === null) return text("Name the username field, the password field, or both, by number.", true);
      const host = hostOf(await address(p));
      if (!host || isEmpty(await address(p))) return text(note() + "Open the sign-in page first.");
      for (const [index, wanted] of [[password, "password"], [username, "text"]]) {
        if (index === null) continue;
        const problem = await checkField(p, index, wanted);
        if (problem) return text(note() + problem);
      }
      const answer = await askUser({ kind: "signIn", host, username: username !== null, password: password !== null });
      if (answer.type !== "signIn") return text(note() + noAnswer(answer, "sign in"));
      const filled = [];
      for (const [index, value, what] of [[username, answer.username, "the username"], [password, answer.password, "the password"]]) {
        if (index === null || !value) continue;
        const outcome = await run(p, scripts.find + scripts.fill, { index, value });
        if (outcome !== "ok") return text(note() + outcome);
        filled.push(what);
      }
      if (!filled.length) return text(note() + "The user didn't give a sign-in for that.");
      await sleep(300);
      return withNote(snapshot(p).then((page) => `Filled ${filled.join(" and ")} for ${host} (you can't see them). Submit the form to sign in.\n\n` + page));
    }
    case "browser_ask_code": {
      const index = integer("index");
      if (index === null) return text("Missing index.", true);
      const host = hostOf(await address(p));
      if (!host) return text(note() + "Open the page that asks for the code first.");
      const problem = await checkField(p, index, "code");
      if (problem) return text(note() + problem);
      const answer = await askUser({ kind: "code", host, prompt: string("prompt") ?? "" });
      if (answer.type !== "code" || !answer.code) return text(note() + noAnswer(answer, "give a code"));
      const outcome = await run(p, scripts.find + scripts.fill, { index, value: answer.code });
      if (outcome !== "ok") return text(note() + outcome);
      await sleep(300);
      return withNote(snapshot(p).then((page) => "Filled the code (you can't see it). Submit it if the page doesn't on its own.\n\n" + page));
    }
    case "browser_ask_user": {
      const instruction = string("instruction");
      if (!instruction) return text("Missing instruction.", true);
      const answer = await askUser({ kind: "action", host: hostOf(await address(p)) ?? "the page", instruction });
      if (answer.type !== "done") return text(note() + noAnswer(answer, "do it"));
      await settle(p, false);
      return withNote(snapshot(p).then((page) => "The user says it's done.\n\n" + page));
    }
    case "browser_wait": {
      const seconds = Math.min(Math.max(Number(args.seconds) || 2, 0), 10);
      await sleep(seconds * 1000);
      return withNote(snapshot(p));
    }
    default:
      return text(`Unknown tool ${name}.`, true);
  }
}

async function mcp() {
  const write = (message) => process.stdout.write(JSON.stringify(message) + "\n");
  // One tool at a time: they share the page.
  let queue = Promise.resolve();
  lines(process.stdin, (line) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return write({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } });
    }
    if (message.id === undefined || message.id === null) return;
    const reply = (result) => write({ jsonrpc: "2.0", id: message.id, result });
    const params = message.params || {};
    switch (message.method) {
      case "initialize": {
        const supported = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
        return reply({
          protocolVersion: supported.includes(params.protocolVersion) ? params.protocolVersion : "2025-06-18",
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "kuvo-browser", title: "Kuvo Code browser", version: CONFIG.version },
          instructions: CONFIG.instructions,
        });
      }
      case "ping":
        return reply({});
      case "tools/list":
        return reply({ tools: CONFIG.tools });
      case "tools/call":
        queue = queue.then(async () => {
          const name = params.name || "";
          const status = (working) => link?.notify("Kuvo.setStatus", working ? { working, tool: name } : { working });
          try {
            await browser();
            busy = true;
            status(true);
            reply(await tool(name, params.arguments || {}));
          } catch (error) {
            reply(text(error instanceof ToolError ? error.message : "The browser ran into a problem: " + error.message, true));
          } finally {
            busy = false;
            notes.length = 0;
            status(false);
          }
        });
        return;
      default:
        return write({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: `Unknown method ${message.method}` } });
    }
  });
  process.stdin.on("end", () => process.exit(0));
  // A keeper that's already running stays up while the engine does, across its restarts.
  if (await reachable()) browser().catch(() => {});
}

const mode = process.argv[2];
const modes = { host, mcp, connect };
if (!modes[mode]) {
  console.error("Usage: kuvo-browser.js host|mcp|connect");
  process.exit(2);
}
modes[mode]().catch((error) => {
  console.error(error?.stack || String(error));
  process.exit(1);
});
