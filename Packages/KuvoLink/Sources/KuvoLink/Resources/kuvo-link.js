// Kuvo Code's link on a machine: lets the phones you've paired reach this machine's engine
// through the relay, so its sessions and bots work from the phone with the Mac closed. The
// engine's own runtime runs it, so the machine needs nothing else:
//
//   BUN_BE_BUN=1 opencode kuvo-link.js run             the bridge, started beside the engine, which
//                                                      also tells your phones what happens in the
//                                                      machine's sessions while no Mac does
//   BUN_BE_BUN=1 opencode kuvo-link.js setup           the Mac's phones and relay, as JSON on stdin
//   BUN_BE_BUN=1 opencode kuvo-link.js pair [relay]    a link to pair a phone with this machine
//   BUN_BE_BUN=1 opencode kuvo-link.js selftest        checks the runtime has what it needs
//
// It keeps its state in ~/.kuvo-code/run/link.json (mode 600), reads the engine's port and
// password from run/engine.json, and connects out to the relay; it never listens. The protocol
// is in PROTOCOL.md beside this file's source (kuvo-ai's Packages/KuvoLink), with the same in
// Swift for the Mac and the phone.

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

// Goes up with every change, so `setup` replaces a running bridge that's older.
export const BRIDGE_VERSION = "0.5.0";
const K = process.env.KUVO_HOME || path.join(os.homedir(), ".kuvo-code");
const RUN = path.join(K, "run");
export const LINK_FILE = path.join(RUN, "link.json");
const ENGINE_FILE = path.join(RUN, "engine.json");
const PID_FILE = path.join(RUN, "link.pid");
const VERSION_FILE = path.join(RUN, "link.version");
const PAIRING_MINUTES = 10;

// ---- Keys: X25519 keys are kept as their raw 32 bytes ----

const PKCS8 = Buffer.from("302e020100300506032b656e04220420", "hex");
const SPKI = Buffer.from("302a300506032b656e032100", "hex");
const EMPTY = Buffer.alloc(0);

const privateKey = raw => crypto.createPrivateKey({ key: Buffer.concat([PKCS8, raw]), format: "der", type: "pkcs8" });
const publicKey = raw => crypto.createPublicKey({ key: Buffer.concat([SPKI, raw]), format: "der", type: "spki" });
export const newKey = () => crypto.generateKeyPairSync("x25519").privateKey.export({ format: "der", type: "pkcs8" }).subarray(PKCS8.length);
export const publicOf = raw => crypto.createPublicKey(privateKey(raw)).export({ format: "der", type: "spki" }).subarray(SPKI.length);
const dh = (raw, remote) => crypto.diffieHellman({ privateKey: privateKey(raw), publicKey: publicKey(remote) });
export const addressOf = secret => crypto.createHash("sha256").update("kuvo-link address v1").update(secret).digest().subarray(0, 16);

// ---- Noise: IK for sessions, K for mail, with X25519, AES-GCM and SHA-256 ----

const sha256 = data => crypto.createHash("sha256").update(data).digest();
const hmac = (key, data) => crypto.createHmac("sha256", key).update(data).digest();
function hkdf(chainingKey, input) {
  const temp = hmac(chainingKey, input);
  const first = hmac(temp, Buffer.from([1]));
  return [first, hmac(temp, Buffer.concat([first, Buffer.from([2])]))];
}

export class CipherState {
  constructor(key) {
    this.key = key;
    this.n = 0n;
  }

  nonce() {
    const nonce = Buffer.alloc(12);
    nonce.writeBigUInt64BE(this.n, 4);
    return nonce;
  }

  encrypt(ad, plaintext) {
    if (!this.key) return plaintext;
    const cipher = crypto.createCipheriv("aes-256-gcm", this.key, this.nonce());
    cipher.setAAD(ad);
    const sealed = Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
    this.n += 1n;
    return sealed;
  }

  decrypt(ad, ciphertext) {
    if (!this.key) return ciphertext;
    if (ciphertext.length < 16) throw new Error("decrypt");
    const decipher = crypto.createDecipheriv("aes-256-gcm", this.key, this.nonce());
    decipher.setAAD(ad);
    decipher.setAuthTag(ciphertext.subarray(-16));
    let plaintext;
    try {
      plaintext = Buffer.concat([decipher.update(ciphertext.subarray(0, -16)), decipher.final()]);
    } catch {
      throw new Error("decrypt");
    }
    this.n += 1n;
    return plaintext;
  }
}

class SymmetricState {
  constructor(name, prologue) {
    const bytes = Buffer.from(name);
    this.h = bytes.length <= 32 ? Buffer.concat([bytes, Buffer.alloc(32 - bytes.length)]) : sha256(bytes);
    this.ck = this.h;
    this.cipher = new CipherState();
    this.mixHash(prologue);
  }

  mixKey(input) {
    const [chainingKey, key] = hkdf(this.ck, input);
    this.ck = chainingKey;
    this.cipher = new CipherState(key);
  }

  mixHash(data) {
    this.h = sha256(Buffer.concat([this.h, data]));
  }

  encryptAndHash(plaintext) {
    const ciphertext = this.cipher.encrypt(this.h, plaintext);
    this.mixHash(ciphertext);
    return ciphertext;
  }

  decryptAndHash(ciphertext) {
    const plaintext = this.cipher.decrypt(this.h, ciphertext);
    this.mixHash(ciphertext);
    return plaintext;
  }

  split() {
    const [first, second] = hkdf(this.ck, EMPTY);
    return [new CipherState(first), new CipherState(second)];
  }
}

const IK = "Noise_IK_25519_AESGCM_SHA256";
const ONE_WAY = "Noise_K_25519_AESGCM_SHA256";
export const PROLOGUE = Buffer.from("kuvo-link v1");
export const MAIL_PROLOGUE = Buffer.from("kuvo-link mail v1");

const transport = (sending, receiving, hash) => ({
  hash,
  seal: plaintext => sending.encrypt(EMPTY, plaintext),
  open: ciphertext => receiving.decrypt(EMPTY, ciphertext),
});

// The side that starts (the phone), knowing the other's static key. Here for tests.
export class IKInitiator {
  constructor(s, rs, prologue, e = newKey()) {
    Object.assign(this, { s, rs, e, state: new SymmetricState(IK, prologue) });
    this.state.mixHash(rs);
  }

  writeMessage1(payload) {
    const state = this.state;
    const ephemeral = publicOf(this.e);
    state.mixHash(ephemeral);
    state.mixKey(dh(this.e, this.rs));
    const s = state.encryptAndHash(publicOf(this.s));
    state.mixKey(dh(this.s, this.rs));
    return Buffer.concat([ephemeral, s, state.encryptAndHash(payload)]);
  }

  readMessage2(message) {
    if (message.length < 48) throw new Error("malformed");
    const state = this.state;
    const re = message.subarray(0, 32);
    state.mixHash(re);
    state.mixKey(dh(this.e, re));
    state.mixKey(dh(this.s, re));
    const payload = state.decryptAndHash(message.subarray(32));
    const [first, second] = state.split();
    return { payload, transport: transport(first, second, state.h) };
  }
}

// The side that answers (this machine), learning the phone's static key.
export class IKResponder {
  constructor(s, prologue, e = newKey()) {
    Object.assign(this, { s, e, state: new SymmetricState(IK, prologue) });
    this.state.mixHash(publicOf(s));
  }

  readMessage1(message) {
    if (message.length < 96) throw new Error("malformed");
    const state = this.state;
    this.re = message.subarray(0, 32);
    state.mixHash(this.re);
    state.mixKey(dh(this.s, this.re));
    this.rs = state.decryptAndHash(message.subarray(32, 80));
    state.mixKey(dh(this.s, this.rs));
    return state.decryptAndHash(message.subarray(80));
  }

  writeMessage2(payload) {
    const state = this.state;
    const ephemeral = publicOf(this.e);
    state.mixHash(ephemeral);
    state.mixKey(dh(this.e, this.re));
    state.mixKey(dh(this.e, this.rs));
    const message = Buffer.concat([ephemeral, state.encryptAndHash(payload)]);
    const [first, second] = state.split();
    return { message, transport: transport(second, first, state.h) };
  }
}

// One message to a device that knows the sender, for pushes.
export function sealOneWay(payload, s, rs, prologue = MAIL_PROLOGUE, e = newKey()) {
  const state = new SymmetricState(ONE_WAY, prologue);
  state.mixHash(publicOf(s));
  state.mixHash(rs);
  const ephemeral = publicOf(e);
  state.mixHash(ephemeral);
  state.mixKey(dh(e, rs));
  state.mixKey(dh(s, rs));
  return { message: Buffer.concat([ephemeral, state.encryptAndHash(payload)]), following: state.split()[0] };
}

export function openOneWay(message, s, rs, prologue = MAIL_PROLOGUE) {
  if (message.length < 48) throw new Error("malformed");
  const state = new SymmetricState(ONE_WAY, prologue);
  state.mixHash(rs);
  state.mixHash(publicOf(s));
  const re = message.subarray(0, 32);
  state.mixHash(re);
  state.mixKey(dh(s, re));
  state.mixKey(dh(s, rs));
  return { payload: state.decryptAndHash(message.subarray(32)), following: state.split()[0] };
}

// ---- Frames ----

export const Frame = { handshake1: 1, handshake2: 2, transport: 3, close: 4, mail: 5 };
const MAX_MESSAGE = 65535 - 16;

export const relayHello = secret => Buffer.concat([Buffer.from([1]), secret]);
export const relaySend = (to, payload) => Buffer.concat([Buffer.from([2]), to, payload]);
export const relayPush = (to, payload) => Buffer.concat([Buffer.from([5]), to, payload]);

// What the relay sent, or null.
export function readRelay(bytes) {
  const kind = bytes[0];
  const address = bytes.subarray(1, 17);
  if (kind === 1 && bytes.length === 17) return { kind: "welcome", address };
  if (kind === 2 && bytes.length >= 17) return { kind: "deliver", address, payload: bytes.subarray(17) };
  if (kind === 3 && bytes.length === 17) return { kind: "unreachable", address };
  if (kind === 6 && bytes.length === 18) return { kind: "pushed", address, status: bytes[17] };
  return null;
}

export function frame(kind, session, body = EMPTY) {
  const header = Buffer.alloc(5);
  header[0] = kind;
  header.writeUInt32BE(session, 1);
  return Buffer.concat([header, body]);
}

export function readFrame(bytes) {
  if (bytes.length < 5 || bytes[0] < 1 || bytes[0] > 5) return null;
  return { kind: bytes[0], session: bytes.readUInt32BE(1), body: bytes.subarray(5) };
}

// JSON with sorted keys, as the Swift side writes it.
function sortedJSON(value) {
  if (Array.isArray(value)) return `[${value.map(sortedJSON).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().filter(k => value[k] !== undefined).map(k => `${JSON.stringify(k)}:${sortedJSON(value[k])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

export function encodeMessage(head, body = EMPTY) {
  const json = Buffer.from(sortedJSON(head));
  const length = Buffer.alloc(2);
  length.writeUInt16BE(json.length);
  return Buffer.concat([length, json, body]);
}

export function decodeMessage(bytes) {
  if (bytes.length < 2) return null;
  const length = bytes.readUInt16BE(0);
  if (bytes.length < 2 + length) return null;
  try {
    return { head: JSON.parse(bytes.subarray(2, 2 + length).toString("utf8")), body: bytes.subarray(2 + length) };
  } catch {
    return null;
  }
}

// `head` and `body` as messages that each fit: the first with `head`, the rest as `data`.
export function pieces(head, body, end) {
  if (Buffer.byteLength(sortedJSON(head)) > 60_000) throw new Error("head too long");
  const out = [];
  let current = { ...head, end: false };
  let offset = 0;
  do {
    const room = MAX_MESSAGE - 2 - Buffer.byteLength(sortedJSON(current)) - 8;
    out.push([current, body.subarray(offset, offset + room)]);
    offset += room;
    current = { t: "data", id: head.id, end: false };
  } while (offset < body.length);
  out[out.length - 1][0].end = end;
  return out.map(([h, b]) => encodeMessage(h, b));
}

// ---- The host: answers paired phones' sessions (the Mac app's LinkServer, in JavaScript) ----

export class LinkHost {
  // authorize(key, hello, address) → whether to let the phone in; handle(request, phone, signal) → an
  // async iterable of { head: { status, headers } } and { body }; connect(request, phone,
  // { open, text, binary, end }) → a socket's { send, close } (PROTOCOL.md, "Sockets");
  // send(bytes) → to the relay.
  constructor({ key, hello, authorize, handle, connect, send }) {
    Object.assign(this, { key, hello, authorize, handle, connect, send });
    this.sessions = new Map();
  }

  // The relay connection dropped: what was under way is gone.
  reset() {
    for (const session of this.sessions.values()) this.end(session, false);
  }

  get active() { return this.sessions.size; }

  // A phone the relay can't reach any more (asleep, gone): what it asked for has nobody to go to.
  forget(address) {
    for (const session of this.sessions.values()) if (session.from.equals(address)) this.end(session, false);
  }

  // Phones no longer paired (removed on the Mac) lose the sessions they have open.
  keepOnly(keys) {
    for (const session of this.sessions.values()) if (!keys.has(session.phone.key.toString("base64url"))) this.end(session, true);
  }

  async receive(from, payload) {
    try {
      await this.receiveFrame(from, payload);
    } catch {
      // Nothing a phone sends gets to stop the bridge.
    }
  }

  async receiveFrame(from, payload) {
    const parsed = readFrame(payload);
    if (!parsed) return;
    const id = `${from.toString("base64url")}:${parsed.session}`;
    const session = this.sessions.get(id);
    switch (parsed.kind) {
      case Frame.handshake1:
        return this.handshake(from, parsed.session, id, parsed.body);
      case Frame.transport: {
        if (!session) return this.send(relaySend(from, frame(Frame.close, parsed.session)));
        let message;
        try {
          message = decodeMessage(session.transport.open(parsed.body));
        } catch {
          message = null;
        }
        if (!message || typeof message.head !== "object" || message.head === null) return this.end(session, true);
        return this.message(session, message);
      }
      case Frame.close:
        if (session) this.end(session, false);
    }
  }

  async handshake(from, number, id, body) {
    const refuse = () => this.send(relaySend(from, frame(Frame.close, number)));
    const responder = new IKResponder(this.key, PROLOGUE);
    let hello;
    try {
      hello = JSON.parse(responder.readMessage1(body).toString("utf8"));
    } catch {
      return refuse();
    }
    if (hello?.v !== 1 || !(await this.authorize(responder.rs, hello, from))) return refuse();
    const { message, transport } = responder.writeMessage2(Buffer.from(JSON.stringify(this.hello)));
    // One session per phone: a new one replaces what's left of the last.
    for (const old of this.sessions.values()) if (old.from.equals(from)) this.end(old, false);
    const phone = { key: responder.rs, name: String(hello.name ?? ""), address: from };
    this.sessions.set(id, { id, from, number, phone, transport, incoming: new Map(), running: new Map(), sockets: new Map() });
    this.send(relaySend(from, frame(Frame.handshake2, number, message)));
  }

  message(session, { head, body }) {
    switch (head.t) {
      case "req": {
        const request = { method: head.m ?? "GET", path: head.p ?? "", headers: head.h ?? {}, body };
        if (String(request.headers.upgrade ?? "").toLowerCase() === "websocket") this.open(session, head.id, request);
        else if (head.end === false) session.incoming.set(head.id, request);
        else this.run(session, head.id, request);
        return;
      }
      case "data": {
        const socket = session.sockets.get(head.id);
        if (socket) {
          if (body.length) socket.handle?.send(body);
          if (head.end === true) {
            session.sockets.delete(head.id);
            socket.handle?.close();
          }
          return;
        }
        const request = session.incoming.get(head.id);
        if (!request) return;
        request.body = Buffer.concat([request.body, body]);
        if (head.end === true) {
          session.incoming.delete(head.id);
          this.run(session, head.id, request);
        }
        return;
      }
      case "cancel":
        session.running.get(head.id)?.abort();
        session.running.delete(head.id);
        session.incoming.delete(head.id);
        session.sockets.get(head.id)?.handle?.close();
        session.sockets.delete(head.id);
        return;
      case "ping":
        return this.seal(session, encodeMessage({ t: "pong" }));
    }
  }

  run(session, id, request) {
    const controller = new AbortController();
    session.running.set(id, controller);
    const live = () => !controller.signal.aborted && this.sessions.get(session.id) === session;
    const reply = (head, body, end) => {
      if (!live()) return;
      for (const piece of pieces(head, body, end)) this.seal(session, piece);
    };
    (async () => {
      let head = null;
      let started = false;
      try {
        for await (const part of this.handle(request, session.phone, controller.signal)) {
          if (!live()) return;
          if (part.head) {
            head = { t: "res", id, s: part.head.status, h: part.head.headers };
          } else if (part.body?.length) {
            // The head goes with the first piece of the body.
            reply(started ? { t: "data", id } : head ?? { t: "data", id }, part.body, false);
            started = true;
          }
        }
        reply(started ? { t: "data", id } : head ?? { t: "data", id }, EMPTY, true);
      } catch (error) {
        if (!live()) return;
        if (!started) reply({ t: "res", id, s: 502, h: { "content-type": "text/plain" } }, Buffer.from(String(error?.message ?? error)), true);
        else this.seal(session, encodeMessage({ t: "cancel", id }));
      } finally {
        if (session.running.get(id) === controller) session.running.delete(id);
      }
    })();
  }

  // A socket: open once the engine's is, then messages both ways until either side ends it.
  open(session, id, request) {
    const socket = { handle: null, opened: false };
    session.sockets.set(id, socket);
    const live = () => this.sessions.get(session.id) === session && session.sockets.get(id) === socket;
    const reply = (head, body, end) => {
      if (!live()) return;
      for (const piece of pieces(head, body, end)) this.seal(session, piece);
    };
    const end = error => {
      if (!live()) return;
      if (socket.opened) reply({ t: "data", id }, EMPTY, true);
      else reply({ t: "res", id, s: 502, h: { "content-type": "text/plain" } }, Buffer.from(String(error?.message ?? "It closed.")), true);
      session.sockets.delete(id);
    };
    if (!this.connect) return end(new Error("Sockets aren't available here."));
    socket.handle = this.connect(request, session.phone, {
      open: () => {
        socket.opened = true;
        reply({ t: "res", id, s: 101 }, EMPTY, false);
      },
      text: data => reply({ t: "data", id }, data, false),
      // Binary messages are small (the engine's notes on a terminal); one too long to go whole
      // doesn't go.
      binary: data => { if (data.length <= 60_000) reply({ t: "data", id, h: { type: "binary" } }, data, false); },
      end,
    });
  }

  seal(session, plaintext) {
    this.send(relaySend(session.from, frame(Frame.transport, session.number, session.transport.seal(plaintext))));
  }

  end(session, notify) {
    if (this.sessions.get(session.id) !== session) return;
    this.sessions.delete(session.id);
    for (const controller of session.running.values()) controller.abort();
    session.running.clear();
    for (const socket of session.sockets.values()) socket.handle?.close();
    session.sockets.clear();
    if (notify) this.send(relaySend(session.from, frame(Frame.close, session.number)));
  }
}

// ---- Forwarding to the engine ----

// What a phone may ask the engine for: sessions and what's in them, live events, what it needs
// to show them, and a project's files to read. Never accounts, keys or integrations, the
// engine's settings, MCP servers or plugins.
const ALLOWED = [
  /^api\/session(\/|\?|$)/,
  /^api\/experimental\/session\/[^/]+\/wait(\?|$)/,
  /^api\/event(\?|$)/,
  /^api\/(info|agent|command|model|provider|project|location|skill|vcs|worktree|permission|form)(\/|\?|$)/,
  /^api\/fs\/(list|find)(\?|$)/,
  /^api\/fs\/read\//,
  /^api\/pty(\/|\?|$)/,
];
// The sockets a phone may open: a terminal's.
const SOCKETS = [/^api\/pty\/[^/?]+\/connect(\?|$)/];
const REQUEST_HEADERS = ["content-type", "accept", "x-opencode-directory", "last-event-id"];
const RESPONSE_HEADERS = ["content-type", "cache-control"];

// No way out of the project, written plainly or percent-encoded ("%2E%2E"): the engine decodes
// it, and lists a folder above the project if asked.
const leavesProject = path => {
  try {
    const decoded = decodeURIComponent(path);
    return path.includes("..") || decoded.includes("..") || decoded.includes("\\");
  } catch {
    return true;
  }
};
export const allowed = path => !leavesProject(path) && ALLOWED.some(pattern => pattern.test(path));
export const socketAllowed = path => !leavesProject(path) && SOCKETS.some(pattern => pattern.test(path));

const readEngineFile = () => JSON.parse(fs.readFileSync(ENGINE_FILE, "utf8"));

// The handler LinkHost runs for each request.
export function engineHandler(readEngine = readEngineFile, info = {}) {
  return async function* (request, phone, signal) {
    const text = (status, words) => [{ head: { status, headers: { "content-type": "text/plain" } } }, { body: Buffer.from(words) }];
    if (request.path === "kuvo/info") {
      let engine = {};
      try { engine = readEngine(); } catch {}
      yield { head: { status: 200, headers: { "content-type": "application/json" } } };
      yield { body: Buffer.from(JSON.stringify({ kind: "machine", bridge: BRIDGE_VERSION, engine: engine.version ?? null, ...info })) };
      return;
    }
    if (!allowed(request.path)) return yield* text(403, "That isn't available over the link.");
    let engine;
    try {
      engine = readEngine();
    } catch {
      return yield* text(503, "The engine isn't running.");
    }
    touchAttached();
    const headers = { authorization: `Basic ${Buffer.from(`opencode:${engine.password}`).toString("base64")}` };
    const given = Object.fromEntries(Object.entries(request.headers).map(([k, v]) => [k.toLowerCase(), v]));
    for (const name of REQUEST_HEADERS) if (given[name]) headers[name] = given[name];
    const method = request.method.toUpperCase();
    const response = await fetch(`http://127.0.0.1:${engine.port}/${request.path}`, {
      method,
      headers,
      body: method === "GET" || method === "HEAD" ? undefined : request.body,
      signal,
    });
    const out = {};
    for (const name of RESPONSE_HEADERS) {
      const value = response.headers.get(name);
      if (value) out[name] = value;
    }
    yield { head: { status: response.status, headers: out } };
    if (!response.body) return;
    const reader = response.body.getReader();
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) return;
        yield { body: Buffer.from(value) };
      }
    } finally {
      reader.cancel().catch(() => {});
    }
  };
}

// What LinkHost runs to open a socket: the engine's WebSocket at that path, with its password.
export function engineConnect(readEngine = readEngineFile) {
  return (request, phone, events) => {
    let ended = false;
    const end = error => {
      if (ended) return;
      ended = true;
      events.end(error);
    };
    const refuse = words => {
      queueMicrotask(() => end(new Error(words)));
      return { send() {}, close() {} };
    };
    if (!socketAllowed(request.path)) return refuse("That isn't available over the link.");
    let engine;
    try {
      engine = readEngine();
    } catch {
      return refuse("The engine isn't running.");
    }
    touchAttached();
    const headers = { authorization: `Basic ${Buffer.from(`opencode:${engine.password}`).toString("base64")}` };
    const directory = Object.entries(request.headers ?? {}).find(([name]) => name.toLowerCase() === "x-opencode-directory")?.[1];
    if (directory) headers["x-opencode-directory"] = directory;
    const socket = new WebSocket(`ws://127.0.0.1:${engine.port}/${request.path}`, { headers });
    socket.binaryType = "arraybuffer";
    socket.onopen = () => events.open();
    socket.onmessage = event => typeof event.data === "string" ? events.text(Buffer.from(event.data)) : events.binary(Buffer.from(event.data));
    socket.onerror = () => end(new Error("The engine closed it."));
    socket.onclose = () => end();
    return {
      send: data => { if (socket.readyState === 1) socket.send(data.toString("utf8")); },
      close: () => {
        ended = true;
        try { socket.close(); } catch {}
      },
    };
  };
}

// The engine's watchdog stops it after a day without the app; a phone counts as the app.
let touched = 0;
function touchAttached() {
  if (Date.now() - touched < 5 * 60_000) return;
  touched = Date.now();
  try {
    const now = new Date();
    fs.utimesSync(path.join(RUN, "attached"), now, now);
  } catch {}
}

// ---- Notifications ----

// While no Mac is telling your phones what happens in this machine's sessions, the bridge does:
// a permission or a question asked, a run finished or failed, a bot's news (PROTOCOL.md,
// "Notifications"). A Mac connected to the engine touches a file of its own in run/present
// each minute, and tells your phones itself for two minutes after; the bridge waits longer.
const PRESENT = path.join(RUN, "present");
const PRESENT_MS = 150_000;
export const NOTICE_LIMIT = 2500;

export function macPresent(folder = PRESENT, now = Date.now()) {
  let names;
  try {
    names = fs.readdirSync(folder);
  } catch {
    return false;
  }
  return names.some(name => {
    try {
      return now - fs.statSync(path.join(folder, name)).mtimeMs < PRESENT_MS;
    } catch {
      return false;
    }
  });
}

// The characters of `text` that fit in `bytes` of UTF-8.
function prefixBytes(text, bytes) {
  let out = "", count = 0;
  for (const character of text) {
    count += Buffer.byteLength(character);
    if (count > bytes) break;
    out += character;
  }
  return out;
}

const cut = (text, count) => text.length <= count ? text : text.slice(0, count - 1) + "…";

// A notification's JSON, under NOTICE_LIMIT bytes: what doesn't fit of the body ends in "…".
export function noticeJSON(notice) {
  const value = { t: "notify", title: cut(String(notice.title ?? ""), 200), category: notice.category, thread: String(notice.thread ?? ""), data: notice.data ?? {} };
  if (notice.subtitle) value.subtitle = cut(String(notice.subtitle), 200);
  let body = String(notice.body ?? "");
  while (true) {
    const json = Buffer.from(sortedJSON({ ...value, body }));
    if (json.length <= NOTICE_LIMIT || !body) return json;
    const room = Buffer.byteLength(body) - (json.length - NOTICE_LIMIT) - Buffer.byteLength("…");
    body = room <= 0 ? "" : prefixBytes(body, room).trimEnd() + "…";
  }
}

// The relay's push of `json` to a phone ({key, address}, base64url), sealed for it alone.
export function pushTo(phone, json, hostKey) {
  const mail = frame(Frame.mail, 0, sealOneWay(json, hostKey, Buffer.from(phone.key, "base64url")).message);
  return relayPush(Buffer.from(phone.address, "base64url"), mail);
}

const plain = text => String(text ?? "").replace(/[*_`#>]+/g, "").replace(/\s+/g, " ").trim();

// "Wants to run a command: npm test", as the Mac says it.
export function describePermission(request) {
  const what = { edit: "edit files", write: "edit files", patch: "edit files", shell: "run a command", bash: "run a command", read: "read a file", external_directory: "work outside the project", webfetch: "open a web page" }[request.action] ?? request.action;
  const resource = request.resources?.[0];
  return !resource || resource === "*" ? `Wants to ${what}.` : `Wants to ${what}: ${resource}`;
}

// What a form asks, as the Mac's notification says it.
export function describeForm(form) {
  const kind = form.metadata?.kind;
  if (kind === "mcp-elicitation") return form.metadata?.message || "Needs your answer.";
  if (kind !== "question") return "Needs your answer.";
  const fields = (form.fields ?? []).filter(field => !field.hidden && !field.when?.length);
  if (fields.length === 1 && fields[0].type === "string") return fields[0].description || fields[0].title || form.title || "Has a question for you.";
  return "Has a question for you.";
}

const isBot = session => Boolean(session.metadata?.kuvo?.bot) || /\/bots\/bot_[^/]+\//.test(`${session.location?.directory ?? ""}/`);

// Asks the engine for `route` (a path under its API), as JSON.
function engineGet(engine, route) {
  return fetch(`http://127.0.0.1:${engine.port}/${route}`, { headers: { authorization: `Basic ${Buffer.from(`opencode:${engine.password}`).toString("base64")}` }, signal: AbortSignal.timeout(10_000) })
    .then(response => response.ok ? response.json() : Promise.reject(new Error(`${response.status}`)));
}

// The notification for an engine event, or null for one that isn't news. `get(route)` asks the
// engine.
export async function noticeFor(event, get) {
  const data = event.data ?? {};
  const session = async id => (await get(`api/session/${encodeURIComponent(id)}`)).data;
  // A subagent's request shows in the session that started it.
  const shown = async id => {
    let current = await session(id);
    for (let step = 0; step < 5 && current.parentID; step++) current = await session(current.parentID);
    return current;
  };
  // A form an MCP server asks for is filed under no session ("global"): it's the running session
  // of its folder with a tool of that server under way, as the Mac finds it; null for none.
  const waitingOn = async (server, folder) => {
    if (!server) return null;
    const active = (await get("api/session/active").catch(() => null))?.data ?? {};
    const name = String(server).replace(/[^\p{L}\p{N}_-]/gu, "_");
    for (const id of Array.isArray(active) ? active : Object.keys(active)) {
      const candidate = await session(id).catch(() => null);
      if (!candidate || (folder && candidate.location?.directory !== folder)) continue;
      const page = await get(`api/session/${encodeURIComponent(id)}/message?limit=8&order=desc`).catch(() => null);
      const steps = (page?.data ?? []).filter(message => message.type === "assistant").flatMap(message => message.content ?? []);
      if (steps.some(block => block.type === "tool" && block.state?.status === "running"
        && (block.name?.startsWith(name + "_") || (block.name === "execute" && String(block.state.input?.code ?? "").includes(server))))) return id;
    }
    return null;
  };
  const about = (shown, category, body, extra = {}) => {
    const bot = isBot(shown);
    const folder = shown.location?.directory ?? "";
    return {
      title: shown.title || "New Session",
      subtitle: bot ? undefined : path.basename(folder) || undefined,
      body,
      category,
      thread: shown.id,
      data: { session: shown.id, ...extra },
    };
  };
  switch (event.type) {
    case "permission.asked": {
      const where = await shown(data.sessionID);
      return about(where, "permission", describePermission(data), { request: data.id, ...(where.id !== data.sessionID ? { requestSession: data.sessionID } : {}) });
    }
    case "form.created": {
      // The form comes under `form`, with its session.
      const form = data.form ?? data;
      const asker = form.sessionID === "global" ? await waitingOn(form.metadata?.server, event.location?.directory) : form.sessionID;
      if (!asker) return null;
      const where = await shown(asker);
      return about(where, "question", describeForm(form), { request: form.id, ...(where.id !== form.sessionID ? { requestSession: form.sessionID } : {}) });
    }
    case "session.execution.succeeded":
    case "session.execution.failed": {
      const id = data.sessionID;
      const ended = await session(id);
      // A subagent's run is part of its parent's.
      if (ended.parentID) return null;
      if (event.type === "session.execution.failed") return about(ended, "failed", "Stopped with an error.");
      let reply = "";
      try {
        const page = await get(`api/session/${encodeURIComponent(id)}/message?limit=6&order=desc`);
        for (const message of page.data ?? []) {
          if (message.type !== "assistant") continue;
          reply = plain((message.content ?? []).filter(part => part.type === "text").map(part => part.text).join(" "));
          if (reply) break;
        }
      } catch {}
      // What it said last, as long as the Mac shows it.
      return about(ended, isBot(ended) ? "report" : "finished", reply ? cut(reply, 220) : "Finished.");
    }
    default:
      return null;
  }
}

// The events in a `text/event-stream` body, parsed.
async function* serverEvents(body) {
  const decoder = new TextDecoder();
  let buffer = "";
  let data = [];
  for await (const chunk of body) {
    buffer += decoder.decode(chunk, { stream: true });
    let end;
    while ((end = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, end).replace(/\r$/, "");
      buffer = buffer.slice(end + 1);
      if (line === "") {
        if (data.length) {
          try { yield JSON.parse(data.join("\n")); } catch {}
        }
        data = [];
      } else if (line.startsWith("data:")) {
        data.push(line.slice(5).replace(/^ /, ""));
      }
    }
  }
}

// The events that can be news.
const NEWS = new Set(["permission.asked", "form.created", "session.execution.succeeded", "session.execution.failed"]);

// Follows the engine's events for as long as the bridge runs, handing each one's notification to
// `tell`, while no Mac is present.
async function watchEngine(tell) {
  let attempt = 0;
  while (true) {
    try {
      const engine = readEngineFile();
      const response = await fetch(`http://127.0.0.1:${engine.port}/api/event`, {
        headers: { authorization: `Basic ${Buffer.from(`opencode:${engine.password}`).toString("base64")}`, accept: "text/event-stream" },
      });
      if (!response.ok || !response.body) throw new Error(`${response.status}`);
      attempt = 0;
      for await (const event of serverEvents(response.body)) {
        if (!NEWS.has(event.type) || macPresent()) continue;
        noticeFor(event, route => engineGet(engine, route)).then(notice => notice && tell(notice)).catch(() => {});
      }
    } catch {}
    attempt += 1;
    await sleep(Math.min(30_000, 1000 * 2 ** Math.min(attempt, 5)));
  }
}

// ---- State ----

export function readLink() {
  try {
    return JSON.parse(fs.readFileSync(LINK_FILE, "utf8"));
  } catch {
    return null;
  }
}

export function writeLink(link) {
  fs.mkdirSync(RUN, { recursive: true, mode: 0o700 });
  const temporary = `${LINK_FILE}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(link, null, 2), { mode: 0o600 });
  fs.renameSync(temporary, LINK_FILE);
}

// Lets in phones in link.json, and a new one showing the pairing token (once, in time). Notes
// where each one is on the relay, for its notifications.
export function authorizePhone(key, hello, address) {
  const link = readLink();
  if (!link) return false;
  const encoded = key.toString("base64url");
  const where = address?.toString("base64url");
  const known = link.phones?.find(phone => phone.key === encoded);
  if (known) {
    if (where && known.address !== where) {
      known.address = where;
      writeLink(link);
    }
    return true;
  }
  const pairing = link.pairing;
  if (!pairing || !hello.pair || Date.now() > pairing.expires) return false;
  const given = Buffer.from(String(hello.pair), "base64url");
  const expected = Buffer.from(pairing.token, "base64url");
  if (given.length !== expected.length || !crypto.timingSafeEqual(given, expected)) return false;
  link.phones = [...(link.phones ?? []), { key: encoded, name: String(hello.name ?? "").slice(0, 100), added: Math.floor(Date.now() / 1000), from: "pair", address: where }];
  delete link.pairing;
  writeLink(link);
  return true;
}

// ---- The relay connection ----

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

// Connects once, serves until the connection ends. Resolves whether it got as far as welcome.
export function connectOnce(relay, secret, host) {
  return new Promise(resolve => {
    const self = addressOf(secret);
    let welcomed = false;
    let lastHeard = Date.now();
    const socket = new WebSocket(relay);
    socket.binaryType = "arraybuffer";
    // Something sent to ourselves comes back through the relay: that shows the connection's
    // alive, where WebSocket pings can't be seen from here.
    const check = setInterval(() => {
      if (Date.now() - lastHeard > 90_000) return finish();
      if (welcomed) socket.send(relaySend(self, EMPTY));
    }, 30_000);
    // Once, however it ends: Node's WebSocket reports a refused connection as an error alone,
    // with no close to follow, and one that never opens has to be given up on.
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      clearInterval(check);
      clearTimeout(opening);
      try { socket.close(); } catch {}
      host.reset();
      host.send = () => {};
      resolve(welcomed);
    };
    const opening = setTimeout(() => { if (!welcomed) finish(); }, 15_000);
    socket.onopen = () => socket.send(relayHello(secret));
    socket.onmessage = event => {
      lastHeard = Date.now();
      const message = readRelay(Buffer.from(event.data));
      if (!message) return;
      if (!welcomed) {
        if (message.kind !== "welcome" || !message.address.equals(self)) return socket.close();
        welcomed = true;
        host.send = bytes => { if (socket.readyState === 1) socket.send(bytes); };
        return;
      }
      if (message.kind === "deliver" && !message.address.equals(self)) host.receive(message.address, message.payload);
      if (message.kind === "unreachable" && !message.address.equals(self)) host.forget(message.address);
    };
    socket.onerror = finish;
    socket.onclose = finish;
  });
}

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

// A bridge, not whatever took its number after a crash: on Linux its command line says so.
function isBridge(pid) {
  if (!pid || pid === process.pid || !alive(pid)) return false;
  try {
    return fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").includes("kuvo-link.js");
  } catch {
    return !fs.existsSync("/proc");
  }
}

// Something to answer: a paired phone, or a pairing code waiting.
const needed = link => Boolean(link && ((link.phones ?? []).length || (link.pairing && Date.now() < link.pairing.expires)));

async function run() {
  // One bridge at a time: a newer one (the engine restarted) takes over.
  try {
    const old = Number(fs.readFileSync(PID_FILE, "utf8"));
    if (isBridge(old)) process.kill(old, "SIGTERM");
  } catch {}
  fs.mkdirSync(RUN, { recursive: true, mode: 0o700 });
  fs.writeFileSync(PID_FILE, String(process.pid), { mode: 0o600 });
  fs.writeFileSync(VERSION_FILE, BRIDGE_VERSION, { mode: 0o600 });
  const cleanUp = () => {
    try { if (fs.readFileSync(PID_FILE, "utf8") === String(process.pid)) fs.unlinkSync(PID_FILE); } catch {}
    process.exit(0);
  };
  process.on("SIGTERM", cleanUp);
  process.on("SIGINT", cleanUp);

  // Stops with the engine, when nothing's paired any more, or when another bridge took over;
  // phones removed since lose what they have open.
  let current = null;
  setInterval(() => {
    let engine;
    try { engine = readEngineFile(); } catch {}
    let owner = null;
    try { owner = Number(fs.readFileSync(PID_FILE, "utf8")); } catch {}
    const link = readLink();
    if (!engine || !alive(engine.pid) || !needed(link) || owner !== process.pid) return cleanUp();
    current?.keepOnly(new Set((link.phones ?? []).map(phone => phone.key)));
  }, 30_000);

  // Your phones' notifications, on whichever relay connection is up.
  watchEngine(notice => {
    const link = readLink();
    if (!current || !link?.key) return;
    const json = noticeJSON(notice);
    const key = Buffer.from(link.key, "base64url");
    for (const phone of link.phones ?? []) if (phone.address) current.send(pushTo(phone, json, key));
  });

  let attempt = 0;
  while (true) {
    const link = readLink();
    if (!needed(link)) return cleanUp();
    let engine = {};
    try { engine = readEngineFile(); } catch {}
    const host = new LinkHost({
      key: Buffer.from(link.key, "base64url"),
      hello: { v: 1, kind: "machine", name: link.name || os.hostname(), app: BRIDGE_VERSION, engine: engine.version ?? null },
      authorize: authorizePhone,
      handle: engineHandler(readEngineFile, { name: link.name || os.hostname() }),
      connect: engineConnect(readEngineFile),
      send: () => {},
    });
    current = host;
    const welcomed = await connectOnce(link.relay, Buffer.from(link.secret, "base64url"), host);
    attempt = welcomed ? 0 : attempt + 1;
    await sleep(Math.min(60_000, 1000 * 2 ** Math.min(attempt, 6)));
  }
}

function runningBridge() {
  try {
    const pid = Number(fs.readFileSync(PID_FILE, "utf8"));
    return isBridge(pid) ? pid : null;
  } catch {
    return null;
  }
}

// Starts the bridge on its own, outliving this command, from the machine's workspace.
function startBridge() {
  const workspace = path.join(K, "workspace");
  const child = spawn(process.execPath, [fileURLToPath(import.meta.url), "run"], {
    detached: true,
    stdio: "ignore",
    cwd: fs.existsSync(workspace) ? workspace : K,
    env: process.env,
  });
  child.unref();
}

// What the Mac sends: the relay, this machine's name, and the phones you've paired with the Mac,
// which may reach it directly. Keeps the machine's own keys (made the first time, and never
// leaving it) and phones paired with the machine itself, starts the bridge or restarts it (on
// another relay, or a newer one), and prints the machine's address and public key for the Mac
// to tell your phones. Nothing left to answer: the bridge stops, and the keys stay.
async function setup() {
  let input;
  try {
    const chunks = [];
    for await (const chunk of process.stdin) chunks.push(chunk);
    input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    console.error("setup takes JSON on stdin: {relay, name, phones: [{key, name, address}]}");
    process.exit(2);
  }
  const phones = Array.isArray(input.phones) ? input.phones.filter(p => typeof p?.key === "string") : [];
  const running = runningBridge();
  const old = readLink();
  const own = (old?.phones ?? []).filter(phone => phone.from === "pair");
  if (!phones.length && !own.length) {
    if (old) writeLink({ ...old, phones: [] });
    if (running) process.kill(running, "SIGTERM");
    console.log("{}");
    return;
  }
  const link = old ?? { secret: crypto.randomBytes(32).toString("base64url"), key: newKey().toString("base64url"), phones: [] };
  link.relay = String(input.relay);
  link.name = String(input.name || link.name || os.hostname()).slice(0, 100);
  const known = new Map((old?.phones ?? []).map(p => [p.key, p]));
  const ADDRESS = /^[A-Za-z0-9_-]{22}$/;
  const fromMac = phones.map(p => ({
    key: p.key,
    name: String(p.name ?? "").slice(0, 100),
    added: known.get(p.key)?.added ?? Math.floor(Date.now() / 1000),
    from: "mac",
    address: ADDRESS.test(p.address ?? "") ? p.address : known.get(p.key)?.address,
  }));
  link.phones = [...fromMac, ...own.filter(phone => !fromMac.some(p => p.key === phone.key))];
  writeLink(link);
  // A new relay or name needs a new connection, and a newer bridge replaces an older one.
  let runningVersion = null;
  try { runningVersion = fs.readFileSync(VERSION_FILE, "utf8").trim(); } catch {}
  const restart = old?.relay !== link.relay || old?.name !== link.name || runningVersion !== BRIDGE_VERSION;
  if (running && restart) process.kill(running, "SIGTERM");
  if (!running || restart) startBridge();
  console.log(JSON.stringify({
    address: addressOf(Buffer.from(link.secret, "base64url")).toString("base64url"),
    key: publicOf(Buffer.from(link.key, "base64url")).toString("base64url"),
  }));
}

function pair(relay) {
  const link = readLink() ?? { secret: crypto.randomBytes(32).toString("base64url"), key: newKey().toString("base64url"), name: os.hostname(), phones: [] };
  if (relay) link.relay = relay;
  if (!link.relay) {
    console.error("Give the relay's address: kuvo-link.js pair wss://…");
    process.exit(1);
  }
  link.pairing = { token: crypto.randomBytes(16).toString("base64url"), expires: Date.now() + PAIRING_MINUTES * 60_000 };
  writeLink(link);
  const query = new URLSearchParams({
    v: "1",
    relay: link.relay,
    host: addressOf(Buffer.from(link.secret, "base64url")).toString("base64url"),
    key: publicOf(Buffer.from(link.key, "base64url")).toString("base64url"),
    token: link.pairing.token,
    name: link.name,
  });
  console.log(`kuvo-link://pair?${query}`);
  console.error(`Open this link on your phone within ${PAIRING_MINUTES} minutes. It works once.`);
  if (!runningBridge()) startBridge();
}

// Checks this runtime has what the link needs, both ends of a session and a mail.
export function selftest() {
  const phone = newKey(), host = newKey();
  const initiator = new IKInitiator(phone, publicOf(host), PROLOGUE);
  const responder = new IKResponder(host, PROLOGUE);
  const said = responder.readMessage1(initiator.writeMessage1(Buffer.from("hello")));
  const { message, transport: hostSide } = responder.writeMessage2(Buffer.from("welcome"));
  const { payload, transport: phoneSide } = initiator.readMessage2(message);
  const echoed = hostSide.open(phoneSide.seal(Buffer.from("ping")));
  const mail = openOneWay(sealOneWay(Buffer.from("mail"), host, publicOf(phone)).message, phone, publicOf(host)).payload;
  const ok = said.toString() === "hello" && payload.toString() === "welcome" && echoed.toString() === "ping" && mail.toString() === "mail"
    && responder.rs.equals(publicOf(phone)) && typeof WebSocket === "function" && typeof fetch === "function";
  return ok;
}

const main = process.argv[1] && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url));
if (main) {
  const [mode, argument] = process.argv.slice(2);
  if (mode === "run") await run();
  else if (mode === "setup") await setup();
  else if (mode === "pair") pair(argument);
  else if (mode === "selftest") {
    const ok = selftest();
    console.log(ok ? "ok" : "failed");
    process.exit(ok ? 0 : 1);
  } else {
    console.error("Usage: kuvo-link.js run | setup | pair [relay] | selftest");
    process.exit(2);
  }
}
