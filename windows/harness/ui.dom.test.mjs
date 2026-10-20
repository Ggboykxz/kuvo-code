// The page's own code — the built app, served by the harness — run in a real browser
// against the live harness and the real engine: boot, a session, a prompt, the answer
// streaming into the view, the folder picker, and a reload reading the stored
// conversation back.
//
//   npm install                              (once, for playwright and its browser)
//   KUVO_HARNESS_LIVE=1 npm run test:live
//
// Off by default, like live.test.mjs: it starts the engine and asks a public free model.
//
// The browser is the point: the page is what a user sees, so it is read there, and the
// checks below are the ones the Mac app's own behaviour would be measured against.

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

let chromium = null;
try {
  ({ chromium } = await import("playwright"));
} catch {
  // Left null: the test says how to get it.
}

const wait = ms => new Promise(resolve => setTimeout(resolve, ms));

test("the page, in a browser, against the real engine", {
  skip: !live
    ? "set KUVO_HARNESS_LIVE=1 to run the page against the engine"
    : chromium === null ? "playwright isn't installed: run `npm install` in windows/harness" : false,
  timeout: 300_000,
}, async t => {
  const project = fs.mkdtempSync(path.join(os.tmpdir(), "kuvo-page-"));
  fs.writeFileSync(path.join(project, "notes.txt"), "Shopping list\n- coffee\n- oats\n");
  fs.mkdirSync(path.join(project, "sub"));

  /** The harness is the page's own server; these are the calls the page makes. */
  const harness = startHarness({ project, port: 0, log: message => t.diagnostic(message) });
  const opened = [];
  // Letting go of the pages is what lets this process end: a page keeps its timers, and
  // the browser's own processes would keep them too.
  t.after(async () => {
    for (const page of opened) await page.close().catch(() => {});
    await harness.close();
    fs.rmSync(project, { recursive: true, force: true });
  });
  const url = await harness.url();

  // The browser is Playwright's own, unless a machine names another (KUVO_CHROME).
  const browser = await chromium.launch({
    executablePath: process.env.KUVO_CHROME || undefined,
    args: ["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage", "--font-render-hinting=none"],
  });
  t.after(async () => { await browser.close(); });

  // One context: the pages share the storage, the way a browser shares it for an address:
  // a draft written by one is read by the next.
  const context = await browser.newContext();
  // The first-run notice is acknowledged before the page opens: it would stand over the
  // window's buttons, and it is not what this test is about.
  await context.addInitScript(() => { localStorage.setItem("kuvo-analytics-ack", "1"); });

  /** A page, and the ways the checks read it. */
  const open = async () => {
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(String(error)));
    page.on("crash", () => errors.push("the page crashed"));
    page.on("console", message => { if (message.type() === "error") errors.push(message.text()); });
    await page.goto(url, { waitUntil: "domcontentloaded" });
    const view = {
      page,
      errors,
      element: id => page.locator(`#${id}`),
      /** Wait for something to be true in the page; the check runs in the browser. */
      seen: async (what, check, argument = null, timeout = 120_000) => {
        try {
          await page.waitForFunction(check, argument, { timeout });
        } catch {
          const shown = await page.locator("#entries").textContent().catch(() => "");
          assert.fail(`timed out waiting for ${what}; the view shows:\n${(shown ?? "").slice(0, 500)}\nthe page said:\n${errors.join("\n")}`);
        }
      },
    };
    opened.push(page);
    return view;
  };

  const page = await open();

  // Boot: the folder it was started on, and the engine coming up behind it.
  await page.seen("the project to show", ([id, name]) => {
    const node = document.getElementById(id);
    return Boolean(node?.textContent?.includes(name));
  }, ["project", path.basename(project)], 30_000);
  await page.seen("the engine to come up", ([id, version]) => {
    const node = document.getElementById(id);
    return Boolean(node?.textContent?.includes(version));
  }, ["engine", VERSION], 120_000);

  // A session, made from the empty state.
  assert.equal(await page.element("empty").isVisible(), true, "the empty state shows first");
  await page.element("start").click();
  await page.seen("the session to appear", () => document.querySelectorAll("#sessions li").length === 1, null, 30_000);

  // The title bar: the Mac's tab strip, with the open session in it, and the project's
  // name over the sessions' width.
  await page.seen("the tab strip to show the session", () => {
    const tab = document.querySelector('.tab-track [role="tab"]');
    return Boolean(tab) && tab.classList.contains("active");
  }, null, 10_000);
  assert.equal(await page.page.locator('.tab-track [role="tab"]').count(), 1, "the open session is one tab");
  assert.ok(await page.page.locator(".tab-pill").count(), "the chosen tab carries the raised pill");
  assert.equal(await page.page.locator(".identity-name").textContent(), path.basename(project), "the title bar names the project");

  // The panel: a card in the window's row, with the Mac's tab strip.
  await page.element("toggle-files").click();
  await page.seen("the panel to open", () => document.getElementById("drawer")?.hidden === false, null, 10_000);
  assert.ok(await page.page.locator("#drawer").evaluate(node => Boolean(node.closest("main"))), "the panel sits in the window's row, beside the conversation");
  assert.deepEqual(
    (await page.page.locator(".drawer-tab").allTextContents()).map(text => text.trim()),
    ["Files", "Changes", "Terminal"],
    "the panel's tabs are the Mac's",
  );
  await page.element("drawer-close").click();
  await page.seen("the panel to close", () => document.getElementById("drawer")?.hidden === true, null, 10_000);

  // The model menu (a call scoped to the project folder, sent as a header).
  await page.seen("the models to load", () => {
    const button = document.getElementById("model");
    if (!button) return false;
    button.click();
    return document.querySelectorAll("#model ~ * .choice-item, .choice-panel .choice-item").length > 1;
  }, null, 30_000);
  await page.element("model").click();

  // A prompt: sent, shown at once, answered by the model, and answered through events.
  const asked = "Reply with exactly: hello from the page";
  const ask = async () => {
    await page.element("prompt").fill(asked);
    await page.element("composer").evaluate(form => form.requestSubmit());
  };
  await ask();
  await page.seen("the user's message to show", ([id, text]) => {
    const node = document.getElementById(id);
    return Boolean(node?.textContent?.includes(text));
  }, ["entries", asked], 30_000);
  // The public model can refuse for a while (a rate limit): the question is asked again,
  // rather than the build failing on the provider's mood.
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const said = (await page.element("entries").textContent().catch(() => "")) ?? "";
    if (/hello from the page/i.test(said)) break;
    if (!/rate limit/i.test(said)) break;
    await wait(20_000);
    await ask();
  }
  await page.seen("the answer to arrive", ([id, text]) => {
    const node = document.getElementById(id);
    return Boolean(node?.textContent?.match(new RegExp(text, "i")));
  }, ["entries", "hello from the page"], 180_000);
  await page.seen("the turn to end", () => document.getElementById("stop")?.hidden, null, 60_000);

  // The folder picker: it opens on the project, walks, and closes without changing it.
  await page.element("project").click();
  await page.seen("the picker to fill", ([id, folder]) => document.getElementById(id)?.value === folder, ["picker-path", project], 15_000);
  assert.equal(await page.element("picker-path").inputValue(), project, "the picker opens on the project");
  assert.deepEqual((await page.page.locator("#picker-folders button").allTextContents()).map(text => text.trim()), ["sub/"], "the folder's insides are listed");
  await page.element("picker-close").click();
  // React draws on its own turn of the loop, so the closing is waited for.
  await page.seen("the picker to close", () => document.getElementById("picker")?.hidden === true, null, 10_000);

  // A reload: the same conversation, read back from what the engine stored.
  const reloaded = await open();
  await reloaded.seen("the stored conversation to read back", ([id, text]) => {
    const node = document.getElementById(id);
    return Boolean(node?.textContent?.match(new RegExp(text, "i")));
  }, ["entries", "hello from the page"], 60_000);
  assert.equal(await reloaded.element("project").textContent(), project, "the project is remembered");
  assert.equal(await reloaded.page.locator("#sessions li").count(), 1, "the session is listed again");
  // The engine can still call a session active for a moment after a turn; the page reads that
  // the same way the Mac app does, and settles as soon as there's nothing to stop.
  await reloaded.seen("nothing to be running", () => document.getElementById("stop")?.hidden, null, 45_000);

  // The reloaded page is in front now; the first one is taken back, so its buttons are
  // drawn and can be pressed (a page in the background does not animate, and Playwright
  // waits for a button to be still before it presses it).
  await page.page.bringToFront();

  // The built page carries what it needs: the formulas (KaTeX and its fonts) travel with it.
  const built = path.join(here, "ui-build");
  if (fs.existsSync(built)) {
    const files = [];
    const walk = folder => {
      for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
        const entryPath = path.join(folder, entry.name);
        if (entry.isDirectory()) walk(entryPath);
        else files.push(entryPath);
      }
    };
    walk(built);
    const fonts = files.filter(name => name.endsWith(".woff2"));
    assert.ok(fonts.length > 0, "the formula renderer's fonts travel with the page");
    assert.ok(files.some(name => name.endsWith(".css")), "the page brings its stylesheet");
  }

  // The settings: the navigation holds only buttons, and every page it can open is a page
  // of the settings itself. (A page once slipped inside the navigation and broke them all.)
  await page.element("settings-open").click();
  await page.seen("the settings to open", () => document.querySelector('.settings-nav button[data-section="keyboard"]') !== null, null, 10_000);
  const nav = page.page.locator(".settings-nav");
  const pages = page.page.locator(".settings-pages");
  assert.ok(await nav.count(), "the settings have a navigation");
  assert.ok(await pages.count(), "the settings have their pages");
  // The Mac's shape: the settings take the sessions' place — a sidebar on the glass, and
  // the open page in a card beside it.
  assert.ok(await page.page.locator(".settings-sidebar").count(), "the settings have their own sidebar");
  assert.ok(await page.page.locator(".settings-content.card").count(), "the open page is in a card");
  assert.match(await page.page.locator(".settings-content-head h1").textContent(), /Appearance|General/);
  assert.equal(await nav.locator(".settings-page").count(), 0, "no page sits inside the navigation");
  assert.equal(
    await page.page.locator(".settings-page").evaluateAll(nodes => nodes.filter(node => !node.closest(".settings-pages")).length),
    0,
    "every page belongs to the settings",
  );
  // The navigation is pressed in the page itself: the pages below the fold are clipped
  // by the sidebar, and a press that waits for the element to settle would wait for ever.
  const pressNav = async section => {
    const pressed = await page.page.evaluate(name => {
      const button = document.querySelector(`.settings-nav button[data-section="${name}"]`);
      button?.click();
      return Boolean(button);
    }, section);
    assert.ok(pressed, `the navigation's "${section}" is there`);
  };
  const sections = await nav.locator("button").evaluateAll(nodes => nodes.map(node => node.dataset.section));
  for (const wanted of sections) {
    assert.ok(
      await pages.locator(`.settings-page[data-section="${wanted}"]`).count(),
      `the navigation's "${wanted}" has a page behind it`,
    );
  }

  // The keyboard page: the recorder writes the keys down, they are kept in the app's own
  // settings, and the app answers to them.
  await pressNav("keyboard");
  const keyboardPage = page.page.locator('.settings-page[data-section="keyboard"]');
  // The chip with that name: the keycaps hold their names exactly, but the text around
  // them is whitespace, so the names are compared trimmed. The chips are pressed in the
  // page itself: they are replaced every time the page draws, and a press that waits for
  // the element to hold still would wait for ever.
  const pressChip = async text => {
    const pressed = await page.page.evaluate(([section, name]) => {
      const kpage = document.querySelector(`.settings-page[data-section="${section}"]`);
      const button = [...(kpage?.querySelectorAll(".keycap-button") ?? [])]
        .find(node => node.textContent.trim() === name);
      button?.click();
      return Boolean(button);
    }, ["keyboard", text]);
    assert.ok(pressed, `the "${text}" chip is there`);
  };
  const chipNames = () => page.page.evaluate(() => {
    const kpage = document.querySelector('.settings-page[data-section="keyboard"]');
    return [...(kpage?.querySelectorAll(".keycap-button") ?? [])].map(node => node.textContent.trim());
  });
  const clearKeys = async () => {
    const cleared = await page.page.evaluate(() => {
      const kpage = document.querySelector('.settings-page[data-section="keyboard"]');
      const row = [...(kpage?.querySelectorAll(".settings-row") ?? [])]
        .find(node => node.textContent.includes("Command palette"));
      const button = row?.querySelector(".keycap-clear");
      button?.click();
      return Boolean(button);
    });
    assert.ok(cleared, "the recorded keys can be cleared");
  };
  const paletteRow = keyboardPage.locator(".settings-row", { hasText: "Command palette" });
  await page.seen("the keyboard page to show", ([text]) => {
    const node = document.querySelector('.settings-page[data-section="keyboard"]');
    return Boolean(node) && !node.hidden && node.textContent.includes(text);
  }, ["Command palette"], 10_000);
  // The app's own keys first: a shortcut recorded by an earlier run is cleared, the way a
  // user clears it.
  if ((await chipNames()).includes("Ctrl+Alt+P")) {
    await clearKeys();
    await page.seen("the keys to go back to the app's own", () => {
      const buttons = [...document.querySelectorAll('.settings-page[data-section="keyboard"] .keycap-button')];
      return buttons.some(node => node.textContent.trim() === "Ctrl+K");
    }, null, 10_000);
  }
  assert.ok((await chipNames()).includes("Ctrl+K"), "the palette's keys are the app's own");
  await pressChip("Ctrl+K");
  await page.seen("the recorder to listen", () => {
    const buttons = [...document.querySelectorAll('.settings-page[data-section="keyboard"] .keycap-button')];
    return buttons.some(node => node.classList.contains("recording"));
  }, null, 10_000);
  // The press: a chord with a real modifier, the way the Mac's recorder takes it.
  await page.page.keyboard.press("Control+Alt+P");
  await page.seen("the keys to be written down", () => {
    const buttons = [...document.querySelectorAll('.settings-page[data-section="keyboard"] .keycap-button')];
    return buttons.some(node => node.textContent.trim() === "Ctrl+Alt+P");
  }, null, 10_000);
  // The keys are kept in the app's own settings.
  const settings = await (await fetch(`${url}api/config`)).json();
  assert.equal(settings.settings?.shortcuts?.palette, "Ctrl+Alt+P", "the settings hold the recorded keys");
  // And the app answers to them: the palette opens on the new keys, not on the old ones.
  await page.page.keyboard.press("Control+Alt+P");
  await page.seen("the palette to open on the recorded keys", () => document.getElementById("palette")?.hidden === false, null, 10_000);
  await page.page.keyboard.press("Escape");
  await page.seen("the palette to close", () => document.getElementById("palette")?.hidden === true, null, 10_000);
  await page.page.keyboard.press("Control+K");
  await wait(400);
  assert.equal(await page.element("palette").isHidden(), true, "the old keys do not answer any more");
  // And the shortcut can be cleared: the app's own keys are back.
  await clearKeys();
  await page.seen("the keys to go back to the app's own", () => {
    const buttons = [...document.querySelectorAll('.settings-page[data-section="keyboard"] .keycap-button')];
    return buttons.some(node => node.textContent.trim() === "Ctrl+K");
  }, null, 10_000);

  // The usage page: what the agent spent, read from the engine's own sessions.
  await pressNav("usage");
  await page.seen("the usage page to show", () => {
    const node = document.querySelector('.settings-page[data-section="usage"]');
    return node !== null && !node.hidden && node.textContent.includes("What the agent has spent");
  }, null, 10_000);
  const usage = await page.page.locator('.settings-page[data-section="usage"]').textContent();
  assert.match(usage, /\$\d+\.\d{4}/, "the usage page shows what the agent spent");
  // And the way back is in the title bar, as it is on the Mac.
  await page.element("settings-back").click();
  await page.seen("the settings to close", () => document.getElementById("settings-modal")?.hidden === true, null, 10_000);

  // The palette: it finds things, and it shows the keys that do the things.
  await page.page.keyboard.press("Control+K");
  await page.seen("the palette to open", () => document.getElementById("palette")?.hidden === false, null, 10_000);
  const paletteRows = page.page.locator("#palette-list .palette-item");
  const paletteTexts = await paletteRows.allTextContents();
  const newSessionRow = paletteTexts.find(text => text.startsWith("New Session") && /Ctrl\+N/.test(text));
  assert.ok(newSessionRow, "the palette offers a new session, with the keys that do it");
  assert.match(newSessionRow, /Ctrl\+N/, "the palette shows the keys that do it");
  // The Mac's sections: the recent sessions, and the actions.
  const paletteSections = (await page.page.locator("#palette-list .palette-title").allTextContents()).map(text => text.trim());
  assert.ok(paletteSections.includes("Recent Sessions"), "the palette opens with the recent sessions");
  assert.ok(paletteSections.includes("Actions"), "and with the actions");
  await page.page.keyboard.press("Escape");
  await page.seen("the palette to close", () => document.getElementById("palette")?.hidden === true, null, 10_000);

  // The draft: what is typed but not sent is kept, per session, across a reload.
  const draftBox = page.element("prompt");
  await draftBox.fill("a draft that is not sent");
  await wait(700);
  const reread = await open();
  await reread.page.bringToFront();
  await reread.seen("the draft to be kept", ([id, text]) => {
    const node = document.getElementById(id);
    return Boolean(node?.value?.includes(text));
  }, ["prompt", "a draft that is not sent"], 30_000);

  // Nothing in the page complained.
  assert.deepEqual([...page.errors, ...reloaded.errors, ...reread.errors], [], "the page had nothing to complain about");

  // Leave the engine as we found it (the hook above closes the pages and the harness).
});
