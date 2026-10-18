// The page's own code — index.html, app.js, transcript.mjs — run in a DOM against the live
// harness and the real engine: boot, a session, a prompt, the answer streaming into the view,
// the folder picker, and a reload reading the stored conversation back. jsdom is the browser
// here; it has no `EventSource`, so the test brings a small one, fed by the same SSE endpoint
// the page asks for.
//
//   npm install                              (once, for jsdom)
//   KUVO_HARNESS_LIVE=1 npm run test:live
//
// Off by default, like live.test.mjs: it starts the engine and asks a public free model.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { VERSION } from "../releases.mjs";
import { startHarness } from "./server.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const live = process.env.KUVO_HARNESS_LIVE === "1";

let JSDOM = null;
let VirtualConsole = null;
try {
  ({ JSDOM, VirtualConsole } = await import("jsdom"));
} catch {
  // Left null: the test says how to get it.
}

const wait = ms => new Promise(resolve => setTimeout(resolve, ms));

test("the page, in a DOM, against the real engine", {
  skip: !live
    ? "set KUVO_HARNESS_LIVE=1 to run the page against the engine"
    : JSDOM === null ? "jsdom isn't installed: run `npm install` in windows/harness" : false,
  timeout: 300_000,
}, async t => {
  const project = fs.mkdtempSync(path.join(os.tmpdir(), "kuvo-page-"));
  fs.writeFileSync(path.join(project, "notes.txt"), "Shopping list\n- coffee\n- oats\n");
  fs.mkdirSync(path.join(project, "sub"));

  /** The harness is the page's own server; these are the calls the page makes. */
  const harness = startHarness({ project, port: 0, log: message => t.diagnostic(message) });
  const sources = [];
  const opened = [];
  // Letting go of the pages is what lets this process end: a page keeps its timers (this one
  // polls its state), and under jsdom those are the test process's own timers.
  t.after(async () => {
    for (const page of opened) page.window.close();
    sources.forEach(source => source.close());
    await harness.close();
    fs.rmSync(project, { recursive: true, force: true });
  });
  const url = await harness.url();

  // The two scripts the page loads, as a browser would take them: the reducer's exports
  // become plain names, the import becomes nothing.
  const html = fs.readFileSync(path.join(here, "ui/index.html"), "utf8");
  const reducer = fs.readFileSync(path.join(here, "transcript.mjs"), "utf8").replace(/^export /gm, "");
  const app = fs.readFileSync(path.join(here, "ui/app.js"), "utf8").replace(/^import .*$/m, "");

  /** A page: jsdom with the two browser pieces it lacks, and the page's code run in it. */
  function open() {
    const errors = [];
    const virtualConsole = new VirtualConsole();
    virtualConsole.on("jsdomError", error => errors.push(error.message));
    const dom = new JSDOM(html, { url, runScripts: "dangerously", pretendToBeVisual: true, virtualConsole });
    const { window } = dom;
    window.fetch = (input, init) => fetch(new URL(input, url), init);
    window.alert = message => errors.push(`alert: ${message}`);
    window.EventSource = class {
      constructor(address) {
        sources.push(this);
        this.controller = new AbortController();
        this.read(address);
      }
      async read(address) {
        const response = await fetch(new URL(address, url), { signal: this.controller.signal });
        this.onopen?.();
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";
        try {
          while (true) {
            const { value, done } = await reader.read();
            if (done) break;
            buffer += decoder.decode(value, { stream: true });
            let at;
            while ((at = buffer.indexOf("\n\n")) >= 0) {
              const frame = buffer.slice(0, at);
              buffer = buffer.slice(at + 2);
              const data = frame.split("\n").filter(line => line.startsWith("data:")).map(line => line.slice(5).trimStart()).join("\n");
              if (data !== "") this.onmessage?.({ data });
            }
          }
        } catch {}
      }
      close() { this.controller.abort(); }
    };
    window.addEventListener("error", event => errors.push(String(event.error ?? event.message)));
    window.eval(`${reducer}\n${app}`);
    const document = window.document;
    const element = id => document.getElementById(id);
    const seen = async (what, check, timeout = 120_000) => {
      const deadline = Date.now() + timeout;
      while (Date.now() < deadline) {
        if (check()) return;
        await wait(120);
      }
      assert.fail(`timed out waiting for ${what}; the view shows:\n${element("entries")?.textContent?.slice(0, 500) ?? ""}`);
    };
    const page = { window, document, element, seen, errors };
    opened.push(page);
    return page;
  }

  const page = open();

  // Boot: the folder it was started on, and the engine coming up behind it.
  await page.seen("the project to show", () => page.element("project").textContent.includes(path.basename(project)), 30_000);
  await page.seen("the engine to come up", () => page.element("engine").textContent.includes(VERSION), 120_000);

  // A session, made from the empty state.
  assert.equal(page.element("empty").hidden, false, "the empty state shows first");
  page.element("start").click();
  await page.seen("the session to appear", () => page.document.querySelectorAll("#sessions li").length === 1, 30_000);

  // The model list (a call scoped to the project folder, sent as a header).
  await page.seen("the models to load", () => page.element("model").options.length > 1, 30_000);

  // A prompt: sent, shown at once, answered by the model, and answered through events.
  const asked = "Reply with exactly: hello from the page";
  page.element("prompt").value = asked;
  page.element("composer").requestSubmit();
  await page.seen("the user's message to show", () => page.element("entries").textContent.includes(asked), 30_000);
  await page.seen("the answer to arrive", () => /hello from the page/i.test(page.element("entries").textContent));
  await page.seen("the turn to end", () => page.element("stop").hidden, 60_000);

  // The folder picker: it opens on the project, walks, and closes without changing it.
  page.element("project").click();
  await page.seen("the picker to fill", () => page.element("picker-path").value !== "", 15_000);
  assert.equal(page.element("picker-path").value, project, "the picker opens on the project");
  assert.deepEqual([...page.document.querySelectorAll("#picker-folders button")].map(node => node.textContent.trim()), ["sub/"], "the folder's insides are listed");
  page.element("picker-close").click();
  assert.equal(page.element("picker").hidden, true, "the picker closes again");

  // A reload: the same conversation, read back from what the engine stored.
  const reloaded = open();
  await reloaded.seen("the stored conversation to read back", () => /hello from the page/i.test(reloaded.element("entries").textContent), 60_000);
  assert.equal(reloaded.element("project").textContent, project, "the project is remembered");
  assert.equal(reloaded.document.querySelectorAll("#sessions li").length, 1, "the session is listed again");
  // The engine can still call a session active for a moment after a turn; the page reads that
  // the same way the Mac app does, and settles as soon as there's nothing to stop.
  await reloaded.seen("nothing to be running", () => reloaded.element("stop").hidden, 15_000);

  assert.deepEqual([...page.errors, ...reloaded.errors], [], "the page had nothing to complain about");

  // Leave the engine as we found it (the hook above closes the pages and the harness).
  const session = page.document.querySelector("#sessions li .session")?.dataset?.id;
  if (session) await fetch(`${url}api/sessions/${encodeURIComponent(session)}`, { method: "DELETE" }).catch(() => {});
});
