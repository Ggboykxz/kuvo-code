// What a find looks for, as places in the text rather than a count: every occurrence,
// left to right, so the words can be marked and stepped through one at a time.
//
// The search is the plain one the app already used: no regular expressions, no locale
// folding beyond case, and a query shorter than two characters finds nothing (a single
// letter would mark half a conversation).

/** @typedef {{ start: number, end: number }} FindRange */

/**
 * Every place `query` occurs in `text`, case-insensitively, without overlapping.
 * @param {string} text
 * @param {string} query
 * @returns {FindRange[]}
 */
export function findRanges(text, query) {
  const needle = String(query ?? "");
  if (needle.length < 2) return [];
  const haystack = String(text ?? "").toLowerCase();
  const lower = needle.toLowerCase();
  /** @type {FindRange[]} */
  const ranges = [];
  let at = 0;
  while (at <= haystack.length - lower.length) {
    const found = haystack.indexOf(lower, at);
    if (found < 0) break;
    ranges.push({ start: found, end: found + lower.length });
    at = found + lower.length;
  }
  return ranges;
}

/**
 * How many times `query` occurs in `text`.
 * @param {string} text
 * @param {string} query
 */
export function countOf(text, query) {
  return findRanges(text, query).length;
}
