// The Mac app's keyboard shortcuts, in our key names, and the keys themselves: read, written
// down, and read back.
//
// The Mac's list lives in KuvoCode/Views/Settings/ShortcutsSettings.swift: it is written the
// macOS way (⌘, ⌥, ⇧, ⌃) and it ends by saying that a menu command's shortcut is changed in
// the system's own settings. Windows has no such place, so the recorder is ours — the same
// one the Mac's menu-bar app uses (Packages/UsageKit/…/ShortcutRecorderField.swift): click the
// keys, press the new ones, and they are kept in this app's own settings.
//
// Only the shortcuts the app answers to are listed: the Mac's list is what its app can do, and
// ours must be what ours can do too. The ones that land later join the list when they land.
//
// This file is pure — the list and the arithmetic of the keys — so the test can hold it to
// the Mac's without a browser. The app's own half (the settings, the recorder) is in
// shortcuts.ts.

/** The Mac's list, in the groups it uses, with the keys a Windows user reads. */
export const SHORTCUT_GROUPS = [
  ["General", [
    { id: "palette", title: "Command palette", keys: "Ctrl+K" },
    { id: "new-session", title: "New session", keys: "Ctrl+N" },
    { id: "save", title: "Save the conversation as Markdown", keys: "Ctrl+S" },
    { id: "settings", title: "Settings", keys: "Ctrl+," },
    { id: "run", title: "Run the project's command", keys: "Ctrl+R" },
  ]],
  ["Sessions", [
    { id: "stop", title: "Stop the agent (or Esc in the composer)", keys: "Ctrl+." },
    { id: "find", title: "Find in the conversation", keys: "Ctrl+F" },
  ]],
  ["Tabs and Window", [
    { id: "sidebar", title: "Show or hide the sidebar", keys: "Ctrl+0" },
  ]],
  ["Side Panel", [
    { id: "panel", title: "Show or hide the panel", keys: "Alt+Ctrl+0" },
    { id: "files", title: "Files", keys: "Alt+Ctrl+F" },
    { id: "changes", title: "Changes", keys: "Alt+Ctrl+I" },
    { id: "terminal", title: "New terminal", keys: "Ctrl+`" },
  ]],
  ["Composer", [
    { id: "send", title: "Send", keys: "Return", plain: true, composer: true },
    { id: "queue", title: "Queue for after the agent is done", keys: "Ctrl+Return", composer: true },
    { id: "newline", title: "New line", keys: "Shift+Return", plain: true, composer: true },
    { id: "command", title: "At the start: a command", keys: "/", plain: true, composer: true },
    { id: "mention", title: "Mention a file", keys: "@", plain: true, composer: true },
  ]],
];

export const ALL_SHORTCUTS = SHORTCUT_GROUPS.flatMap(([, shortcuts]) => shortcuts);

export const shortcutById = id => ALL_SHORTCUTS.find(shortcut => shortcut.id === id);

/**
 * The keys the user recorded for a shortcut, or the ones the app ships with.
 *
 * @param {string} id
 * @param {Record<string, string>} [recorded]
 * @returns {string}
 */
export const keysOf = (id, recorded) => {
  const saved = recorded ? recorded[id] : undefined;
  if (typeof saved === "string" && saved.length > 0) return saved;
  const shortcut = shortcutById(id);
  return shortcut ? shortcut.keys : "";
};

// ---- The keys, read and written ----

/** The name a key is written with, the way the Mac writes it: Return, Esc, Space. */
const KEY_NAMES = {
  Enter: "Return",
  Escape: "Esc",
  " ": "Space",
  ArrowUp: "Up",
  ArrowDown: "Down",
  ArrowLeft: "Left",
  ArrowRight: "Right",
  Backspace: "Delete",
};

/** The key a name stands for, the way the browser writes it. */
const KEY_ALIASES = {
  Return: "Enter",
  Esc: "Escape",
  Space: " ",
  Up: "ArrowUp",
  Down: "ArrowDown",
  Left: "ArrowLeft",
  Right: "ArrowRight",
};

export const displayKey = key => KEY_NAMES[key] ?? key;
export const eventKey = key => KEY_ALIASES[key] ?? key;

/**
 * "Ctrl+Shift+K" — read back into its parts.
 *
 * @param {string} spec
 * @returns {{ctrl: boolean, alt: boolean, shift: boolean, key: string} | null}
 */
export function parseKeys(spec) {
  const parts = String(spec).split("+").map(part => part.trim()).filter(part => part.length > 0);
  if (parts.length === 0) return null;
  const binding = { ctrl: false, alt: false, shift: false, key: "" };
  for (const part of parts) {
    const lower = part.toLowerCase();
    if (lower === "ctrl" || lower === "control") binding.ctrl = true;
    else if (lower === "alt" || lower === "option") binding.alt = true;
    else if (lower === "shift") binding.shift = true;
    else binding.key = eventKey(part);
  }
  if (!binding.key) return null;
  return binding;
}

/**
 * The keys of a press, the way they are written down: "Ctrl+Shift+K". A chord needs a real
 * modifier — Ctrl or Alt; Shift alone would take the typing away.
 *
 * @param {{key: string, ctrlKey: boolean, altKey: boolean, shiftKey: boolean}} event
 * @returns {string | null}
 */
export function specFromEvent(event) {
  const key = event.key;
  if (!key || ["Shift", "Control", "Alt", "Meta"].includes(key)) return null;
  if (!event.ctrlKey && !event.altKey) return null;
  const parts = [];
  if (event.ctrlKey) parts.push("Ctrl");
  if (event.altKey) parts.push("Alt");
  if (event.shiftKey) parts.push("Shift");
  // A letter is written in capitals, the way a key cap reads it.
  parts.push(key.length === 1 && /[a-z]/i.test(key) ? key.toUpperCase() : displayKey(key));
  return parts.join("+");
}

/**
 * Does this press answer to these keys?
 *
 * @param {string} spec
 * @param {{key: string, ctrlKey: boolean, altKey: boolean, shiftKey: boolean}} event
 * @returns {boolean}
 */
export function matchesEvent(spec, event) {
  const binding = parseKeys(spec);
  if (!binding) return false;
  if (binding.ctrl !== event.ctrlKey) return false;
  if (binding.alt !== event.altKey) return false;
  if (binding.shift !== event.shiftKey) return false;
  const key = event.key;
  if (key.length !== 1 && !KEY_ALIASES[binding.key]) {
    // A named key (F5, Escape…): the names must be the same one.
    return displayKey(key) === displayKey(binding.key);
  }
  return key.toLowerCase() === binding.key.toLowerCase();
}

/**
 * The keys, one by one, the way they are drawn: ["Ctrl", "Shift", "K"].
 *
 * @param {string} spec
 * @returns {string[]}
 */
export const keyCaps = spec => String(spec).split("+").map(part => part.trim()).filter(part => part.length > 0);
