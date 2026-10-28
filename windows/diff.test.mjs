// The diff's own lines — a patch read as the rows the Mac shows — checked here, without a
// browser: the kinds of line, the number in the gutter, the side a line is on, and the
// width of the gutter.
//
//   node --test windows/diff.test.mjs

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import { diffGutterWidth, diffNumber, diffSide, foldRows, parsePatch } from "./app/src/diff.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, "..");
// The Mac's source, read with the line endings put to one: a rule read as text must not
// depend on whether the file was checked out on Windows or on a Mac.
const mac = (...parts) => fs.readFileSync(path.join(root, ...parts), "utf8").replace(/\r\n/g, "\n");

// A patch as git writes it: the headers, a hunk, and the lines of the change.
const PATCH = [
  "diff --git a/src/app.ts b/src/app.ts",
  "index 1234567..89abcde 100644",
  "--- a/src/app.ts",
  "+++ b/src/app.ts",
  "@@ -10,4 +10,5 @@ export function main() {",
  " const before = 1;",
  "-const removed = 2;",
  "+const added = 3;",
  "+const addedToo = 4;",
  " const after = 5;",
].join("\n");

// ---- The rows ----

test("the headers git writes are not rows of the change", () => {
  const rows = parsePatch(PATCH);
  assert.equal(rows.length, 5);
  for (const row of rows) {
    assert.ok(!row.text.startsWith("diff --git"), "no file line");
    assert.ok(!row.text.startsWith("index "), "no index line");
    assert.ok(!row.text.startsWith("+++"), "no new file line");
    assert.ok(!row.text.startsWith("---"), "no old file line");
    assert.ok(!row.text.startsWith("@@"), "no hunk header");
  }
});

test("a row is the Mac's: a kind, a number on each side, and the text", () => {
  const rows = parsePatch(PATCH);
  assert.deepEqual(rows.map(row => row.kind), ["context", "removed", "added", "added", "context"]);
  // The text is the line as it reads, without the patch's sign.
  assert.deepEqual(rows.map(row => row.text), [
    "const before = 1;",
    "const removed = 2;",
    "const added = 3;",
    "const addedToo = 4;",
    "const after = 5;",
  ]);
  // The numbers: the hunk starts at 10 on both sides.
  assert.equal(rows[0].oldNumber, 10);
  assert.equal(rows[0].newNumber, 10);
  assert.equal(rows[1].oldNumber, 11);
  assert.equal(rows[1].newNumber, undefined);
  assert.equal(rows[2].oldNumber, undefined);
  assert.equal(rows[2].newNumber, 11);
  assert.equal(rows[4].newNumber, 13);
});

test("the number in the gutter is the old one for a removed line, the new one otherwise", () => {
  const rows = parsePatch(PATCH);
  assert.deepEqual(rows.map(diffNumber), [10, 11, 11, 12, 13]);
});

test("a line is on the old side when it was removed, and on the new one otherwise", () => {
  const rows = parsePatch(PATCH);
  assert.deepEqual(rows.map(diffSide), ["new", "old", "new", "new", "new"]);
});

test("the gutter is as wide as the widest number, and 22 more", () => {
  // The Mac's own: a character for the widest number, and 22 more
  // (ChangesPanel.swift:968-971).
  assert.equal(diffGutterWidth(parsePatch(PATCH)), 2 * 7.5 + 22);
  assert.equal(diffGutterWidth([]), 7.5 + 22);
});

// ---- Folding ----

/// A patch with a long run of unchanged lines between two changes.
const LONG = [
  "diff --git a/long.txt b/long.txt",
  "--- a/long.txt",
  "+++ b/long.txt",
  "@@ -1,12 +1,12 @@",
  ...Array.from({ length: 10 }, (_, index) => ` line ${index + 1}`),
  "-old line",
  "+new line",
].join("\n");

test("the long unchanged stretches are folded, with three lines kept on each side", () => {
  const rows = foldRows(parsePatch(LONG), [], "long.txt");
  // The change, three lines before it and three after it, and the fold between.
  const folds = rows.filter(row => row.kind === "fold");
  assert.equal(folds.length, 1, "one fold");
  assert.equal(folds[0].count, 7, "the fold holds the seven lines before the change");
  assert.equal(folds[0].id, "long.txt#fold0", "the fold belongs to its file");
  // The three lines before the change are kept, and the change itself is shown.
  const shown = rows.filter(row => row.kind === "line").map(row => row.index);
  assert.deepEqual(shown, [7, 8, 9, 10, 11], "three lines are kept before the change");
});

test("a fold that is open shows its lines again", () => {
  const rows = foldRows(parsePatch(LONG), ["long.txt#fold0"], "long.txt");
  assert.equal(rows.filter(row => row.kind === "fold").length, 0, "no fold row");
  assert.equal(rows.filter(row => row.kind === "line").length, 12, "every line is shown");
});

test("a short run of unchanged lines is not folded", () => {
  const rows = foldRows(parsePatch(PATCH), [], "notes.txt");
  assert.equal(rows.filter(row => row.kind === "fold").length, 0, "nothing to fold");
  assert.equal(rows.filter(row => row.kind === "line").length, 5, "every line is shown");
});

test("the lines between two hunks are a gap", () => {
  const two = [
    "--- a/two.txt",
    "+++ b/two.txt",
    "@@ -1,2 +1,2 @@",
    " one",
    "-two",
    "@@ -20,2 +20,2 @@",
    " twenty",
    "+twenty one",
  ].join("\n");
  const lines = parsePatch(two);
  // The line after the second hunk says the ones before it are not in the patch
  // (ProjectChanges.swift:503).
  assert.equal(lines[2].gapBefore, true, "the gap is marked");
  assert.equal(lines[0].gapBefore, undefined, "the first line has no gap before it");
  // And the rows keep the gap as a row of its own (ChangesPanel.swift:903).
  const rows = foldRows(lines, [], "two.txt");
  assert.equal(rows.filter(row => row.kind === "gap").length, 1, "the gap is a row");
});

test("the Mac's own rule is the one we keep", () => {
  const panel = mac("KuvoCode", "Views", "Session", "ChangesPanel.swift");
  assert.match(panel, /static let context = 3/);
  assert.match(panel, /if foldEnd - foldStart > 3, !expanded\.contains\(foldID\)/);
  assert.ok(panel.includes('Text("\\(count) unmodified lines")'), "the fold row says how many lines");
  assert.ok(panel.includes('help(count == nil ? "" : "Show these lines")'), "the fold row's help");
});

// ---- The rules, held to the Mac's own source ----

test("the kinds of line are the Mac's own", () => {
  const source = mac("KuvoCode", "Stores", "ProjectChanges.swift");
  assert.match(source, /enum Kind: Sendable \{ case context, added, removed \}/);
  // And the number the gutter shows is the old one for a removed line
  // (ChangesPanel.swift:882-885).
  const panel = mac("KuvoCode", "Views", "Session", "ChangesPanel.swift");
  assert.match(panel, /var number: Int \{ \(kind == \.removed \? oldNumber : newNumber\) \?\? 0 \}/);
});

test("the Mac's rows carry a number on each side and a text", () => {
  const source = mac("KuvoCode", "Stores", "ProjectChanges.swift");
  assert.match(source, /var oldNumber: Int\?/);
  assert.match(source, /var newNumber: Int\?/);
  assert.match(source, /var text: String/);
});

test("the app's rows are the Mac's: the gutter, the text and the edge", () => {
  const css = mac("windows", "harness", "ui", "style.css");
  // The gutter holds the number, and the text sits 8 pt after it.
  assert.match(css, /\.diff-line \.diff-number \{[^}]*width: calc\(var\(--gutter/);
  assert.match(css, /\.diff-line \.diff-text \{[^}]*padding-left: 8px/);
  // A line that changed carries a 3 pt edge, as the Mac's does.
  assert.match(css, /\.diff-line\.add \{[^}]*inset 3px 0 0 var\(--ok\)/);
  assert.match(css, /\.diff-line\.del \{[^}]*inset 3px 0 0 var\(--danger\)/);
  // And the mark that writes a comment on the line is the Mac's, in the gutter.
  const panel = mac("KuvoCode", "Views", "Session", "ChangesPanel.swift");
  assert.match(panel, /\.help\("Comment on This Line"\)/);
  assert.match(css, /\.diff-comment \{[^}]*left: 2px/);
});
