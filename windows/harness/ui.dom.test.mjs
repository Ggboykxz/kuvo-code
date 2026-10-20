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

  // The page as a browser takes it: the built one (React and TypeScript) when there is
  // one, the hand-written page otherwise. The built page is one bundle, so it is inlined
  // the way the browser would fetch it.
  const built = path.join(here, "ui-build", "index.html");
  const usingBuild = fs.existsSync(built);
  let html;
  let reducer = "";
  let app = "";
  if (usingBuild) {
    const bundle = fs.readFileSync(path.join(here, "ui-build", "app.js"), "utf8");
    // A function, not a string: the bundle is full of `$` and would be read as a pattern.
    html = fs.readFileSync(built, "utf8").replace(/<script[^>]*src="\/app\.js"[^>]*><\/script>/, () => `<script>${bundle}</script>`);
  } else {
    html = fs.readFileSync(path.join(here, "ui/index.html"), "utf8");
    reducer = fs.readFileSync(path.join(here, "transcript.mjs"), "utf8").replace(/^export /gm, "");
    app = fs.readFileSync(path.join(here, "ui/app.js"), "utf8").replace(/^import .*$/m, "");
  }

  // The pages share one storage, the way a browser shares it for an address: a draft
  // written by one is read by the next.
  const held = new Map();
  const storage = {
    getItem: key => (held.has(key) ? held.get(key) : null),
    setItem: (key, value) => { held.set(key, String(value)); },
    removeItem: key => { held.delete(key); },
    clear: () => { held.clear(); },
    key: index => [...held.keys()][index] ?? null,
    get length() { return held.size; },
  };

  /** A page: jsdom with the two browser pieces it lacks, and the page's code run in it. */
  function open() {
    const errors = [];
    const virtualConsole = new VirtualConsole();
    virtualConsole.on("jsdomError", error => errors.push(error.message));
    const dom = new JSDOM(html, { url, runScripts: "dangerously", pretendToBeVisual: true, virtualConsole });
    const { window } = dom;
    Object.defineProperty(window, "localStorage", { configurable: true, value: storage });
    window.fetch = (input, init) => fetch(new URL(input, url), init);
    window.alert = message => errors.push(`alert: ${message}`);
    // jsdom has no matchMedia; the page asks it about the dark mode.
    window.matchMedia = query => ({
      matches: false,
      media: query,
      onchange: null,
      addEventListener() {},
      removeEventListener() {},
      addListener() {},
      removeListener() {},
      dispatchEvent: () => false,
    });
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
  await page.seen("the project to show", () => page.element("project")?.textContent.includes(path.basename(project)), 30_000);
  await page.seen("the engine to come up", () => page.element("engine")?.textContent.includes(VERSION), 120_000);

  // A session, made from the empty state.
  assert.equal(page.element("empty")?.hidden, false, "the empty state shows first");
  page.element("start")?.click();
  await page.seen("the session to appear", () => page.document.querySelectorAll("#sessions li").length === 1, 30_000);

  // The title bar: the Mac's tab strip, with the open session in it, and the project's
  // name over the sessions' width.
  await page.seen("the tab strip to show the session", () => {
    const tab = page.document.querySelector('.tab-track [role="tab"]');
    return Boolean(tab) && tab.classList.contains("active");
  }, 10_000);
  assert.equal(page.document.querySelectorAll('.tab-track [role="tab"]').length, 1, "the open session is one tab");
  assert.ok(page.document.querySelector(".tab-pill"), "the chosen tab carries the raised pill");
  assert.equal(page.document.querySelector(".identity-name")?.textContent, path.basename(project), "the title bar names the project");

  // The panel: a card in the window's row, with the Mac's tab strip.
  page.element("toggle-files")?.click();
  await page.seen("the panel to open", () => page.element("drawer")?.hidden === false, 10_000);
  const drawer = page.element("drawer");
  assert.ok(drawer?.closest("main"), "the panel sits in the window's row, beside the conversation");
  assert.deepEqual([...drawer.querySelectorAll(".drawer-tab")].map(node => node.textContent.trim()), ["Files", "Changes", "Terminal"]);
  page.element("drawer-close")?.click();
  await page.seen("the panel to close", () => page.element("drawer")?.hidden === true, 10_000);

  // The model menu (a call scoped to the project folder, sent as a header).
  await page.seen("the models to load", () => {
    const button = page.element("model");
    if (!button) return false;
    button.click();
    return page.document.querySelectorAll("#model ~ * .choice-item, .choice-panel .choice-item").length > 1;
  }, 30_000);
  page.element("model")?.click();

  // A prompt: sent, shown at once, answered by the model, and answered through events.
  const asked = "Reply with exactly: hello from the page";
  const promptBox = page.element("prompt");
  const setter = Object.getOwnPropertyDescriptor(page.window.HTMLTextAreaElement.prototype, "value").set;
  const ask = async () => {
    setter.call(promptBox, asked);
    promptBox.dispatchEvent(new page.window.Event("input", { bubbles: true }));
    page.element("composer")?.requestSubmit();
  };
  await ask();
  await page.seen("the user's message to show", () => page.element("entries")?.textContent.includes(asked), 30_000);
  // The public model can refuse for a while (a rate limit): the question is asked again,
  // rather than the build failing on the provider's mood.
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const said = page.element("entries")?.textContent ?? "";
    if (/hello from the page/i.test(said)) break;
    if (!/rate limit/i.test(said)) break;
    await wait(20_000);
    await ask();
  }
  await page.seen("the answer to arrive", () => /hello from the page/i.test(page.element("entries")?.textContent), 180_000);
  await page.seen("the turn to end", () => page.element("stop")?.hidden, 60_000);

  // The folder picker: it opens on the project, walks, and closes without changing it.
  page.element("project")?.click();
  await page.seen("the picker to fill", () => page.element("picker-path")?.value === project, 15_000);
  assert.equal(page.element("picker-path")?.value, project, "the picker opens on the project");
  assert.deepEqual([...page.document.querySelectorAll("#picker-folders button")].map(node => node.textContent.trim()), ["sub/"], "the folder's insides are listed");
  page.element("picker-close")?.click();
  // React draws on its own turn of the loop, so the closing is waited for.
  await page.seen("the picker to close", () => page.element("picker")?.hidden === true, 10_000);

  // A reload: the same conversation, read back from what the engine stored.
  const reloaded = open();
  await reloaded.seen("the stored conversation to read back", () => /hello from the page/i.test(reloaded.element("entries")?.textContent), 60_000);
  assert.equal(reloaded.element("project")?.textContent, project, "the project is remembered");
  assert.equal(reloaded.document.querySelectorAll("#sessions li").length, 1, "the session is listed again");
  // The engine can still call a session active for a moment after a turn; the page reads that
  // the same way the Mac app does, and settles as soon as there's nothing to stop.
  // The engine can still call a session active for a moment after the turn ends; the page
  // reads that the way the Mac app does, and settles as soon as there's nothing to stop.
  await reloaded.seen("nothing to be running", () => reloaded.element("stop")?.hidden, 45_000);

  // The built page carries what it needs: the formulas (KaTeX and its fonts) travel with it.
  if (usingBuild) {
    const bundle = fs.readFileSync(path.join(here, "ui-build", "app.js"), "utf8");
    assert.match(bundle, /katex/i, "the page brings the formula renderer");
    const fonts = fs.readdirSync(path.join(here, "ui-build")).filter(name => name.endsWith(".woff2"));
    assert.ok(fonts.length > 0, "the formula renderer's fonts travel with the page");
  }

  // The settings: the navigation holds only buttons, and every page it can open is a page
  // of the settings itself. (A page once slipped inside the navigation and broke them all.)
  const nav = page.document.querySelector(".settings-nav");
  const pages = page.document.querySelector(".settings-pages");
  assert.ok(nav, "the settings have a navigation");
  assert.ok(pages, "the settings have their pages");
  // The Mac's shape: the settings take the sessions' place — a sidebar on the glass, and
  // the open page in a card beside it.
  assert.ok(page.document.querySelector(".settings-sidebar"), "the settings have their own sidebar");
  assert.ok(page.document.querySelector(".settings-content.card"), "the open page is in a card");
  assert.match(page.document.querySelector(".settings-content-head h1")?.textContent ?? "", /Appearance|General/);
  assert.equal(nav.querySelectorAll(".settings-page").length, 0, "no page sits inside the navigation");
  assert.equal([...page.document.querySelectorAll(".settings-page")].filter(node => !node.closest(".settings-pages")).length, 0, "every page belongs to the settings");
  for (const button of nav.querySelectorAll("button")) {
    const wanted = button.dataset.section;
    assert.ok([...pages.querySelectorAll(".settings-page")].some(node => node.dataset.section === wanted),
      `the navigation's "${wanted}" has a page behind it`);
  }

  // The keyboard page: the recorder writes the keys down, they are kept in the app's own
  // settings, and the app answers to them.
  page.element("settings-open")?.click();
  await page.seen("the settings to open", () => page.document.querySelector('.settings-nav button[data-section="keyboard"]') !== null, 10_000);
  page.document.querySelector('.settings-nav button[data-section="keyboard"]').click();
  const keyboardPage = () => page.document.querySelector('.settings-page[data-section="keyboard"]');
  const chip = (text) => [...keyboardPage().querySelectorAll(".keycap-button")].find(node => node.textContent.trim() === text);
  const paletteRow = () => [...keyboardPage().querySelectorAll(".settings-row")]
    .find(row => row.querySelector("span")?.textContent === "Command palette");
  await page.seen("the keyboard page to show", () => keyboardPage() && !keyboardPage().hidden && keyboardPage().textContent.includes("Command palette"), 10_000);
  // The app's own keys first: a shortcut recorded by an earlier run is cleared, the way a
  // user clears it.
  const clear = () => paletteRow()?.querySelector(".keycap-clear");
  if (clear()) {
    clear().click();
    await page.seen("the keys to go back to the app's own", () => chip("Ctrl+K") !== undefined, 10_000);
  }
  assert.ok(chip("Ctrl+K"), "the palette's keys are the app's own");
  chip("Ctrl+K").click();
  await page.seen("the recorder to listen", () => keyboardPage().querySelector(".keycap-button.recording") !== null, 10_000);
  // The press: a chord with a real modifier, the way the Mac's recorder takes it.
  page.document.body.dispatchEvent(new page.window.KeyboardEvent("keydown", { key: "p", ctrlKey: true, altKey: true, bubbles: true }));
  await page.seen("the keys to be written down", () => chip("Ctrl+Alt+P") !== undefined, 10_000);
  // The keys are kept in the app's own settings.
  const settings = await (await fetch(`${url}api/config`)).json();
  assert.equal(settings.settings?.shortcuts?.palette, "Ctrl+Alt+P", "the settings hold the recorded keys");
  // And the app answers to them: the palette opens on the new keys, not on the old ones.
  page.document.body.dispatchEvent(new page.window.KeyboardEvent("keydown", { key: "p", ctrlKey: true, altKey: true, bubbles: true }));
  await page.seen("the palette to open on the recorded keys", () => page.element("palette")?.hidden === false, 10_000);
  page.document.body.dispatchEvent(new page.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  await page.seen("the palette to close", () => page.element("palette")?.hidden === true, 10_000);
  page.document.body.dispatchEvent(new page.window.KeyboardEvent("keydown", { key: "k", ctrlKey: true, bubbles: true }));
  await wait(400);
  assert.equal(page.element("palette")?.hidden, true, "the old keys do not answer any more");
  // And the shortcut can be cleared: the app's own keys are back.
  assert.ok(clear(), "the recorded keys can be cleared");
  clear().click();
  await page.seen("the keys to go back to the app's own", () => chip("Ctrl+K") !== undefined, 10_000);

  // The usage page: what the agent spent, read from the engine's own sessions.
  page.document.querySelector('.settings-nav button[data-section="usage"]').click();
  await page.seen("the usage page to show", () => {
    const section = page.document.querySelector('.settings-page[data-section="usage"]');
    return section !== null && !section.hidden && section.textContent.includes("What the agent has spent");
  }, 10_000);
  const usage = page.document.querySelector('.settings-page[data-section="usage"]');
  assert.match(usage.textContent, /\$\d+\.\d{4}/, "the usage page shows what the agent spent");
  // And the way back is in the title bar, as it is on the Mac.
  page.element("settings-back")?.click();
  await page.seen("the settings to close", () => page.element("settings-modal")?.hidden === true, 10_000);

  // The palette: it finds things, and it shows the keys that do the things.
  page.document.body.dispatchEvent(new page.window.KeyboardEvent("keydown", { key: "k", ctrlKey: true, bubbles: true }));
  await page.seen("the palette to open", () => page.element("palette")?.hidden === false, 10_000);
  const paletteRows = [...page.document.querySelectorAll("#palette-list .palette-item")];
  const newSessionRow = paletteRows.find(row => row.textContent.includes("New session"));
  assert.ok(newSessionRow, "the palette offers a new session");
  assert.match(newSessionRow.textContent, /Ctrl\+N/, "the palette shows the keys that do it");
  // The Mac's sections: the recent sessions, and the actions.
  const sections = [...page.document.querySelectorAll("#palette-list .palette-title")].map(node => node.textContent.trim());
  assert.ok(sections.includes("Recent Sessions"), "the palette opens with the recent sessions");
  assert.ok(sections.includes("Actions"), "and with the actions");
  page.document.body.dispatchEvent(new page.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  await page.seen("the palette to close", () => page.element("palette")?.hidden === true, 10_000);

  // The draft: what is typed but not sent is kept, per session, across a reload.
  const draftBox = page.element("prompt");
  const draftSetter = Object.getOwnPropertyDescriptor(page.window.HTMLTextAreaElement.prototype, "value").set;
  draftSetter.call(draftBox, "a half-written thought");
  draftBox.dispatchEvent(new page.window.Event("input", { bubbles: true }));
  await wait(900); // the draft is written down after a pause, the Mac's way
  const drafted = open();
  await drafted.seen("the draft to come back", () => drafted.element("prompt")?.value === "a half-written thought", 30_000);
  drafted.window.close();

  assert.deepEqual([...page.errors, ...reloaded.errors], [], "the page had nothing to complain about");

  // Leave the engine as we found it (the hook above closes the pages and the harness).
  const session = page.document.querySelector("#sessions li .session")?.dataset?.id;
  if (session) await fetch(`${url}api/sessions/${encodeURIComponent(session)}`, { method: "DELETE" }).catch(() => {});
});
