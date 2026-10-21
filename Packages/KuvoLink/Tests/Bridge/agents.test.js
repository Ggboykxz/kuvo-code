// A machine's coding agents through its bridge (PROTOCOL.md, `kuvo/agents/api/…`): passed to the
// agents' bridge beside its engine, as a Mac passes them to its own. Run with
// `node --test Packages/KuvoLink/Tests/Bridge/*.test.js`.
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";

const home = fs.mkdtempSync(path.join(os.tmpdir(), "kuvo-link-agents-"));
process.env.KUVO_HOME = home;
after(() => fs.rmSync(home, { recursive: true, force: true }));
const link = await import("../../Sources/KuvoLink/Resources/kuvo-link.js");

async function ask(handle, method, p, { headers = {}, body } = {}) {
  const parts = [];
  for await (const part of handle({ method, path: p, headers, body: body ? Buffer.from(body) : Buffer.alloc(0) }, {}, undefined)) parts.push(part);
  const text = Buffer.concat(parts.filter(part => part.body).map(part => part.body)).toString();
  let json;
  try { json = JSON.parse(text); } catch {}
  return { status: parts[0].head.status, headers: parts[0].head.headers, json, text };
}

// The agents' bridge on a free port: answers with what it was asked.
async function fakeBridge() {
  const asked = [];
  const server = http.createServer((request, response) => {
    let body = "";
    request.on("data", chunk => { body += chunk; });
    request.on("end", () => {
      asked.push({ method: request.method, url: request.url, auth: request.headers.authorization, directory: request.headers["x-opencode-directory"], body });
      response.writeHead(200, { "content-type": "application/json", "set-cookie": "no=thanks" });
      response.end(JSON.stringify({ url: request.url }));
    });
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  return { asked, port: server.address().port, close: () => { server.closeAllConnections(); server.close(); } };
}

test("the coding agents' sessions and accounts go to their bridge with its password; where the engine is, never", async t => {
  const bridge = await fakeBridge();
  t.after(bridge.close);
  let record = { pid: process.pid, port: bridge.port, password: "agents" };
  const handle = link.engineHandler(() => ({ port: 1, password: "engine", version: "2.0.32" }), { name: "my-server" }, () => record);

  const info = await ask(handle, "GET", "kuvo/info");
  assert.equal(info.json.agents, true, "kuvo/info says they're up");

  const prompt = await ask(handle, "POST", "kuvo/agents/api/session/ses_1/prompt", { headers: { "X-Opencode-Directory": "/home/me/p", Authorization: "Basic forged" }, body: '{"text":"hi"}' });
  assert.equal(prompt.status, 200);
  assert.equal(prompt.headers["set-cookie"], undefined);
  const sent = bridge.asked.at(-1);
  assert.equal(sent.url, "/api/session/ses_1/prompt");
  assert.equal(sent.auth, `Basic ${Buffer.from("opencode:agents").toString("base64")}`);
  assert.equal(sent.directory, "/home/me/p");
  assert.equal(sent.body, '{"text":"hi"}');
  assert.equal((await ask(handle, "PUT", "kuvo/agents/api/kuvo/auto", { body: "{}" })).status, 200);

  const before = bridge.asked.length;
  for (const [method, p] of [["PUT", "kuvo/agents/api/kuvo/engine"], ["POST", "kuvo/agents/api/integration/claude-code/%75pdate"], ["GET", "kuvo/agents/api/credential"]]) {
    assert.equal((await ask(handle, method, p)).status, 403, p);
  }
  assert.equal(bridge.asked.length, before, "none of those reached it");

  // Not running: kuvo/info says so, and its routes answer 503.
  record = null;
  assert.equal((await ask(handle, "GET", "kuvo/info")).json.agents, false);
  const down = await ask(handle, "GET", "kuvo/agents/api/session");
  assert.equal(down.status, 503);
  assert.match(down.json.message, /coding agents/);
  // One left by a bridge that stopped (its process gone) counts as not running.
  record = { pid: 2 ** 22 + 12345, port: bridge.port, password: "agents" };
  assert.equal((await ask(handle, "GET", "kuvo/agents/api/session")).status, 503);
});
