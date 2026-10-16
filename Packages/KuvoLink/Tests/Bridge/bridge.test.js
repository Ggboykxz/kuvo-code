// The bridge, checked against the shared vectors and against a phone and an engine in this
// process. Run with `node --test Packages/KuvoLink/Tests/Bridge/*.test.js`.
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";

// The bridge keeps its state in KUVO_HOME, so give it a folder of its own before loading it.
const home = fs.mkdtempSync(path.join(os.tmpdir(), "kuvo-link-test-"));
process.env.KUVO_HOME = home;
after(() => fs.rmSync(home, { recursive: true, force: true }));
const link = await import("../../Sources/KuvoLink/Resources/kuvo-link.js");

const vectors = name => JSON.parse(fs.readFileSync(new URL(`../../Vectors/${name}`, import.meta.url), "utf8"));
const hex = s => Buffer.from(s, "hex");

test("Noise IK matches the vectors", () => {
  for (const v of vectors("noise.json").vectors.filter(v => v.protocol_name === "Noise_IK_25519_AESGCM_SHA256")) {
    const initiator = new link.IKInitiator(hex(v.init_static), hex(v.init_remote_static), hex(v.init_prologue), hex(v.init_ephemeral));
    const responder = new link.IKResponder(hex(v.resp_static), hex(v.resp_prologue), hex(v.resp_ephemeral));
    const [m0, m1, ...rest] = v.messages;
    const first = initiator.writeMessage1(hex(m0.payload));
    assert.equal(first.toString("hex"), m0.ciphertext);
    assert.equal(responder.readMessage1(first).toString("hex"), m0.payload);
    const { message, transport: responderSide } = responder.writeMessage2(hex(m1.payload));
    assert.equal(message.toString("hex"), m1.ciphertext);
    const { payload, transport: initiatorSide } = initiator.readMessage2(message);
    assert.equal(payload.toString("hex"), m1.payload);
    assert.equal(initiatorSide.hash.toString("hex"), v.handshake_hash);
    rest.forEach((m, i) => {
      const [from, to] = i % 2 === 0 ? [initiatorSide, responderSide] : [responderSide, initiatorSide];
      assert.equal(from.seal(hex(m.payload)).toString("hex"), m.ciphertext);
      assert.equal(to.open(hex(m.ciphertext)).toString("hex"), m.payload);
    });
  }
});

test("Noise K matches the vectors", () => {
  for (const v of vectors("noise.json").vectors.filter(v => v.protocol_name === "Noise_K_25519_AESGCM_SHA256")) {
    const [m0, ...rest] = v.messages;
    const sealed = link.sealOneWay(hex(m0.payload), hex(v.init_static), hex(v.init_remote_static), hex(v.init_prologue), hex(v.init_ephemeral));
    assert.equal(sealed.message.toString("hex"), m0.ciphertext);
    const opened = link.openOneWay(sealed.message, hex(v.resp_static), link.publicOf(hex(v.init_static)), hex(v.resp_prologue));
    assert.equal(opened.payload.toString("hex"), m0.payload);
    for (const m of rest) {
      assert.equal(sealed.following.encrypt(Buffer.alloc(0), hex(m.payload)).toString("hex"), m.ciphertext);
      assert.equal(opened.following.decrypt(Buffer.alloc(0), hex(m.ciphertext)).toString("hex"), m.payload);
    }
  }
});

test("addresses, relay messages, frames and messages match the vectors", () => {
  const v = vectors("link.json");
  for (const { secret, address } of v.addresses) assert.equal(link.addressOf(hex(secret)).toString("hex"), address);
  for (const r of v.relay) {
    const bytes = hex(r.bytes);
    if (r.name === "hello") assert.deepEqual(link.relayHello(bytes.subarray(1)), bytes);
    if (r.name === "send") assert.deepEqual(link.relaySend(hex(r.to), hex(r.payload)), bytes);
    if (r.name === "welcome") assert.equal(link.readRelay(bytes).address.toString("hex"), r.address);
    if (r.name === "deliver") assert.deepEqual(link.readRelay(bytes), { kind: "deliver", address: hex(r.address), payload: hex(r.payload) });
    if (r.name === "unreachable") assert.equal(link.readRelay(bytes).kind, "unreachable");
    if (r.name === "pushed") assert.equal(link.readRelay(bytes).status, r.status);
  }
  for (const f of v.frames) {
    assert.equal(link.frame(f.kind, f.session, hex(f.body)).toString("hex"), f.bytes);
    assert.deepEqual(link.readFrame(hex(f.bytes)), { kind: f.kind, session: f.session, body: hex(f.body) });
  }
  for (const r of v.routes) assert.equal(link.allowed(r.path), r.allowed, r.path);
  for (const r of v.sockets) assert.equal(link.socketAllowed(r.path), r.allowed, r.path);
  for (const m of v.messages) {
    assert.equal(link.encodeMessage(m.head, hex(m.body)).toString("hex"), m.bytes);
    assert.deepEqual(link.decodeMessage(hex(m.bytes)), { head: m.head, body: hex(m.body) });
  }
});

test("long bodies split into messages that fit", () => {
  const body = crypto.randomBytes(200_000);
  const parts = link.pieces({ t: "res", id: 3, s: 200, h: { "content-type": "x" } }, body, true).map(link.decodeMessage);
  assert.equal(parts.length, 4);
  assert.deepEqual(parts.map(p => p.head.t), ["res", "data", "data", "data"]);
  assert.deepEqual(parts.map(p => p.head.end), [false, false, false, true]);
  assert.deepEqual(Buffer.concat(parts.map(p => p.body)), body);
});

// ---- A phone talking to a LinkHost in this process ----

function phoneFor(host, hostKey) {
  const key = link.newKey();
  const address = crypto.randomBytes(16);
  const session = crypto.randomInt(1, 2 ** 32);
  const inbox = [];
  const waiting = [];
  // What the host sends goes straight to the phone.
  host.send = bytes => {
    const message = link.readRelay(Buffer.concat([Buffer.from([2]), bytes.subarray(1, 17), bytes.subarray(17)]));
    const frame = link.readFrame(message.payload);
    const resolve = waiting.shift();
    if (resolve) resolve(frame); else inbox.push(frame);
  };
  const next = () => new Promise((resolve, reject) => {
    if (inbox.length) return resolve(inbox.shift());
    waiting.push(resolve);
    setTimeout(() => reject(new Error("nothing arrived")), 2000).unref();
  });
  let transport;
  return {
    key,
    async open(hello) {
      const initiator = new link.IKInitiator(key, link.publicOf(hostKey), link.PROLOGUE);
      await host.receive(address, link.frame(link.Frame.handshake1, session, initiator.writeMessage1(Buffer.from(JSON.stringify({ v: 1, name: "Test iPhone", app: "0", ...hello })))));
      const answer = await next();
      if (answer.kind !== link.Frame.handshake2) return { refused: true };
      const opened = initiator.readMessage2(answer.body);
      transport = opened.transport;
      return JSON.parse(opened.payload);
    },
    send(head, body = Buffer.alloc(0)) {
      for (const piece of link.pieces(head, body, head.end ?? true)) host.receive(address, link.frame(link.Frame.transport, session, transport.seal(piece)));
    },
    async receive() {
      const frame = await next();
      if (frame.kind !== link.Frame.transport) return { closed: true };
      return link.decodeMessage(transport.open(frame.body));
    },
    // A whole response: its head, and its body up to the message marked end.
    async response() {
      const first = await this.receive();
      const body = [first.body];
      for (let last = first; last.head.end !== true;) {
        last = await this.receive();
        body.push(last.body);
      }
      return { head: first.head, body: Buffer.concat(body) };
    },
  };
}

test("the host lets in a phone with the pairing token once, then by its key", async () => {
  const hostKey = link.newKey();
  link.writeLink({ relay: "wss://relay.test", secret: "", key: hostKey.toString("base64url"), phones: [], pairing: { token: Buffer.alloc(16, 7).toString("base64url"), expires: Date.now() + 60_000 } });
  const host = new link.LinkHost({ key: hostKey, hello: { v: 1, kind: "machine", name: "my-server", app: "0", engine: "2.0.30" }, authorize: link.authorizePhone, handle: async function* () {} });

  const stranger = phoneFor(host, hostKey);
  assert.deepEqual(await stranger.open({ pair: Buffer.alloc(16, 8).toString("base64url") }), { refused: true });

  const phone = phoneFor(host, hostKey);
  const hello = await phone.open({ pair: Buffer.alloc(16, 7).toString("base64url") });
  assert.equal(hello.kind, "machine");
  assert.equal(hello.name, "my-server");
  const saved = link.readLink();
  assert.equal(saved.pairing, undefined);
  assert.deepEqual(saved.phones.map(p => [p.key, p.name]), [[link.publicOf(phone.key).toString("base64url"), "Test iPhone"]]);
  assert.equal((fs.statSync(link.LINK_FILE).mode & 0o777).toString(8), "600");

  // The token is used up; the paired phone comes back without it.
  const late = phoneFor(host, hostKey);
  assert.deepEqual(await late.open({ pair: Buffer.alloc(16, 7).toString("base64url") }), { refused: true });
  const returning = phoneFor(host, hostKey);
  returning.key.set(phone.key);
  assert.equal((await returning.open({})).name, "my-server");
});

// An engine on a free port that answers like opencode does, and records what it was asked.
async function fakeEngine() {
  const asked = [];
  const server = http.createServer((request, response) => {
    asked.push({ method: request.method, url: request.url, auth: request.headers.authorization, directory: request.headers["x-opencode-directory"] });
    if (request.url === "/api/event") {
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.write('data: {"type":"server.connected"}\n\n');
      const timer = setInterval(() => response.write('data: {"type":"server.heartbeat"}\n\n'), 10);
      request.on("close", () => { clearInterval(timer); asked.push({ closed: request.url }); });
      return;
    }
    let body = "";
    request.on("data", chunk => { body += chunk; });
    request.on("end", () => {
      response.writeHead(200, { "content-type": "application/json", "set-cookie": "nope" });
      response.end(JSON.stringify({ path: request.url, body }));
    });
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  return { asked, port: server.address().port, close: () => { server.closeAllConnections(); server.close(); } };
}

test("requests go to the engine with its password; other routes don't", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const hostKey = link.newKey();
  const handle = link.engineHandler(() => ({ pid: process.pid, port: engine.port, password: "s3cret", version: "2.0.30" }));
  const host = new link.LinkHost({ key: hostKey, hello: { v: 1, kind: "machine", name: "m", app: "0" }, authorize: () => true, handle });
  const phone = phoneFor(host, hostKey);
  await phone.open({});

  phone.send({ t: "req", id: 1, m: "POST", p: "api/session/ses_1/prompt?x=1", h: { "Content-Type": "application/json", "X-Opencode-Directory": "/home/me/p", Authorization: "Basic forged" } }, Buffer.from('{"text":"hi"}'));
  const answer = await phone.response();
  assert.equal(answer.head.t, "res");
  assert.equal(answer.head.s, 200);
  assert.equal(answer.head.h["content-type"], "application/json");
  assert.equal(answer.head.h["set-cookie"], undefined);
  assert.deepEqual(JSON.parse(answer.body), { path: "/api/session/ses_1/prompt?x=1", body: '{"text":"hi"}' });
  const call = engine.asked.at(-1);
  assert.equal(call.auth, `Basic ${Buffer.from("opencode:s3cret").toString("base64")}`);
  assert.equal(call.directory, "/home/me/p");

  for (const [id, p] of [[2, "api/credential"], [3, "api/integration/github/connect/key"], [4, "api/config"], [5, "api/session/../credential"]]) {
    phone.send({ t: "req", id, m: "GET", p, h: {} });
    const refused = await phone.response();
    assert.equal(refused.head.s, 403, p);
  }
  assert.ok(!engine.asked.some(a => a.url?.includes("credential") || a.url?.includes("config")));

  // An event stream runs until the phone cancels it, and then the engine sees it close.
  phone.send({ t: "req", id: 9, m: "GET", p: "api/event", h: { Accept: "text/event-stream" } });
  const head = await phone.receive();
  assert.equal(head.head.h["content-type"], "text/event-stream");
  assert.match(head.body.toString(), /server.connected/);
  await phone.receive();
  phone.send({ t: "cancel", id: 9 });
  for (let i = 0; i < 50 && !engine.asked.some(a => a.closed === "/api/event"); i++) await new Promise(r => setTimeout(r, 20));
  assert.ok(engine.asked.some(a => a.closed === "/api/event"));
});

// A terminal on a free port as the engine serves one: a WebSocket that first says where its
// output starts, then answers each line. Short frames only, which is all this needs.
async function fakeTerminal() {
  const asked = [];
  const server = http.createServer();
  server.on("upgrade", (request, socket) => {
    asked.push({ url: request.url, auth: request.headers.authorization, directory: request.headers["x-opencode-directory"] });
    const accept = crypto.createHash("sha1").update(request.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    const send = (opcode, payload) => socket.write(Buffer.concat([Buffer.from([0x80 | opcode, payload.length]), payload]));
    send(2, Buffer.concat([Buffer.from([0]), Buffer.from('{"cursor":0}')]));
    let buffered = Buffer.alloc(0);
    socket.on("data", chunk => {
      buffered = Buffer.concat([buffered, chunk]);
      while (buffered.length >= 6) {
        const opcode = buffered[0] & 0x0f;
        const length = buffered[1] & 0x7f;
        if (buffered.length < 6 + length) return;
        const mask = buffered.subarray(2, 6);
        const payload = Buffer.from(buffered.subarray(6, 6 + length).map((byte, i) => byte ^ mask[i % 4]));
        buffered = buffered.subarray(6 + length);
        if (opcode === 1) send(1, Buffer.concat([Buffer.from("echo:"), payload]));
        if (opcode === 8) socket.end();
      }
    });
    socket.on("close", () => asked.push({ closed: request.url }));
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  return { asked, port: server.address().port, close: () => { server.closeAllConnections(); server.close(); } };
}

test("a socket reaches the engine's terminal with its password, both ways, until the phone closes it", async t => {
  const terminal = await fakeTerminal();
  t.after(terminal.close);
  const hostKey = link.newKey();
  const engine = () => ({ pid: process.pid, port: terminal.port, password: "s3cret", version: "2.0.30" });
  const host = new link.LinkHost({ key: hostKey, hello: { v: 1, kind: "machine", name: "m", app: "0" }, authorize: () => true, handle: link.engineHandler(engine), connect: link.engineConnect(engine) });
  const phone = phoneFor(host, hostKey);
  await phone.open({});

  phone.send({ t: "req", id: 1, m: "GET", p: "api/pty/pty_1/connect?cursor=0", h: { upgrade: "websocket", "x-opencode-directory": "/home/me/p" } });
  const opened = await phone.receive();
  assert.deepEqual([opened.head.t, opened.head.s, opened.head.end], ["res", 101, false]);
  const note = await phone.receive();
  assert.equal(note.head.h.type, "binary");
  assert.deepEqual(note.body, Buffer.concat([Buffer.from([0]), Buffer.from('{"cursor":0}')]));
  const call = terminal.asked[0];
  assert.equal(call.url, "/api/pty/pty_1/connect?cursor=0");
  assert.equal(call.auth, `Basic ${Buffer.from("opencode:s3cret").toString("base64")}`);
  assert.equal(call.directory, "/home/me/p");

  phone.send({ t: "data", id: 1, end: false }, Buffer.from("ls\r"));
  const answer = await phone.receive();
  assert.equal(answer.head.t, "data");
  assert.equal(answer.head.h, undefined);
  assert.equal(answer.body.toString(), "echo:ls\r");

  phone.send({ t: "cancel", id: 1 });
  for (let i = 0; i < 50 && !terminal.asked.some(a => a.closed); i++) await new Promise(r => setTimeout(r, 20));
  assert.ok(terminal.asked.some(a => a.closed));

  // Anything but a terminal's socket is turned away, without reaching the engine.
  phone.send({ t: "req", id: 2, m: "GET", p: "api/event", h: { upgrade: "websocket" } });
  const refused = await phone.response();
  assert.equal(refused.head.s, 502);
  assert.equal(terminal.asked.length, 2);
});

test("a relay that isn't there ends the attempt, so the bridge tries again", async () => {
  const host = { reset() {}, send() {} };
  const started = Date.now();
  assert.equal(await link.connectOnce("ws://127.0.0.1:9", crypto.randomBytes(32), host), false);
  assert.ok(Date.now() - started < 5000);
});

test("a session the host doesn't know is closed, and tampering ends one", async () => {
  const hostKey = link.newKey();
  const host = new link.LinkHost({ key: hostKey, hello: { v: 1, kind: "machine", name: "m", app: "0" }, authorize: () => true, handle: async function* () {} });
  const sent = [];
  host.send = bytes => sent.push(link.readFrame(bytes.subarray(17)));
  await host.receive(crypto.randomBytes(16), link.frame(link.Frame.transport, 99, Buffer.from("junk")));
  assert.equal(sent.at(-1).kind, link.Frame.close);
  assert.equal(sent.at(-1).session, 99);
});

test("the self-test passes here", () => {
  assert.ok(link.selftest());
});

test("setup keeps the machine's keys and its own phones, starts the bridge, and stops it with no phones left", async () => {
  const { spawnSync } = await import("node:child_process");
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), "kuvo-link-setup-"));
  fs.mkdirSync(path.join(folder, "workspace"));
  const script = new URL("../../Sources/KuvoLink/Resources/kuvo-link.js", import.meta.url).pathname;
  const setup = input => {
    const result = spawnSync(process.execPath, [script, "setup"], { input: JSON.stringify(input), env: { ...process.env, KUVO_HOME: folder }, encoding: "utf8" });
    return JSON.parse(result.stdout);
  };
  const pidFile = path.join(folder, "run", "link.pid");
  try {
    // A relay nobody listens on: the bridge keeps trying, which is all this needs.
    const first = setup({ relay: "ws://127.0.0.1:9", name: "test", phones: [{ key: "AAAA", name: "A" }] });
    assert.match(first.address, /^[A-Za-z0-9_-]{22}$/);
    for (let i = 0; i < 50 && !fs.existsSync(pidFile); i++) await new Promise(r => setTimeout(r, 50));
    const pid = Number(fs.readFileSync(pidFile, "utf8"));
    process.kill(pid, 0);

    // Its keys stay; the phones are what the Mac says now; the same bridge carries on.
    const second = setup({ relay: "ws://127.0.0.1:9", name: "test", phones: [{ key: "AAAA", name: "A" }, { key: "BBBB", name: "B" }] });
    assert.deepEqual(second, first);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(folder, "run", "link.json"), "utf8")).phones.map(p => p.key), ["AAAA", "BBBB"]);
    assert.equal(Number(fs.readFileSync(pidFile, "utf8")), pid);

    // A phone paired with the machine itself stays when the Mac's list changes.
    const linkFile = path.join(folder, "run", "link.json");
    const saved = JSON.parse(fs.readFileSync(linkFile, "utf8"));
    fs.writeFileSync(linkFile, JSON.stringify({ ...saved, phones: [...saved.phones, { key: "CCCC", name: "C", added: 1, from: "pair" }] }));
    setup({ relay: "ws://127.0.0.1:9", name: "test", phones: [{ key: "BBBB", name: "B" }] });
    assert.deepEqual(JSON.parse(fs.readFileSync(linkFile, "utf8")).phones.map(p => p.key), ["BBBB", "CCCC"]);

    // Nothing left to answer: the bridge stops, and the machine keeps its keys.
    fs.writeFileSync(linkFile, JSON.stringify({ ...saved, phones: [] }));
    assert.deepEqual(setup({ relay: "ws://127.0.0.1:9", phones: [] }), {});
    const kept = JSON.parse(fs.readFileSync(linkFile, "utf8"));
    assert.equal(kept.secret, saved.secret);
    assert.deepEqual(kept.phones, []);
    let stopped = false;
    for (let i = 0; i < 50 && !stopped; i++) {
      try { process.kill(pid, 0); await new Promise(r => setTimeout(r, 50)); } catch { stopped = true; }
    }
    assert.ok(stopped);
  } finally {
    try { process.kill(Number(fs.readFileSync(pidFile, "utf8")), "SIGKILL"); } catch {}
    fs.rmSync(folder, { recursive: true, force: true });
  }
});
