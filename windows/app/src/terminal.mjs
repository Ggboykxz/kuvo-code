// The terminal's small, testable pieces: the address the page opens to the shell, and
// the text the right-click menu's Add to Message sends. No browser is needed to check
// either, so they can be tested on the same machines that build the app.

/**
 * The local terminal's WebSocket address. The folder and the grid travel with the
 * connection, so the shell starts in the project at the size the page has drawn, rather
 * than at 80×24 until the window is resized.
 *
 * @param {number} port
 * @param {string | null | undefined} cwd
 * @param {number} cols
 * @param {number} rows
 * @returns {string}
 */
export function terminalSocketUrl(port, cwd, cols, rows) {
  const params = new URLSearchParams();
  if (cwd) params.set("cwd", cwd);
  if (Number.isFinite(cols)) params.set("cols", String(Math.max(2, Math.min(1000, Math.round(cols)))));
  if (Number.isFinite(rows)) params.set("rows", String(Math.max(1, Math.min(500, Math.round(rows)))));
  return `ws://127.0.0.1:${port}/${params.size ? `?${params}` : ""}`;
}

/**
 * A terminal selection as the Mac adds it to the composer (TerminalSession.swift:147-158):
 * in a code block, with the trailing whitespace each terminal line carries taken off.
 *
 * @param {string} text
 * @returns {string}
 */
export function terminalSelectionBlock(text) {
  const lines = String(text ?? "").replace(/\r\n?/g, "\n").split("\n").map(line => line.replace(/[ \t]+$/, ""));
  while (lines.length > 0 && lines[0].trim() === "") lines.shift();
  while (lines.length > 0 && lines[lines.length - 1].trim() === "") lines.pop();
  if (lines.length === 0) return "";
  return `\`\`\`\n${lines.join("\n")}\n\`\`\``;
}
