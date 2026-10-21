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
          const beside = await page.locator("#split-entries").textContent().catch(() => "");
          assert.fail(
            `timed out waiting for ${what}; the view shows:\n${(shown ?? "").slice(0, 500)}`
            + (beside ? `\nthe split shows:\n${beside.slice(0, 500)}` : "")
            + `\nthe page said:\n${errors.join("\n")}`,
          );
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

  // The conversation at rest, before a word is said in it: the Mac's own question about
  // the folder the session works in, with its mark over it (TranscriptView.swift:69-75).
  await page.seen("the empty conversation to ask", ([folder]) => {
    const node = document.querySelector(".empty-conversation p");
    const mark = document.querySelector(".empty-conversation svg");
    return Boolean(mark) && Boolean(node?.textContent?.includes(folder));
  }, [path.basename(project)], 30_000);

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
  // With words in it, the conversation's question has stepped aside.
  await page.seen("the question to step aside", () => document.querySelector(".empty-conversation") === null, null, 10_000);

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
  // The reloaded page draws its list a moment after it opens: wait for the row before
  // reading its id, or the id is read from a page that has not drawn yet.
  await reloaded.seen("the session to be listed", () => Boolean(document.querySelector("#sessions li .session")?.getAttribute("data-id")), null, 30_000);
  const reloadedId = await reloaded.page.evaluate(() => document.querySelector("#sessions li .session")?.getAttribute("data-id") ?? "");
  await reloaded.seen("the stored conversation to read back", ([id, text]) => {
    const node = document.getElementById(id);
    return Boolean(node?.textContent?.match(new RegExp(text, "i")));
  }, ["entries", "hello from the page"], 60_000);
  assert.equal(await reloaded.element("project").textContent(), project, "the project is remembered");
  assert.equal(await reloaded.page.locator("#sessions li").count(), 1, "the session is listed again");
  // The engine can still call a session active for a moment after a turn; the page reads that
  // the same way the Mac app does, and settles as soon as there's nothing to stop.
  // Nothing to be running: the app reads the engine's own words, and the engine writes
  // them a moment after the turn ends — the Mac waits the same way. If the engine's
  // history still has the message unfinished, that is the engine's lag, not the app's.
  const stillRunning = await reloaded.seen("nothing to be running", () => document.getElementById("stop")?.hidden, null, 90_000)
    .then(() => false)
    .catch(() => true);
  if (stillRunning) {
    const detail = await (await fetch(`${url}api/sessions/${encodeURIComponent(reloadedId)}`)).json();
    const messages = detail.messages ?? [];
    const last = messages.filter(message => message.type === "assistant").at(-1);
    if (last?.time?.completed) {
      // The engine says the turn ended: this page read its words a moment before the
      // engine had written them, and no event will come now to say otherwise. Reading
      // them again must agree with what a page shows — a fresh read is the same test the
      // first reload ran, and it must come out settled.
      await reloaded.page.reload({ waitUntil: "domcontentloaded" });
      await reloaded.seen("the stored conversation to read back", ([id, text]) => {
        const node = document.getElementById(id);
        return Boolean(node?.textContent?.match(new RegExp(text, "i")));
      }, ["entries", "hello from the page"], 60_000);
      await reloaded.seen("the settled run to stay settled", () => document.getElementById("stop")?.hidden, null, 60_000);
    }
    // Otherwise the engine's own history still has the message unfinished: that is the
    // engine's lag, not the app's, and the Mac waits the same way.
  }

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

  // The window remembers: the row at the top can be put away, and stays away
  // (TabBar.showsKey, GeneralSettings.swift:23).
  await page.element("settings-open").click();
  await pressNav("general");
  const tabBar = page.page.locator('.settings-page[data-section="general"] input[type="checkbox"]').first();
  await tabBar.uncheck();
  await page.element("settings-back").click();
  await page.seen("the row at the top to go", () => document.querySelector("header.titlebar")?.classList.contains("no-tab-bar") === true, null, 10_000);
  const remembered = await open();
  await remembered.seen("the row at the top to stay away", () => document.querySelector("header.titlebar")?.classList.contains("no-tab-bar") === true, null, 10_000);
  await remembered.page.close();
  // And it comes back when the user says so.
  await page.element("settings-open").click();
  await pressNav("general");
  await page.page.locator('.settings-page[data-section="general"] input[type="checkbox"]').first().check();
  await page.element("settings-back").click();
  await page.seen("the row at the top to come back", () => document.querySelector("header.titlebar")?.classList.contains("no-tab-bar") === false, null, 10_000);

  // The find: it is invoked, and it is the Mac's bar over the conversation.
  await page.page.keyboard.press("Control+f");
  await page.seen("the find bar to open", () => Boolean(document.getElementById("find-bar")), null, 10_000);
  await page.page.locator("#find").fill("hello");
  await page.seen("the find to count what it found", () => {
    const count = document.getElementById("find-bar")?.querySelector(".find-count")?.textContent ?? "";
    return /\d+ \/ \d+ result/.test(count);
  }, null, 10_000);
  await page.page.keyboard.press("Escape");
  await page.seen("the find bar to close", () => !document.getElementById("find-bar"), null, 10_000);

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

  // The split: another session beside this one, as the Mac draws it — a card with the same
  // header the conversation has (its session's name, Swap, Close), the session's own rows
  // read into it, and no strip of controls that could pass for the title bar.
  // The session beside this one, by its id: the engine may rename a session at any time,
  // so the test names the row it means rather than the words it showed a moment ago.
  const firstId = await page.page.locator("#sessions li button.session").first().getAttribute("data-id");
  assert.ok(firstId, "the first session has an id to name it by");
  await page.element("new-session").click();
  await page.seen("the second session to be listed", () => document.querySelectorAll("#sessions li").length === 2, null, 30_000);
  // The new session is the one in view before the split is asked for: Open Beside opens
  // the session beside the one in view, and "beside" is only known once it is (and a
  // Windows runner does not race the panel's own timing). The title cannot say so: the
  // engine names both sessions "New Session" until it writes a name, so the empty
  // conversation — the session with no words in it — is what tells them apart.
  await page.seen("the new session to be in view", () => Boolean(document.querySelector("#conversation .empty-conversation")), null, 30_000);
  await page.element("split").click();
  await page.seen("the split card to open", () => {
    const pane = document.getElementById("split-pane");
    return Boolean(pane) && pane.hidden === false && Boolean(pane.querySelector(".card-header"));
  }, null, 30_000);
  assert.equal(await page.page.locator("#split-pane .split-head").count(), 0, "the split has no strip of its own");
  await page.seen("its head to name the session beside this one", ([id]) => {
    const row = document.querySelector(`#sessions li button.session[data-id="${id}"] .session-title`);
    const head = document.querySelector("#split-pane .card-title > span:first-child");
    return Boolean(row?.textContent) && head?.textContent === row?.textContent;
  }, [firstId], 30_000);
  await page.seen("the session beside this one to read back", ([id, text]) => {
    const node = document.getElementById(id);
    return Boolean(node?.textContent?.match(new RegExp(text, "i")));
  }, ["split-entries", "hello from the page"], 30_000);
  assert.equal(await page.page.locator("#split-swap").count(), 1, "Swap sits in its header");
  await page.element("split-swap").click();
  // The words are the ones that say which session went where: the titles can both read
  // "New Session", and then a title says nothing.
  await page.seen("the two to change places", () => {
    const main = document.getElementById("entries")?.textContent ?? "";
    return /hello from the page/i.test(main);
  }, null, 10_000);
  await page.seen("the empty session's own question beside", () => Boolean(document.querySelector("#split-pane .empty-conversation p")), null, 10_000);
  // The window has no room for all of them: the split gives way first, and comes back
  // when the room does (PaneLayout, MainView.swift:2112-2179).
  await page.page.setViewportSize({ width: 900, height: 720 });
  await page.seen("the split to give way when the window has no room", () => document.getElementById("split-pane")?.hidden === true, null, 10_000);
  await page.page.setViewportSize({ width: 1280, height: 720 });
  await page.seen("the split to come back when the room does", () => document.getElementById("split-pane")?.hidden === false, null, 10_000);
  await page.element("split-close").click();
  await page.seen("the split card to close", () => document.getElementById("split-pane")?.hidden === true, null, 10_000);

  // The session's own menu: the Mac's, in its order (SidebarView.swift:600-643), and the
  // pin that keeps a session at the top of the sidebar.
  const other = page.page.locator("#sessions li:not(.current) button.session").first();
  await other.click({ button: "right" });
  await page.seen("the session's menu to open", () => document.querySelector(".context-menu") !== null, null, 10_000);
  assert.deepEqual(
    (await page.page.locator(".context-menu [role='menuitem']").allTextContents()).map(text => text.trim()),
    ["Pin", "Open Beside", "Rename…", "Show in Folder", "Copy as Markdown", "Export as Markdown…", "Archive", "Delete…"],
    "the menu is the Mac's, in its order",
  );
  await page.page.locator(".context-menu [role='menuitem']", { hasText: "Pin" }).click();
  await page.seen("the pinned session to sit at the top of the sidebar", () => {
    const section = [...document.querySelectorAll(".section-title")].find(node => node.textContent?.trim() === "Pinned");
    return Boolean(section) && Boolean(document.querySelector(".sessions.pinned li"));
  }, null, 10_000);

  // The tab's own menu: the Mac's, in its order (TitleBar.swift:214-231). The tab in view
  // has no "Open Beside" — the Mac offers it for the tabs beside the one in view only.
  await page.page.locator(".tab-track [role='tab']:not([aria-selected='true'])").first().click({ button: "right" });
  await page.seen("the tab's menu to open", () => document.querySelector(".context-menu") !== null, null, 10_000);
  assert.deepEqual(
    (await page.page.locator(".context-menu [role='menuitem']").allTextContents()).map(text => text.trim()),
    ["Open Beside", "Rename…", "Close Tab", "Close Other Tabs", "Close All Tabs"],
    "the tab's menu is the Mac's, in its order",
  );

  // The mode menu: the Mac's, with the tool permissions in it (ComposerMenus.swift:120-135).
  await page.element("agent").click();
  await page.seen("the mode menu to open", () => document.querySelectorAll(".choice-panel .choice-item").length > 0, null, 10_000);
  const modeItems = (await page.page.locator(".choice-panel .choice-item").allTextContents()).map(text => text.trim());
  assert.ok(modeItems.some(text => text.includes("Approve All")), "the menu offers Approve All");
  assert.ok(modeItems.some(text => text.includes("Ask First")), "the menu offers Ask First");
  assert.ok(modeItems.some(text => text.includes("Runs tools without asking")), "with the Mac's own words");
  assert.ok(modeItems.some(text => text.includes("Asks before editing files or running commands")), "and the other one's too");
  await page.page.keyboard.press("Escape");

  // The image viewer: the picture opens over the window, and the window under it dims with
  // it (ImageViewer.swift:33-41). A page of its own: a model that will not look at a
  // picture is the engine's mood, not this client's business.
  const viewer = await open();
  const picture = path.join(project, "a-picture.png");
  fs.writeFileSync(picture, Buffer.from(
    // A picture of eight by eight pixels: the engine decodes what comes with a message,
    // and a broken one is refused whole.
    "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGO4Y2ODFTEMLQkAXrdVAdmuFfUAAAAASUVORK5CYII=",
    "base64",
  ));
  // The page is open and the app is awake: the composer is there to be given a file.
  await viewer.seen("the sessions to be listed", () => document.querySelectorAll("#sessions li").length > 0, null, 30_000);
  await viewer.page.setInputFiles("#attach-input", picture);
  await viewer.seen("the attachment to be picked", () => document.querySelectorAll("#attachments .attachment-chip").length > 0, null, 10_000);
  await viewer.element("composer").evaluate(form => form.requestSubmit());
  await viewer.seen("the picture to show in the conversation", () => document.querySelector("#entries .attachment-image") !== null, null, 30_000);
  await viewer.page.locator("#entries .attachment-image").click();
  await viewer.seen("the picture to open over the window", () => document.querySelector(".image-viewer") !== null, null, 10_000);
  await viewer.seen("the window under it to dim", () => {
    const header = document.querySelector("header.titlebar");
    return document.body.classList.contains("viewing-image") && Number(getComputedStyle(header).opacity) < 0.5;
  }, null, 10_000);
  await viewer.page.keyboard.press("Escape");
  await viewer.seen("the picture to go away", () => document.querySelector(".image-viewer") === null, null, 10_000);

  // Nothing in the page complained.
  assert.deepEqual([...page.errors, ...reloaded.errors, ...reread.errors], [], "the page had nothing to complain about");

  // Leave the engine as we found it (the hook above closes the pages and the harness).
});
