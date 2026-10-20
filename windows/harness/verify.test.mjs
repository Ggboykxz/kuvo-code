// The page's own values, measured in the browser, against the Mac's ledger.
//
// The Mac's numbers are in docs/MAC-UI-MAP.md (§2 and §3) and in the Swift they come
// from. This reads the rendered page — the real paddings, radii, colours and sizes — and
// holds them to those numbers, so a change that drifts from the Mac is caught here and
// not in a screenshot six weeks later.
//
//   KUVO_HARNESS_LIVE=1 npm run test:live

import assert from "node:assert/strict";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
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

test("the page's own values, measured against the Mac's", {
  skip: !live
    ? "set KUVO_HARNESS_LIVE=1 to run the page against the engine"
    : chromium === null ? "playwright isn't installed: run `npm install` in windows/harness" : false,
  timeout: 180_000,
}, async t => {
  const harness = startHarness({ project: null, port: 0, log: message => t.diagnostic(message) });
  const url = await harness.url();
  // The browser is Playwright's own, unless a machine names another (KUVO_CHROME).
  const browser = await chromium.launch({
    executablePath: process.env.KUVO_CHROME || undefined,
    args: ["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage"],
  });
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await context.addInitScript(() => { localStorage.setItem("kuvo-analytics-ack", "1"); });
  const page = await context.newPage();
  const problems = [];
  page.on("pageerror", error => problems.push(String(error)));
  t.after(async () => {
    await browser.close();
    await harness.close();
  });
  await page.goto(url, { waitUntil: "domcontentloaded" });
  await wait(2500);

  /// The value of a property, as the browser computes it.
  const style = (selector, property) => page.evaluate(([selector, property]) => {
    const node = document.querySelector(selector);
    if (!node) return null;
    return getComputedStyle(node).getPropertyValue(property).trim();
  }, [selector, property]);

  const box = selector => page.evaluate(selector => {
    const node = document.querySelector(selector);
    if (!node) return null;
    const rect = node.getBoundingClientRect();
    return { width: rect.width, height: rect.height, left: rect.left, top: rect.top };
  }, selector);

  // The card: 14 pt round, with the 38 pt header and the 62 pt fade (Card.swift:52-89).
  assert.equal(await style("#conversation", "border-radius"), "14px", "the card is 14 pt round");
  assert.equal((await box(".card-header"))?.height, 38, "the card's header is 38 pt high");
  assert.equal((await box(".card-fade"))?.height, 62, "the fade under it is 62 pt deep");

  // The window: 8 pt between the panes and at the edges, 20 pt of gutter (Theme.swift:16).
  const gap = await page.evaluate(() => {
    const main = document.querySelector("main");
    if (!main) return null;
    return getComputedStyle(main).gap;
  });
  assert.equal(gap, "8px", "the panes are 8 pt apart");
  const gutter = await style("#entries", "padding-left");
  assert.equal(gutter, "20px", "the transcript keeps 20 pt at the sides");

  // The title bar: the track is 36 pt high with 3 pt of padding, and the tabs 30 pt
  // (TitleBar.swift:98-103, 282). There is a track only when a session is open.
  const track = await box(".tab-track");
  if (track) {
    assert.equal(track.height, 36, "the tab track is 36 pt high");
    assert.equal(await style(".tab-track", "padding-top"), "3px", "with 3 pt of padding");
    assert.equal((await box(".tab"))?.height, 30, "and the tabs 30 pt");
    assert.equal(await style(".tab-track", "border-radius"), "999px", "the track is a capsule");
    assert.equal(await style(".tab-pill", "border-radius"), "999px", "and the pill with it");
  }

  // The sessions: 280 pt wide, 32 pt rows (SidebarView.swift:724).
  assert.equal((await box("aside"))?.width, 280, "the sessions are 280 pt wide");
  const row = await box("#sessions li");
  if (row) assert.equal(row.height, 32, "and their rows 32 pt high");

  // The composer: 14 pt round, opaque (Composer.swift:489-511).
  assert.equal(await style(".composer", "border-radius"), "14px", "the composer is 14 pt round");
  assert.equal(await style(".composer", "backdrop-filter"), "none", "and it is opaque, not glass");

  // The wells: 10 pt round (Surfaces.swift:179-191).
  assert.equal(await style(".sidebar-search", "border-radius"), "10px", "a well is 10 pt round");
  assert.equal(await style(".sidebar-search", "border-bottom-width"), "0px", "and a well has no bezel");

  // The palette: 600 pt wide with an 18 pt corner (CommandPalette.swift:81-111).
  await page.keyboard.press("Control+k");
  await page.waitForTimeout(500);
  assert.equal((await box(".palette-card"))?.width, 600, "the palette is 600 pt wide");
  assert.equal(await style(".palette-card", "border-radius"), "18px", "with an 18 pt corner");
  assert.equal((await box(".palette-search"))?.height, 48, "and a 48 pt search");
  assert.equal((await box(".palette-item"))?.height, 30, "and 30 pt rows");
  await page.keyboard.press("Escape");

  // The gauge: a 12 pt ring with a 2.5 stroke (ContextGauge.swift:25-31).
  const ring = await page.evaluate(() => {
    const node = document.querySelector(".context-gauge");
    if (!node) return null;
    const style = getComputedStyle(node, "::before");
    return { width: style.width, height: style.height, stroke: style.borderTopWidth };
  });
  if (ring) {
    assert.equal(ring.width, "12px", "the gauge's ring is 12 pt across");
    // The browser rounds a stroke to whole pixels when it lays it out.
    assert.ok(["2px", "2.5px"].includes(ring.stroke), `with a 2.5 pt stroke (${ring.stroke})`);
  }

  // And the page had nothing to complain about.
  assert.deepEqual(problems, [], "the page had nothing to complain about");
});
