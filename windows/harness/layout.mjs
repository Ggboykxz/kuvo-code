// The Mac's PaneLayout (MainView.swift:2112-2179): the widths of the two side cards and of
// the split beside the conversation, and what gives way when the window has no room left
// for all of them.
//
//   the ranges: sessions 220…440, changes 300…900, split 380…1200
//   the conversation keeps at least 380
//   out of room, the panes go in `givesWay`'s order — the split first, then the panel,
//   then the sessions
//   a pane that went early comes back if a later one's going left room for it, the last
//   to go first
//   then the rest shrink as far as they must, the panel first and the split last
//
// A width of null means the pane is not on screen — by choice, or for lack of room.

export const paneRanges = {
  sessions: { lower: 220, upper: 440 },
  changes: { lower: 300, upper: 900 },
  split: { lower: 380, upper: 1200 },
};

export const conversationMinimum = 380;
export const paneOrder = ["sessions", "changes", "split"];

const clamped = (width, range) => (width === null || width === undefined ? null : Math.min(Math.max(width, range.lower), range.upper));

/**
 * @param {{ available: number, sessions?: number | null, changes?: number | null,
 *   split?: number | null, gap?: number, givesWay?: string[] }} input
 * @returns {{ sessions: number | null, changes: number | null, split: number | null,
 *   sessionsMax: number, changesMax: number, splitMax: number }}
 */
export function paneLayout({ available, sessions = null, changes = null, split = null, gap = 8, givesWay = ["split", "changes", "sessions"] }) {
  const wanted = {
    sessions: clamped(sessions, paneRanges.sessions),
    changes: clamped(changes, paneRanges.changes),
    split: clamped(split, paneRanges.split),
  };
  const width = { ...wanted };

  // What is over the room the conversation keeps, at the widths as they stand (or at the
  // panes' smallest, to know which ones could never fit).
  const overflow = (smallest = false) => paneOrder.reduce((sum, pane) => {
    if (width[pane] === null) return sum;
    return sum + (smallest ? paneRanges[pane].lower : width[pane]) + gap;
  }, conversationMinimum - available);

  const dropped = [];
  for (const pane of givesWay) {
    if (overflow(true) <= 0) break;
    width[pane] = null;
    dropped.push(pane);
  }
  // One that went early comes back if a later one's going left room for it.
  for (const pane of [...dropped].reverse()) {
    width[pane] = wanted[pane];
    if (overflow(true) <= 0) continue;
    width[pane] = null;
  }
  // Then the rest shrink as far as they must, the panel first and the split last.
  for (const pane of ["changes", "sessions", "split"]) {
    if (width[pane] === null) continue;
    const over = overflow();
    if (over > 0) width[pane] = Math.max(paneRanges[pane].lower, width[pane] - over);
  }

  const room = available - conversationMinimum;
  const rest = side => (width[side] === null ? 0 : width[side] + gap);
  return {
    sessions: width.sessions,
    changes: width.changes,
    split: width.split,
    sessionsMax: Math.min(paneRanges.sessions.upper, room - gap - rest("changes") - rest("split")),
    changesMax: Math.min(paneRanges.changes.upper, room - gap - rest("sessions") - rest("split")),
    splitMax: Math.min(paneRanges.split.upper, room - gap - rest("sessions") - rest("changes")),
  };
}
