// The Mac binding, checked: the tokens the page is painted with are the Mac's values, not the
// retired OpenDesign direction's. These are static checks on the source of the binding, so they
// run in CI without a browser or an engine.
//
//   node --test windows/mac-tokens.test.mjs

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const css = fs.readFileSync(path.join(here, "harness", "ui", "style.css"), "utf8");
const store = fs.readFileSync(path.join(here, "app", "src", "store.ts"), "utf8");
const settings = fs.readFileSync(path.join(here, "app", "src", "Settings.tsx"), "utf8");
const overlays = fs.readFileSync(path.join(here, "app", "src", "Overlays.tsx"), "utf8");
const app = fs.readFileSync(path.join(here, "app", "src", "App.tsx"), "utf8");
const design = fs.readFileSync(path.join(here, "harness", "ui", "DESIGN.md"), "utf8");

// The Mac binding is the last block of the file; a token's last declaration in that block is
// the one the cascade uses. Test those, not the retired block at the top.
const tokensIn = (start, name) => {
  assert.ok(start >= 0, "token block exists");
  const body = css.slice(start, css.indexOf("\n}", start));
  return [...body.matchAll(new RegExp(`--${name}:\\s*([^;]+);`, "g"))].at(-1)?.[1]?.trim();
};
const lightTokens = (name) => tokensIn(css.lastIndexOf(":root {"), name);
const darkTokens = (name) => tokensIn(css.lastIndexOf('html[data-theme="dark"] {'), name);

/// The rule that is written last for a selector: the one the cascade uses. A rule inside
/// a media query is not that one (it only applies at some widths), so those are skipped.
const mediaRanges = () => {
  const ranges = [];
  const pattern = /@media[^{]*\{/g;
  let found;
  while ((found = pattern.exec(css))) {
    let depth = 1;
    let at = found.index + found[0].length;
    while (at < css.length && depth > 0) {
      if (css[at] === "{") depth += 1;
      else if (css[at] === "}") depth -= 1;
      at += 1;
    }
    ranges.push([found.index, at]);
  }
  return ranges;
};
const rule = (selector) => {
  const ranges = mediaRanges();
  let start = -1;
  let at = css.indexOf(selector);
  while (at >= 0) {
    if (!ranges.some(([from, to]) => at > from && at < to)) start = at;
    at = css.indexOf(selector, at + 1);
  }
  assert.ok(start >= 0, `the rule for ${selector} exists`);
  const end = css.indexOf("\n}", start);
  return css.slice(start, end < 0 ? css.length : end);
};

test("the canvas is the Mac's warm canvas, with its two-corner ambient", () => {
  assert.equal(lightTokens("bg"), "#F6F4EE");
  assert.equal(darkTokens("bg"), "#131417");
  const ambient = lightTokens("bg-ambient");
  assert.match(ambient, /255, 158, 107/);
  assert.match(ambient, /107, 140, 255/);
  assert.match(ambient, /0\.07/);
  assert.match(ambient, /0\.0175/);
});

test("cards, bubble, panel and well use the Mac's radii", () => {
  assert.equal(lightTokens("radius-card"), "14px");
  assert.equal(lightTokens("radius-panel"), "14px");
  assert.equal(lightTokens("radius-bubble"), "18px");
  assert.equal(lightTokens("radius-palette"), "18px");
  assert.equal(lightTokens("radius-well"), "10px");
  assert.equal(lightTokens("radius-button"), "6px");
});

test("cards cast the Mac's soft shadow, and keep a lit top edge", () => {
  assert.match(lightTokens("shadow-card"), /0 2px 6px/);
  assert.doesNotMatch(lightTokens("shadow-card"), /none/);
  assert.match(lightTokens("shadow-composer"), /inset 0 1px 0/);
  assert.match(darkTokens("shadow-card"), /rgba\(0, 0, 0/);
});

test("the accent glass is a wash with an edge, and no blur", () => {
  assert.match(lightTokens("bubble-fill"), /transparent 90%/);
  assert.match(darkTokens("bubble-fill"), /transparent 78%/);
  assert.match(lightTokens("bubble-edge"), /var\(--accent\) 28%/);
  const bubble = css.slice(css.lastIndexOf(".entry.user .text {"));
  assert.match(bubble, /backdrop-filter: none/);
  assert.match(bubble, /border-radius: var\(--radius-bubble\)/);
});

test("the composer is an opaque card, not glass", () => {
  const composer = css.slice(css.lastIndexOf(".composer {"));
  assert.match(composer, /background: var\(--panel\)/);
  assert.match(composer, /backdrop-filter: none/);
  assert.match(composer, /border-radius: var\(--radius-panel\)/);
  const editor = css.slice(css.lastIndexOf(".composer textarea {"));
  assert.match(editor, /background: transparent/);
  assert.match(editor, /border: 0/);
});

test("the text size is a conversation size, and the Mac's four steps", () => {
  assert.match(store, /--message-size/);
  assert.doesNotMatch(store, /setProperty\("--text-base"/);
  assert.match(store, /"15\.5"/);
  assert.match(settings, /value="15\.5"/);
  assert.match(settings, /value="17"/);
  assert.match(store, /look\.motion === "reduced" \? "1ms" : "120ms"/);
});

test("the design doc is bound to the Mac, not to OpenDesign", () => {
  assert.match(design, /Source of truth/);
  assert.match(design, /Surfaces\.swift/);
  assert.match(design, /The OpenDesign direction `modern-minimal`.*is retired/s);
  assert.doesNotMatch(settings, /The look is bound to OpenDesign/);
});

test("the window's panes are on the glass, 8 pt apart, and the sidebar has no surface", () => {
  assert.match(css, /--pane-gap:\s*8px/);
  const main = css.slice(css.lastIndexOf("main {"));
  assert.match(main, /gap: var\(--pane-gap\)/);
  assert.match(main, /padding: 0 var\(--pane-gap\) var\(--pane-gap\)/);
  const aside = css.slice(css.lastIndexOf("/* The sessions have no card of their own"));
  assert.match(aside, /background: transparent/);
  assert.match(aside, /border: 0/);
});

test("the conversation is a card, with the Mac's 38 pt header and 62 pt fade", () => {
  assert.match(css, /#conversation\.conversation-card\s*\{[^}]*border-radius: var\(--radius-card\)/s);
  assert.match(css, /--card-header:\s*38px/);
  const fade = css.slice(css.lastIndexOf(".card-fade {"));
  assert.match(fade, /height: 62px/);
  assert.match(fade, /mask-image: linear-gradient/);
  assert.match(app, /className="card conversation-card"/);
  assert.match(app, /<CardHeader \/>/);
});

test("the conversation runs under the header, and the composer is inside the card", () => {
  assert.match(css, /#conversation #entries \{ padding: calc\(var\(--card-header\) \+ 16px\)/);
  const composer = css.slice(css.lastIndexOf(".composer {"));
  assert.match(composer, /max-width: var\(--readable-width\)/);
  assert.match(app, /<Composer \/>/);
  assert.match(app, /id="conversation"/);
});

test("the sidebar is one search, with 32 pt rows and the state dot", () => {
  assert.match(css, /#sessions li \{ height: 32px; \}/);
  assert.match(css, /\.session \{[^}]*height: 32px/s);
  assert.match(app, /placeholder="Search"/);
  assert.doesNotMatch(app, /placeholder="Search sessions…"/);
  assert.doesNotMatch(app, /placeholder="Search messages…"/);
  assert.match(app, /className="sidebar-new"/);
});

test("the palette floats over the page, and the card inside it is the glass", () => {
  const palette = css.slice(css.lastIndexOf(".palette {"));
  assert.match(palette, /position: fixed/);
  assert.match(palette, /inset: 0/);
  assert.match(css, /\.palette-card::before/);
  assert.match(css, /\.gauge-pop \{ position: fixed; \}/);
});

test("the title bar holds the sessions as tabs, in the Mac's glass track", () => {
  const track = rule(".tab-track {");
  assert.match(track, /height: 36px/);
  assert.match(track, /padding: 3px/);
  assert.match(track, /border-radius: 999px/);
  const tab = rule(".tab {");
  assert.match(tab, /height: 30px/);
  assert.match(tab, /gap: 8px/);
  assert.match(rule(".tab-title {"), /max-width: 190px/);
  // The pill: white in the light, a lighter glass in the dark, held off the track.
  assert.match(css, /(^|\n)\.tab\.active \{\n  background: #fff;/);
  assert.match(css, /(^|\n)html\[data-theme="dark"\] \.tab\.active \{[^}]*background: rgba\(255, 255, 255, 0\.17\)/s);
  assert.match(app, /role="tablist" aria-label="Open sessions"/);
  assert.match(app, /className=\{`tab \$\{active \? "active" : ""\}`\}/);
  // The strip is the title bar's now, not the card's.
  assert.doesNotMatch(app, /id="session-tabs"/);
});

test("the project identity takes the sessions' width, and the tabs the card's", () => {
  assert.match(css, /(^|\n)\.titlebar-identity \{[^}]*flex: 0 0 var\(--sessions-width\)/s);
  assert.match(css, /(^|\n)\.titlebar-identity \{[^}]*width: var\(--sessions-width\)/s);
  assert.match(css, /header\.titlebar\.sidebar-hidden \.titlebar-identity \{ flex-basis: auto/);
  assert.match(app, /className="identity-name"/);
  assert.match(app, /className="identity-branch"/);
  assert.match(app, /aria-label=\{sidebarOpen \? "Hide Sessions" : "Show Sessions"\}/);
});

test("the panel is a card beside the conversation, with a 44 pt tab strip", () => {
  const pane = rule(".drawer.utility-pane {\n  position: relative;");
  assert.match(pane, /width: 420px/);
  assert.match(pane, /border-radius: var\(--radius-card\)/);
  assert.match(pane, /background: var\(--panel\)/);
  assert.match(rule(".drawer-head {"), /height: 44px/);
  const tab = rule(".drawer-tab {");
  assert.match(tab, /height: 30px/);
  assert.match(tab, /border-radius: 9px/);
  // The panel sits in the window's row, beside the conversation, not over it.
  const main = app.indexOf("<main");
  const drawer = app.indexOf("<Drawer />");
  assert.ok(main >= 0 && drawer > main && drawer < app.indexOf("</main>"), "the panel is in the window's row");
});

test("the palette is the Mac's card: 600 wide, 18 corner, 48 pt search, 30 pt rows", () => {
  assert.match(rule(".palette-card {"), /width: min\(600px, 92vw\)/);
  assert.match(rule(".palette-card {"), /border-radius: var\(--radius-palette\)/);
  assert.match(rule(".palette-search {"), /height: 48px/);
  assert.match(rule(".palette-item {"), /height: 30px/);
  const overlay = rule(".palette {");
  assert.match(overlay, /padding-top: 80px/);
  // The Mac dims the page by a hair, not with a scrim.
  assert.match(overlay, /background: rgba\(0, 0, 0, 0\.001\)/);
  assert.doesNotMatch(overlay, /backdrop-filter: blur/);
  // The sections the Mac's palette has.
  for (const title of ["Recent Sessions", "Actions", "Sessions", "Files"]) {
    assert.match(overlays, new RegExp(`title: "${title}"`));
  }
});

test("Settings takes the sessions' place: a sidebar on the glass, the page in a card", () => {
  assert.match(settings, /className="settings-sidebar"/);
  assert.match(settings, /className="settings-content card"/);
  assert.match(settings, /className="settings-nav"/);
  assert.match(settings, /id="settings-search"/);
  assert.match(settings, /No Results/);
  assert.match(rule(".settings {"), /inset: var\(--header-height\) 0 0 0/);
  assert.match(rule(".settings-content {"), /border-radius: var\(--radius-panel\)/);
  assert.match(rule(".settings-content-head {"), /padding: 26px 49px 4px/);
  assert.match(rule(".settings-page {"), /max-width: 798px/);
  assert.match(rule(".settings-nav button {"), /height: 32px/);
});

test("the shell leaves room for Windows' own window controls, and the page drags", () => {
  const shell = rule("body.in-shell header.titlebar {");
  assert.match(shell, /padding-right: calc\(138px \+ var\(--pane-gap\)\)/);
  assert.match(shell, /-webkit-app-region: drag/);
  assert.match(css, /body\.in-shell header\.titlebar button[\s\S]*?-webkit-app-region: no-drag/);
  assert.match(app, /document\.body\.classList\.toggle\("in-shell", inShell\)/);
  assert.doesNotMatch(app, /titlebar-drag/);
});

test("the fields sit in a well, with no focus ring of their own", () => {
  const well = rule(".search-well {\n  display: flex;");
  assert.match(well, /height: 28px/);
  assert.match(well, /border-radius: var\(--radius-well\)/);
  assert.match(rule(".search-well > input {"), /background: transparent/);
  assert.match(rule("input:focus, textarea:focus, select:focus {"), /box-shadow: none/);
});
