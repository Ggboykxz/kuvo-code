// The app's half of the shortcuts: the keys the user recorded (kept in this app's own
// settings), the recorder that writes them down, and the answer to "does this press mean
// something?".
//
// The list and the arithmetic of the keys are in keys.mjs, pure and shared with the test.

import { ALL_SHORTCUTS, keysOf as keysOfList, matchesEvent, type KeyPress, type Shortcut } from "./keys.mjs";
import { cfgGet, cfgSet, saveConfig } from "./store";

export { ALL_SHORTCUTS, keyCaps, keysOf as keysOfPure, matchesEvent, parseKeys, specFromEvent, displayKey, SHORTCUT_GROUPS, shortcutById } from "./keys.mjs";
export type { KeyPress, Shortcut } from "./keys.mjs";

/// The keys the user recorded, or the ones the app ships with.
export function keysOf(id: string): string {
  const recorded = cfgGet(["shortcuts", id]);
  return keysOfList(id, typeof recorded === "string" ? { [id]: recorded } : undefined);
}

// ---- The recording ----

/// While a shortcut is being recorded the app's own keys stay quiet — the Mac does the same
/// (it disables the hotkey for as long as the recorder listens).
let recording = false;
export const isRecording = () => recording;
export const setRecording = (value: boolean) => { recording = value; };

/// The keys the user recorded for this shortcut, kept in the app's own settings.
export async function recordShortcut(id: string, spec: string) {
  cfgSet(["shortcuts", id], spec);
  await saveConfig();
}

export async function clearShortcut(id: string) {
  cfgSet(["shortcuts", id], null);
  await saveConfig();
}

/// The shortcut a press answers to, with the keys the user gave it.
export function shortcutFor(event: KeyPress): Shortcut | undefined {
  for (const shortcut of ALL_SHORTCUTS) {
    if (shortcut.plain || shortcut.composer) continue;
    if (matchesEvent(keysOf(shortcut.id), event)) return shortcut;
  }
  return undefined;
}
