// The shortcuts and the keys, as they are written in keys.mjs; this declares their shape
// for TypeScript. The list and the arithmetic are pure, so the test holds them to the
// Mac's without a browser.

declare module "*/keys.mjs" {
  export type Shortcut = {
    id: string;
    title: string;
    /** The keys, the way a Windows user reads them: Ctrl, Alt, Shift. */
    keys: string;
    /** The keys that are typing, not a chord: they are shown, not recorded. */
    plain?: boolean;
    /** The composer answers to these itself; the window's handler leaves them alone. */
    composer?: boolean;
  };

  export type KeyPress = {
    key: string;
    ctrlKey: boolean;
    altKey: boolean;
    shiftKey: boolean;
  };

  export type Binding = { ctrl: boolean; alt: boolean; shift: boolean; key: string };

  export const SHORTCUT_GROUPS: [string, Shortcut[]][];
  export const ALL_SHORTCUTS: Shortcut[];
  export function shortcutById(id: string): Shortcut | undefined;
  export function keysOf(id: string, recorded?: Record<string, string>): string;
  export function displayKey(key: string): string;
  export function eventKey(key: string): string;
  export function parseKeys(spec: string): Binding | null;
  export function specFromEvent(event: KeyPress): string | null;
  export function matchesEvent(spec: string, event: KeyPress): boolean;
  export function keyCaps(spec: string): string[];
}
