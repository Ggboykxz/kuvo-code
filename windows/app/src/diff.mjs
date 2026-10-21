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
  let pendingGap = false;
  for (const text of raw) {
    if (!inHunk) {
      const header = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(text);
      if (!header) continue;
      oldNumber = Number(header[1]);
      newNumber = Number(header[2]);
      inHunk = true;
      continue;
    }
    // A second hunk: the lines between the two are not in the patch, and the row that
    // follows it says so (ProjectChanges.swift:503).
    if (/^@@ -\d+(?:,\d+)? \+\d+(?:,\d+)? @@/.test(text)) {
      pendingGap = true;
      continue;
    }
    // "\ No newline at end of file": a note about the line before it, not a line.
    if (text.startsWith("\\")) continue;
    const sign = text[0];
    const row = { kind: "context", oldNumber, newNumber, text: sign === " " ? text.slice(1) : text };
    if (sign === "+") {
      row.kind = "added";
      delete row.oldNumber;
      row.newNumber = newNumber;
      row.text = text.slice(1);
      newNumber += 1;
    } else if (sign === "-") {
      row.kind = "removed";
      delete row.newNumber;
      row.oldNumber = oldNumber;
      row.text = text.slice(1);
      oldNumber += 1;
    } else {
      oldNumber += 1;
      newNumber += 1;
    }
    if (pendingGap) {
      row.gapBefore = true;
      pendingGap = false;
    }
    rows.push(row);
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

/** The lines the Mac keeps on each side of a change (ChangesPanel.swift:891). */
export const DIFF_CONTEXT = 3;

/**
 * The rows of a diff, with the long unchanged stretches folded, the Mac's way
 * (ChangesPanel.swift:890-927): three lines are kept on each side of a change, and a
 * longer run of unchanged lines is folded into a row of its own — until it is opened.
 *
 * @param {{kind: string, gapBefore?: boolean}[]} lines
 * @param {string[]} expanded The folds that are open, by their name.
 * @param {string} file The file's name: a fold belongs to one file.
 * @returns {{kind: string, id: string, index?: number, count?: number}[]}
 */
export function foldRows(lines, expanded = [], file = "") {
  const rows = [];
  let index = 0;
  while (index < lines.length) {
    if (lines[index].gapBefore) rows.push({ kind: "gap", id: `${file}#gap${index}` });
    if (lines[index].kind !== "context") {
      rows.push({ kind: "line", id: `${file}#${index}`, index });
      index += 1;
      continue;
    }
    // A run of unchanged lines, up to the next change (or a gap git left).
    let end = index + 1;
    while (end < lines.length && lines[end].kind === "context" && !lines[end].gapBefore) end += 1;
    const keepStart = index === 0 || lines[index].gapBefore ? 0 : DIFF_CONTEXT;
    const keepEnd = end === lines.length || lines[end].gapBefore ? 0 : DIFF_CONTEXT;
    const foldStart = index + keepStart;
    const foldEnd = end - keepEnd;
    const foldID = `${file}#fold${foldStart}`;
    if (foldEnd - foldStart > 3 && !expanded.includes(foldID)) {
      for (let at = index; at < foldStart; at += 1) rows.push({ kind: "line", id: `${file}#${at}`, index: at });
      rows.push({ kind: "fold", id: foldID, count: foldEnd - foldStart });
      for (let at = foldEnd; at < end; at += 1) rows.push({ kind: "line", id: `${file}#${at}`, index: at });
    } else {
      for (let at = index; at < end; at += 1) rows.push({ kind: "line", id: `${file}#${at}`, index: at });
    }
    index = end;
  }
  return rows;
}
