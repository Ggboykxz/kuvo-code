// The Mac app's file links (KuvoCode/Views/Session/FileLinks.swift): a code span in a reply
// that names a file of the project becomes a link that opens the file in the side panel.
//
// This file is pure — the rule and the label — so the test can hold it to the Mac's. The
// app's half (asking the server which files exist) is in the view.

// The line a span may end with: "App.swift:42", "App.swift:12-20", "App.swift#L12".
const LINE = /(:\d+(-\d+)?|#L\d+(-L?\d+)?)$/;

/**
 * The file a code span names, if it names one: the path, the label to show, and the line.
 *
 * @param {string} span the code span's own words
 * @param {string[]} files the project's files, relative to it
 * @returns {{path: string, label: string, line: number | null} | null}
 */
export function fileIn(span, files) {
  const text = String(span ?? "").trim();
  // A path, not a sentence, and not an address.
  if (text === "" || /\s/.test(text) || text.includes("://")) return null;
  if (!text.includes("/") && !text.includes(".")) return null;

  const match = text.match(LINE);
  const written = match ? text.slice(0, match.index) : text;
  // A name has a letter in it: not "1.2.3" and not "..".
  if (!/[a-z]/i.test(written.split("/").pop() ?? "")) return null;

  // The file, by its path in the project, or by its name in one of the project's folders
  // ("api/README.md"), as the Mac's "@" writes them.
  const known = files.find(file => file === written || file.endsWith("/" + written));
  if (!known) return null;

  const name = known.split("/").pop() ?? known;
  const line = match ? Number((match[0].match(/\d+/) ?? ["0"])[0]) : null;
  return { path: known, label: line ? `${name}:${line}` : name, line };
}

/**
 * The code spans of a rendered text that name a file: the label to show and the file to open.
 *
 * @param {string} text the code span's own words
 * @param {string[]} files the project's files, relative to it
 */
export const fileLabel = (text, files) => fileIn(text, files)?.label ?? null;
