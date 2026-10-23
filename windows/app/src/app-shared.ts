// Shared helpers used by several of the App modules. Kept here so the modules do not
// import from each other in a circle.

import { look } from "./store";
import { splitComments } from "./review-comments.mjs";

export function motionIsReduced() {
  if (look.motion === "reduced") return true;
  return typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

export function folderName(path: string) {
  const name = path.replace(/[/\\]+$/, "").split(/[/\\]+/).pop() ?? path;
  return name || path;
}

export function duration(seconds: number) {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
}

export const stepKind = (name: string) => {
  const lower = (name ?? "").toLowerCase();
  if (lower.startsWith("kuvo-browser_browser_") || lower.startsWith("browser_")) return "browser";
  switch (lower) {
    case "grep": case "glob": case "list": return "search";
    case "bash": case "shell": return "shell";
    case "edit": case "write": case "patch": return "edit";
    case "kuvo-browser_show_in_panel": return "show";
    case "kuvo-browser_send_message": return "message";
    case "kuvo-browser_list_agents": return "agents";
    default: return lower;
  }
};

export const stepPhrase = (kind: string, count: number) => {
  const many = count > 1;
  switch (kind) {
    case "websearch": return many ? `searched the web ${count} times` : "searched the web";
    case "webfetch": return many ? `fetched ${count} pages` : "fetched a page";
    case "read": return many ? `read ${count} files` : "read a file";
    case "search": return many ? `searched the files ${count} times` : "searched the files";
    case "shell": return many ? `ran ${count} commands` : "ran a command";
    case "edit": return many ? `edited files ${count} times` : "edited a file";
    case "browser": return many ? `used the browser (${count} steps)` : "used the browser";
    case "subagent": return many ? `handed off ${count} tasks` : "handed off a task";
    case "question": return many ? `asked you ${count} questions` : "asked you a question";
    case "show": return many ? `showed you ${count} things` : "showed you something";
    case "message": return many ? `wrote to other agents ${count} times` : "wrote to another agent";
    case "agents": return "looked up the other agents";
    case "todowrite": case "todoread": return "kept its to-do list";
    default: return many ? `used ${kind} ${count} times` : `used ${kind}`;
  }
};

export function entryText(entry: { kind?: string; text?: string; parts?: { type: string; text?: string }[] }) {
  if (entry.text) return entry.kind === "user" ? splitComments(entry.text).text : entry.text;
  return (entry.parts ?? []).map(part => (part.type === "text" || part.type === "reasoning" ? part.text ?? "" : "")).join("\n");
}

export function countOf(text: string, query: string) {
  if (query.length < 2) return 0;
  const haystack = text.toLowerCase();
  const needle = query.toLowerCase();
  let count = 0;
  let at = haystack.indexOf(needle);
  while (at >= 0) {
    count += 1;
    at = haystack.indexOf(needle, at + needle.length);
  }
  return count;
}
