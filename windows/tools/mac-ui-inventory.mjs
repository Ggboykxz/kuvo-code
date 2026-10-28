#!/usr/bin/env node
// Generates docs/MAC-UI-INVENTORY.md from the Mac app's Swift source.
//
// The registry in docs/MAC-UI-MAP.md is written by hand, because it carries judgement:
// what a component is for, what the Windows app does today, and what still has to be
// built. This file carries the part that must not be retyped: every design and view file,
// every SF Symbol, every animation call site and every user-facing string, each with its
// file:line, straight out of KuvoCode/.
//
//   node windows/tools/mac-ui-inventory.mjs
//
// It is deterministic: the same source produces the same document.

import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("../../", import.meta.url));
const SWIFT = join(ROOT, "KuvoCode");
const OUT = join(ROOT, "docs", "MAC-UI-INVENTORY.md");

function walk(dir) {
  const found = [];
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) found.push(...walk(path));
    else if (name.endsWith(".swift")) found.push(path);
  }
  return found.sort();
}

const files = walk(SWIFT);
const rel = (path) => relative(ROOT, path);
const lines = (path) => readFileSync(path, "utf8").split("\n");

function docLine(path) {
  for (const line of lines(path)) {
    const match = line.match(/^\/\/\/\s?(.+)$/);
    if (match) return match[1].trim();
  }
  return "";
}

function count(path) {
  const text = readFileSync(path, "utf8");
  return text.split("\n").length - (text.endsWith("\n") ? 1 : 0);
}

// A table cell: pipes and backticks must not break the row.
const cell = (text) => String(text).replace(/\|/g, "\\|").replace(/`/g, "\\`").trim();
const code = (text) => "`" + String(text).replace(/`/g, "'") + "`";

// ---------------------------------------------------------------------------
// Design/ and Views/ inventory

const design = files.filter((path) => path.includes("/Design/"));
const views = files.filter((path) => path.includes("/Views/"));
const app = files.filter((path) => path.includes("/App/"));
const stores = files.filter((path) => path.includes("/Stores/"));

function fileTable(list, base) {
  const rows = list.map((path) => {
    const name = relative(base, path);
    return `| ${code(name)} | ${count(path)} | ${cell(docLine(path))} |`;
  });
  return [
    "| File | Lines | Purpose (first doc line) |",
    "| --- | ---: | --- |",
    ...rows,
  ].join("\n");
}

// ---------------------------------------------------------------------------
// SF Symbols, with every use site

const symbolSites = new Map();
for (const path of files) {
  const text = readFileSync(path, "utf8");
  const finding = /(?:systemName|systemImage):\s*"([^"]+)"/g;
  let match;
  while ((match = finding.exec(text))) {
    const before = text.slice(0, match.index);
    const line = before.split("\n").length;
    const name = match[1];
    if (!symbolSites.has(name)) symbolSites.set(name, []);
    symbolSites.get(name).push(`${rel(path)}:${line}`);
  }
}
const symbols = [...symbolSites.entries()].sort((a, b) => b[1].length - a[1].length || a[0].localeCompare(b[0]));
const symbolUses = symbols.reduce((total, [, sites]) => total + sites.length, 0);

function symbolTable() {
  const rows = symbols.map(([name, sites]) => {
    const uniqueFiles = [...new Set(sites.map((site) => site.replace(/:\d+$/, "")))];
    return `| ${code(name)} | ${sites.length} | ${uniqueFiles.map(cell).join("<br>")} |`;
  });
  return [
    "| Symbol | Uses | Files |",
    "| --- | ---: | --- |",
    ...rows,
  ].join("\n");
}

// ---------------------------------------------------------------------------
// Motion call sites

const MOTION = /(withAnimation\(|\.animation\(|\.spring\(|\.snappy\(|\.bouncy\(|\.smooth\(|\.easeInOut\(|\.easeOut\(|\.easeIn\(|\.linear\(|\.timingCurve\(|\.keyframeAnimator|\.phaseAnimator|matchedGeometryEffect|symbolEffect|contentTransition|transition\()/;

const motion = [];
for (const path of files) {
  const text = readFileSync(path, "utf8");
  text.split("\n").forEach((line, index) => {
    if (MOTION.test(line)) motion.push({ site: `${rel(path)}:${index + 1}`, text: line.trim() });
  });
}

function motionList() {
  return motion.map(({ site, text }) => `- ${code(site)} — ${code(text)}`).join("\n");
}

// ---------------------------------------------------------------------------
// User-facing strings, with every use site

const STRING = /(?:Text|Button|Label|Toggle|Picker|Section|TextField|SecureField|Link|help|accessibilityLabel|prompt|title|placeholder|subtitle|detail|name)\s*\(\s*"((?:[^"\\]|\\.)*)"/g;
const PROPERTY = /(?:title|detail|prompt|placeholder|name|subtitle|label):\s*"((?:[^"\\]|\\.)*)"/g;

const strings = [];
for (const path of files) {
  const text = readFileSync(path, "utf8");
  text.split("\n").forEach((line, index) => {
    for (const finding of [STRING, PROPERTY]) {
      finding.lastIndex = 0;
      let match;
      while ((match = finding.exec(line))) {
        const value = match[1];
        if (!value || value.length < 2) continue;
        strings.push({ site: `${rel(path)}:${index + 1}`, value });
      }
    }
  });
}
strings.sort((a, b) => a.site.localeCompare(b.site) || a.value.localeCompare(b.value));

function stringList() {
  return strings.map(({ site, value }) => `- ${code(site)} — “${value}”`).join("\n");
}

const uniqueStrings = new Set(strings.map((item) => item.value));

// ---------------------------------------------------------------------------
// Drawn artwork (custom shapes, canvases and paths)

const artwork = [];
for (const path of files) {
  lines(path).forEach((line, index) => {
    const site = `${rel(path)}:${index + 1}`;
    const shape = line.match(/(?:struct|enum)\s+(\w+)\s*:\s*(?:Shape|InsettableShape)/);
    if (shape) artwork.push({ site, kind: "Shape", name: shape[1] });
    if (/\bCanvas\s*\{/.test(line)) artwork.push({ site, kind: "Canvas", name: "" });
  });
}

function artworkTable() {
  const rows = artwork.map(({ site, kind, name }) => `| ${kind} | ${code(name || "—")} | ${code(site)} |`);
  return [
    "| Kind | Type | Site |",
    "| --- | --- | --- |",
    ...rows,
  ].join("\n");
}

// ---------------------------------------------------------------------------
// Settings pages, Mac and Windows

const settingsSource = readFileSync(join(SWIFT, "Views", "SettingsView.swift"), "utf8");
const settingsEnum = settingsSource.match(/enum SettingsPage[\s\S]*?\n\s*var id/)?.[0] ?? "";
const settingsCases = [];
for (const line of settingsEnum.split("\n")) {
  const match = line.match(/^\s*case\s+(.+)$/);
  if (!match) continue;
  for (const name of match[1].split(",").map((part) => part.trim())) {
    if (/^[a-z][a-z0-9]*$/.test(name)) settingsCases.push(name);
  }
}
const macPages = [...new Set(settingsCases)];

let windowsPages = [];
try {
  const settingsTsx = readFileSync(join(ROOT, "windows", "app", "src", "Settings.tsx"), "utf8");
  const block = settingsTsx.match(/const PAGES = \[([\s\S]*?)\] as const;/);
  if (block) {
    windowsPages = [...block[1].matchAll(/\[\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\]/g)].map((match) => `${match[1]} — ${match[2]}`);
  }
} catch {
  windowsPages = ["(windows/app/src/Settings.tsx not found)"];
}

// ---------------------------------------------------------------------------
// Write

const generated = new Date().toISOString().slice(0, 10);

const document = `# Mac UI inventory — generated from the Swift source

Generated on ${generated} by \`windows/tools/mac-ui-inventory.mjs\` from the source of
truth, \`KuvoCode/\`. **Do not edit by hand**; run the tool again. The registry that reads
this inventory — what each piece is, what the Windows app does today, and what remains —
is \`docs/MAC-UI-MAP.md\`.

Scope: ${files.length} Swift files under \`KuvoCode/\` (${design.length} in \`Design/\`,
${views.length} in \`Views/\`, ${app.length} in \`App/\`, ${stores.length} in \`Stores/\`).
Every row below cites its site as \`file:line\`.

## 1. Design files (${design.length})

${fileTable(design, join(SWIFT, "Design"))}

## 2. View files (${views.length})

${fileTable(views, join(SWIFT, "Views"))}

## 3. SF Symbols (${symbols.length} unique, ${symbolUses} uses)

${symbolTable()}

## 4. Motion call sites (${motion.length})

Every line that starts an animation, a transition, or a matched-geometry effect. The
values they use, and the CSS equivalents, are catalogued in \`docs/MAC-UI-MAP.md\` §4.

${motionList()}

## 5. User-facing strings (${strings.length} sites, ${uniqueStrings.size} distinct)

Extracted from \`Text\`, \`Button\`, \`Label\`, \`Toggle\`, \`Picker\`, \`Section\`,
\`TextField\`, \`SecureField\`, \`Link\`, \`.help\`, \`.accessibilityLabel\`, prompts and
titles, plus \`title:\`/\`detail:\`/\`name:\` properties. Strings built at runtime by
interpolation are included with their interpolation left visible.

${stringList()}

## 6. Drawn artwork (${artwork.length})

The Shape and Canvas declarations found by the scan. The hand-written list of all drawn
artwork — including the avatar views, whose drawing is not a single Shape — is in
\`docs/MAC-UI-MAP.md\` §7.

${artworkTable()}

## 7. Settings pages

Mac, in \`SettingsPage\` (\`KuvoCode/Views/SettingsView.swift\`): ${macPages.length}.

${macPages.map((page) => `- \`${page}\``).join("\n")}

Windows, in \`PAGES\` (\`windows/app/src/Settings.tsx\`): ${windowsPages.length}.

${windowsPages.map((page) => `- ${page}`).join("\n")}
`;

writeFileSync(OUT, document);
console.log(`Wrote ${relative(ROOT, OUT)}: ${design.length} design files, ${views.length} views, ${symbols.length} symbols (${symbolUses} uses), ${motion.length} motion sites, ${strings.length} string sites (${uniqueStrings.size} distinct), ${artwork.length} drawn types.`);
