#!/usr/bin/env node
// Measures the page's own colour tokens against WCAG 2.1 AA, the promise the design makes:
// every ink the page writes with, on every surface it writes on, reads at 4.5:1 or better.
//
// The tokens are read from windows/harness/ui/style.css, not copied here, and in the order the
// cascade applies them: the direction's `:root`, then the Mac binding's `:root` that wins over
// it. The dark ground is the light one with the dark media block and `html[data-theme="dark"]`
// laid over it, as the page gets it. Inks written with an alpha are composited over the surface
// they sit on before they are measured.
//
// Borders (`--line`, `--line-soft`) are hairlines that show a card's shape, never the only sign
// of a control, so they are not text and are not held to 4.5:1; the shapes they draw are also
// carried by the surfaces' own difference in lightness.
//
//   node windows/tools/contrast-check.mjs
//
// Exits 1 when a pair falls short, so `node windows/tools/verify.mjs` can run it.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const stylesheet = path.join(here, "..", "harness", "ui", "style.css");
const css = fs.readFileSync(stylesheet, "utf8").replace(/\/\*[\s\S]*?\*\//g, "");

// ---- Reading the stylesheet's rules, in source order ----

/** Every style rule, with the media queries it sits inside. */
function rulesIn(text, media = "") {
  const rules = [];
  let at = 0;
  while (at < text.length) {
    const open = text.indexOf("{", at);
    if (open === -1) break;
    const selector = text.slice(at, open).trim();
    let depth = 1;
    let end = open + 1;
    for (; end < text.length && depth > 0; end += 1) {
      if (text[end] === "{") depth += 1;
      else if (text[end] === "}") depth -= 1;
    }
    const body = text.slice(open + 1, end - 1);
    if (selector.startsWith("@media") || selector.startsWith("@supports")) {
      rules.push(...rulesIn(body, `${media} ${selector}`.trim()));
    } else if (!selector.startsWith("@")) {
      rules.push({ selector, body, media });
    }
    at = end;
  }
  return rules;
}

const rules = rulesIn(css);

function declarations(body) {
  const found = {};
  for (const line of body.split(";")) {
    const match = line.match(/^\s*(--[A-Za-z0-9-]+)\s*:\s*([\s\S]+?)\s*$/);
    if (match) found[match[1]] = match[2].replace(/\s+/g, " ").trim();
  }
  return found;
}

const rootRules = rules.filter(rule => rule.media === "" && rule.selector === ":root");
if (rootRules.length === 0) throw new Error("no :root block in ui/style.css");
const light = Object.assign({}, ...rootRules.map(rule => declarations(rule.body)));

// The dark ground: what the system's dark scheme lays over the light tokens, then the app's
// own `data-theme="dark"` (which holds the same values, so the two choices look alike).
const dark = { ...light };
for (const rule of rules) {
  if (/prefers-color-scheme:\s*dark/.test(rule.media) && /^html:not\(\[data-theme="light"\]\)$/.test(rule.selector)) {
    Object.assign(dark, declarations(rule.body));
  }
}
for (const rule of rules) {
  if (rule.media === "" && rule.selector === 'html[data-theme="dark"]') {
    Object.assign(dark, declarations(rule.body));
  }
}

// A narrow window has a palette of its own, laid over the light one (the dark blocks have a
// higher specificity and still win there, so narrow dark is the dark ground).
const narrow = { ...light };
for (const rule of rules) {
  if (/max-width:\s*760px/.test(rule.media) && !/prefers-color-scheme:\s*dark/.test(rule.media) && rule.selector === ":root") {
    Object.assign(narrow, declarations(rule.body));
  }
}

// ---- Colours, as sRGB with an alpha ----

function oklchToRgb(l, c, h) {
  const radians = (h * Math.PI) / 180;
  const a = c * Math.cos(radians);
  const b = c * Math.sin(radians);
  const l2 = l + 0.3963377774 * a + 0.2158037573 * b;
  const m = l - 0.1055613458 * a - 0.0638541728 * b;
  const s = l - 0.0894841775 * a - 1.291485548 * b;
  const [l3, m3, s3] = [l2 ** 3, m ** 3, s ** 3];
  const linear = [
    4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
    -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
    -0.0041960863 * l3 - 0.7034186147 * m3 + 1.707614701 * s3,
  ];
  const toSrgb = value => (value <= 0.0031308 ? 12.92 * value : 1.055 * value ** (1 / 2.4) - 0.055);
  return linear.map(value => Math.round(Math.max(0, Math.min(1, toSrgb(value))) * 255));
}

function hexToRgb(hex) {
  const digits = hex.length <= 5
    ? [...hex.slice(1)].map(digit => digit + digit)
    : hex.slice(1).match(/../g);
  const [r, g, b, a] = digits.map(pair => parseInt(pair, 16));
  return { rgb: [r, g, b], alpha: a === undefined ? 1 : a / 255 };
}

/** A token's colour, following `var(--x)` to what it names. null for what can't be measured
 *  here: `color-mix`, a gradient, a shadow. */
function colourOf(tokens, name, seen = new Set()) {
  if (seen.has(name)) return null;
  seen.add(name);
  const value = tokens[name];
  if (typeof value !== "string") return null;
  const reference = value.match(/^var\((--[A-Za-z0-9-]+)\)$/);
  if (reference) return colourOf(tokens, reference[1], seen);
  const oklch = value.match(/^oklch\(([\d.]+)%\s+([\d.]+)\s+([\d.]+)(?:\s*\/\s*([\d.]+))?\)$/);
  if (oklch) {
    return {
      rgb: oklchToRgb(Number(oklch[1]) / 100, Number(oklch[2]), Number(oklch[3])),
      alpha: oklch[4] === undefined ? 1 : Number(oklch[4]),
    };
  }
  const rgba = value.match(/^rgba?\(([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:[,\s/]+([\d.]+))?\)$/);
  if (rgba) {
    return { rgb: [Number(rgba[1]), Number(rgba[2]), Number(rgba[3])], alpha: rgba[4] === undefined ? 1 : Number(rgba[4]) };
  }
  if (/^#[0-9a-fA-F]{3,8}$/.test(value)) return hexToRgb(value);
  return null;
}

/** A colour laid over an opaque one, as the screen shows it. */
function over(colour, ground) {
  if (colour.alpha >= 1) return colour.rgb;
  return colour.rgb.map((channel, at) => Math.round(channel * colour.alpha + ground[at] * (1 - colour.alpha)));
}

function luminance([r, g, b]) {
  const toLinear = value => (value / 255 <= 0.04045 ? value / 255 / 12.92 : ((value / 255 + 0.055) / 1.055) ** 2.4);
  return 0.2126 * toLinear(r) + 0.7152 * toLinear(g) + 0.0722 * toLinear(b);
}

function ratio(one, two) {
  const [a, b] = [luminance(one), luminance(two)];
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}

// ---- What the page writes with, and where ----

const inks = ["--ink", "--ink-soft", "--ink-faint", "--accent", "--ok", "--warn", "--danger"];
const AA = 4.5;

let failed = 0;
for (const [ground, tokens] of [["light", light], ["light, narrow", narrow], ["dark", dark]]) {
  console.log(`\n=== ${ground} ===`);
  const missing = [...inks, "--accent-ink", "--bg", "--panel", "--panel-2", "--code-bg"].filter(name => !colourOf(tokens, name));
  if (missing.length) {
    console.log(`  can't be measured (no plain colour): ${missing.join(", ")}`);
    failed += missing.length;
    continue;
  }
  // The ground is opaque; a panel sits on it, and the code well on a panel.
  const bg = over(colourOf(tokens, "--bg"), [255, 255, 255]);
  const surfaces = {
    "--bg": bg,
    "--panel": over(colourOf(tokens, "--panel"), bg),
    "--panel-2": over(colourOf(tokens, "--panel-2"), bg),
    "--code-bg": over(colourOf(tokens, "--code-bg"), over(colourOf(tokens, "--panel"), bg)),
  };
  for (const [surface, behind] of Object.entries(surfaces)) {
    for (const ink of inks) {
      const measured = ratio(over(colourOf(tokens, ink), behind), behind);
      const pass = measured >= AA;
      if (!pass) failed += 1;
      console.log(`  ${ink.padEnd(13)} on ${surface.padEnd(9)} ${measured.toFixed(2)}:1  ${pass ? "ok" : "SHORT"}`);
    }
  }
  // The label on a filled button is ink on the accent, not on a surface.
  const accent = over(colourOf(tokens, "--accent"), bg);
  const label = ratio(over(colourOf(tokens, "--accent-ink"), accent), accent);
  const labelPass = label >= AA;
  if (!labelPass) failed += 1;
  console.log(`  --accent-ink  on --accent   ${label.toFixed(2)}:1  ${labelPass ? "ok" : "SHORT"}`);
}

if (failed) {
  console.log(`\n${failed} pair${failed === 1 ? "" : "s"} fall short of ${AA}:1.`);
  process.exit(1);
}
console.log(`\nAll ${(inks.length * 4 + 1) * 3} pairs read at ${AA}:1 or better.`);
