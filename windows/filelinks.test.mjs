// The Mac app's file links, checked here: which code span names a file of the project, and
// the label the link shows.
//
//   node --test windows/filelinks.test.mjs

import assert from "node:assert/strict";
import { test } from "node:test";

import { fileIn } from "./app/src/filelinks.mjs";

const files = ["notes.txt", "src/App.tsx", "src/lib/store.ts", "api/README.md", "package.json"];

test("a code span that names a file of the project is a link", () => {
  assert.deepEqual(fileIn("src/App.tsx", files), { path: "src/App.tsx", label: "App.tsx", line: null });
  assert.deepEqual(fileIn("notes.txt", files), { path: "notes.txt", label: "notes.txt", line: null });
  // A file of a folder, named the way "@" writes it.
  assert.deepEqual(fileIn("api/README.md", files), { path: "api/README.md", label: "README.md", line: null });
});

test("the line a span ends with is kept, and the label is the name", () => {
  assert.deepEqual(fileIn("src/App.tsx:42", files), { path: "src/App.tsx", label: "App.tsx:42", line: 42 });
  assert.deepEqual(fileIn("src/App.tsx:12-20", files), { path: "src/App.tsx", label: "App.tsx:12", line: 12 });
  assert.deepEqual(fileIn("src/App.tsx#L12", files), { path: "src/App.tsx", label: "App.tsx:12", line: 12 });
});

test("a span that names nothing is left alone", () => {
  assert.equal(fileIn("const answer = 42", files), null, "a sentence is not a path");
  assert.equal(fileIn("https://example.com/app.tsx", files), null, "an address is not a path");
  assert.equal(fileIn("1.2.3", files), null, "a version is not a path");
  assert.equal(fileIn("..", files), null, "a name has a letter in it");
  assert.equal(fileIn("src/Unknown.tsx", files), null, "the file is not in the project");
  assert.equal(fileIn("", files), null);
});

test("the project's files are what the link is made of", () => {
  assert.equal(fileIn("notes.txt", []), null, "with no files, nothing is a link");
  assert.deepEqual(fileIn("src/App.tsx", ["src/App.tsx"]), { path: "src/App.tsx", label: "App.tsx", line: null });
});
