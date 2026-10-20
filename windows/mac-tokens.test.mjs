// The Mac binding, checked: the tokens the page is painted with are the Mac's values, not the
// retired OpenDesign direction's. These are static checks on the source of the binding, so they
// run in CI without a browser or an engine.
//
//   node --test windows/mac-tokens.test.mjs
//
// The same checks are run twice: once over the sources as they are, and once over the same
// sources with Windows' line endings. A rule read as text must not depend on whether the
// file was checked out on Windows or on a Mac.

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const read = (...parts) => fs.readFileSync(path.join(here, ...parts), "utf8");

const sources = {
  css: read("harness", "ui", "style.css"),
  store: read("app", "src", "store.ts"),
  settings: read("app", "src", "Settings.tsx"),
  overlays: read("app", "src", "Overlays.tsx"),
  app: read("app", "src", "App.tsx"),
  design: read("harness", "ui", "DESIGN.md"),
  motion: read("app", "src", "motion.ts"),
  shimmer: read("app", "src", "components", "ai-elements", "shimmer.tsx"),
  tailwind: read("app", "src", "tailwind.css"),
  build: read("app", "build.mjs"),
};

/// The sources of one run, with the line endings of the platform put to one.
const withEndings = (raw, windows) => {
  const out = {};
  for (const [name, text] of Object.entries(raw)) {
    const flat = text.replace(/\r\n/g, "\n");
    out[name] = windows ? flat.replace(/\n/g, "\r\n") : flat;
  }
  return out;
};

/// The helpers the checks read the stylesheet with.
const reader = (css) => {
  // The Mac binding is the last block of the file; a token's last declaration in that block
  // is the one the cascade uses. Test those, not the retired block at the top.
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
  return { lightTokens, darkTokens, rule };
};

const checks = [
  ["the canvas is the Mac's warm canvas, with its two-corner ambient", ({ css, lightTokens, darkTokens }) => {
    assert.equal(lightTokens("bg"), "#F6F4EE");
    assert.equal(darkTokens("bg"), "#131417");
    const ambient = lightTokens("bg-ambient");
    assert.match(ambient, /255, 158, 107/);
    assert.match(ambient, /107, 140, 255/);
    assert.match(ambient, /0\.07/);
    assert.match(ambient, /0\.0175/);
  }],

  ["cards, bubble, panel and well use the Mac's radii", ({ lightTokens }) => {
    assert.equal(lightTokens("radius-card"), "14px");
    assert.equal(lightTokens("radius-panel"), "14px");
    assert.equal(lightTokens("radius-bubble"), "18px");
    assert.equal(lightTokens("radius-palette"), "18px");
    assert.equal(lightTokens("radius-well"), "10px");
    assert.equal(lightTokens("radius-button"), "6px");
  }],

  ["cards cast the Mac's soft shadow, and keep a lit top edge", ({ css, lightTokens, darkTokens }) => {
    assert.match(lightTokens("shadow-card"), /0 2px 6px/);
    assert.doesNotMatch(lightTokens("shadow-card"), /none/);
    assert.match(lightTokens("shadow-composer"), /inset 0 1px 0/);
    assert.match(darkTokens("shadow-card"), /rgba\(0, 0, 0/);
  }],

  ["the accent glass is a wash with an edge, and no blur", ({ css, lightTokens, darkTokens }) => {
    assert.match(lightTokens("bubble-fill"), /transparent 90%/);
    assert.match(darkTokens("bubble-fill"), /transparent 78%/);
    assert.match(lightTokens("bubble-edge"), /var\(--accent\) 28%/);
    const bubble = css.slice(css.lastIndexOf(".entry.user .text {"));
    assert.match(bubble, /backdrop-filter: none/);
    assert.match(bubble, /border-radius: var\(--radius-bubble\)/);
  }],

  ["the composer is an opaque card, not glass", ({ css }) => {
    const composer = css.slice(css.lastIndexOf(".composer {"));
    assert.match(composer, /background: var\(--panel\)/);
    assert.match(composer, /backdrop-filter: none/);
    assert.match(composer, /border-radius: var\(--radius-panel\)/);
    const editor = css.slice(css.lastIndexOf(".composer textarea {"));
    assert.match(editor, /background: transparent/);
    assert.match(editor, /border: 0/);
  }],

  ["the text size is a conversation size, and the Mac's four steps", ({ store, settings }) => {
    assert.match(store, /--message-size/);
    assert.doesNotMatch(store, /setProperty\("--text-base"/);
    assert.match(store, /"15\.5"/);
    assert.match(settings, /value="15\.5"/);
    assert.match(settings, /value="17"/);
    assert.match(store, /look\.motion === "reduced" \? "1ms" : "120ms"/);
  }],

  ["the design doc is bound to the Mac, not to OpenDesign", ({ design, settings }) => {
    assert.match(design, /Source of truth/);
    assert.match(design, /Surfaces\.swift/);
    assert.match(design, /The OpenDesign direction `modern-minimal`.*is retired/s);
    assert.doesNotMatch(settings, /The look is bound to OpenDesign/);
  }],

  ["the window's panes are on the glass, 8 pt apart, and the sidebar has no surface", ({ css }) => {
    assert.match(css, /--pane-gap:\s*8px/);
    const main = css.slice(css.lastIndexOf("main {"));
    assert.match(main, /gap: var\(--pane-gap\)/);
    assert.match(main, /padding: 0 var\(--pane-gap\) var\(--pane-gap\)/);
    const aside = css.slice(css.lastIndexOf("/* The sessions have no card of their own"));
    assert.match(aside, /background: transparent/);
    assert.match(aside, /border: 0/);
  }],

  ["the conversation is a card, with the Mac's 38 pt header and 62 pt fade", ({ css, app }) => {
    assert.match(css, /#conversation\.conversation-card\s*\{[^}]*border-radius: var\(--radius-card\)/s);
    assert.match(css, /--card-header:\s*38px/);
    const fade = css.slice(css.lastIndexOf(".card-fade {"));
    assert.match(fade, /height: 62px/);
    assert.match(fade, /mask-image: linear-gradient/);
    assert.match(app, /className="card conversation-card"/);
    assert.match(app, /<CardHeader \/>/);
  }],

  ["the conversation runs under the header, and the composer is inside the card", ({ css, app }) => {
    assert.match(css, /#conversation #entries \{ padding: calc\(var\(--card-header\) \+ 16px\)/);
    const composer = css.slice(css.lastIndexOf(".composer {"));
    assert.match(composer, /max-width: var\(--readable-width\)/);
    assert.match(app, /<Composer \/>/);
    assert.match(app, /id="conversation"/);
  }],

  ["the sidebar is one search, with 32 pt rows and the state dot", ({ css, app }) => {
    assert.match(css, /#sessions li \{ height: 32px; \}/);
    assert.match(css, /\.session \{[^}]*height: 32px/s);
    assert.match(app, /placeholder="Search"/);
    assert.doesNotMatch(app, /placeholder="Search sessions…"/);
    assert.doesNotMatch(app, /placeholder="Search messages…"/);
    assert.match(app, /className="sidebar-new"/);
  }],

  ["the palette floats over the page, and the card inside it is the glass", ({ css }) => {
    const palette = css.slice(css.lastIndexOf(".palette {"));
    assert.match(palette, /position: fixed/);
    assert.match(palette, /inset: 0/);
    assert.match(css, /\.palette-card::before/);
    assert.match(css, /\.gauge-pop \{ position: fixed; \}/);
  }],

  ["the title bar holds the sessions as tabs, in the Mac's glass track", ({ css, app, rule }) => {
    const track = rule(".tab-track {");
    assert.match(track, /height: 36px/);
    assert.match(track, /padding: 3px/);
    assert.match(track, /border-radius: 999px/);
    const tab = rule(".tab {");
    assert.match(tab, /height: 30px/);
    assert.match(tab, /gap: 8px/);
    assert.match(rule(".tab-title {"), /max-width: 190px/);
    // The pill: white in the light, a lighter glass in the dark, held off the track.
    assert.match(css, /(^|\n)\.tab-pill \{[^}]*background: #fff;/s);
    assert.match(css, /(^|\n)html\[data-theme="dark"\] \.tab-pill \{[^}]*background: rgba\(255, 255, 255, 0\.17\)/s);
    assert.match(app, /role="tablist" aria-label="Open sessions"/);
    assert.match(app, /className=\{`tab \$\{active \? "active" : ""\}`\}/);
    // The strip is the title bar's now, not the card's.
    assert.doesNotMatch(app, /id="session-tabs"/);
  }],

  ["the project identity takes the sessions' width, and the tabs the card's", ({ css, app }) => {
    assert.match(css, /(^|\n)\.titlebar-identity \{[^}]*flex: 0 0 var\(--sessions-width\)/s);
    assert.match(css, /(^|\n)\.titlebar-identity \{[^}]*width: var\(--sessions-width\)/s);
    assert.match(css, /header\.titlebar\.sidebar-hidden \.titlebar-identity \{ flex-basis: auto/);
    assert.match(app, /className="identity-name"/);
    assert.match(app, /className="identity-branch"/);
    assert.match(app, /aria-label=\{sidebarOpen \? "Hide Sessions" : "Show Sessions"\}/);
  }],

  ["the panel is a card beside the conversation, with a 44 pt tab strip", ({ css, app, rule }) => {
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
  }],

  ["the palette is the Mac's card: 600 wide, 18 corner, 48 pt search, 30 pt rows", ({ css, overlays, rule }) => {
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
  }],

  ["Settings takes the sessions' place: a sidebar on the glass, the page in a card", ({ css, settings, rule }) => {
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
  }],

  ["the shell leaves room for Windows' own window controls, and the page drags", ({ css, app, rule }) => {
    const shell = rule("body.in-shell header.titlebar {");
    assert.match(shell, /padding-right: calc\(138px \+ var\(--pane-gap\)\)/);
    assert.match(shell, /-webkit-app-region: drag/);
    assert.match(css, /body\.in-shell header\.titlebar button[\s\S]*?-webkit-app-region: no-drag/);
    assert.match(app, /document\.body\.classList\.toggle\("in-shell", inShell\)/);
    assert.doesNotMatch(app, /titlebar-drag/);
  }],

  ["the fields sit in a well, with no focus ring of their own", ({ css, rule }) => {
    const well = rule(".search-well {\n  display: flex;");
    assert.match(well, /height: 28px/);
    assert.match(well, /border-radius: var\(--radius-well\)/);
    assert.match(rule(".search-well > input {"), /background: transparent/);
    assert.match(rule("input:focus, textarea:focus, select:focus {"), /box-shadow: none/);
  }],

  ["the app's motion is the Mac's spring, written as the analytic curve", ({ css, motion, app, lightTokens }) => {
    // The curve: 0 at the start, a little past 1 (the Mac's spring settles with a half
    // percent of overshoot), and 1 at the end.
    const curve = lightTokens("ease-spring");
    assert.ok(curve?.startsWith("linear("), "the spring is the analytic curve");
    const points = curve.slice(7, -1).split(",").map(value => Number(value.trim()));
    assert.equal(points[0], 0);
    assert.equal(points.at(-1), 1);
    assert.ok(Math.max(...points) > 1, "the spring goes a little past its mark");
    assert.ok(Math.max(...points) < 1.01, "and not far past it");
    // The spring's own length: the time it takes to settle.
    assert.equal(lightTokens("motion-spring"), "450ms");
    // The same spring, as Motion takes it: ω = 2π / 0.32, damping 2ζω.
    assert.match(motion, /stiffness: 385\.5/);
    assert.match(motion, /damping: 33\.8/);
    assert.match(motion, /mass: 1/);
    assert.match(motion, /response: 0\.32/);
    assert.match(motion, /dampingFraction: 0\.86/);
    // The tab's pill is drawn by it, so the pill slides the way the Mac's does.
    assert.match(app, /layoutId="session-tab-pill"/);
    assert.match(app, /transition=\{macSpringOrStill\(motionIsReduced\(\)\)\}/);
  }],

  ["the pointer fills a control, and the press does not squeeze it", ({ css, lightTokens, rule }) => {
    assert.match(lightTokens("press-hover"), /var\(--ink\) 8%/);
    assert.match(lightTokens("press-active"), /var\(--ink\) 13%/);
    assert.equal(lightTokens("motion-hover"), "120ms");
    assert.equal(lightTokens("ease-hover"), "cubic-bezier(0, 0, 0.2, 1)");
    // The press is a fill: the Mac has no press scale (Pressable.swift:8-9).
    const pressed = rule("button:active {");
    assert.doesNotMatch(pressed, /scale/);
    assert.match(pressed, /transform: none/);
  }],

  ["the thinking shimmer is AI Elements', painted in the Mac's ink", ({ css, app, shimmer, rule }) => {
    // The component is upstream's, and says where it came from.
    assert.match(shimmer, /AI Elements — Shimmer \(Vercel\), Apache-2\.0/);
    assert.match(shimmer, /elements\.ai-sdk\.dev/);
    assert.match(shimmer, /bg-clip-text/);
    assert.match(shimmer, /motion\/react/);
    // The app uses it for the thinking words, at the Mac's beat (Theme.swift:93).
    assert.match(app, /<Shimmer as="span" className="thinking-shimmer" duration=\{1\.6\}>Thinking…<\/Shimmer>/);
    assert.match(app, /function motionIsReduced\(\)/);
    assert.match(app, /look\.motion === "reduced"/);
    // The light that sweeps is the Mac's, and the words are its secondary ink.
    const thinking = rule(".thinking-shimmer {");
    assert.match(thinking, /--color-background: var\(--ink\)/);
    assert.match(thinking, /--color-muted-foreground: var\(--ink-soft\)/);
  }],

  ["the working mark turns at the Mac's beat, and stands still when asked", ({ css, rule }) => {
    assert.match(rule(".tab-status.running {"), /animation: kuvo-spin 1\.6s linear infinite/);
    assert.match(css, /@keyframes kuvo-spin \{\n  to \{ transform: rotate\(360deg\); \}/);
    assert.match(css, /@media \(prefers-reduced-motion: reduce\) \{[^}]*\.tab-status\.running \{ animation: none; \}/s);
  }],

  ["the stylesheet is compiled with Tailwind, and only the AI Elements' classes are in it", ({ build, tailwind }) => {
    // The build compiles the stylesheet with this app's own copy of Tailwind.
    assert.match(build, /@tailwindcss/);
    assert.match(build, /tailwind\.css/);
    assert.match(build, /--minify/);
    // The Mac's own stylesheet rides in its own layer; the utilities sit above it.
    assert.match(tailwind, /@layer theme, mac, utilities;/);
    assert.match(tailwind, /@import "tailwindcss\/theme\.css" layer\(theme\);/);
    assert.match(tailwind, /@import "tailwindcss\/utilities\.css" layer\(utilities\);/);
    assert.match(tailwind, /@import "\.\.\/\.\.\/harness\/ui\/style\.css" layer\(mac\);/);
    // Preflight is not imported: the Mac's rules are the base of the app.
    assert.doesNotMatch(tailwind, /@import "tailwindcss";/);
    // shadcn's tokens are the Mac's own.
    assert.match(tailwind, /--color-background: var\(--panel\)/);
    assert.match(tailwind, /--color-muted-foreground: var\(--ink-soft\)/);
    assert.match(tailwind, /--color-primary: var\(--accent\)/);
    // And only the AI Elements' own files are scanned.
    assert.match(tailwind, /@source "\.\/components\/ai-elements";/);
  }],
];

const run = (raw, name) => {
  const flat = {};
  for (const [key, text] of Object.entries(raw)) flat[key] = text.replace(/\r\n/g, "\n");
  const helpers = reader(flat.css);
  for (const [title, check] of checks) {
    test(`${name}: ${title}`, () => check({ ...flat, ...helpers }));
  }
};

run(sources, "the Mac binding");
run(withEndings(sources, true), "the Mac binding, with Windows' line endings");
