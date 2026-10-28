// Shared constants, helpers and small components for the Settings pages.

import { type ReactNode } from "react";
import { type SymbolName } from "./components/symbols";

/// What a list looks like before it arrives: rows of the shape it will have, shimmering
/// rather than saying "Loading…". The shimmer stops when motion is reduced.
export function SkeletonRows({ rows = 3, label = "Loading" }: { rows?: number; label?: string }) {
  return (
    <div className="skeleton-rows" role="status" aria-label={label}>
      {Array.from({ length: rows }, (_, index) => (
        <div className="skeleton-row" key={index} aria-hidden="true">
          <span className="skeleton-dot" />
          <span className="skeleton-line" style={{ width: `${58 + (index % 3) * 12}%` }} />
        </div>
      ))}
    </div>
  );
}

export const PAGES = [
  ["appearance", "Appearance"],
  ["general", "General"],
  ["keyboard", "Keyboard Shortcuts"],
  ["mcp", "MCP Servers"],
  ["agents", "Agents"],
  ["bots", "Bots"],
  ["skills", "Skills"],
  ["commands", "Commands"],
  ["projects", "Projects"],
  ["providers", "Providers"],
  ["accounts", "Accounts"],
  ["usage", "Usage"],
  ["git", "Git"],
  ["worktrees", "Worktrees"],
  ["storage", "Storage"],
  ["integrations", "Integrations"],
  ["browser", "Browser"],
  ["passwords", "Passwords"],
  ["phone", "Phone"],
  ["auto", "Custom Auto"],
  ["machines", "Machines"],
  ["archived", "Archived Sessions"],
  ["permissions", "Permissions"],
  ["system", "Engine & Storage"],
  ["notifications", "Notifications"],
  ["privacy", "Privacy"],
  ["panel", "Panel"],
] as const;

export const PAGE_GROUPS = [
  ["Kuvo Code", ["appearance", "general", "keyboard", "notifications", "privacy"]],
  ["Models", ["providers", "accounts", "usage", "auto"]],
  ["Agent", ["mcp", "agents", "bots", "skills", "commands", "permissions", "system"]],
  ["Projects", ["projects", "git", "worktrees", "machines", "archived"]],
  ["Side Panel", ["panel", "browser", "passwords"]],
  ["Engine", ["system", "storage", "integrations"]],
  ["Phone", ["phone"]],
] as const;

/// The Mac's three modes, in its order (Look.Mode).
export const MODES = [
  { value: "system", title: "System" },
  { value: "light", title: "Light" },
  { value: "dark", title: "Dark" },
];

export const PAGE_SUBTITLES: Record<string, string> = {
  appearance: "How Kuvo Code looks, and how conversations read.",
  keyboard: "Every keyboard shortcut in Kuvo Code.",
  mcp: "Programs and services that give the agent more tools.",
  agents: "The agents you pick in the composer, and the subagents they hand work to.",
  bots: "Your own bots: a name, a job, and the model that does it.",
  skills: "Instructions and scripts the agent loads when a task calls for them.",
  commands: "Prompts you use often, run by typing / and their name.",
  projects: "The folders and sessions you work in.",
  providers: "Sign in with a subscription you already have, or add an API key. Credentials stay on this machine.",
  accounts: "What's connected, the popular providers, and every other one the engine knows.",
  git: "Branches, commits and pull requests made from Kuvo Code.",
  worktrees: "Where they go, and the ones sessions have, with what each takes.",
  storage: "Where this machine keeps things, and what the engine is running.",
  integrations: "Services that give the agent more tools.",
  browser: "Not in Kuvo Code for Windows yet.",
  passwords: "Not in Kuvo Code for Windows yet.",
  phone: "Not in Kuvo Code for Windows yet.",
  auto: "Coding agents found on this computer. Running them here comes next.",
  machines: "Computers you reach over SSH. The list and a reachability test; remote sessions next.",
  archived: "Sessions you put away: still searchable, out of the sidebar.",
  permissions: "What the agent may do without asking you first.",
  notifications: "Not in Kuvo Code for Windows yet.",
  privacy: "What the app collects (nothing), and where your data is.",
  panel: "The Mac's side-panel choices; Windows doesn't read them yet.",
};

export const settingsPageTitle = (section: string) =>
  PAGES.find(([id]) => id === section)?.[1] ?? "Settings";

export const MCP_CATALOG = [
  { id: "linear", title: "Linear", summary: "Issues, projects and cycles", access: "needs an account", settings: { type: "remote", url: "https://mcp.linear.app/mcp" } },
  { id: "sentry", title: "Sentry", summary: "Errors and performance problems in your apps", access: "needs an account", settings: { type: "remote", url: "https://mcp.sentry.dev/mcp" } },
  { id: "notion", title: "Notion", summary: "Pages and databases in your workspace", access: "needs an account", settings: { type: "remote", url: "https://mcp.notion.com/mcp" } },
  { id: "atlassian", title: "Atlassian", summary: "Jira issues and Confluence pages", access: "needs an account", settings: { type: "remote", url: "https://mcp.atlassian.com/v2/mcp" } },
  { id: "stripe", title: "Stripe", summary: "Payments, customers and Stripe's docs", access: "needs an account", settings: { type: "remote", url: "https://mcp.stripe.com" } },
  { id: "supabase", title: "Supabase", summary: "Databases, auth and storage in your projects", access: "needs an account", settings: { type: "remote", url: "https://mcp.supabase.com/mcp" } },
  { id: "neon", title: "Neon", summary: "Postgres databases and branches", access: "needs an account", settings: { type: "remote", url: "https://mcp.neon.tech/mcp" } },
  { id: "context7", title: "Context7", summary: "Current docs and examples for libraries", access: "no account needed", settings: { type: "remote", url: "https://mcp.context7.com/mcp" } },
  { id: "cloudflare-docs", title: "Cloudflare Docs", summary: "Cloudflare's documentation", access: "no account needed", settings: { type: "remote", url: "https://docs.mcp.cloudflare.com/mcp" } },
  { id: "huggingface", title: "Hugging Face", summary: "Models, datasets, Spaces and papers", access: "no account needed", settings: { type: "remote", url: "https://huggingface.co/mcp" } },
  { id: "chrome-devtools", title: "Chrome DevTools", summary: "Inspect and debug pages in Google Chrome", access: "runs on this machine", settings: { type: "local", command: ["npx", "chrome-devtools-mcp@latest"] } },
];

export const AGENTS_BUILTIN = ["build", "plan", "general", "explore"];

export const idForName = (text: string) => text.trim().replace(/ /g, "-").replace(/[^a-zA-Z0-9_-]/g, "");
export const lowerIDForName = (text: string) => text.toLowerCase().trim().replace(/ /g, "-").replace(/[^a-z0-9_-]/g, "");
export const skillNameFrom = (text: string) => text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 64).replace(/[^a-z0-9-]/g, "");

/// The command as words (quotes hold spaces together); a word typed back quoted where needed.
export function commandWords(line: string): string[] {
  const words: string[] = [];
  let word = "";
  let quote: string | null = null;
  let escaped = false;
  let hasWord = false;
  for (const character of line) {
    if (escaped) { word += character; escaped = false; }
    else if (character === "\\" && quote !== "'") { escaped = true; hasWord = true; }
    else if (quote) { if (character === quote) quote = null; else word += character; }
    else if (character === '"' || character === "'") { quote = character; hasWord = true; }
    else if (character === " " || character === "\t") { if (hasWord) { words.push(word); word = ""; hasWord = false; } }
    else { word += character; hasWord = true; }
  }
  if (hasWord) words.push(word);
  return words;
}

export const commandQuoted = (word: string) =>
  word.includes(" ") || word.includes('"') || word.includes("'") || word.includes("\\")
    ? `"${word.replace(/\\/g, "\\\\").replace(/"/g, "\\\"")}"`
    : word;

export const commandLine = (command: unknown) =>
  (Array.isArray(command) ? command.filter(word => typeof word === "string") : []).map(commandQuoted).join(" ");

export const mcpDetail = (settings: Record<string, unknown> | undefined) => {
  if (!settings) return "";
  if (typeof settings.url === "string") return settings.url;
  if (Array.isArray(settings.command)) return settings.command.filter(word => typeof word === "string").join(" ");
  if (typeof settings.command === "string") return settings.command;
  return "";
};

export const skillText = (name: string, summary: string, body: string) => {
  const quote = (text: string) => `"${text.replace(/\\/g, "\\\\").replace(/"/g, "\\\"")}"`;
  return `---\nname: ${name}\ndescription: ${quote(summary.replace(/[\r\n]+/g, " ").trim())}\n---\n\n${body.trim()}\n`;
};

export const PAGE_SYMBOLS: Record<string, SymbolName> = {
  appearance: "paintpalette",
  general: "gearshape",
  keyboard: "command",
  mcp: "puzzlepiece.extension",
  agents: "person.2",
  bots: "bubble.left.and.text.bubble.right",
  skills: "graduationcap",
  commands: "slash.circle",
  projects: "folder",
  providers: "person.crop.circle",
  accounts: "person.crop.circle",
  usage: "gauge.with.dots.needle.50percent",
  git: "arrow.triangle.branch",
  worktrees: "arrow.triangle.branch",
  storage: "server.rack",
  integrations: "puzzlepiece.extension",
  browser: "globe",
  passwords: "checkmark.shield",
  phone: "questionmark.bubble",
  auto: "wand.and.stars",
  machines: "server.rack",
  archived: "archivebox",
  permissions: "checkmark.shield",
  system: "cpu",
  notifications: "bell",
  privacy: "checkmark.shield",
  panel: "sidebar.right",
};

export function SettingGroup({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="setting-group">
      <h3 className="setting-group-title">{title}</h3>
      <div className="setting-group-card">{children}</div>
    </section>
  );
}

/// A row: the setting's name, what it does under it, and the control at the right.
export function SettingRow({ label, note, children }: { label: string; note?: string; children?: ReactNode }) {
  return (
    <div className="settings-row">
      <span className="setting-row-label">
        <span>{label}</span>
        {note ? <span className="setting-row-note">{note}</span> : null}
      </span>
      <span className="setting-row-control">{children}</span>
    </div>
  );
}

