// The tabs' own history, kept as the Mac keeps it (MainView.swift:1150-1232): the tab you
// close goes on a stack, where it was; Reopen Closed Tab takes it back, skipping the ones
// that are open again or whose session is gone. Pure, so the test can hold it to the Mac's
// numbers without a browser.

/** How many closed tabs the Mac remembers (MainView.swift:1199). */
export const MAX_CLOSED_TABS = 50;

/**
 * The stack with more tabs closed. The last one added is the first reopened.
 *
 * @param {{ id: string, index: number }[]} closed
 * @param {{ id: string, index: number }[]} entries
 * @returns {{ id: string, index: number }[]}
 */
export function rememberClosed(closed, entries) {
  const next = [...closed, ...entries];
  return next.length > MAX_CLOSED_TABS ? next.slice(next.length - MAX_CLOSED_TABS) : next;
}

/**
 * The tab to reopen: the last one closed that is not open and still exists, and the stack
 * without it. The rest of the stack stays, so the ones it skipped can come back later.
 *
 * @param {{ id: string, index: number }[]} closed
 * @param {string[]} open
 * @param {(id: string) => boolean} exists
 * @returns {{ entry: { id: string, index: number } | null, closed: { id: string, index: number }[] }}
 */
export function takeClosed(closed, open, exists) {
  const stack = [...closed];
  while (stack.length) {
    const entry = stack.pop();
    if (entry && !open.includes(entry.id) && exists(entry.id)) return { entry, closed: stack };
  }
  return { entry: null, closed: stack };
}

/**
 * The tab that takes the closed one's place: the next one to the right, or the last one.
 *
 * @param {string[]} tabs the tabs left after the close
 * @param {number} index where the closed tab was
 * @returns {string | null}
 */
export function tabAfterClose(tabs, index) {
  return tabs[index] ?? tabs[tabs.length - 1] ?? null;
}

/**
 * The next or previous tab, around the end.
 *
 * @param {string[]} tabs
 * @param {string | null} current
 * @param {number} step 1 or -1
 * @returns {string | null}
 */
export function cycledTab(tabs, current, step) {
  if (!tabs.length) return null;
  const at = current === null ? -1 : tabs.indexOf(current);
  const index = ((at < 0 ? 0 : at) + step + tabs.length) % tabs.length;
  return tabs[index] ?? null;
}

/**
 * The tab a number names: 1 through 8 count from the left, 9 is the last one.
 *
 * @param {string[]} tabs
 * @param {number} number
 * @returns {string | null}
 */
export function tabAt(tabs, number) {
  if (!tabs.length || number < 1 || number > 9) return null;
  return tabs[number === 9 ? tabs.length - 1 : number - 1] ?? null;
}
