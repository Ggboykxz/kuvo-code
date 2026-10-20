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
