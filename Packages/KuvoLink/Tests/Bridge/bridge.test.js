// The bridge, checked against the shared vectors and against a phone and an engine in this
// process. Run with `node --test Packages/KuvoLink/Bridge/test`.
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
const link = await import("../kuvo-link.js");

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
