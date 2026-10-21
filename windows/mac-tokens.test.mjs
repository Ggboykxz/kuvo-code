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
  symbols: read("app", "src", "components", "symbols.tsx"),
  lib: read("app", "src", "lib.ts"),
  changes: read("app", "src", "Changes.tsx"),
  styles: read("harness", "ui", "style.css"),
  shimmer: read("app", "src", "components", "ai-elements", "shimmer.tsx"),
  logo: read("app", "src", "components", "provider-logo.tsx"),
  spinner: read("app", "src", "components", "spinner.tsx"),
  transcript: read("harness", "transcript.mjs"),
  layout: read("harness", "layout.mjs"),
  engine: read("harness", "engine.mjs"),
  shell: read("electron", "main.js"),
  preload: read("electron", "preload.js"),
  toolCall: read("app", "src", "components", "tool-call.tsx"),
  mac: read("..", "Packages", "OpenCodeKit", "Sources", "OpenCodeKit", "Events", "Transcript.swift"),
  sidebar: read("..", "KuvoCode", "Views", "SidebarView.swift"),
  tailwind: read("app", "app", "globals.css"),
  postcss: read("app", "postcss.config.mjs"),
  next: read("app", "next.config.mjs"),
  page: read("app", "app", "page.tsx"),
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
    assert.match(app, /<CardHeader\s+session=\{state\.session\}/);
  }],

  ["the conversation runs under the header, and the composer is inside the card", ({ css, app }) => {
    assert.match(css, /#conversation #entries, #split-entries \{ padding: calc\(var\(--card-header\) \+ 16px\)/);
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

  ["the panes take the Mac's terrain, and give way in its order", ({ app, css, layout, rule }) => {
    // PaneLayout (MainView.swift:2112-2179): sessions 220…440, changes 300…900, split
    // 380…1200, and the conversation keeps at least 380. Out of room the split goes first,
    // then the panel, then the sessions; a pane that went early comes back if a later
    // one's going left room for it; the rest shrink, the panel first and the split last.
    assert.match(layout, /sessions: \{ lower: 220, upper: 440 \}/);
    assert.match(layout, /changes: \{ lower: 300, upper: 900 \}/);
    assert.match(layout, /split: \{ lower: 380, upper: 1200 \}/);
    assert.ok(layout.includes("export const conversationMinimum = 380;"));
    assert.ok(layout.includes('givesWay = ["split", "changes", "sessions"]'), "the Mac's order of giving way");
    assert.ok(layout.includes('for (const pane of ["changes", "sessions", "split"])'), "and the Mac's order of shrinking");
    // The page measures the window and passes what each pane asks for: the sessions and
    // the panel only while shown, the split only while a session is beside the one in view.
    assert.match(app, /function paneLayoutNow\(\)[\s\S]*?main\.clientWidth[\s\S]*?paneLayout\(\{[\s\S]*?sessions: state\.sidebarOpen === false \? null : state\.sessionsWidth[\s\S]*?changes: state\.drawerOpen \? state\.changesWidth : null[\s\S]*?split: state\.split \? state\.splitWidth : null/);
    assert.ok(app.includes("hidden={!state.split || layout.split === null}"), "a split the window has no room for is put aside");
    assert.ok(app.includes('<PaneResizer pane="split" />'), "and the split has its own handle, as the Mac's has");
    // The pane widths come from the layout, with the Mac's defaults when there is room.
    const pane = rule(".split-pane {");
    assert.match(pane, /flex: 0 0 var\(--split-width\)/);
    assert.match(css, /--split-width: 560px/);
    assert.ok(css.includes("width: var(--changes-width, 420px)"));
  }],

  ["the panel is a card beside the conversation, with a 44 pt tab strip", ({ css, app, rule }) => {
    const pane = rule(".drawer.utility-pane {\n  position: relative;");
    // The panel takes its width from the layout, as the Mac's changesWidth does
    // (MainView.swift:39) — 420 by default, and less when the window has no room.
    assert.match(pane, /width: var\(--changes-width, 420px\)/);
    assert.match(css, /--changes-width: 420px/);
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
    const pressed = rule("button:active { transform: none; }");
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

  ["the working mark is the app's own, written at the Mac's beat", ({ css, symbols, spinner }) => {
    // The Mac's spinner writes the app's prompt mark: the chevron first, the cursor next,
    // a hold, and a fade, over its 1.6 s round (Spinner.swift:40-54).
    assert.match(css, /animation: kuvo-spinner-chevron 1\.6s linear infinite/);
    assert.match(css, /animation: kuvo-spinner-cursor 1\.6s linear infinite/);
    assert.match(css, /animation: kuvo-spinner-fade 1\.6s linear infinite/);
    assert.match(css, /@keyframes kuvo-spinner-chevron \{\n  0% \{ stroke-dashoffset: 1; \}/);
    assert.match(css, /@keyframes kuvo-spinner-fade \{\n  0%, 78% \{ opacity: 1; \}/);
    // The faint copy is the Mac's: the mark at 18 % of the ink (Spinner.swift:104-108),
    // and the whole mark fades together (Spinner.swift:141-143).
    assert.match(css, /\.spinner-faint \{ opacity: 0\.18; \}/);
    assert.match(css, /\.spinner \{[^}]*animation: kuvo-spinner-fade 1\.6s linear infinite;/s);
    // And it stands still when the system asks for less movement (Spinner.swift:19-24).
    assert.match(css, /@media \(prefers-reduced-motion: reduce\) \{[\s\S]*?\.spinner-drawn \{ display: none; \}/);
    // The mark itself is the Mac's own: the chevron and the cursor, on the icon's
    // coordinates, with the icon's stroke (Spinner.swift:153-177, scripts/icon.py:15-17).
    assert.match(symbols, /export const PROMPT_CHEVRON = "M77 74L267 262 77 450"/);
    assert.match(symbols, /export const PROMPT_CURSOR = "M377 450h230"/);
    assert.match(symbols, /Math\.max\(1, size \* 0\.11\) \* \(PROMPT_BOX \/ size\)/);
    // The mark is drawn in the spinner, on the box's own units.
    assert.match(spinner, /viewBox=\{`0 0 \$\{PROMPT_BOX\} \$\{PROMPT_HEIGHT\}`\}/);
    // And the spinner draws the faint copy under the drawn one (Spinner.swift:118-126).
    assert.match(spinner, /className="spinner-faint"/);
    assert.match(spinner, /className="spinner-drawn"/);
    assert.match(spinner, /strokeDasharray=\{dash\}/);
  }],

  ["the tool rows say what the call did, in the Mac's words", ({ app, toolCall, symbols }) => {
    // ToolCallView.swift:163-200: the words of the call. Ours said the tool's raw name.
    assert.match(toolCall, /case "read": return `\$\{active \? "Reading " : "Read "\}/);
    assert.match(toolCall, /case "shell": return `\$\{active \? "Running " : "Ran "\}/);
    assert.match(toolCall, /case "grep": return `Searched for/);
    assert.match(toolCall, /case "websearch": return `Searched the web for/);
    // And the mark that stands for it (ToolCallView.swift:312-326), drawn.
    assert.match(toolCall, /case "read": return "doc\.text"/);
    assert.match(toolCall, /case "grep":\s*case "glob": return "magnifyingglass"/);
    for (const mark of ["doc.text", "doc.badge.plus", "pencil", "terminal", "globe", "questionmark.bubble", "wand.and.stars", "wrench.and.screwdriver"]) {
      assert.ok(symbols.includes(`"${mark}"`), `${mark} is drawn`);
    }
    // And the row shows them.
    assert.match(app, /<Spinner size=\{11\} \/> : <Symbol name=\{toolSymbol\(/);
  }],

  ["the lines a call added and removed come from where the Mac reads them", ({ app, css, toolCall, transcript }) => {
    // The Mac sums the files out of the call's own metadata — nowhere else
    // (ToolCallView.swift:358-366; SessionEdits.swift:19-22 reads the same field) — and
    // prints them in the row (ToolCallView.swift:106-107, Theme.swift:147-156): the
    // system's green and red, medium weight, monospaced digits, a space of four between.
    assert.ok(transcript.includes("metadata: block.state?.metadata ?? null"), "the stored call brings its metadata with it");
    assert.ok(transcript.includes("part.metadata = payload.metadata ?? part.metadata"), "the outcome's metadata reaches the call");
    assert.match(toolCall, /metadata\?\.files as/);
    assert.ok(!toolCall.includes("input?.files"), "the input is not where the engine keeps the files");
    assert.match(app, /toolDiffStat\(part\.metadata\)/);
    assert.ok(app.includes("+{stat.additions}") && app.includes("−{stat.deletions}"), "the Mac's own signs, the minus and not a hyphen");
    assert.ok(css.includes(".diff-stat { display: inline-flex; gap: 4px; font-size: var(--text-xs);"), "the stat sits in the row at the caption size");
    assert.ok(css.includes("font-variant-numeric: tabular-nums; font-weight: 500;"), "the digits line up, at the medium weight");
    assert.ok(css.includes(".diff-stat .added { color: var(--ok); }"), "the system's green");
    assert.ok(css.includes(".diff-stat .removed { color: var(--danger); }"), "the system's red");
  }],

  ["a conversation with nothing in it asks the Mac's own question", ({ app, css, symbols }) => {
    // TranscriptView.swift:69-75 overlays the empty view while there are no rows and
    // nothing waiting; its `plain` form (1757-1767) is the Mac's mark at 34 pt light in
    // the tertiary ink over the question at title3 medium in the secondary ink, a
    // spacing of 10, lifted from the bottom by 120.
    assert.ok(symbols.includes('"bubble.left.and.text.bubble.right"'), "the Mac's mark is drawn");
    assert.match(app, /<Symbol name="bubble\.left\.and\.text\.bubble\.right" size=\{34\} stroke=\{2\.4\} \/>/);
    assert.ok(app.includes("What should we work on in "), "the Mac's own question, about the folder");
    assert.match(app, /state\.transcript\.entries\.length === 0 && state\.transcript\.pending\.length === 0/, "the overlay shows while the rows and the waiting are both empty");
    assert.ok(css.includes("--text-title3: 15px"), "the Mac's title3, 15 pt on macOS");
    assert.ok(css.includes(".empty-conversation p { margin: 0; font-size: var(--text-title3); font-weight: 500; color: var(--ink-soft); }"), "the question at title3 medium, in the secondary ink");
    assert.ok(css.includes("padding-bottom: 120px"), "the 120 pt lift from the bottom");
    assert.ok(css.includes("gap: 10px"), "the spacing of the stack");
    assert.ok(css.includes(".empty-conversation > svg { color: var(--ink-faint); }"), "the mark in the tertiary ink");
  }],

  ["a message the engine has stamped finished is a turn that ended", ({ transcript }) => {
    // The Mac's own measure reads the message itself (Message.isRunning): a reply the
    // engine has finished ends the turn — whatever its flag still says, and however few
    // parts it carries. The stale flag alone had kept the Stop button up over a turn that
    // was over (the live test kept meeting it).
    assert.ok(transcript.includes("const done = Boolean(last?.completed)"), "the message's own state is read");
    assert.match(transcript, /transcript\.running = !done && Boolean\(running\) && \(unfinished \|\| !written\)/, "either half can end the run, and a finished message ends it first");
  }],

  ["the split pane is a card, and its head is the conversation's own", ({ app, css }) => {
    // The Mac draws the split as a Card with the same header the conversation has
    // (MainView.swift:733-754): its session's title, its ring, Swap and Close. Nothing
    // there is a strip of its own — no picker, no band that could pass for a title bar.
    assert.ok(app.includes('id="split-pane" className="card split-pane"'), "the split is a card");
    assert.ok(!app.includes('className="split-head"') && !app.includes('id="split-session"'), "no strip of controls of its own");
    assert.ok(css.includes("#conversation #entries, #split-entries { padding: calc(var(--card-header) + 16px)"), "its rows run under its header as the conversation's do");
    assert.ok(app.includes("function SplitHeader()") && app.includes("<CardHeader session={split}"), "the very same CardHeader heads it");
    assert.ok(app.includes('title="Swap the two sessions"') && app.includes('title="Close Split View"'), "the Mac's two actions");
    assert.ok(app.includes("<ContextGauge session={split} />"), "its own ring");
  }],

  ["every open conversation follows the engine's events, and a connection re-reads them", ({ store }) => {
    // The Mac routes each event to the model of the session it names (Workspace.swift:1458)
    // and at a reconnection reads everything on screen again (AppModel.swift:448-459 →
    // Workspace.resync, Workspace.swift:1347-1359). The page does the same: the split's
    // transcript is kept current, and a connection re-reads the list and both conversations.
    assert.ok(store.includes("state.transcripts.forEach((transcript, id) =>"), "the events reach the split's own transcript");
    assert.ok(store.includes("source.onopen = () => { void resync(); }"), "a connection re-reads");
    assert.match(store, /async function resync\(\)[\s\S]*?await loadSessions\(\);[\s\S]*?await openSession\(state\.session\.id\);[\s\S]*?await openSplit\(state\.split, true\);/, "the list and both open conversations");
    assert.ok(store.includes("if (state.split && ended === state.split) await openSplit(state.split, true);"), "a turn that ends in the split is read back");
  }],

  ["a session opens beside another the Mac's way", ({ app, store }) => {
    // Open Beside is the Mac's (SidebarView.swift:609, MainView.swift:757-775): the session
    // opens beside the one in view — the pane never carries a picker of its own.
    assert.ok(app.includes('label: "Open Beside"'), "the session's menu offers it");
    assert.ok(app.includes("async function openBeside(id: string)"), "it opens the pair");
    assert.ok(app.includes("if (!id || id === state.session?.id) return;"), "the session in view is not opened beside itself");
    assert.ok(store.includes("export async function openSplit(id: string, force = false)"), "the split's history reads through the store");
  }],

  ["the page listens for the engine's own event names, and the transcript knows them", ({ app, transcript, mac }) => {
    // The page was listening for names the engine never sends (`message.part.updated`), so
    // the words of a reply arrived only on a reload, and the Stop button stayed. The names
    // are the engine's own, and the transcript reads the same ones.
    const names = (source, pattern) => new Set([...source.matchAll(pattern)].map(match => match[1]));
    const listened = names(app, /"((?:session|permission|form)\.[a-z.]+)"/g);
    const known = names(transcript, /case "([^"]+)"/g);
    const macs = names(mac, /case "([^"]+)"/g);
    const unheard = [...listened].filter(name => !known.has(name));
    assert.deepEqual(unheard, [], "every event the page listens for, the transcript reads");
    // And the names are the Mac's own, where the Mac has them.
    const strange = [...listened].filter(name => !macs.has(name) && known.has(name));
    assert.deepEqual(strange, [], "every event the page listens for, the Mac knows it too");
  }],

  ["the stylesheet is compiled with Tailwind, and only the AI Elements' classes are in it", ({ build, tailwind, postcss }) => {
    // Tailwind runs through its PostCSS plugin, in Next's own build.
    assert.match(postcss, /@tailwindcss\/postcss/);
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
    assert.match(tailwind, /@source "\.\.\/src\/components\/ai-elements";/);
    // The build copies the export where the harness looks for it.
    assert.match(build, /ui-build/);
    assert.match(build, /fs\.copyFileSync/);
  }],

  ["no text glyph stands for a mark: the Mac's symbols are drawn", ({ app, overlays, settings, changes, styles, symbols }) => {
    // The Mac draws its symbols; a letter, an arrow or a cross standing in for one is a
    // defect (docs/MAC-UI-MAP.md §7).
    const marks = /[✕✖▾▸▴▵↺↻⇩⇧↑↓⋯]/g;
    for (const [name, source] of Object.entries({ app, overlays, settings, changes, styles })) {
      const found = source.match(marks);
      assert.equal(found, null, `${name} has no glyph standing in for a mark (${found?.join(" ") ?? ""})`);
    }
    // The drawings themselves: the Mac's house style — a 1.5 pt stroke at 16 pt as the
    // default, round caps and joins, in the ink of the text they sit in. A mark the Mac
    // draws at another weight (its `.light`) asks for its own stroke beside its use, and
    // nowhere else.
    assert.match(symbols, /strokeWidth=\{strokeWidth\}/);
    assert.match(symbols, /const strokeWidth = stroke \?\? \(1\.5 \* size\) \/ 16;/);
    assert.match(symbols, /stroke="currentColor"/);
    assert.match(symbols, /strokeLinecap="round"/);
    assert.match(symbols, /strokeLinejoin="round"/);
    // And the two the Mac draws rather than borrowing: the folder (a 16 × 13 grid) and the
    // app's own prompt mark, the `>_` the spinner writes.
    assert.match(symbols, /viewBox="0 0 16 13"/);
    assert.match(symbols, /fillOpacity="0\.2"/);
    assert.match(symbols, /const stroke = size \/ 11\.5;/);
    assert.match(symbols, /export const PROMPT_BOX = 690;/);
    assert.match(symbols, /export const PROMPT_HEIGHT = 530;/);
    assert.match(symbols, /M77 74L267 262 77 450/);
    assert.match(symbols, /M377 450h230/);
  }],

  ["the gauge is the Mac's: a ring with its number, in a 24 pt pill", ({ css, rule }) => {
    // ContextGauge.swift:13-40: a 12 pt ring with a 2.5 stroke, the number beside it in
    // the secondary ink, and orange once the window is more than eight parts full.
    const gauge = rule(".context-gauge {");
    assert.match(gauge, /height: 24px/);
    assert.match(gauge, /padding: 0 6px/);
    assert.match(gauge, /border-radius: 7px/);
    assert.match(rule(".context-gauge::before {"), /width: 12px; height: 12px/);
    assert.match(rule(".context-gauge::before {"), /border: 2\.5px solid/);
    assert.match(rule(".context-gauge.warn {"), /color: var\(--warn\)/);
    // And the details, 320 pt wide with 16 pt of padding.
    assert.match(css, /\.gauge-pop \{[^}]*width: 320px;/s);
    assert.match(css, /\.gauge-pop \{[\s\S]*?padding: 16px;/);
  }],

  ["the working line says what the Mac's says, and shimmers", ({ app, css }) => {
    // TranscriptView.swift:598-610: "Working…", the time it has been at it, and the way
    // to stop it — the words shimmering.
    assert.match(app, /Working…/);
    assert.match(app, /· Esc to stop/);
    // And the time it has been at it, the Mac's way: 45s, 2m 5s, 1h 5m.
    assert.match(app, /`\$\{Math\.floor\(seconds \/ 60\)\}m \$\{seconds % 60\}s`/);
    assert.match(app, /`\$\{Math\.floor\(seconds \/ 3600\)\}h \$\{Math\.floor\(\(seconds % 3600\) \/ 60\)\}m`/);
    assert.match(app, /className="thinking-shimmer"/);
    assert.match(css, /\.working-line \{/);
  }],

  ["the steps row is the Mac's: the mark, the summary, the chevron that turns", ({ app, css, symbols }) => {
    // StepsRow.swift:37-48.
    assert.match(app, /<Symbol name="list\.bullet"/);
    assert.match(app, /<Symbol name="chevron\.right" size=\{11\} className=\{open \? "turned" : ""\} \/>/);
    assert.match(css, /\.turned \{ transform: rotate\(90deg\); \}/);
    assert.match(symbols, /"list\.bullet":/);
  }],

  ["the settings are the Mac's grouped form: a name, and the rows in a card", ({ css, settings, rule }) => {
    // SettingsControls.swift:350-367: a grouped Form, its sections named, their rows in a
    // card under them.
    assert.match(rule(".setting-group {"), /margin: 0 0 18px/);
    assert.match(rule(".setting-group-title {"), /font-size: 13px/);
    assert.match(rule(".setting-group-card {"), /border-radius: 10px/);
    assert.match(rule(".setting-row-note {"), /font-size: 12px/);
    assert.match(settings, /function SettingGroup\(/);
    assert.match(settings, /function SettingRow\(/);
    // The pages that use it, with the Mac's group names.
    for (const group of ["Mode", "Colors", "Messages", "Updates", "While Agents Work"]) {
      assert.ok(settings.includes(`title="${group}"`), `the "${group}" group is there`);
    }
    // And the Mac's three modes, each with a window of its own.
    assert.match(settings, /const MODES = \[/);
    assert.match(settings, /className=\{`mode-choice/);
    assert.match(rule(".mode-thumb {"), /width: 84px/);
  }],

  ["the panel's files are a tree, the Mac's way (FilesView.swift:250-275)", ({ app, css, overlays, symbols, rule }) => {
    assert.match(overlays, /function FileTree\(/);
    assert.match(overlays, /function buildTree\(/);
    // The folders carry a chevron that turns; the files carry their own mark.
    assert.match(overlays, /<Symbol name="chevron\.right" size=\{10\} className=\{open\[node\.path\] \? "turned" : ""\} \/>/);
    assert.match(overlays, /<Symbol name="doc" size=\{13\} \/>/);
    assert.match(symbols, /"doc": \[/);
    // And the tree is the project's own: the folder it sits in is the root.
    assert.match(overlays, /file\.path\.startsWith\(prefix\)/);
    assert.match(rule(".file-row {"), /gap: 6px/);
    assert.match(rule(".file-row {"), /font-size: var\(--text-sm\)/);
    assert.match(css, /\.file-tree \{ display: flex; flex-direction: column;/);
  }],

  ["the gestures: a name typed in its row, a handle in the gap, a shell's history", ({ app, css, rule }) => {
    // The inline rename (InlineTitleField.swift:4-55): the name is selected, Return
    // commits, Escape cancels, and clicking away keeps it.
    assert.match(app, /className="session-rename"/);
    assert.match(app, /onFocus=\{event => event\.currentTarget\.select\(\)\}/);
    assert.match(app, /event\.key === "Enter"[\s\S]{0,120}commitRename/);
    assert.match(app, /event\.key === "Escape"[\s\S]{0,80}setRenaming\(null\)/);
    // The menu it is reached from (SidebarView.swift:586-590).
    assert.match(app, /onContextMenu=\{event => \{/);
    assert.match(app, /label: "Rename…"/);
    // The handle in the gap (WindowGlass.swift:43-81): the gap is the handle, the capsule
    // is 3 pt and shows at half strength, and the cursor says what it does.
    assert.match(app, /function PaneResizer\(/);
    assert.match(rule(".pane-resizer {"), /cursor: col-resize/);
    assert.match(rule(".pane-resizer::after {"), /width: 3px/);
    assert.match(rule(".pane-resizer::after {"), /top: 40px;[\s\S]*bottom: 40px/);
    assert.match(css, /\.pane-resizer:hover::after,\n\.pane-resizer\.dragging::after \{ opacity: 0\.5; \}/);
    // And the composer's history: up and down walk what you have sent, as in a shell
    // (Composer.swift:22-24).
    assert.match(app, /The composer's history/);
    assert.match(app, /event\.key === "ArrowUp" \|\| event\.key === "ArrowDown"/);
  }],

  ["the find is invoked, and it is the Mac's bar (FindBar.swift:251-291)", ({ app, css, lib, rule }) => {
    assert.match(app, /function FindBar\(/);
    assert.match(app, /placeholder="Find in Conversation"/);
    assert.match(app, /state\.findOpen = true;/);
    assert.match(rule(".find-row {"), /height: 38px/);
    // The count, the arrows, and Done.
    assert.match(app, /places === 1 \? "result" : "results"/);
    assert.match(app, /"No results"/);
    assert.match(app, /id="find-previous"/);
    assert.match(app, /id="find-next"/);
    assert.match(app, /id="find-done"/);
    // And what it found is marked in the words.
    assert.match(lib, /mark\.className = "find-mark"/);
    assert.match(css, /\.find-mark \{/);
  }],

  ["the popover flips, and the search can be cleared", ({ app, css, rule }) => {
    // A popover that outgrows its side flips to the other (ScreenRoom.swift:4-33): the
    // gauge's sits by the gauge, and never past the window's edge.
    assert.match(app, /const wanted = button\.left \+ button\.width - box\.width;/);
    assert.match(app, /Math\.min\(Math\.max\(8, wanted\), Math\.max\(8, window\.innerWidth - box\.width - 8\)\)/);
    // And the clear in a search field (Pressable.swift:73-91).
    assert.match(app, /id="session-search-clear"/);
    assert.match(rule(".search-clear {"), /color: var\(--ink-faint\)/);
    assert.match(css, /\.search-clear:hover \{ background: var\(--hover\); color: var\(--ink-soft\); \}/);
  }],

  ["the actions under a message are the Mac's (YourMessage.swift:41-64)", ({ app, css, rule }) => {
    assert.match(app, /className="entry-actions"/);
    assert.match(app, /title="Copy"/);
    assert.match(app, /title="New Session From Here"/);
    assert.match(app, /title="Undo From Here…"/);
    assert.match(app, /sentAt\(entry\.created\)/);
    // Always laid out, so nothing moves when they appear, and shown under the pointer.
    assert.match(rule(".entry-actions {\n  display: flex;"), /opacity: 0/);
    assert.match(rule(".entry-actions {\n  display: flex;"), /min-height: 22px/);
    assert.match(css, /\.entry\.user:hover \.entry-actions,[\s\S]*?opacity: 1;/);
  }],

  ["a control that cannot be used is dimmed, and a remove turns red", ({ css, rule }) => {
    // Pressable.swift:61 — a control that cannot be used is dimmed to 45 %.
    assert.match(rule("button:disabled {"), /opacity: \.45/);
    // Pressable.swift:93-112 — the remove turns red under the pointer, and is dimmer
    // while it is pressed.
    assert.match(rule(".remove-button {"), /color: var\(--ink-faint\)/);
    assert.match(css, /\.remove-button:hover \{ background: var\(--danger-soft\); color: var\(--danger\); \}/);
    assert.match(css, /\.remove-button:active \{ opacity: \.7; \}/);
  }],

  ["the sidebar names the project, with the Mac's drawn folder", ({ app, css, rule }) => {
    // SidebarView.swift:795-845: the project's folder (open or closed) and its name, with
    // the compose button showing under the pointer.
    assert.match(app, /<FolderIcon open=\{open\}/);
    assert.match(app, /className="project-row"/);
    assert.match(app, /className="project-compose"/);
    assert.match(app, /New Session in \$\{folderName\(folder\)\}/);
    assert.match(rule("aside .project-row {"), /height: 32px/);
    assert.match(rule("aside .project-icon {"), /flex: 0 0 18px/);
    assert.match(css, /aside \.project-compose \{[\s\S]*?opacity: 0;/);
  }],

  ["the sidebar holds every project, with its own sessions, and the Recents", ({ app, css, rule }) => {
    // SidebarView.swift:178-196 (the projects, under a heading of their own), 353-402
    // (each project, its sessions, and "Show N More"), 490-493 (the Recents).
    assert.match(app, /<SectionHeader\s+title="Projects"/);
    assert.match(app, /<SectionHeader title="Recents"/);
    assert.match(app, /state\.projects\.map/);
    assert.match(app, /state\.sessionsByProject/);
    // Five sessions to a project, then the rest on request (SidebarView.swift:62-63).
    assert.match(app, /sessions\.slice\(0, 5\)/);
    assert.match(app, /Show \$\{sessions\.length - 5\} More/);
    // The eight most recent sessions across the projects.
    assert.match(app, /\.slice\(0, 8\)/);
    // The heading folds the section away, and the sessions of a project line their titles
    // up with the project names above them.
    assert.match(rule("aside .section-header {"), /height: 22px/);
    assert.match(rule("aside .sessions .session {"), /padding-left: 38px/);
    assert.match(rule("aside .recents .session {"), /padding-left: 10px/);
  }],

  ["a provider's mark is the Mac's: fetched, drawn in the ink, with the initial first", ({ app, css, logo }) => {
    // ProviderLogo.swift:7-46 — the mark from models.dev, monochrome, or in the maker's own
    // colour; the initial stands in for it at 55 % of the size, semibold and rounded.
    assert.match(logo, /\/api\/logo\/\$\{encodeURIComponent\(id\)\}/);
    assert.match(read("harness", "server.mjs"), /models\.opencode\.ai\/logos\/\$\{id\}\.svg/);
    assert.match(logo, /MAKER_COLORS/);
    assert.match(logo, /anthropic: 0xd97757/);
    assert.match(logo, /fontSize: size \* 0\.55/);
    assert.match(logo, /maskImage/);
    // And the model's menu shows it beside each model (ModelPicker.swift:218).
    assert.match(app, /logo: model\.providerID/);
    assert.match(app, /<ProviderLogo id=\{item\.logo\} size=\{15\}/);
    assert.match(css, /\.provider-logo\.fallback \{[\s\S]*?font-weight: 600;/);
  }],

  ["the press is the Mac's: the control darkens, it does not shrink", ({ css, rule }) => {
    // Pressable.swift:8-9 (8 % under the pointer, 13 % while it is down) and 85 (the
    // press is a fill) — the Mac's app has no press scale anywhere.
    // The Mac's app has no press scale anywhere: a pressed control is filled, not squeezed.
    assert.ok(!/button:active \{[^}]*scale\(/.test(css), "no press scale");
    assert.match(rule("\nbutton:active {"), /transform: none/);
    // And the fills are the Mac's own: 8 % under the pointer, 13 % while it is down.
    assert.match(rule(":root {"), /--press-hover: color-mix\(in oklab, var\(--ink\) 8%, transparent\)/);
    assert.match(rule(":root {"), /--press-active: color-mix\(in oklab, var\(--ink\) 13%, transparent\)/);
    assert.match(rule("\nbutton.small:active {"), /background: var\(--press-active\)/);
  }],

  ["the settings' pages carry the Mac's own symbols, drawn", ({ settings, symbols }) => {
    // SettingsView.swift:196-232 — the mark each page has.
    for (const [page, name] of Object.entries({
      appearance: "paintpalette", general: "gearshape", keyboard: "command",
      mcp: "puzzlepiece.extension", agents: "person.2", skills: "graduationcap",
      commands: "slash.circle", projects: "folder", providers: "person.crop.circle",
      usage: "gauge.with.dots.needle.50percent", git: "arrow.triangle.branch",
      archived: "archivebox", permissions: "checkmark.shield", system: "cpu",
    })) {
      assert.ok(symbols.includes(`"${name}"`), `the library draws ${name}`);
      assert.ok(settings.includes(`${page}: "${name}"`), `${page} carries ${name}`);
    }
    // And they are drawn, not typed: the library's paths.
    assert.match(symbols, /"gearshape": \["M/);
    assert.match(symbols, /"paintpalette": \["M/);
  }],

  ["the menus carry the Mac's chevron", ({ app, css, rule }) => {
    // Pressable.swift:192-198 — 8 pt, bold, in the secondary ink, after the label.
    assert.match(app, /<Symbol name="chevron\.down" size=\{8\} className="choice-chevron" \/>/);
    assert.match(rule(".choice-chevron {"), /flex: 0 0 8px/);
    assert.match(css, /\.choice-chevron \{[^}]*stroke-width: 2;/s);
  }],

  ["the accent badge grows and darkens, as the Mac's does", ({ css, rule }) => {
    // Pressable.swift:201-220 — it grows to 1.12 and darkens 7 % under the pointer, and
    // darkens more while it is pressed.
    assert.match(rule(".swatch {"), /transform var\(--motion-fast\) var\(--ease-spring\)/);
    assert.match(css, /\.swatch:hover \{ transform: scale\(1\.12\); filter: brightness\(0\.93\); \}/);
    assert.match(css, /\.swatch:active \{ transform: scale\(1\.12\); filter: brightness\(0\.85\); \}/);
  }],

  ["the changes panel says what the Mac's says", ({ changes }) => {
    // ProjectChanges.swift:50-62 — the scopes' own names.
    assert.match(changes, /\["uncommitted", "Uncommitted"\]/);
    assert.match(changes, /\["unstaged", "Unstaged"\]/);
    assert.match(changes, /\["staged", "Staged"\]/);
    assert.match(changes, /\["branch", "Branch"\]/);
    assert.match(changes, /\["session", "This Session"\]/);
  }],

  ["the shell has a real menu bar, and the window can be zoomed with two clicks", ({ app, css, lib, rule }) => {
    // NativeMenu.swift:5-165 — a real menu bar, with the items the Mac has.
    const shell = fs.readFileSync(path.join(here, "electron", "main.js"), "utf8");
    const preload = fs.readFileSync(path.join(here, "electron", "preload.js"), "utf8");
    assert.match(shell, /Menu\.setApplicationMenu/);
    for (const item of ["New Session", "Open Folder…", "Export Conversation as Markdown", "Command Palette", "Settings…", "Show Panel", "Show Sessions", "Check for Updates…"]) {
      assert.ok(shell.includes(`label: "${item}"`), `the menu has "${item}"`);
    }
    assert.match(preload, /onMenu/);
    assert.match(app, /kuvo\?\.onMenu\?\./);
    // The Mac's double-click on the title bar zooms (Card.swift:186-198); on Windows, the
    // window is maximised.
    assert.match(preload, /maximize: \(\) => ipcRenderer\.send\("kuvo:maximize"\)/);
    assert.match(shell, /ipcMain\.on\("kuvo:maximize"/);
    assert.match(app, /kuvo\?\.maximize\?\.\(\)/);
    // And the code block's copy mark, which becomes a check (CodeBlockStyle.swift).
    assert.match(lib, /doc\.on\.doc/);
    assert.match(lib, /checkmark/);
  }],

  ["the session's own menu is the Mac's, in its order", ({ app, sidebar }) => {
    // The Mac's menu for a session (SidebarView.swift:600-643): pinned or not, beside the
    // one in view, its name, the folder it works in, the conversation as Markdown, put away
    // or brought back, and the one that undoes.
    const order = ["Open Beside", "Rename…", "Show in Folder", "Copy as Markdown", "Export as Markdown…", "Archive", "Delete…"];
    let last = -1;
    for (const label of order) {
      const where = app.indexOf(`"${label}"`);
      assert.ok(where > last, `the menu keeps the Mac's order (${label})`);
      last = where;
    }
    // The Mac's own words, said by the Mac itself.
    for (const label of ["Pin", "Unpin", "Open Beside", "Rename…", "Copy as Markdown", "Export as Markdown…", "Archive", "Unarchive", "Delete…"]) {
      assert.ok(sidebar.includes(`"${label}"`), `the Mac says "${label}"`);
    }
    // Pinned or not, the app says both.
    assert.ok(app.includes('"Unpin"') && app.includes('"Pin"'), "the app says Pin and Unpin");
    assert.ok(app.includes('"Unarchive"') && app.includes('"Archive"'), "the app says Archive and Unarchive");
    // The one that undoes is the Mac's own: red, and with the ellipsis that says a
    // question follows.
    assert.match(app, /label: "Delete…", danger: true/);
    // The pinned sessions sit at the top of the sidebar, in a section of their own
    // (SidebarView.swift:115-121, 513-515), and are not in the recents.
    assert.match(app, /title="Pinned"/);
    assert.match(app, /className="sessions pinned"/);
    assert.match(app, /filter\(session => session\.metadata\?\.\["kuvo\.pinned"\] !== true\)/);
  }],

  ["the window is built by Next.js, and exported as the static files the harness serves", ({ next, page, build }) => {
    // The app talks to the engine over the harness's API: there is no server to render
    // it, so the export is the whole app.
    assert.match(next, /output: "export"/);
    assert.match(next, /turbopack: \{ root:/);
    // The page draws with the DOM, so it is the browser's: the export is the shell, and
    // the app takes over when the page is alive.
    assert.match(page, /"use client"/);
    assert.match(page, /useEffect\(\(\) => setAlive\(true\)/);
    assert.match(page, /<App \/>/);
    // And the build puts the export where the harness serves it.
    assert.match(build, /ui-build/);
    assert.match(build, /out/);
  }],

  ["the shell's seams travel by the bridge, and the window pins its page", ({ preload, shell, app, overlays }) => {
    // The title bar's room for the window's controls, and the terminal's port, are the
    // shell's: they travel by the bridge, so a reload or a stray Back cannot take them
    // away (a Back used to take the address's own "?shell=1" with it).
    assert.match(preload, /isShell: true/);
    assert.match(preload, /terminalPort: ipcRenderer\.sendSync\("kuvo:terminal-port"\)/);
    assert.match(shell, /ipcMain\.on\("kuvo:terminal-port"/);
    assert.match(app, /kuvo\?\.isShell === true/);
    assert.match(overlays, /kuvo\?\.terminalPort/);
    // And the shell pins its page: the mouse's own Back and Forward, the keyboard's
    // Alt+Left and Alt+Right, and any navigation away from the harness.
    assert.match(shell, /command === 'browser-backward' \|\| command === 'browser-forward'/);
    assert.match(shell, /before-input-event/);
    assert.match(shell, /will-navigate/);
  }],

  ["a model chosen reaches the engine as its Model.ref", ({ engine, app }) => {
    // The engine takes a Model.ref — an object (OpenCodeKit's Models/Common.swift:70,
    // OpenCodeAPI.swift:473-476). The picker speaks "provider/id", and an id may hold
    // slashes of its own (OpenRouter's "anthropic/claude-sonnet-4.5"), so only the first
    // slash splits. The bare string is what the engine refused with "Expected Model.Ref
    // at [model]".
    assert.match(engine, /return \{ providerID: text\.slice\(0, slash\), id: text\.slice\(slash \+ 1\) \};/);
    assert.match(engine, /body: \{ model: ref \}/);
    // The page sends the object too, and shows the model it has at once (the Mac's
    // SessionModel.swift:1333-1341: the model shows, and a refusal puts the old one back).
    assert.match(app, /body: \{ model: ref \}/);
    assert.match(app, /current\.model = ref;/);
    assert.match(app, /current\.model = previous;/);
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
