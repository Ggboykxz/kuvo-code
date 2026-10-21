// The harness on whatever machine runs the tests: the engine client (against a registry of
// one engine), the transcript reducer (against recorded events), and the server in front
// (against the same fake engine). Run with:
//   node --test "windows/harness/harness.test.mjs"

import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import { EngineClient, EngineError, messageID } from "./engine.mjs";
import { conversationMarkdown } from "./markdown.mjs";
import { paneLayout } from "./layout.mjs";
import { apply, applyAll, emptyTranscript, fromHistory } from "./transcript.mjs";
import { startHarness } from "./server.mjs";

const home = fs.mkdtempSync(path.join(os.tmpdir(), "kuvo-harness-test-"));
after(() => fs.rmSync(home, { recursive: true, force: true }));

// ---- A registry of one engine: the routes a conversation view uses ----

const PASSWORD = "hunter2-not-in-json";

async function readAll(request) {
  let text = "";
  for await (const chunk of request) text += chunk;
  return text;
}

function fakeEngine({ password = PASSWORD, session = null } = {}) {
  const asked = [];
  const subscribers = new Set();
  const engine = {
    asked,
    messages: [],
    permissions: [],
    events: [],
    session: session ?? { id: "ses_1", title: "A session", location: { directory: "/tmp/project" }, time: { created: 1, updated: 2 } },
    sessions: [session ?? { id: "ses_1", title: "A session", location: { directory: "/tmp/project" }, time: { created: 1, updated: 2 } }],
    push(event) {
      engine.events.push(event);
      for (const response of subscribers) response.write(`data: ${JSON.stringify(event)}\n\n`);
    },
    close: null,
  };

  const server = http.createServer(async (request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    const body = await readAll(request);
    asked.push({ method: request.method, path: url.pathname, query: url.searchParams, headers: request.headers, body: body === "" ? undefined : JSON.parse(body) });
    const send = (what, status = 200) => {
      response.writeHead(status, { "content-type": "application/json" });
      response.end(JSON.stringify(what));
    };

    const expected = `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}`;
    if (request.headers.authorization !== expected) return send({ message: "Missing or wrong password." }, 401);

    if (url.pathname === "/api/event") {
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.write(": hello\n\n");
      subscribers.add(response);
      request.on("close", () => subscribers.delete(response));
      return;
    }
    if (url.pathname === "/api/info") return send({ version: "2.0.32-test" });
    if (url.pathname === "/api/model") return send({ data: [{ id: "big", providerID: "prov", name: "Big" }] });
    if (url.pathname === "/api/session/active") return send({ data: {} });
    if (url.pathname === "/api/session" && request.method === "GET") return send({ data: engine.sessions, cursor: null });
    if (url.pathname === "/api/session" && request.method === "POST") {
      const made = { id: "ses_new", title: null, location: body.location, time: { created: 3, updated: 3 } };
      engine.sessions.unshift(made);
      return send({ data: made });
    }
    if (url.pathname === `/api/session/${engine.session.id}` && request.method === "GET") return send({ data: engine.session });
    if (url.pathname === `/api/session/${engine.session.id}` && request.method === "PATCH") return send({ data: engine.session });
    if (url.pathname === `/api/session/${engine.session.id}/message`) return send({ data: engine.messages, cursor: null });
    if (url.pathname === `/api/session/${engine.session.id}/permission`) return send({ data: engine.permissions });
    if (url.pathname.endsWith("/prompt")) return send({ ok: true });
    if (url.pathname.endsWith("/reply")) return send({ ok: true });
    if (url.pathname.endsWith("/interrupt") || url.pathname.endsWith("/model") || url.pathname.endsWith("/move")) return send({ ok: true });
    if (url.pathname.startsWith(`/api/session/${engine.session.id}`) && request.method === "DELETE") return send({ ok: true });
    return send({ message: `No route ${request.method} ${url.pathname}` }, 404);
  });
  engine.close = () => new Promise(resolve => { for (const r of subscribers) r.end(); server.close(resolve); });
  return new Promise(resolve => server.listen(0, "127.0.0.1", () => {
    engine.url = `http://127.0.0.1:${server.address().port}/`;
    resolve(engine);
  }));
}

// ---- The engine client ----

test("the client talks to the engine the Mac app's way: auth, folder scoping, routes", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const client = new EngineClient({ url: engine.url, password: PASSWORD });

  assert.equal((await client.info()).version, "2.0.32-test");
  const sessions = await client.sessions({ directory: "C:\\work\\app" });
  assert.equal(sessions.length, 1);
  const listed = engine.asked.at(-1);
  assert.equal(String(listed.query.get("directory")), "C:\\work\\app");
  assert.equal(String(listed.query.get("parentID")), "null");

  const made = await client.createSession({ directory: "C:\\work\\app", title: "Fix the tests" });
  assert.equal(made.id, "ses_new");
  assert.deepEqual(engine.asked.at(-1).body, { location: { directory: "C:\\work\\app" }, title: "Fix the tests" });

  // The model the picker chose goes as the engine's Model.ref — the object
  // (OpenCodeAPI.swift:473-476) — never the picker's "provider/id" shorthand, which the
  // engine refuses with 'Expected Model.Ref at ["model"]'. An id's own slashes stay in it.
  await client.setModel("ses_1", "openrouter/anthropic/claude-sonnet-4.5");
  assert.deepEqual(engine.asked.at(-1).body, { model: { providerID: "openrouter", id: "anthropic/claude-sonnet-4.5" } });
  await client.setModel("ses_1", { providerID: "prov", id: "big", variant: "high" });
  assert.deepEqual(engine.asked.at(-1).body, { model: { providerID: "prov", id: "big", variant: "high" } });

  const id = await client.prompt({ session: "ses_1", text: "hello" });
  assert.match(id, /^msg_[0-9A-Za-z]{10}$/);
  const prompted = engine.asked.at(-1);
  assert.equal(prompted.path, "/api/session/ses_1/prompt");
  assert.deepEqual(prompted.body, { id, text: "hello", delivery: "steer" });

  await client.replyPermission({ session: "ses_1", permission: "perm_1", decision: "always" });
  assert.deepEqual(engine.asked.at(-1).body, { decision: "always" });
  assert.equal(engine.asked.at(-1).headers.authorization, `Basic ${Buffer.from(`opencode:${PASSWORD}`).toString("base64")}`);
});

test("a refusal arrives as an EngineError with what the engine said", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const wrong = new EngineClient({ url: engine.url, password: "not-the-password" });
  await assert.rejects(wrong.sessions({ directory: "/x" }), error => {
    assert.ok(error instanceof EngineError);
    assert.equal(error.status, 401);
    assert.match(error.message, /password/);
    return true;
  });
});

test("events arrive parsed, across the chunk boundaries a stream makes", async t => {
  const frames = [
    "data: {\"type\":\"session.text.delta\",\"data\":{\"delta\":\"he\"}}\n\n",
    "data: {\"type\":\"session.text.de",
    "lta\",\"data\":{\"delta\":\"llo\"}}\n\n",
    ": keep-alive\n\n",
    "data: {\"type\":\"session.text.ended\",\"data\":\ndata: {\"text\":\"hello\"}}\n\n",
  ];
  const server = http.createServer((request, response) => {
    response.writeHead(200, { "content-type": "text/event-stream" });
    let index = 0;
    const drip = setInterval(() => {
      if (index >= frames.length) return clearInterval(drip);
      response.write(frames[index++]);
    }, 5);
    request.on("close", () => clearInterval(drip));
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));

  const client = new EngineClient({ url: `http://127.0.0.1:${server.address().port}/`, password: PASSWORD });
  const controller = new AbortController();
  const events = [];
  for await (const event of client.events(controller.signal)) {
    events.push(event);
    if (events.length === 3) break;
  }
  controller.abort();
  assert.deepEqual(events[0], { type: "session.text.delta", data: { delta: "he" } });
  assert.deepEqual(events[1], { type: "session.text.delta", data: { delta: "llo" } });
  assert.deepEqual(events[2], { type: "session.text.ended", data: { text: "hello" } });
});

test("message ids look like the Mac app's and don't repeat", () => {
  const ids = new Set();
  for (let index = 0; index < 500; index += 1) ids.add(messageID());
  assert.equal(ids.size, 500);
  for (const id of ids) assert.match(id, /^msg_[0-9A-Za-z]{10}$/);
});

// ---- The transcript ----

const event = (type, data, id) => ({ id: id ?? `evt_${type}`, type, created: 10, data: { sessionID: "ses_1", ...data } });

test("a whole turn: text, a tool, a permission asked and answered, the user's words", () => {
  const transcript = emptyTranscript("ses_1");
  applyAll(transcript, [
    event("session.execution.started", {}),
    event("session.step.started", { assistantMessageID: "msg_a1", agent: "build", model: { id: "big", providerID: "prov" }, started: 1 }),
    event("session.text.started", { assistantMessageID: "msg_a1", ordinal: 0 }),
    event("session.text.delta", { assistantMessageID: "msg_a1", ordinal: 0, delta: "Hello " }),
    event("session.text.delta", { assistantMessageID: "msg_a1", ordinal: 0, delta: "world" }),
    event("session.text.ended", { assistantMessageID: "msg_a1", ordinal: 0, text: "Hello world" }),
    event("session.tool.input.started", { assistantMessageID: "msg_a1", id: "call_1", name: "bash" }),
    event("session.tool.called", { assistantMessageID: "msg_a1", id: "call_1", input: { command: "ls" } }),
    event("permission.asked", { id: "perm_1", action: "shell", resources: ["ls"], message: "Wants to run ls" }),
    event("session.tool.success", { assistantMessageID: "msg_a1", id: "call_1", content: [{ type: "text", text: "a.txt" }] }),
    event("permission.replied", { requestID: "perm_1" }),
    event("session.inbox.enqueued", { inboxID: "msg_u1", item: { type: "user", payload: { text: "list the files" }, delivery: "steer" } }),
    event("session.inbox.delivered", { inboxID: "msg_u1" }),
    event("session.execution.succeeded", { reason: "completed" }),
  ]);

  assert.equal(transcript.running, false);
  assert.deepEqual(transcript.permissions, []);
  assert.deepEqual(transcript.pending, []);

  const assistant = transcript.entries.find(entry => entry.kind === "assistant");
  assert.equal(assistant.agent, "build");
  const [text, tool] = assistant.parts;
  assert.deepEqual(text, { type: "text", ordinal: 0, text: "Hello world", done: true });
  assert.equal(tool.name, "bash");
  assert.equal(tool.status, "completed");
  assert.deepEqual(tool.input, { command: "ls" });
  assert.deepEqual(tool.output, [{ type: "text", text: "a.txt" }]);

  const user = transcript.entries.find(entry => entry.kind === "user");
  assert.equal(user.text, "list the files");
  const idle = transcript.entries.find(entry => entry.kind === "idle");
  assert.equal(idle.outcome, "succeeded");

  // An event for another session changes nothing.
  const before = JSON.stringify(transcript);
  apply(transcript, { type: "session.text.delta", data: { sessionID: "ses_other", assistantMessageID: "msg_a1", delta: "!!!" } });
  assert.equal(JSON.stringify(transcript), before);
});

test("a running turn is running, a failed one says why, a shutdown says nothing", () => {
  const transcript = emptyTranscript("ses_1");
  apply(transcript, event("session.execution.started", {}));
  assert.equal(transcript.running, true);
  apply(transcript, event("session.execution.failed", { error: { message: "no provider" } }));
  assert.equal(transcript.running, false);
  assert.equal(transcript.entries.at(-1).outcome, "failed");
  assert.equal(transcript.entries.at(-1).error.message, "no provider");
  apply(transcript, event("session.execution.interrupted", { reason: "shutdown" }));
  assert.equal(transcript.entries.at(-1).outcome, "failed", "a shutdown adds no ending");
});

test("a permission shows until it's answered, a delta with no start still shows its words", () => {
  const transcript = emptyTranscript("ses_1");
  apply(transcript, event("permission.asked", { id: "perm_2", action: "edit", resources: ["a.txt"] }));
  assert.equal(transcript.permissions.length, 1);
  apply(transcript, { type: "session.text.delta", data: { sessionID: "ses_1", assistantMessageID: "msg_a2", ordinal: 0, delta: "late words" } });
  const assistant = transcript.entries.find(entry => entry.kind === "assistant");
  assert.equal(assistant.parts[0].text, "late words");
  apply(transcript, event("permission.replied", { requestID: "perm_2" }));
  assert.deepEqual(transcript.permissions, []);
});

test("a shell the engine ran: started, then ended with what it printed", () => {
  const transcript = emptyTranscript("ses_1");
  applyAll(transcript, [
    event("session.shell.started", { shell: { id: "sh_1", command: "npm test", status: "running" } }),
    event("session.shell.ended", { shell: { id: "sh_1", command: "npm test", status: "exited", exit: 1 }, output: { output: "1 test failed\n", truncated: false } }),
  ]);
  assert.equal(transcript.entries.length, 1);
  const [shell] = transcript.entries;
  assert.deepEqual(shell, { kind: "shell", id: "shell_sh_1", created: 10, command: "npm test", status: "exited", exit: 1, output: "1 test failed\n" });
  // As the engine stores one.
  const stored = fromHistory("ses_1", [{
    type: "shell", id: "msg_sh1", time: { created: 5 }, shellID: "sh_1", command: "npm test", status: "exited", exit: 1,
    output: { output: "1 test failed\n", truncated: false },
  }]);
  assert.equal(stored.entries[0].output, "1 test failed\n");
  assert.equal(stored.entries[0].exit, 1);
});

test("tool input streams in, a late called doesn't undo a result, a retry shows and clears", () => {
  const transcript = emptyTranscript("ses_1");
  applyAll(transcript, [
    event("session.tool.input.started", { assistantMessageID: "msg_a1", id: "call_1", name: "edit" }),
    event("session.tool.input.delta", { assistantMessageID: "msg_a1", id: "call_1", delta: "{\"file\":" }),
    event("session.tool.input.delta", { assistantMessageID: "msg_a1", id: "call_1", delta: "\"a.txt\"}" }),
  ]);
  assert.equal(transcript.running, true, "tool input means work");
  const [part] = transcript.entries[0].parts;
  assert.equal(part.status, "streaming");
  assert.equal(part.inputText, "{\"file\":\"a.txt\"}");

  // What a read gave as finished stays finished when the older event arrives late.
  applyAll(transcript, [
    event("session.tool.called", { assistantMessageID: "msg_a1", id: "call_1", input: { file: "a.txt" } }),
    event("session.tool.success", { assistantMessageID: "msg_a1", id: "call_1", content: "wrote a.txt" }),
    event("session.tool.called", { assistantMessageID: "msg_a1", id: "call_1", input: { file: "b.txt" } }),
    event("session.tool.failed", { assistantMessageID: "msg_a1", id: "call_1", error: { message: "nope" } }),
  ]);
  assert.equal(part.status, "completed");
  assert.equal(part.output, "wrote a.txt");
  assert.equal(part.error, undefined);

  // A retry is shown while it waits, and goes away when the next step starts.
  applyAll(transcript, [
    event("session.step.failed", { assistantMessageID: "msg_a1", error: { message: "rate limited" } }),
    event("session.retry.scheduled", { assistantMessageID: "msg_a1", attempt: 2, at: 20, error: { message: "rate limited" } }),
  ]);
  const assistant = transcript.entries[0];
  assert.deepEqual(assistant.retry, { attempt: 2, at: 20 });
  assert.equal(assistant.error.message, "rate limited");
  apply(transcript, event("session.step.started", { assistantMessageID: "msg_a1" }));
  assert.equal(assistant.retry, undefined);
  assert.equal(assistant.error, undefined);

  // A queued item says so until the engine delivers it.
  applyAll(transcript, [
    event("session.inbox.enqueued", { inboxID: "msg_u1", item: { type: "user", payload: { text: "and then" }, delivery: "steer" } }),
    event("session.inbox.delivery.changed", { inboxID: "msg_u1", delivery: "queue" }),
  ]);
  assert.equal(transcript.pending[0].delivery, "queue");
});

test("what the engine stored reads back the same", () => {
  const messages = [
    { type: "user", id: "msg_u1", time: { created: 1 }, text: "do the thing" },
    {
      type: "assistant", id: "msg_a1", time: { created: 2, completed: 9 }, agent: "build", model: { id: "big", providerID: "prov" },
      content: [
        { type: "reasoning", text: "thinking about it", time: { created: 2, completed: 3 } },
        { type: "text", text: "Done.", time: { created: 3, completed: 4 } },
        { type: "tool", id: "call_1", name: "edit", state: { status: "completed", input: { file: "a.txt" }, content: [{ type: "text", text: "ok" }] } },
      ],
      cost: 0.01,
    },
    { type: "idle", id: "msg_i1", time: { created: 9 }, outcome: "succeeded" },
  ];
  const pending = [{ id: "perm_1", sessionID: "ses_1", action: "shell", resources: [] }, { id: "perm_x", sessionID: "ses_other", action: "shell", resources: [] }];
  const transcript = fromHistory("ses_1", messages, pending, false);

  assert.deepEqual(transcript.entries.map(entry => entry.kind), ["user", "assistant", "idle"]);
  const assistant = transcript.entries[1];
  assert.deepEqual(assistant.parts.map(part => part.type === "tool" ? `${part.type}:${part.status}` : part.type), ["reasoning", "text", "tool:completed"]);
  assert.equal(transcript.permissions.length, 1, "another session's asks aren't shown");
});

// ---- The server in front ----

async function inFront(engine) {
  const harness = startHarness({
    project: null,
    port: 0,
    clientFor: async () => ({
      client: new EngineClient({ url: engine.url, password: PASSWORD }),
      version: "2.0.32-test",
      stop: async () => {},
    }),
    log: () => {},
  });
  return { harness, url: await harness.url() };
}

test("the server keeps the engine's password to itself, and answers the page", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());

  const stopped = await (await fetch(`${url}api/state`)).json();
  assert.equal(stopped.project, null);
  assert.equal(stopped.engine.status, "stopped");

  const project = path.join(home, "project");
  fs.mkdirSync(path.join(project, "src"), { recursive: true });
  const chosen = await (await fetch(`${url}api/project`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ directory: project }) })).json();
  assert.equal(chosen.project, path.resolve(project));

  const browsed = await (await fetch(`${url}api/browse?path=${encodeURIComponent(project)}`)).json();
  assert.deepEqual(browsed.folders.map(child => child.name), ["src"]);
  assert.equal(browsed.folders[0].path, path.join(path.resolve(project), "src"));
  assert.equal(browsed.parent, path.dirname(path.resolve(project)));

  const made = await (await fetch(`${url}api/sessions`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" })).json();
  assert.equal(made.session.id, "ses_new");
  assert.equal(engine.asked.at(-1).body.location.directory, path.resolve(project), "the session is made in the chosen folder");

  const started = await (await fetch(`${url}api/state`)).json();
  assert.equal(started.engine.status, "running", "the first call that needs it starts the engine");
  assert.equal(started.engine.version, "2.0.32-test");

  const listed = await (await fetch(`${url}api/sessions?directory=${encodeURIComponent(project)}`)).json();
  assert.equal(listed.sessions.length, 2, "the made session joined the listed ones");
  assert.equal(listed.sessions[0].id, "ses_new");
  assert.ok(!JSON.stringify(started).includes(PASSWORD), "the page never sees the password");
  assert.ok(!JSON.stringify(listed).includes(PASSWORD));
});

test("a prompt from the page reaches the engine; an empty one doesn't", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());
  const send = body => fetch(`${url}api/sessions/ses_1/prompt`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

  const empty = await send({ text: "   " });
  assert.equal(empty.status, 400);

  const { id } = await (await send({ text: "hello there" })).json();
  assert.match(id, /^msg_/);
  assert.deepEqual(engine.asked.at(-1).body, { id, text: "hello there", delivery: "steer" });

  const queued = await (await send({ text: "and this", delivery: "queue" })).json();
  assert.equal(engine.asked.at(-1).body.delivery, "queue");
  assert.notEqual(queued.id, id);
});

test("permission answers and the session's history cross the server", async t => {
  const engine = await fakeEngine();
  engine.messages = [{ type: "user", id: "msg_u1", time: { created: 1 }, text: "hi" }];
  engine.permissions = [{ id: "perm_1", sessionID: "ses_1", action: "edit", resources: ["a.txt"] }];
  t.after(engine.close);
  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());

  const detail = await (await fetch(`${url}api/sessions/ses_1`)).json();
  assert.equal(detail.messages.length, 1);
  assert.equal(detail.permissions[0].id, "perm_1");
  assert.equal(detail.running, false);

  const answered = await fetch(`${url}api/sessions/ses_1/permission/perm_1`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ decision: "once" }) });
  assert.equal(answered.status, 200);
  assert.deepEqual(engine.asked.at(-1).body, { decision: "once" });
});

test("events reach the page as they happen", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());

  const controller = new AbortController();
  const response = await fetch(`${url}api/events`, { signal: controller.signal });
  assert.equal(response.status, 200);
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  const received = [];
  const reading = (async () => {
    while (received.length < 2) {
      const { value, done } = await reader.read();
      if (done) break;
      for (const line of decoder.decode(value).split("\n")) {
        if (line.startsWith("data: ")) received.push(JSON.parse(line.slice(6)));
      }
    }
  })();
  // The page connects before anything happens; give the relay a moment, then speak.
  await new Promise(resolve => setTimeout(resolve, 100));
  engine.push(event("session.text.delta", { assistantMessageID: "msg_a1", ordinal: 0, delta: "hi" }, "evt_1"));
  engine.push(event("session.text.ended", { assistantMessageID: "msg_a1", ordinal: 0, text: "hi" }, "evt_2"));
  await Promise.race([reading, new Promise(resolve => setTimeout(resolve, 3000))]);
  controller.abort();

  assert.equal(received.length, 2);
  assert.equal(received[0].type, "session.text.delta");
  assert.equal(received[0].data.sessionID, "ses_1");
});

test("the page and the reducer are served", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());

  // The page is the built one (React, built by Next.js) when there is a build, the
  // hand-written one otherwise; both are the app, and both carry the same ids.
  const page = await fetch(url);
  assert.equal(page.status, 200);
  const html = await page.text();
  assert.match(html, /Kuvo/);
  // The built page brings its own scripts, and the app's code is in one of them.
  const scripts = [...html.matchAll(/<script[^>]+src="([^"]+)"/g)].map(match => match[1]);
  assert.ok(scripts.length > 0, "the page brings its scripts");
  const bodies = await Promise.all(scripts.map(src => fetch(new URL(src, url)).then(answer => answer.text())));
  assert.ok(bodies.some(body => /EventSource/.test(body)), "the app's code is in the page");
  const reducer = await fetch(`${url}transcript.mjs`);
  assert.match(await reducer.text(), /export function apply/);
});

test("the project's files are listed, and a file is read by its path in the project", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());

  const project = path.join(home, "files-project");
  fs.mkdirSync(path.join(project, "src"), { recursive: true });
  fs.writeFileSync(path.join(project, "notes.txt"), "Shopping list\n- coffee\n");
  fs.writeFileSync(path.join(project, "src", "app.tsx"), "export const answer = 42;\n");
  const opened = await fetch(`${url}api/project`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ directory: project }) });
  assert.equal(opened.status, 200);

  // The file links of a reply ask which files are real: the server answers with the list.
  const listed = await (await fetch(`${url}api/project-files`)).json();
  assert.deepEqual([...listed.files].sort(), ["notes.txt", "src/app.tsx"]);
  // And the file itself is read by its path in the project.
  const file = await (await fetch(`${url}api/file?path=${encodeURIComponent("src/app.tsx")}`)).json();
  assert.match(file.content, /answer = 42/);
});

test("a project folder that isn't there is refused with a word about it", async t => {  const engine = await fakeEngine();
  t.after(engine.close);
  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());
  const response = await fetch(`${url}api/project`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ directory: path.join(home, "nope") }) });
  assert.equal(response.status, 400);
  assert.match((await response.json()).error, /no such folder/i);
});

// ---- The settings file (what the Mac app edits through EngineConfig) ----

test("the settings file is read, served with its problems, and written whole", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const file = path.join(home, "config", "opencode", "opencode.json");
  process.env.KUVO_ENGINE_CONFIG_ROOT = file;
  t.after(() => { delete process.env.KUVO_ENGINE_CONFIG_ROOT; delete process.env.KUVO_SKILLS_ROOT; });
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());

  // Nothing yet: an empty object, no problem, and where it would live.
  let fine = await fetch(`${url}api/config`);
  assert.equal(fine.status, 200);
  let body = await fine.json();
  assert.deepEqual(body.settings, {});
  assert.equal(body.problem, null);
  assert.equal(body.path, file);

  // A file with a whole server, a command and permissions reads back as it is.
  const settings = {
    mcp: { servers: { linear: { type: "remote", url: "https://mcp.linear.app/mcp", codemode: false } } },
    commands: { test: { description: "Run the tests", template: "npm test" } },
    permissions: [{ action: "skill", resource: "writing-well", effect: "deny" }],
  };
  fs.writeFileSync(file, JSON.stringify(settings, null, 2));
  fine = await fetch(`${url}api/config`);
  body = await fine.json();
  assert.deepEqual(body.settings, settings);

  // Unreadable JSON comes back as a problem, not as a crash.
  fs.writeFileSync(file, "{ mcp: {");
  fine = await fetch(`${url}api/config`);
  body = await fine.json();
  assert.equal(body.settings, null);
  assert.match(body.problem, /JSON/i);

  // PUT writes the file whole and pretty; a non-object is refused.
  const written = await fetch(`${url}api/config`, {
    method: "PUT", headers: { "content-type": "application/json" },
    body: JSON.stringify({ settings: { agents: { reviewer: { mode: "primary" } } } }),
  });
  assert.equal(written.status, 200);
  assert.equal(JSON.parse(fs.readFileSync(file, "utf8")).agents.reviewer.mode, "primary");

  const bad = await fetch(`${url}api/config`, {
    method: "PUT", headers: { "content-type": "application/json" },
    body: JSON.stringify({ settings: [1, 2] }),
  });
  assert.equal(bad.status, 400);

  const missing = await fetch(`${url}api/config`, {
    method: "PUT", headers: { "content-type": "application/json" },
    body: "{}",
  });
  assert.equal(missing.status, 400);
});

test("a skill is written to its own folder as one SKILL.md, read back, deleted", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const root = path.join(home, "skills-root");
  process.env.KUVO_ENGINE_CONFIG_ROOT = path.join(home, "config", "opencode", "opencode.json");
  process.env.KUVO_SKILLS_ROOT = root;
  t.after(() => { delete process.env.KUVO_ENGINE_CONFIG_ROOT; delete process.env.KUVO_SKILLS_ROOT; });
  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());

  const put = await fetch(`${url}api/skill-file/writing-well`, {
    method: "PUT", headers: { "content-type": "application/json" },
    body: JSON.stringify({ text: "---\nname: writing-well\ndescription: \"How to write\"\n---\n\nBe clear.\n" }),
  });
  assert.equal(put.status, 200);
  assert.equal(put.ok, true);
  assert.equal(fs.readFileSync(path.join(root, "writing-well", "SKILL.md"), "utf8"), "---\nname: writing-well\ndescription: \"How to write\"\n---\n\nBe clear.\n");
  const got = await fetch(`${url}api/skill-file/writing-well`);
  assert.deepEqual(await got.json(), { id: "writing-well", text: "---\nname: writing-well\ndescription: \"How to write\"\n---\n\nBe clear.\n" });

  const gone = await fetch(`${url}api/skill-file/writing-well`, { method: "DELETE" });
  assert.equal(gone.status, 200);
  assert.ok(!fs.existsSync(path.join(root, "writing-well")));

  // A name the page can't send (the ids are guarded) isn't a route.
  const guarded = await fetch(`${url}api/skill-file/../escape`, { method: "DELETE" });
  assert.notEqual(guarded.status, 200);
});

test("connecting an MCP server again reaches the engine the Mac app's way", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());
  await fetch(`${url}api/mcp/jira/connect`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
  const go = engine.asked.find(asked => asked.path.startsWith("/api/experimental/mcp"));
  assert.equal(go.path, "/api/experimental/mcp/jira/connect");
  await fetch(`${url}api/mcp/jira/disconnect`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
  const stop = engine.asked.find(asked => asked.path.startsWith("/api/experimental/mcp") && asked.path.endsWith("/disconnect"));
  assert.equal(stop.path, "/api/experimental/mcp/jira/disconnect");
});

test("the page and its files are served, and a file that isn't there is a plain 404", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());

  const page = await fetch(url);
  assert.equal(page.status, 200);
  const html = await page.text();
  assert.match(html, /<title>Kuvo Code<\/title>/);

  // The shell loads the page with its own query string; that is the same page.
  const withQuery = await fetch(`${url}?terminalPort=0&shell=1`);
  assert.equal(withQuery.status, 200);
  assert.match(await withQuery.text(), /<title>Kuvo Code<\/title>/);

  const scripts = [...html.matchAll(/<script[^>]+src="([^"]+)"/g)].map(match => match[1]);
  for (const src of scripts) {
    const script = await fetch(new URL(src, url));
    assert.equal(script.status, 200, `the page's ${src} is served`);
  }

  const missing = await fetch(`${url}nope.js`);
  assert.equal(missing.status, 404);
  assert.match(await missing.text(), /not found/i);
});

test("what opencode's own settings hold can be brought over, in the shape the engine reads", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const mine = path.join(home, "mine", "opencode.json");
  const theirs = path.join(home, "theirs", "opencode.json");
  process.env.KUVO_ENGINE_CONFIG_ROOT = mine;
  process.env.KUVO_OPENCODE_CONFIG_ROOT = theirs;
  t.after(() => { delete process.env.KUVO_ENGINE_CONFIG_ROOT; delete process.env.KUVO_OPENCODE_CONFIG_ROOT; });
  fs.mkdirSync(path.dirname(theirs), { recursive: true });
  // The shape other tools write: straight under `mcp`, with `enabled` and `env`.
  fs.writeFileSync(theirs, JSON.stringify({
    mcp: {
      "open-design": { type: "local", command: ["C:\\od\\od.mjs", "mcp"], enabled: true, env: { OD_DATA_DIR: "C:\\data" } },
      context7: { type: "remote", url: "https://mcp.context7.com/mcp" },
    },
  }));
  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());

  const config = await (await fetch(`${url}api/config`)).json();
  assert.equal(config.opencode.exists, true);
  assert.equal(config.opencode.path, theirs);

  const brought = await (await fetch(`${url}api/config/import`, {
    method: "POST", headers: { "content-type": "application/json" }, body: "{}",
  })).json();
  assert.deepEqual([...brought.added].sort(), ["mcp:context7", "mcp:open-design"]);

  const written = JSON.parse(fs.readFileSync(mine, "utf8"));
  const design = written.mcp.servers["open-design"];
  assert.equal(design.type, "local");
  assert.deepEqual(design.command, ["C:\\od\\od.mjs", "mcp"]);
  assert.equal(design.environment.OD_DATA_DIR, "C:\\data");
  assert.equal(design.enabled, undefined);
  assert.equal(written.mcp.servers.context7.url, "https://mcp.context7.com/mcp");

  // A second time, nothing is added and nothing already here is touched.
  const again = await (await fetch(`${url}api/config/import`, {
    method: "POST", headers: { "content-type": "application/json" }, body: "{}",
  })).json();
  assert.deepEqual(again.added, []);
  assert.deepEqual([...again.skipped].sort(), ["mcp:context7", "mcp:open-design"]);

  // The agents, the commands and the model come across as well.
  fs.writeFileSync(theirs, JSON.stringify({
    mcp: { "open-design": { type: "local", command: ["od", "mcp"], enabled: true } },
    agents: { reviewer: { mode: "primary", description: "Reviews" } },
    commands: { ship: { template: "ship it" } },
    model: "openai/gpt-5",
  }));
  const wider = await (await fetch(`${url}api/config/import`, {
    method: "POST", headers: { "content-type": "application/json" }, body: "{}",
  })).json();
  assert.deepEqual([...wider.added].sort(), ["agents:reviewer", "commands:ship", "model"]);
  const widerSettings = JSON.parse(fs.readFileSync(mine, "utf8"));
  assert.equal(widerSettings.agents.reviewer.description, "Reviews");
  assert.equal(widerSettings.commands.ship.template, "ship it");
  assert.equal(widerSettings.model, "openai/gpt-5");

  // One server at a time.
  const one = await (await fetch(`${url}api/config/import`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ name: "open-design" }),
  })).json();
  assert.deepEqual(one.added, []);
  assert.deepEqual(one.skipped, ["mcp:open-design"]);
});

test("the shell's own settings are read and written, so the page can speak to the app", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());

  const first = await (await fetch(`${url}api/app-settings`)).json();
  assert.equal(typeof first.updates, "boolean");
  assert.equal(typeof first.startAtLogin, "boolean");
  assert.equal(typeof first.keepAwake, "boolean");

  const written = await (await fetch(`${url}api/app-settings`, {
    method: "PUT", headers: { "content-type": "application/json" },
    body: JSON.stringify({ updates: false, keepAwake: true }),
  })).json();
  assert.equal(written.updates, false);
  assert.equal(written.keepAwake, true);
  assert.equal(written.startAtLogin, first.startAtLogin);
});

test("a session can be put away and brought back, the way the Mac app does it", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());

  const archived = await fetch(`${url}api/sessions/${engine.session.id}/archive`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ archived: true }),
  });
  assert.equal(archived.status, 200);
  assert.deepEqual(await archived.json(), { ok: true, archived: true });
  const change = engine.asked.find(asked => asked.method === "PATCH" && asked.path.includes(engine.session.id));
  assert.ok(change, "the engine was asked to change the session");
  assert.equal(change.body.metadata["kuvo.archived"], true);

  const back = await fetch(`${url}api/sessions/${engine.session.id}/archive`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ archived: false }),
  });
  assert.equal(back.status, 200);
});

test("a session can be pinned, and the mark goes out with the session's own metadata", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());

  // The session carries a mark of its own: the pin goes out with it, because the engine
  // may merge metadata rather than replace it (Workspace.swift:366-375).
  engine.session.metadata = { "kuvo.archived": false };

  const pinned = await fetch(`${url}api/sessions/${engine.session.id}/pin`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ pinned: true }),
  });
  assert.equal(pinned.status, 200);
  assert.deepEqual(await pinned.json(), { ok: true, pinned: true });
  const change = engine.asked.find(asked => asked.method === "PATCH");
  assert.ok(change, "the engine was asked to change the session");
  assert.equal(change.body.metadata["kuvo.pinned"], true);
  assert.equal(change.body.metadata["kuvo.archived"], false, "the other marks stay");

  const unpinned = await fetch(`${url}api/sessions/${engine.session.id}/pin`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ pinned: false }),
  });
  assert.equal(unpinned.status, 200);
  assert.deepEqual(await unpinned.json(), { ok: true, pinned: false });
});

test("a commit can push afterwards, as the Mac's commit form does", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());

  const { execFileSync } = await import("node:child_process");
  const project = fs.mkdtempSync(path.join(home, "git-push-"));
  const remote = fs.mkdtempSync(path.join(home, "git-remote-"));
  const git = (...args) => execFileSync("git", ["-C", project, ...args], { encoding: "utf8" });
  git("init", "-q");
  git("config", "user.email", "kuvo@example.test");
  git("config", "user.name", "Kuvo");
  // The branch it pushes to: a bare repository of its own, as a remote is.
  execFileSync("git", ["init", "--bare", "-q", remote]);
  git("remote", "add", "origin", remote);
  fs.writeFileSync(path.join(project, "a.txt"), "one\n");
  git("add", "-A");
  git("commit", "-q", "-m", "first");
  git("push", "-q", "-u", "origin", "HEAD:main");

  fs.writeFileSync(path.join(project, "a.txt"), "two\n");
  const pushed = await (await fetch(`${url}api/changes/commit`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ directory: project, message: "Second", push: true }),
  })).json();
  assert.equal(pushed.ok, true);
  assert.equal(pushed.pushed, true, "the branch was pushed");
  const log = git("log", "--oneline", "origin/main");
  assert.match(log, /Second/, "the commit is on the branch that was pushed");
});

test("a session's own rules are set, the way the Mac sets them", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());

  const asked = await fetch(`${url}api/sessions/${engine.session.id}/permissions`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ permissions: [{ action: "edit", resource: "*", effect: "ask" }] }),
  });
  assert.equal(asked.status, 200);
  const change = engine.asked.find(entry => entry.method === "PATCH");
  assert.ok(change, "the engine was asked to change the session");
  assert.deepEqual(change.body.permissions, [{ action: "edit", resource: "*", effect: "ask" }]);
});

test("a picture sent with a message stays in the conversation", () => {
  // The message is delivered: the picture that came with it is not lost on the way
  // (the file travels with the message, as the Mac's does).
  const transcript = emptyTranscript("ses_1");
  transcript.pending = [{ id: "inbox_1", text: "", files: [{ name: "a.png", mime: "image/png", data: "AAAA" }] }];
  apply(transcript, { type: "session.inbox.delivered", data: { sessionID: "ses_1", inboxID: "inbox_1" } });
  assert.equal(transcript.pending.length, 0, "the message is no longer on its way");
  const entry = transcript.entries.find(item => item.kind === "user");
  assert.ok(entry, "the message is in the conversation");
  assert.equal(entry.files?.length, 1, "the picture is with it");
  assert.equal(entry.files[0].name, "a.png");
});

test("a conversation is written out as Markdown, the Mac's way", () => {
  // ConversationExport.swift:9-69: the title over it, "You" and "Agent" as the speakers,
  // the agent's steps listed together, the blocks a blank line apart.
  const transcript = {
    entries: [
      { kind: "user", text: "What should we do?", files: [{ name: "notes.txt" }] },
      {
        kind: "assistant",
        parts: [
          { type: "tool", name: "read", input: { path: "notes.txt" } },
          { type: "text", text: "We read the notes." },
        ],
      },
    ],
  };
  const markdown = conversationMarkdown("Notes", transcript, { summary: part => `Read ${part.input.path}` });
  assert.equal(
    markdown,
    [
      "# Notes",
      "",
      "**You**",
      "",
      "What should we do?",
      "",
      "Attached: notes.txt",
      "",
      "**Agent**",
      "",
      "- Read notes.txt",
      "",
      "We read the notes.",
      "",
    ].join("\n"),
  );
  // A conversation with nothing in it is still its title.
  assert.equal(conversationMarkdown("New Session", { entries: [] }), "# New Session\n");
});

test("the project's changes are read from git, and a commit is really made", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const { execFileSync } = await import("node:child_process");
  const project = fs.mkdtempSync(path.join(home, "git-project-"));
  const git = (...args) => execFileSync("git", ["-C", project, ...args], { encoding: "utf8" });
  git("init", "-q");
  git("config", "user.email", "kuvo@example.test");
  git("config", "user.name", "Kuvo");
  fs.writeFileSync(path.join(project, "a.txt"), "one\n");
  git("add", "-A");
  git("commit", "-q", "-m", "first");

  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());

  // Nothing changed yet.
  let answer = await (await fetch(`${url}api/changes?directory=${encodeURIComponent(project)}&scope=uncommitted`)).json();
  assert.equal(answer.git, true);
  assert.equal(answer.files.length, 0);

  // A change, and a new file.
  fs.writeFileSync(path.join(project, "a.txt"), "one\ntwo\n");
  fs.writeFileSync(path.join(project, "b.txt"), "new\n");
  answer = await (await fetch(`${url}api/changes?directory=${encodeURIComponent(project)}&scope=uncommitted`)).json();
  const names = answer.files.map(file => file.file).sort();
  assert.deepEqual(names, ["a.txt", "b.txt"]);
  const changed = answer.files.find(file => file.file === "a.txt");
  assert.ok(changed.patch.includes("+two"), "the patch carries the new line");
  assert.equal(changed.additions, 1);

  // A commit, for real.
  const committed = await fetch(`${url}api/changes/commit`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ directory: project, message: "Add a second line" }),
  });
  assert.equal(committed.status, 200);
  const result = await committed.json();
  assert.equal(result.ok, true);
  assert.equal(git("log", "-1", "--pretty=%s").trim(), "Add a second line");

  // And the panel is empty again.
  answer = await (await fetch(`${url}api/changes?directory=${encodeURIComponent(project)}&scope=uncommitted`)).json();
  assert.equal(answer.files.length, 0);
});

test("the branch scope shows what the branch added since it left its base", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const { execFileSync } = await import("node:child_process");
  const project = fs.mkdtempSync(path.join(home, "git-branch-"));
  const git = (...args) => execFileSync("git", ["-C", project, ...args], { encoding: "utf8" });
  git("init", "-q", "-b", "main");
  git("config", "user.email", "kuvo@example.test");
  git("config", "user.name", "Kuvo");
  fs.writeFileSync(path.join(project, "a.txt"), "one\n");
  git("add", "-A");
  git("commit", "-q", "-m", "first");

  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());

  // A branch that adds a file, and the base that moves on without it.
  git("checkout", "-q", "-b", "feature");
  fs.writeFileSync(path.join(project, "b.txt"), "on the branch\n");
  git("add", "-A");
  git("commit", "-q", "-m", "add b");
  git("checkout", "-q", "main");
  fs.writeFileSync(path.join(project, "c.txt"), "on main\n");
  git("add", "-A");
  git("commit", "-q", "-m", "add c");
  git("checkout", "-q", "feature");

  const answer = await (await fetch(`${url}api/changes?directory=${encodeURIComponent(project)}&scope=branch`)).json();
  assert.equal(answer.git, true);
  assert.equal(answer.base, "main");
  assert.equal(answer.branch, "feature");
  // What the branch added since it left main: b.txt — not c.txt, which is main's own work.
  const names = answer.files.map(file => file.file);
  assert.ok(names.includes("b.txt"), "the branch's own file is there");
  assert.ok(!names.includes("c.txt"), "the base's work is not");

  // Uncommitted shows only what is not committed, whatever the branch.
  fs.writeFileSync(path.join(project, "d.txt"), "working\n");
  const uncommitted = await (await fetch(`${url}api/changes?directory=${encodeURIComponent(project)}&scope=uncommitted`)).json();
  assert.ok(uncommitted.files.some(file => file.file === "d.txt"));
});

test("opencode's own settings are read even when they are .jsonc, with comments", async t => {
  const engine = await fakeEngine();
  t.after(engine.close);
  const file = path.join(home, "opencode.jsonc");
  process.env.KUVO_OPENCODE_CONFIG_ROOT = file;
  process.env.KUVO_ENGINE_CONFIG_ROOT = path.join(home, "app-empty", "opencode.json");
  t.after(() => { delete process.env.KUVO_OPENCODE_CONFIG_ROOT; delete process.env.KUVO_ENGINE_CONFIG_ROOT; });
  fs.writeFileSync(file, `{
  // what REA and the CLI write
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "rea": { "type": "local", "command": ["npx", "-y", "rea-agents@6.7.0", "mcp"] },
    },
  },
}`);
  const { harness, url } = await inFront(engine);
  t.after(() => harness.close());

  const config = await (await fetch(`${url}api/config`)).json();
  assert.equal(config.opencode.problem, null, "the file is read, comments and all");
  assert.equal(config.opencode.settings.mcp.servers.rea.command[2], "rea-agents@6.7.0");

  const brought = await (await fetch(`${url}api/config/import`, {
    method: "POST", headers: { "content-type": "application/json" }, body: "{}",
  })).json();
  assert.deepEqual(brought.added, ["mcp:rea"]);
});

test("a session is running while its last words are unfinished, not while a flag says so", async t => {
  const { fromHistory } = await import("./transcript.mjs");
  const finished = fromHistory("ses_1", [
    { id: "msg_1", type: "assistant", time: { created: 1 }, content: [{ type: "text", text: "done", time: { created: 1, completed: 2 } }] },
  ], [], true);
  assert.equal(finished.running, false, "the engine's flag alone does not keep a finished run running");

  const going = fromHistory("ses_1", [
    { id: "msg_1", type: "assistant", time: { created: 1 }, content: [{ type: "text", text: "still", time: { created: 1 } }] },
  ], [], true);
  assert.equal(going.running, true, "unfinished words mean the run is going");

  // The parts can lag behind the message in the engine's history: the message's own
  // state is what counts (Message.isRunning).
  const lagged = fromHistory("ses_1", [
    { id: "msg_1", type: "assistant", time: { created: 1, completed: 2 }, content: [{ type: "text", text: "done", time: { created: 1 } }] },
  ], [], true);
  assert.equal(lagged.running, false, "the message's own completion ends the run, whatever its parts say");

  // And an earlier message that never finished is not a run under way: only the last
  // words are read.
  const earlier = fromHistory("ses_1", [
    { id: "msg_0", type: "assistant", time: { created: 1 }, content: [{ type: "text", text: "cut off", time: { created: 1 } }] },
    { id: "msg_1", type: "assistant", time: { created: 3, completed: 4 }, content: [{ type: "text", text: "done", time: { created: 3, completed: 4 } }] },
  ], [], false);
  assert.equal(earlier.running, false, "the last words are finished, so nothing is running");

  // The engine's own answer counts too (SessionModel.swift:573-587): it says whether the
  // session is among the active ones, and its stored words can lag behind it. A page that
  // loads just after a turn ended must not keep showing that the agent is at work.
  const stored = fromHistory("ses_1", [
    { id: "msg_1", type: "assistant", time: { created: 1 }, content: [{ type: "text", text: "words the engine has not stamped yet", time: { created: 1 } }] },
  ], [], false);
  assert.equal(stored.running, false, "the engine says the session is not active, so the run is over");

  // And a run that has begun but has not written a word yet is the engine's answer alone.
  const beginning = fromHistory("ses_1", [
    { id: "msg_1", type: "assistant", time: { created: 1 }, content: [] },
  ], [], true);
  assert.equal(beginning.running, true, "the engine says the session is active, and no word has ended it");

  // But a message the engine has stamped finished ends the turn on its own: the engine
  // writes a reply's words and its finished state in its own order, and its flag can still
  // call the session active for a moment. Whatever the reply carries — even nothing at
  // all — the Mac's measure reads the message, and the message says the turn ended.
  const emptied = fromHistory("ses_1", [
    { id: "msg_1", type: "assistant", time: { created: 1, completed: 2 }, content: [] },
  ], [], true);
  assert.equal(emptied.running, false, "the engine's own words say the turn ended, whatever its flag still says");
});

test("a call carries its own metadata, in the history and in the events both", async () => {
  const { apply, fromHistory } = await import("./transcript.mjs");

  // What the engine stored with the call: the files it changed. The Mac reads the same
  // field off the same messages (SessionEdits.swift:19-22, ToolCallView.swift:358-366).
  const stored = fromHistory("ses_1", [
    {
      id: "msg_1", type: "assistant", time: { created: 1 },
      content: [{ type: "tool", id: "tool_1", name: "edit", state: { status: "completed", metadata: { files: [{ filePath: "a.ts", additions: 3, deletions: 1 }] } } }],
    },
  ], [], false);
  assert.deepEqual(
    stored.entries[0].parts[0].metadata.files,
    [{ filePath: "a.ts", additions: 3, deletions: 1 }],
    "the stored call brings its metadata with it",
  );

  // And the outcome of a live call carries it too (Transcript.swift:422).
  const live = fromHistory("ses_1", [], [], false);
  apply(live, {
    type: "session.tool.success",
    sessionID: "ses_1",
    created: 2,
    data: { assistantMessageID: "msg_1", id: "tool_1", name: "edit", content: [], metadata: { files: [{ filePath: "a.ts", additions: 7, deletions: 2 }] } },
  });
  assert.equal(live.entries[0].parts[0].metadata.files[0].additions, 7, "the event's metadata reaches the call");
});

// ---- The pane layout: the Mac's PaneLayout, measured (MainView.swift:2112-2179) ----

test("the panes take their ranges, and the conversation keeps its floor", () => {
  // A window with room for everything: the sessions at their default 280, the panel at
  // 420, the split at 560, the conversation the rest — 1700 − 8 − (280 + 8) − (420 + 8) −
  // (560 + 8) = 408, over its floor.
  const roomy = paneLayout({ available: 1700, sessions: 280, changes: 420, split: 560 });
  assert.deepEqual([roomy.sessions, roomy.changes, roomy.split], [280, 420, 560]);
  assert.equal(1700 - 8 - 288 - 428 - 568, 408, "the conversation keeps 408");
  // The Mac's ranges are the ones applied: nothing below 380 or over 1200 can be asked.
  assert.equal(paneLayout({ available: 3000, split: 200 }).split, 380);
  assert.equal(paneLayout({ available: 3000, split: 4000 }).split, 1200);
  assert.equal(paneLayout({ available: 3000, sessions: 100 }).sessions, 220);
  assert.equal(paneLayout({ available: 3000, changes: 5000 }).changes, 900);
});

test("out of room, the split goes first, then the panel, then the sessions", () => {
  // The Mac's measure decides the going by the smallest each pane can be, before anything
  // shrinks (MainView.swift:2134-2148): at 1200 the split still fits at its floor, so it
  // stays and the sessions give the rest — 280 + 8 + 560 + 8 + 380 = 1236.
  const tight = paneLayout({ available: 1200, sessions: 280, split: 560 });
  assert.equal(tight.split, 560, "the split still fits at its floor");
  assert.equal(tight.sessions, 244, "the sessions give what is over");
  // 700 cannot hold the split at 380 beside the conversation's floor: it goes, and the
  // sessions keep their smallest.
  const noSplit = paneLayout({ available: 700, sessions: 280, split: 560 });
  assert.equal(noSplit.split, null, "the split gives way first");
  assert.equal(noSplit.sessions, 280, "and the sessions keep their width, the room being there");
  // With the panel too, 900 leaves room for the sessions only: 220 + 8 + 300 + 8 + 380
  // is over, and the panel goes next.
  const tighter = paneLayout({ available: 900, sessions: 280, changes: 420 });
  assert.equal(tighter.changes, null, "the panel goes next");
  assert.equal(tighter.sessions, 280);
  // 600 cannot hold even the sessions beside the conversation's floor.
  const smallest = paneLayout({ available: 600, sessions: 280 });
  assert.equal(smallest.sessions, null);
  // A pane that went early comes back when a later one's going left room for it: at 1000
  // the split has gone, and the panel fits beside the sessions — shrunk to the room left.
  const back = paneLayout({ available: 1000, sessions: 280, changes: 420, split: 560 });
  assert.deepEqual([back.sessions, back.changes, back.split], [280, 324, null]);
});

test("the rest shrink as far as they must, the panel first and the split last", () => {
  // 1650: 14 over the room the conversation needs. The panel gives the 14, not the
  // conversation and not the split.
  const shrunk = paneLayout({ available: 1650, sessions: 280, changes: 420, split: 560 });
  assert.deepEqual([shrunk.sessions, shrunk.changes, shrunk.split], [280, 406, 560]);
  // 1200: the sessions shrink, and the split keeps its floor: 244 + 8 + 560 + 8 + 380.
  const sessions = paneLayout({ available: 1200, sessions: 280, split: 560 });
  assert.equal(sessions.sessions, 244);
  // 1150: the sessions are at their floor, so the split gives the rest — 534, not 560.
  const split = paneLayout({ available: 1150, sessions: 280, split: 560 });
  assert.equal(split.sessions, 220);
  assert.equal(split.split, 534, "the split shrinks last");
  // 1300: the panel could shrink 4, but the smallest passage is still over — the split
  // goes instead, and the panel keeps its width.
  const dropped = paneLayout({ available: 1300, sessions: 280, changes: 420, split: 380 });
  assert.deepEqual([dropped.sessions, dropped.changes, dropped.split], [280, 420, null]);
});

test("each pane knows how wide it may be dragged right now", () => {
  const layout = paneLayout({ available: 1700, sessions: 280, changes: 420, split: 560 });
  // room 1320; the others take what they take, gap by gap.
  assert.equal(layout.sessionsMax, 316);
  assert.equal(layout.changesMax, 456);
  assert.equal(layout.splitMax, 596);
  // A pane that is not on screen has no room to grow into either.
  const hidden = paneLayout({ available: 1700, sessions: 280, split: 560 });
  assert.equal(hidden.changesMax, 456, "an opened panel still leaves the others their room");
  const roomy = paneLayout({ available: 3000, sessions: 280, split: 560 });
  assert.equal(roomy.changesMax, 900, "at a roomy window the panel opens at its full width");
});
