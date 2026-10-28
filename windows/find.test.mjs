// What a find finds — every occurrence, in order, so the conversation can mark each one
// and step through them. The count and the marks come from the same ranges; before, the
// count saw every occurrence and the highlighter saw only the first in each text node.
//
//   node --test windows/find.test.mjs

import assert from "node:assert/strict";
import { test } from "node:test";

import { countOf, findRanges } from "./app/src/find.mjs";

test("every occurrence is found, in order", () => {
  assert.deepEqual(findRanges("one two one", "one"), [
    { start: 0, end: 3 },
    { start: 8, end: 11 },
  ]);
});

test("the search ignores case and keeps the text's own letters", () => {
  const text = "Kuvo Code and KUVO code";
  assert.deepEqual(findRanges(text, "kuvo"), [
    { start: 0, end: 4 },
    { start: 14, end: 18 },
  ]);
  assert.equal(text.slice(0, 4), "Kuvo");
});

test("matches next to each other do not overlap", () => {
  assert.deepEqual(findRanges("aaaa", "aa"), [
    { start: 0, end: 2 },
    { start: 2, end: 4 },
  ]);
});

test("a query shorter than two characters finds nothing", () => {
  assert.deepEqual(findRanges("a conversation", "a"), []);
  assert.deepEqual(findRanges("a conversation", ""), []);
  assert.equal(countOf("a conversation", "a"), 0);
});

test("a query that is not there is no range at all", () => {
  assert.deepEqual(findRanges("nothing here", "elsewhere"), []);
  assert.equal(countOf("nothing here", "elsewhere"), 0);
});

test("the count is the number of ranges", () => {
  const text = "read a file, then read another file";
  assert.equal(countOf(text, "read"), findRanges(text, "read").length);
  assert.equal(countOf(text, "read"), 2);
  assert.equal(countOf(text, "file"), 2);
});
