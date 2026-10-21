// The app's own words, against the Mac's.
//
// The Mac's strings are the app's strings: the same words, the same punctuation, in the
// same places (`docs/MAC-UI-INVENTORY.md` §5). The check below holds the shell's strings
// to the Mac's own source, and the few strings that are ours alone (with the reason) are
// written down here, so a new one has to be argued for rather than slipped in.

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, "..");

/// Every file under a folder, with its text.
const readAll = (folder, extensions) => {
  const found = [];
  const walk = (directory) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const entryPath = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        if (entry.name === ".git" || entry.name === "node_modules") continue;
        walk(entryPath);
      } else if (extensions.some(extension => entry.name.endsWith(extension))) {
        found.push(fs.readFileSync(entryPath, "utf8").replace(/\r\n/g, "\n"));
      }
    }
  };
  walk(folder);
  return found.join("\n");
};

const mac = readAll(path.join(root, "KuvoCode"), [".swift"]);
const app = readAll(path.join(root, "windows", "app", "src"), [".tsx", ".ts"]);

/// The strings of the window's shell, as the Mac says them.
const SHELL = [
  "New Session",
  "Show Sessions",
  "Hide Sessions",
  "Show Panel",
  "Hide Panel",
  "Show Files",
  "Show Changes",
  "New Terminal",
  "Find in Conversation…",
  "Allow",
  "Always Allow",
  "Deny",
  "Stop",
  "Redo",
  "New Session From Here",
  "Undo From Here…",
  "Open Folder…",
  "Recent Sessions",
  "Actions",
  "Sessions",
  "Files",
  "Send",
  "Nothing matches.",
  "Attach Files… You can also drop files here, or paste them.",
  // A session's own menu, the Mac's (SidebarView.swift:600-643).
  "Pin",
  "Unpin",
  "Open Beside",
  "Rename…",
  "Copy as Markdown",
  "Export as Markdown…",
  "Archive",
  "Unarchive",
  "Delete…",
  "Pinned",
  // A tab's own menu, the Mac's (TitleBar.swift:214-231).
  "Close Tab",
  "Close Other Tabs",
  "Close All Tabs",
  // The row at the top, which can be put away (GeneralSettings.swift:23).
  "Show the tab bar",
  // The appearance's own choices (Look.swift:42-63, AppearanceSettings.swift:9-77).
  "Window",
  "Typeface",
  "Agent’s steps",
  "Each Step",
  "Summarized",
  "Minimal",
  "Frosted glass that lets your desktop’s colors through.",
  "A solid background, with nothing showing through.",
  "Code always stays monospaced.",
  "Every step the agent takes, as it takes it.",
  "Only how many steps it took, to open if you want.",
  // The mode menu's tool permissions (ComposerMenus.swift:6-26, 120-135).
  "Tool Permissions",
  "Approve All",
  "Ask First",
  "Runs tools without asking",
  "Asks before editing files or running commands",
];

/// The transcript's own words, the same way.
const TRANSCRIPT = [
  "Show More",
  "Show Less",
  "Stopped",
  "Hide the steps",
  "Show each step",
];

/// The strings that are ours alone, and why.
const OURS = {
  "Before you start": "The note about what the app collects: the Windows client's facts are its own, so the Mac's wording would be a lie here.",
  "The engine's choice": "What the composer says when the engine has not chosen a model yet; the Mac shows the model's own name.",
  "Compact context": "The gauge's own action; the Mac compacts from the transcript, which this client does not have.",
  "Queue for After This Run": "The Mac's own name for the queue; ours says the same thing in the queue's own words.",
  "Show in Folder": "The Mac's \"Show in Finder\" opens the Finder; a Windows client opens the Explorer, and says so.",
};

test("the Mac says the shell's strings, and so does the app", () => {
  for (const text of [...SHELL, ...TRANSCRIPT]) {
    assert.ok(mac.includes(`"${text}"`), `the Mac says "${text}"`);
    // In the app a string is either a quoted one or a word between two tags.
    const said = app.includes(`"${text}"`) || app.includes(`>${text}<`) || app.includes(`> ${text} <`);
    assert.ok(said, `the app says "${text}"`);
  }
});

test("the strings that are ours alone are written down, with the reason", () => {
  // Every string the app says that the Mac does not, in the shell, is one of ours.
  for (const [text, reason] of Object.entries(OURS)) {
    assert.ok(reason.length > 20, `the reason for "${text}" is a reason`);
    assert.ok(app.includes(text), `the app says "${text}"`);
  }
});
