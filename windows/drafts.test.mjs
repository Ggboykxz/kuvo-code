// The Mac app's drafts, checked here: what is typed but not sent, by session, kept across
// launches, and what is dropped when it is sent.
//
//   node --test windows/drafts.test.mjs

import assert from "node:assert/strict";
import { test } from "node:test";

import { clearDraft, draftKey, readDraft, saveDraft } from "./app/src/drafts.mjs";

/// A storage that keeps what it is given, as the browser's does.
function memory() {
  const held = new Map();
  return {
    getItem: key => (held.has(key) ? held.get(key) : null),
    setItem: (key, value) => { held.set(key, String(value)); },
    removeItem: key => { held.delete(key); },
    raw: key => held.get(key) ?? null,
  };
}

test("a draft is kept under its session, or the project's new one", () => {
  assert.equal(draftKey("ses_1", "/tmp/project"), "ses_1");
  assert.equal(draftKey(null, "/tmp/project"), "new:/tmp/project");
  assert.equal(draftKey(null, null), "new:");
});

test("what is typed is kept, and read back", () => {
  const storage = memory();
  saveDraft(storage, "ses_1", { text: "a half-written thought" });
  assert.deepEqual(readDraft(storage, "ses_1"), { text: "a half-written thought", files: [] });
  // Another session's composer has its own.
  assert.equal(readDraft(storage, "ses_2"), null);
});

test("the attachments that still exist are kept, the others are dropped", () => {
  const storage = memory();
  saveDraft(storage, "ses_1", {
    text: "",
    files: [{ name: "notes.txt", uri: "/tmp/project/notes.txt" }, { name: "pasted.png", data: "data:image/png;base64,..." }],
  });
  const draft = readDraft(storage, "ses_1");
  assert.equal(draft.files.length, 1, "the pasted one is not kept");
  assert.equal(draft.files[0].name, "notes.txt");
});

test("an empty draft is forgotten", () => {
  const storage = memory();
  saveDraft(storage, "ses_1", { text: "words" });
  saveDraft(storage, "ses_1", { text: "" });
  assert.equal(readDraft(storage, "ses_1"), null);
});

test("a draft that was sent is gone", () => {
  const storage = memory();
  saveDraft(storage, "ses_1", { text: "words" });
  clearDraft(storage, "ses_1");
  assert.equal(readDraft(storage, "ses_1"), null);
});

test("a storage that is broken does not break the composer", () => {
  const broken = {
    getItem: () => "{not json",
    setItem: () => { throw new Error("full"); },
    removeItem: () => {},
  };
  assert.equal(readDraft(broken, "ses_1"), null);
  saveDraft(broken, "ses_1", { text: "words" });
  assert.equal(readDraft(broken, "ses_1"), null);
});
