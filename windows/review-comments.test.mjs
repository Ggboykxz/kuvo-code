// A comment on a line of the changes — the Mac's own rules and the block it travels in —
// checked here, without a browser: where a comment belongs, how it is written, and the
// block a message carries its comments in.
//
//   node --test windows/review-comments.test.mjs

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import {
  BLOCK_END,
  BLOCK_HEADING,
  BLOCK_START,
  commentLocation,
  commentMatches,
  commentsText,
  escapeBlock,
} from "./app/src/review-comments.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, "..");
const mac = (...parts) => fs.readFileSync(path.join(root, ...parts), "utf8");

// A comment on a line, and the line it was written on.
const comment = { id: "1", file: "src/app.ts", line: 12, side: "new", snippet: "const added = 3;", text: "why is this here?" };
const line = { kind: "added", newNumber: 12, oldNumber: undefined, text: "const added = 3;" };

// ---- Where a comment belongs ----

test("a comment belongs to its line: the same side, the same number, the same text", () => {
  assert.equal(commentMatches(comment, line), true, "the line it was written on");
  // A different number is a different line.
  assert.equal(commentMatches({ ...comment, line: 13 }, line), false, "another line's number");
  // Another side is another line.
  assert.equal(commentMatches({ ...comment, side: "old" }, line), false, "the other side");
  // And the text: once the file has changed, the comment stays with the line it was written
  // on, and not with the place (ChangesPanel.swift:873-880).
  assert.equal(commentMatches(comment, { ...line, text: "const added = 4;" }), false, "another line's text");
  // A removed line is on the old side, and its number is the old one.
  assert.equal(
    commentMatches({ ...comment, side: "old", line: 11, snippet: "const removed = 2;" }, { kind: "removed", oldNumber: 11, newNumber: undefined, text: "const removed = 2;" }),
    true,
    "a removed line",
  );
});

test("the Mac's own rule is the one we keep", () => {
  const panel = mac("KuvoCode", "Views", "Session", "ChangesPanel.swift");
  assert.match(
    panel,
    /side == \(line\.kind == \.removed \? \.old : \.new\) && self\.line == line\.number\n\s*&& line\.text\.trimmingCharacters\(in: \.whitespaces\) == snippet/,
  );
});

// ---- Where a comment points ----

test("a comment's place is the path and the line, and a removed line says so", () => {
  assert.equal(commentLocation(comment), "src/app.ts:12");
  assert.equal(commentLocation({ ...comment, side: "old" }), "src/app.ts:12 (removed)");
  const store = mac("KuvoCode", "Stores", "ReviewComments.swift");
  assert.match(store, /var location: String \{ "\\\(file\):\\\(line\)" \+ \(side == \.old \? " \(removed\)" : ""\) \}/);
});

// ---- The block the comments travel in ----

test("the comments go to the agent in a block of their own", () => {
  const sent = commentsText("please look at this", [comment]);
  assert.equal(
    sent,
    [
      "please look at this",
      "",
      BLOCK_START,
      BLOCK_HEADING,
      "",
      "[src/app.ts:12]",
      "> const added = 3;",
      "why is this here?",
      BLOCK_END,
    ].join("\n"),
  );
});

test("a removed line's comment says it was removed", () => {
  const sent = commentsText("", [{ ...comment, side: "old", line: 11, snippet: "const removed = 2;" }]);
  assert.match(sent, /\[src\/app\.ts:11 \(removed\)\]/);
  assert.match(sent, /> const removed = 2;/);
  // With no words of its own, the block stands alone.
  assert.ok(sent.startsWith(BLOCK_START), "the block is the whole message");
});

test("no comments, no block: the words are sent as they are", () => {
  assert.equal(commentsText("just this", []), "just this");
});

test("a message copied from another one cannot be read as a block", () => {
  // The Mac escapes a text that would end with the block, so the model reads the words
  // (MessageBlock.swift:20-24).
  const copied = `look at this\n\n${BLOCK_START}\n${BLOCK_HEADING}\n\n[src/app.ts:12]\n> const added = 3;\nwhy is this here?\n${BLOCK_END}`;
  const escaped = escapeBlock(copied);
  assert.ok(escaped.includes(`${BLOCK_START} `), "the tag gets a space after it");
  assert.ok(!escaped.includes(`${BLOCK_START}\n`), "the block's own opening is broken");
  // And the words are sent as they are when there are no comments.
  assert.equal(commentsText(copied, []), escaped);
});

test("the Mac's block and heading are the ones we send", () => {
  const store = mac("KuvoCode", "Stores", "ReviewComments.swift");
  assert.match(store, /private static let intro = "Comments on lines of the current changes:"/);
  assert.match(store, /private static let block = MessageBlock\(start: "<review-comments>", end: "<\/review-comments>", headings: \[intro\]\)/);
  assert.equal(BLOCK_START, "<review-comments>");
  assert.equal(BLOCK_END, "</review-comments>");
  assert.equal(BLOCK_HEADING, "Comments on lines of the current changes:");
});
