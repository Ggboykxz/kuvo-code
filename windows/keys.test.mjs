// The app's keyboard shortcuts — the Mac's list in our key names, and the keys themselves —
// checked here, without a browser: the list the Mac writes, the keys the user records, and
// the arithmetic that tells a press from another.
//
//   node --test windows/keys.test.mjs

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import {
  ALL_SHORTCUTS,
  SHORTCUT_GROUPS,
  keyCaps,
  keysOf,
  matchesEvent,
  parseKeys,
  specFromEvent,
} from "./app/src/keys.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, "..");

const press = (key, modifiers = {}) => ({
  key,
  ctrlKey: Boolean(modifiers.ctrl),
  altKey: Boolean(modifiers.alt),
  shiftKey: Boolean(modifiers.shift),
});

// ---- The list ----

test("the list is the Mac's, in the groups it uses", () => {
  assert.deepEqual(SHORTCUT_GROUPS.map(([title]) => title), [
    "General",
    "Sessions",
    "Tabs and Window",
    "Side Panel",
    "Composer",
  ]);
  const titles = ALL_SHORTCUTS.map(shortcut => shortcut.title);
  // The Mac's own wording (KuvoCode/Views/Settings/ShortcutsSettings.swift).
  for (const title of [
    "Command palette",
    "New session",
    "Open a folder as a project",
    "Open Quickly: a project file by name",
    "Settings",
    "Stop the agent (or Esc in the composer)",
    "Find in the conversation",
    "Build mode",
    "Plan mode",
    "Close the session tab",
    "Close the window",
    "Reopen the tab you closed last",
    "Next session tab",
    "Previous session tab",
    "Show or hide the sidebar",
    "Show or hide the tab bar",
    "Files",
    "Changes",
    "New terminal",
    "Send",
    "Queue for after the agent is done",
    "New line",
    "At the start: a command",
    "Mention a file",
  ]) {
    assert.ok(titles.includes(title), `the list holds “${title}”`);
  }
});

test("the Mac's keys are written the Windows way", () => {
  const mac = fs.readFileSync(path.join(root, "KuvoCode", "Views", "Settings", "ShortcutsSettings.swift"), "utf8");
  const ours = ALL_SHORTCUTS.map(shortcut => shortcut.keys).join(" ");
  // The Mac writes ⌘, ⌥, ⇧ and ⌃; ours are read by a Windows user.
  assert.doesNotMatch(ours, /[⌘⌥⇧⌃]/, "no macOS key names are left");
  // The Mac's ⌥⌘I (Changes) is Alt+Ctrl+I here, and its ⌃` (a new terminal) is Ctrl+`.
  assert.ok(mac.includes("⌥", "⌘", "I"), "the Mac's Changes shortcut");
  assert.ok(ours.includes("Alt+Ctrl+I"), "our Changes shortcut");
  assert.ok(mac.includes("⌃", "`"), "the Mac's terminal shortcut");
  assert.ok(ours.includes("Ctrl+`"), "our terminal shortcut");
  // And the Mac's ⌘0 (the sidebar) is Ctrl+0 here.
  assert.ok(ours.includes("Ctrl+0"), "our sidebar shortcut");
  // The Mac's tab and menu keys, as Windows writes them.
  assert.ok(ours.includes("Ctrl+W"), "our close-tab shortcut");
  assert.ok(ours.includes("Ctrl+Shift+W"), "our close-window shortcut");
  assert.ok(ours.includes("Ctrl+Shift+T"), "our reopen-tab shortcut");
  assert.ok(ours.includes("Ctrl+Tab"), "our next-tab shortcut");
  assert.ok(ours.includes("Ctrl+Shift+Tab"), "our previous-tab shortcut");
  assert.ok(ours.includes("Ctrl+Shift+O"), "our Open Quickly shortcut");
  assert.ok(ours.includes("Ctrl+Alt+T"), "our tab-bar shortcut");
});

test("every shortcut has its own name, and the keys are ours to read", () => {
  const ids = ALL_SHORTCUTS.map(shortcut => shortcut.id);
  assert.equal(new Set(ids).size, ids.length, "no two shortcuts share a name");
  for (const shortcut of ALL_SHORTCUTS) {
    assert.ok(shortcut.keys.length > 0, `${shortcut.id} has keys`);
    assert.ok(shortcut.title.length > 0, `${shortcut.id} has a title`);
  }
});

// ---- The keys the user recorded ----

test("the keys the user recorded win over the ones the app ships with", () => {
  assert.equal(keysOf("palette"), "Ctrl+K", "the app's own keys");
  assert.equal(keysOf("palette", { palette: "Alt+Ctrl+P" }), "Alt+Ctrl+P", "the recorded keys");
  assert.equal(keysOf("palette", { palette: "" }), "Ctrl+K", "an empty recording keeps the app's");
  assert.equal(keysOf("nothing"), "", "a shortcut that does not exist has no keys");
});

// ---- The keys, read and written ----

test("the keys are read back into their parts", () => {
  assert.deepEqual(parseKeys("Ctrl+Shift+K"), { ctrl: true, alt: false, shift: true, key: "K" });
  assert.deepEqual(parseKeys("Alt+Ctrl+,"), { ctrl: true, alt: true, shift: false, key: "," });
  assert.deepEqual(parseKeys("Ctrl+Return"), { ctrl: true, alt: false, shift: false, key: "Enter" });
  assert.equal(parseKeys("Ctrl"), null, "a modifier alone is not a key");
});

test("a press is written down the way it was pressed", () => {
  assert.equal(specFromEvent(press("k", { ctrl: true })), "Ctrl+K");
  assert.equal(specFromEvent(press("K", { ctrl: true })), "Ctrl+K");
  assert.equal(specFromEvent(press("i", { ctrl: true, alt: true })), "Ctrl+Alt+I");
  assert.equal(specFromEvent(press("Enter", { ctrl: true })), "Ctrl+Return");
  assert.equal(specFromEvent(press("k", { shift: true })), null, "Shift alone would take the typing away");
  assert.equal(specFromEvent(press("k")), null, "a key on its own is not a shortcut");
  assert.equal(specFromEvent(press("Shift", { ctrl: true })), null, "a modifier on its own is not a shortcut");
});

test("a press answers to the keys, and only to them", () => {
  assert.ok(matchesEvent("Ctrl+K", press("k", { ctrl: true })));
  assert.ok(matchesEvent("Ctrl+K", press("K", { ctrl: true })));
  assert.ok(!matchesEvent("Ctrl+K", press("k")), "the modifier is needed");
  assert.ok(!matchesEvent("Ctrl+K", press("k", { ctrl: true, shift: true })), "and only that one");
  assert.ok(matchesEvent("Alt+Ctrl+I", press("i", { ctrl: true, alt: true })));
  assert.ok(matchesEvent("Ctrl+Return", press("Enter", { ctrl: true })));
  assert.ok(matchesEvent("Ctrl+`", press("`", { ctrl: true })));
  assert.ok(matchesEvent("Ctrl+,", press(",", { ctrl: true })));
  assert.ok(matchesEvent("Ctrl+.", press(".", { ctrl: true })));
  assert.ok(matchesEvent("Ctrl+0", press("0", { ctrl: true })));
});

test("the keys are drawn one by one", () => {
  assert.deepEqual(keyCaps("Ctrl+Shift+K"), ["Ctrl", "Shift", "K"]);
  assert.deepEqual(keyCaps("Ctrl+,"), ["Ctrl", ","]);
  assert.deepEqual(keyCaps("Return"), ["Return"]);
});
