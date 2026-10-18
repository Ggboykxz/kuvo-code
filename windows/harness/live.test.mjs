// The whole loop against the real engine on this machine: the pinned build is installed
// (if it isn't already), started, a session is made in a scratch project, a prompt is sent,
// and what comes back over the event stream is checked against what the engine stored —
// through the same reducer the page uses.
//
//   KUVO_HARNESS_LIVE=1 node --test "windows/harness/live.test.mjs"
//
// Off by default: it downloads the engine on a machine that doesn't have it, asks a public
// free model (the engine's own default, no account needed), and takes a couple of minutes.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { VERSION } from "../releases.mjs";
import { startHarness } from "./server.mjs";
import { apply, emptyTranscript, fromHistory } from "./transcript.mjs";

const live = process.env.KUVO_HARNESS_LIVE === "1";
const minutes = 240_000;

test("a real turn, end to end, on the pinned engine", { skip: live ? false : "set KUVO_HARNESS_LIVE=1 to install the engine and ask a public free model", timeout: minutes + 60_000 }, async t => {
  const project = fs.mkdtempSync(path.join(os.tmpdir(), "kuvo-live-"));
  fs.writeFileSync(path.join(project, "hello.txt"), "hello from a file\n");
  t.after(() => fs.rmSync(project, { recursive: true, force: true }));

  /** The harness is the page's own server; these are the calls the page makes. */
  const harness = startHarness({ project, port: 0, log: message => t.diagnostic(message) });
  t.after(() => harness.close());
  const url = await harness.url();
  const get = async route => {
    const response = await fetch(`${url}${route}`);
    const text = await response.text();
    const data = text === "" ? {} : JSON.parse(text);
    if (!response.ok) throw new Error(`${route}: ${data.error ?? response.status}`);
    return data;
  };
  const post = async (route, body = {}) => {
    const response = await fetch(`${url}${route}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
    const text = await response.text();
    const data = text === "" ? {} : JSON.parse(text);
    if (!response.ok) throw new Error(`${route}: ${data.error ?? response.status}`);
    return data;
  };

  // A session in the scratch project — which is what starts the engine.
  const { session } = await post("api/sessions", {});
  assert.equal(session.location.directory, project, "the session is in the folder we chose");
  const state = await get("api/state");
  assert.equal(state.engine.status, "running", "the engine came up on first need");
  assert.equal(state.engine.version, VERSION, `the pinned engine ${VERSION} is the one running`);
  const listed = await get(`api/sessions?directory=${encodeURIComponent(project)}`);
  assert.ok(listed.sessions.some(entry => entry.id === session.id), "the new session is in the list");

  // Watch the relay the page watches, feeding every event through the reducer.
  const transcript = emptyTranscript(session.id);
  const types = [];
  const controller = new AbortController();
  t.after(() => controller.abort());
  const response = await fetch(`${url}api/events`, { signal: controller.signal });
  assert.equal(response.status, 200);
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let turnEnded = null;
  const reading = (async () => {
    let buffer = "";
    while (turnEnded === null) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let at;
      while ((at = buffer.indexOf("\n\n")) >= 0) {
        const frame = buffer.slice(0, at);
        buffer = buffer.slice(at + 2);
        for (const line of frame.split("\n")) {
          if (!line.startsWith("data: ")) continue;
          const event = JSON.parse(line.slice(6));
          apply(transcript, event);
          if (event.data?.sessionID !== undefined && event.data.sessionID !== session.id) continue;
          types.push(event.type);
          if (event.type === "session.execution.succeeded" || event.type === "session.execution.failed" || event.type === "session.execution.interrupted") {
            turnEnded = event;
          }
        }
      }
    }
  })().catch(error => t.diagnostic(`the relay ended: ${error.message}`));

  const text = "Run the shell tool with `cat hello.txt`, then reply with the file's contents and nothing else.";
  const { id } = await post(`api/sessions/${encodeURIComponent(session.id)}/prompt`, { text });
  assert.match(id, /^msg_/, "the prompt's id is one of ours");

  const deadline = Date.now() + minutes;
  while (turnEnded === null && Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 250));
  }
  controller.abort();
  await reading;
  assert.notEqual(turnEnded, null, `the turn never ended; events seen: ${[...new Set(types)].join(", ")}`);
  assert.notEqual(turnEnded.type, "session.execution.failed", `the model didn't answer here: ${JSON.stringify(turnEnded.data?.error ?? turnEnded.data)}`);
  for (const wanted of ["session.inbox.enqueued", "session.inbox.delivered"]) {
    assert.ok(types.includes(wanted), `the prompt passed through ${wanted}`);
  }
  assert.ok(types.includes("session.text.delta") || types.includes("session.tool.called"), `the turn did something; events seen: ${[...new Set(types)].join(", ")}`);

  // As the page would show it: the user's words, the step's parts, a clean ending.
  assert.equal(transcript.running, false);
  const shown = transcript.entries.find(entry => entry.kind === "user");
  assert.equal(shown?.id, id, "the user's message is the one we sent");
  assert.equal(shown.text, text);
  const assistant = transcript.entries.filter(entry => entry.kind === "assistant").at(-1);
  assert.ok(assistant, "the turn left an assistant message");
  assert.equal(transcript.entries.filter(entry => entry.kind === "idle").at(-1)?.outcome, "succeeded");

  // What the engine stored reads back as what streamed.
  const detail = await get(`api/sessions/${encodeURIComponent(session.id)}`);
  assert.equal(detail.running, false, "nothing is running now");
  const stored = fromHistory(session.id, detail.messages, detail.permissions, detail.running);
  const storedAssistant = stored.entries.filter(entry => entry.kind === "assistant").at(-1);
  const words = entry => entry.parts.filter(part => part.type === "text").map(part => part.text).join("\n").trim();
  assert.equal(storedAssistant.id, assistant.id, "the same message, from the stream and from the store");
  assert.equal(words(storedAssistant), words(assistant), "the same words, from the stream and from the store");

  // And the session can go away again.
  const deleted = await fetch(`${url}api/sessions/${encodeURIComponent(session.id)}`, { method: "DELETE" });
  assert.equal(deleted.status, 200);
  const afterwards = await get(`api/sessions?directory=${encodeURIComponent(project)}`);
  assert.ok(!afterwards.sessions.some(entry => entry.id === session.id), "the session is gone from the list");
});
