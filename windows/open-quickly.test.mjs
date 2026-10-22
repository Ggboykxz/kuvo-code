// Open Quickly's ranking, without a browser: the Mac's Mentions.matches over a project's
// files (Mentions.swift:21-45), with the newest first when nothing is typed.

import assert from "node:assert/strict";
import { test } from "node:test";

import { openQuicklyMatches } from "./app/src/open-quickly.mjs";

const files = [
  { name: "notes.txt", relative: "notes.txt" },
  { name: "README.md", relative: "README.md" },
  { name: "App.tsx", relative: "src/App.tsx" },
  { name: "App.test.tsx", relative: "src/App.test.tsx" },
  { name: "app.ts", relative: "examples/app.ts" },
  { name: "licence.md", relative: "legal/licence.md" },
];

test("with nothing typed the newest ten are offered, in order", () => {
  assert.deepEqual(openQuicklyMatches("", files).map(file => file.name), files.map(file => file.name));
  assert.equal(openQuicklyMatches("", files, 3).length, 3);
});

test("the name itself comes first, then its start, then anywhere, then the path", () => {
  assert.deepEqual(openQuicklyMatches("app.tsx", files).map(file => file.name), ["App.tsx"]);
  assert.deepEqual(openQuicklyMatches("app", files).map(file => file.name), ["app.ts", "App.tsx", "App.test.tsx"]);
  assert.deepEqual(openQuicklyMatches("readme", files).map(file => file.name), ["README.md"]);
  assert.deepEqual(openQuicklyMatches("legal", files).map(file => file.name), ["licence.md"], "a folder in the path");
});

test("the Mac's ties: folder, shorter path, then path", () => {
  const tied = [
    { name: "App.tsx", relative: "z/App.tsx" },
    { name: "App.tsx", relative: "a/App.tsx" },
    { name: "App.tsx", relative: "App.tsx" },
  ];
  assert.deepEqual(openQuicklyMatches("app.tsx", tied).map(file => file.relative), ["App.tsx", "a/App.tsx", "z/App.tsx"]);
});

test("nothing matches means nothing is offered", () => {
  assert.deepEqual(openQuicklyMatches("zzz", files), []);
});
