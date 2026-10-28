// A comment on a line of the changes, the Mac's own.
//
// The Mac keeps a comment on the line it was written on: the line's number and — once the
// file has changed — the line's text, so the comment doesn't slide onto another line
// (ChangesPanel.swift:873-880). Its place is written as "path:line", with "(removed)" for
// a line on the old side (ReviewComments.swift:12-18).
//
// The comments go to the agent with the next message, in a block of their own, so the model
// reads them as what they are (ReviewComments.swift:21-39, MessageBlock.swift:7-56).
//
// This file is pure — the rules about a comment, and the block it travels in — so the test
// can hold it to the Mac's without a browser.

/** The block a message carries its comments in (ReviewComments.swift:24-25). */
export const BLOCK_START = "<review-comments>";
export const BLOCK_END = "</review-comments>";
/** What the block's first line says (ReviewComments.swift:24). */
export const BLOCK_HEADING = "Comments on lines of the current changes:";

/**
 * Whether a comment belongs to a line of the diff: the same side, the same number, and the
 * same text (ChangesPanel.swift:876-879).
 *
 * @param {{side: string, line: number, snippet: string}} comment
 * @param {{kind: string, oldNumber?: number, newNumber?: number, text: string}} line
 * @returns {boolean}
 */
export function commentMatches(comment, line) {
  const side = line.kind === "removed" ? "old" : "new";
  const number = side === "old" ? line.oldNumber ?? 0 : line.newNumber ?? 0;
  return comment.side === side && comment.line === number && String(line.text).trim() === comment.snippet;
}

/**
 * Where a comment points, as the Mac writes it: the path, the line's number, and
 * "(removed)" for a line on the old side (ReviewComments.swift:18).
 *
 * @param {{file: string, line: number, side: string}} comment
 * @returns {string}
 */
export function commentLocation(comment) {
  return `${comment.file}:${comment.line}` + (comment.side === "old" ? " (removed)" : "");
}

/**
 * The block that ends `text`: where it opens, and its lines from its heading on
 * (MessageBlock.swift:15-18, 39-55).
 *
 * @param {string} text
 * @returns {{open: number, lines: string[]}|null}
 */
export function findBlock(text) {
  const body = String(text ?? "").replace(/\s+$/, "");
  if (!body.endsWith("\n" + BLOCK_END)) return null;
  const close = body.length - BLOCK_END.length;
  let before = close;
  for (;;) {
    const open = body.lastIndexOf(BLOCK_START + "\n", before);
    if (open < 0) return null;
    before = open;
    // The last tag with its heading after it: one in what's before the block is the message's.
    if (open !== 0 && body[open - 1] !== "\n") continue;
    const lines = body.slice(open + BLOCK_START.length + 1, close).split("\n");
    if (lines[0] !== BLOCK_HEADING) continue;
    return { open, lines };
  }
}

/**
 * `text` as it can't be read as ending with the block: a tag copied from a message gets a
 * space after it (MessageBlock.swift:20-24).
 *
 * @param {string} text
 * @returns {string}
 */
export function escapeBlock(text) {
  let out = String(text ?? "");
  for (;;) {
    const found = findBlock(out);
    if (!found) return out;
    out = out.slice(0, found.open + BLOCK_START.length) + " " + out.slice(found.open + BLOCK_START.length);
  }
}

/**
 * The message without the block that ends it, and the comments in it
 * (ReviewComments.swift:42-69).
 *
 * @param {string} text
 * @returns {{text: string, comments: {file: string, line: number, side: string, snippet: string, text: string}[]}}
 */
export function splitComments(text) {
  const found = findBlock(text);
  if (!found) return { text: String(text ?? ""), comments: [] };
  const lines = found.lines;
  const comments = [];
  let current = null;
  for (let index = 1; index < lines.length; index += 1) {
    const line = lines[index];
    // A comment starts after a blank line, with its line of the changes under it; a line
    // like "[b.swift:10]" in what you wrote is part of it (ReviewComments.swift:50-52).
    if (lines[index - 1] === "" && index + 1 < lines.length && lines[index + 1].startsWith("> ")) {
      const header = parseHeader(line);
      if (header) {
        if (current) comments.push(current);
        current = { file: header.file, line: header.line, side: header.side, snippet: "", text: "" };
        continue;
      }
    }
    if (current) {
      if (line.startsWith("> ") && current.snippet === "" && current.text === "") current.snippet = line.slice(2);
      else current.text += (current.text === "" ? "" : "\n") + line;
    }
  }
  if (current) comments.push(current);
  return {
    text: String(text ?? "").slice(0, found.open).trim(),
    comments: comments.map(comment => ({ ...comment, text: comment.text.trim() })),
  };
}

/**
 * The place a comment names: "[path/to/file.swift:124]" or "[notes.md:3 (removed)]"
 * (ReviewComments.swift:71-82).
 *
 * @param {string} line
 * @returns {{file: string, line: number, side: string}|null}
 */
function parseHeader(line) {
  if (!line.startsWith("[") || !line.endsWith("]")) return null;
  let body = line.slice(1, -1);
  let side = "new";
  if (body.endsWith(" (removed)")) {
    body = body.slice(0, -" (removed)".length);
    side = "old";
  }
  const colon = body.lastIndexOf(":");
  if (colon < 0) return null;
  const number = body.slice(colon + 1);
  if (!/^\d+$/.test(number)) return null;
  return { file: body.slice(0, colon), line: Number(number), side };
}

/**
 * The message with the comments in their block, the way the Mac sends them
 * (ReviewComments.swift:27-39).
 *
 * @param {string} text The words the user wrote.
 * @param {{file: string, line: number, side: string, snippet: string, text: string}[]} comments
 * @returns {string}
 */
export function commentsText(text, comments) {
  const words = escapeBlock(text);
  if (!comments.length) return words;
  const lines = [BLOCK_START, BLOCK_HEADING];
  for (const comment of comments) {
    lines.push("");
    lines.push(`[${commentLocation(comment)}]`);
    lines.push("> " + comment.snippet);
    lines.push(comment.text);
  }
  lines.push(BLOCK_END);
  return (words === "" ? "" : words + "\n\n") + lines.join("\n");
}
