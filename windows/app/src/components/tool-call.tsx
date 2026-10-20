// The Mac's tool calls (ToolCallView.swift:99-326): what the call did, in words, and the
// mark that stands for it. Ours showed the tool's raw name — "read", "edit" — where the
// Mac says "Read notes.txt" and draws the mark of the tool.

import type { SymbolName } from "./symbols";

/// What the call did, in words: its line in the transcript
/// (ToolCallView.swift:163-200).
export function toolSummary(
  name: string,
  input: Record<string, unknown> | undefined,
  active: boolean,
  directory: string | null,
): string {
  const text = (key: string): string | undefined => {
    const value = input?.[key];
    return typeof value === "string" && value !== "" ? value : undefined;
  };
  const path = relative(text("path"), directory);
  const files = (input?.diffs as { file?: string }[] | undefined)?.map(diff => relative(diff.file, directory) ?? diff.file ?? "") ?? [];
  switch (name) {
    case "read": return `${active ? "Reading " : "Read "}${path ?? "a file"}`;
    case "write": return `${active ? "Writing " : "Wrote "}${path ?? "a file"}`;
    case "edit": return `${active ? "Editing " : "Edited "}${path ?? "a file"}`;
    case "patch":
      return `${active ? "Editing " : "Edited "}${files.length === 1 ? files[0] : files.length === 0 ? "files" : `${files.length} files`}`;
    case "shell": return `${active ? "Running " : "Ran "}${text("command") ? `\`${text("command")}\`` : "a command"}`;
    case "grep": return `Searched for “${text("pattern") ?? ""}”${path ? ` in ${path}` : ""}`;
    case "glob": return `Found files matching “${text("pattern") ?? ""}”`;
    case "webfetch": return `${active ? "Fetching " : "Fetched "}${text("url") ?? "a page"}`;
    case "websearch": return `Searched the web for “${text("query") ?? ""}”`;
    case "question": return active ? "Asking you a question" : "Asked you a question";
    case "subagent": return `${text("description") ?? (active ? "Starting a subagent…" : "A subagent's task")}${text("agent") ? ` · ${text("agent")}` : ""}`;
    case "skill": return "Used a skill";
    default: return name;
  }
}

/// The file's path, as the project names it (ToolCallView.swift:151-159): the project
/// folder itself goes by its name, and what is under it by what is left.
function relative(path: string | undefined, directory: string | null): string | undefined {
  if (!path) return undefined;
  if (!directory) return path;
  const base = directory.endsWith("/") ? directory : `${directory}/`;
  if (path === directory || path === base) return base.slice(0, -1).split("/").pop() ?? path;
  return path.startsWith(base) ? path.slice(base.length) : path;
}

/// The mark that stands for the call (ToolCallView.swift:312-326).
export function toolSymbol(name: string): SymbolName {
  switch (name) {
    case "read": return "doc.text";
    case "write": return "doc.badge.plus";
    case "edit":
    case "patch": return "pencil";
    case "shell": return "terminal";
    case "grep":
    case "glob": return "magnifyingglass";
    case "webfetch":
    case "websearch": return "globe";
    case "question": return "questionmark.bubble";
    case "subagent": return "person.2";
    case "skill": return "wand.and.stars";
    case "execute": return "chevron.left.forwardslash.chevron.right";
    default: return "wrench.and.screwdriver";
  }
}
