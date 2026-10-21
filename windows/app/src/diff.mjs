// The diff's own lines: what a patch says, read as the rows the Mac shows.
//
// The Mac reads a project's changes into lines of their own — a kind (unchanged, added,
// removed), the number the line has on each side, and the text (ProjectChanges.swift:40-48).
// Its rows show that number in a gutter, the text without the patch's signs, and a coloured
// edge on a line that changed (ChangesPanel.swift:959-1042).
//
// This file is pure — the reading of a patch, and the arithmetic of its numbers — so the test
// can hold it to the Mac's without a browser.

/** The kinds of line a diff holds, the Mac's own (ProjectChanges.swift:41). */
export const DIFF_KINDS = ["context", "added", "removed"];

/**
 * The rows of a patch, in the Mac's shape.
 *
 * The headers git writes before the first hunk are not rows: they name the file and the
 * commit, and the Mac's rows hold the lines of the change alone.
 *
 * @param {string} patch A unified diff, as git writes it.
 * @returns {{kind: string, oldNumber?: number, newNumber?: number, text: string}[]}
 */
export function parsePatch(patch) {
  const rows = [];
  const raw = String(patch ?? "").split("\n");
  // The patch ends with a newline; that is not a line of the file.
  if (raw.length && raw[raw.length - 1] === "") raw.pop();
  let oldNumber = 0;
  let newNumber = 0;
  let inHunk = false;
  for (const text of raw) {
    if (!inHunk) {
      const header = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(text);
      if (!header) continue;
      oldNumber = Number(header[1]);
      newNumber = Number(header[2]);
      inHunk = true;
      continue;
    }
    // "\ No newline at end of file": a note about the line before it, not a line.
    if (text.startsWith("\\")) continue;
    const sign = text[0];
    if (sign === "+") {
      rows.push({ kind: "added", newNumber, text: text.slice(1) });
      newNumber += 1;
    } else if (sign === "-") {
      rows.push({ kind: "removed", oldNumber, text: text.slice(1) });
      oldNumber += 1;
    } else {
      // A context line: git writes a space before it, and an empty line is one too.
      rows.push({ kind: "context", oldNumber, newNumber, text: sign === " " ? text.slice(1) : text });
      oldNumber += 1;
      newNumber += 1;
    }
  }
  return rows;
}

/**
 * The number the gutter shows: the old one for a removed line, the new one otherwise
 * (ChangesPanel.swift:882-885).
 *
 * @param {{kind: string, oldNumber?: number, newNumber?: number}} line
 * @returns {number}
 */
export function diffNumber(line) {
  return line.kind === "removed" ? line.oldNumber ?? 0 : line.newNumber ?? 0;
}

/**
 * Which side of the change a line is on: the old one for a removed line, the new one
 * otherwise (ReviewComments.swift:18).
 *
 * @param {{kind: string}} line
 * @returns {"old" | "new"}
 */
export function diffSide(line) {
  return line.kind === "removed" ? "old" : "new";
}

/**
 * The width of the gutter, in points: the Mac's own — a character for the widest number,
 * and 22 more (ChangesPanel.swift:968-971).
 *
 * @param {{kind: string, oldNumber?: number, newNumber?: number}[]} lines
 * @returns {number}
 */
export function diffGutterWidth(lines) {
  const largest = lines.reduce((most, line) => Math.max(most, diffNumber(line)), 1);
  return String(largest).length * 7.5 + 22;
}
