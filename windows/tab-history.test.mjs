// The tab history, without a browser: where a closed tab comes back, which tab takes its
// place, and the keys that walk the strip. The Mac's own numbers (MainView.swift:1150-1232).

import assert from "node:assert/strict";
import { test } from "node:test";

import { MAX_CLOSED_TABS, cycledTab, rememberClosed, tabAfterClose, tabAt, takeClosed } from "./app/src/tab-history.mjs";

test("a closed tab is remembered where it was, and the last one closed comes back first", () => {
  let closed = rememberClosed([], [{ id: "b", index: 1 }]);
  closed = rememberClosed(closed, [{ id: "c", index: 2 }]);
  assert.deepEqual(closed, [{ id: "b", index: 1 }, { id: "c", index: 2 }]);
  const taken = takeClosed(closed, ["a"], id => ["a", "b", "c"].includes(id));
  assert.deepEqual(taken.entry, { id: "c", index: 2 }, "the last one closed");
  assert.deepEqual(taken.closed, [{ id: "b", index: 1 }], "the rest waits its turn");
});

test("the stack keeps fifty, as the Mac does", () => {
  const many = Array.from({ length: 60 }, (_, index) => ({ id: `s${index}`, index }));
  const kept = rememberClosed([], many);
  assert.equal(kept.length, MAX_CLOSED_TABS);
  assert.equal(kept[0].id, "s10", "the oldest ten have fallen off");
  assert.equal(kept.at(-1).id, "s59");
});

test("a tab open again, or a session deleted since, is skipped", () => {
  const closed = [{ id: "a", index: 0 }, { id: "b", index: 1 }, { id: "gone", index: 2 }];
  const taken = takeClosed(closed, ["a"], id => id !== "gone");
  assert.deepEqual(taken.entry, { id: "b", index: 1 });
  assert.deepEqual(taken.closed, [{ id: "a", index: 0 }], "the deleted one is not left in the way");
});

test("closing a tab shows the one that took its place, or the last one", () => {
  assert.equal(tabAfterClose(["b"], 0), "b", "the tab to the right");
  assert.equal(tabAfterClose(["a"], 1), "a", "the last one");
  assert.equal(tabAfterClose([], 0), null, "none left");
});

test("the next and previous tab go round the strip", () => {
  assert.equal(cycledTab(["a", "b", "c"], "a", 1), "b");
  assert.equal(cycledTab(["a", "b", "c"], "c", 1), "a");
  assert.equal(cycledTab(["a", "b", "c"], "a", -1), "c");
  assert.equal(cycledTab([], "a", 1), null);
});

test("a number names a tab, and nine is the last", () => {
  assert.equal(tabAt(["a", "b", "c"], 1), "a");
  assert.equal(tabAt(["a", "b", "c"], 8), null);
  assert.equal(tabAt(["a", "b", "c"], 9), "c");
  assert.equal(tabAt([], 1), null);
});
