// The settings: the Mac app's pages, edited the same way — values in, changes into the
// engine's settings file, saved whole as they are made.

import { useEffect, useState } from "react";
import { Symbol, type SymbolName } from "./components/symbols";
import { api } from "./api";
import {
  clearShortcut,
  keyCaps,
  keysOf,
  recordShortcut,
  setRecording,
  SHORTCUT_GROUPS,
  specFromEvent,
  type Shortcut,
} from "./shortcuts";
import {
  applyLook,
  bootConfig,
  loadSessions,
  cfgGet,
  cfgSet,
  complain,
  look,
  lookAccents,
  notify,
  rememberTabBar,
  render,
  restartEngineNow,
  saveConfig,
  state,
  useStore,
  worktrees,
  createWorktree,
  removeWorktree,
} from "./store";

const PAGES = [
  ["appearance", "Appearance"],
  ["general", "General"],
  ["keyboard", "Keyboard Shortcuts"],
  ["mcp", "MCP Servers"],
  ["agents", "Agents"],
  ["skills", "Skills"],
  ["commands", "Commands"],
  ["projects", "Projects"],
  ["providers", "Providers"],
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

const PAGE_GROUPS = [
  ["Kuvo Code", ["appearance", "general", "keyboard", "notifications", "privacy"]],
  ["Models", ["providers", "usage", "auto"]],
  ["Agent", ["mcp", "agents", "skills", "commands", "permissions", "system"]],
  ["Projects", ["projects", "git", "worktrees", "machines", "archived"]],
  ["Side Panel", ["panel", "browser", "passwords"]],
  ["Engine", ["system", "storage", "integrations"]],
  ["Phone", ["phone"]],
] as const;

/// The Mac's three modes, in its order (Look.Mode).
const MODES = [
  { value: "system", title: "System" },
  { value: "light", title: "Light" },
  { value: "dark", title: "Dark" },
];

const PAGE_SUBTITLES: Record<string, string> = {
  appearance: "How Kuvo Code looks, and how conversations read.",
  keyboard: "Every keyboard shortcut in Kuvo Code.",
  mcp: "Programs and services that give the agent more tools.",
  agents: "The agents you pick in the composer, and the subagents they hand work to.",
  skills: "Instructions and scripts the agent loads when a task calls for them.",
  commands: "Prompts you use often, run by typing / and their name.",
  projects: "The folders and sessions you work in.",
  providers: "Sign in with a subscription you already have, or add an API key. Credentials stay on this machine.",
  git: "Branches, commits and pull requests made from Kuvo Code.",
  worktrees: "Where they go, and the ones sessions have, with what each takes.",
  storage: "Where this machine keeps things, and what the engine is running.",
  integrations: "Services that give the agent more tools.",
  browser: "The panel's browser: its search engine, history and website data.",
  passwords: "The sign-ins the panel's browser saved.",
  phone: "Pair Kuvo Code for iPhone with this Mac.",
  auto: "Your lists of models, one for bugfixes and one for features.",
  machines: "Linux servers whose engine Kuvo Code runs over SSH.",
  archived: "Sessions you put away: still searchable, out of the sidebar.",
  permissions: "What the agent may do without asking you first.",
  notifications: "When Kuvo Code tells you about a session, and how.",
  privacy: "Anonymous usage, and where your data is.",
  panel: "What the side panel starts with, and its new tab page.",
};

export const settingsPageTitle = (section: string) =>
  PAGES.find(([id]) => id === section)?.[1] ?? "Settings";

const MCP_CATALOG = [
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

const AGENTS_BUILTIN = ["build", "plan", "general", "explore"];

const idForName = (text: string) => text.trim().replace(/ /g, "-").replace(/[^a-zA-Z0-9_-]/g, "");
const lowerIDForName = (text: string) => text.toLowerCase().trim().replace(/ /g, "-").replace(/[^a-z0-9_-]/g, "");
const skillNameFrom = (text: string) => text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 64).replace(/[^a-z0-9-]/g, "");

/// The command as words (quotes hold spaces together); a word typed back quoted where needed.
function commandWords(line: string): string[] {
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

const commandQuoted = (word: string) =>
  word.includes(" ") || word.includes('"') || word.includes("'") || word.includes("\\")
    ? `"${word.replace(/\\/g, "\\\\").replace(/"/g, "\\\"")}"`
    : word;

const commandLine = (command: unknown) =>
  (Array.isArray(command) ? command.filter(word => typeof word === "string") : []).map(commandQuoted).join(" ");

const mcpDetail = (settings: Record<string, unknown> | undefined) => {
  if (!settings) return "";
  if (typeof settings.url === "string") return settings.url;
  if (Array.isArray(settings.command)) return settings.command.filter(word => typeof word === "string").join(" ");
  if (typeof settings.command === "string") return settings.command;
  return "";
};

const skillText = (name: string, summary: string, body: string) => {
  const quote = (text: string) => `"${text.replace(/\\/g, "\\\\").replace(/"/g, "\\\"")}"`;
  return `---\nname: ${name}\ndescription: ${quote(summary.replace(/[\r\n]+/g, " ").trim())}\n---\n\n${body.trim()}\n`;
};

export function Settings() {
  useStore();
  const [savedPermissions, setSavedPermissions] = useState<{ id: string; action?: string; resource?: string }[]>([]);
  const [system, setSystem] = useState<{ engine?: string; storage?: string; lists?: string }>({});
  const [search, setSearch] = useState("");

  useEffect(() => {
    void bootConfig();
    void api<{ permissions: { id: string; action?: string; resource?: string }[] }>("/api/permission/saved")
      .then(answer => setSavedPermissions(answer.permissions ?? []))
      .catch(() => setSavedPermissions([]));
    void api<{ engine?: { status: string; version?: string }; storage?: { log?: number; attachments?: number }; lists?: Record<string, unknown> }>("/api/state")
      .then(answer => setSystem({
        engine: answer.engine ? `${answer.engine.status}${answer.engine.version ? ` · ${answer.engine.version}` : ""}` : undefined,
        storage: answer.storage ? `${answer.storage.log ?? 0} log lines · ${answer.storage.attachments ?? 0} attachments` : undefined,
        lists: answer.lists
          ? Object.entries(answer.lists).map(([key, value]) => `${key}: ${Array.isArray(value) ? value.length : typeof value === "object" && value ? Object.keys(value).length : String(value)}`).join(" · ")
          : undefined,
      }))
      .catch(() => {});
  }, []);

  const section = state.settingsSection;
  const needle = search.trim().toLowerCase();
  const visiblePages = PAGES.filter(([, title]) => !needle || title.toLowerCase().includes(needle));
  const title = settingsPageTitle(section);
  const subtitle = PAGE_SUBTITLES[section];
  const page = (id: string) => {
    switch (id) {
      case "appearance": return <AppearancePage />;
      case "general": return <GeneralPage />;
      case "keyboard": return <KeyboardPage />;
      case "mcp": return <McpPage />;
      case "agents": return <AgentsPage />;
      case "skills": return <SkillsPage />;
      case "commands": return <CommandsPage />;
      case "projects": return <ProjectsPage />;
      case "providers": return <ProvidersPage />;
      case "usage": return <UsagePage />;
      case "git": return <GitPage />;
      case "worktrees": return <WorktreesPage />;
      case "storage": return <StoragePage />;
      case "integrations": return <IntegrationsPage />;
      case "browser": return <BrowserPage />;
      case "passwords": return <PasswordsPage />;
      case "phone": return <PhonePage />;
      case "auto": return <AutoPage />;
      case "machines": return <MachinesPage />;
      case "archived": return <ArchivedPage />;
      case "permissions": return <PermissionsPage permissions={savedPermissions} onChange={setSavedPermissions} />;
      case "notifications": return <NotificationsPage />;
      case "privacy": return <PrivacyPage />;
      case "panel": return <PanelPage />;
      default: return <SystemPage system={system} />;
    }
  };

  return (
    <div id="settings-modal" className={`settings ${state.settingsOpen ? "shown" : ""}`} hidden={!state.settingsOpen}>
      {/* Settings takes the sessions' place, the Mac's way: its sidebar on the glass,
          the open page in a card beside it (SettingsView.swift:24-73). */}
      <aside className="settings-sidebar">
        <div className="settings-heading">Settings</div>
        <label className="search-well settings-search">
          <svg viewBox="0 0 16 16" width="12" height="12" fill="none" aria-hidden="true">
            <circle cx="6.9" cy="6.9" r="4" stroke="currentColor" strokeWidth="1.2" />
            <path d="M9.9 9.9l3.2 3.2" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
          </svg>
          <input
            id="settings-search"
            value={search}
            placeholder="Search"
            spellCheck={false}
            onChange={event => setSearch(event.target.value)}
          />
        </label>
        <div className="settings-nav-scroll">
          <nav className="settings-nav">
            {PAGE_GROUPS.map(([group, ids]) => {
              const members = visiblePages.filter(([id]) => (ids as readonly string[]).includes(id));
              if (!members.length) return null;
              return (
                <div className="settings-group" key={group}>
                  <div className="settings-group-title">{group}</div>
                  {members.map(([id, name]) => (
                    <button
                      key={id}
                      data-section={id}
                      className={section === id ? "active" : ""}
                      onClick={() => { state.settingsSection = id; render(); }}
                    >
                      <Symbol name={PAGE_SYMBOLS[id] ?? "gearshape"} size={15} />
                      <span>{name}</span>
                    </button>
                  ))}
                </div>
              );
            })}
          </nav>
          {visiblePages.length === 0 ? <div className="settings-no-results">No Results</div> : null}
        </div>
      </aside>
      <section className="settings-content card">
        <div className="settings-content-head">
          <h1>{title}</h1>
          {subtitle ? <p>{subtitle}</p> : null}
        </div>
        <div className="settings-pages">
          {PAGES.map(([id]) => (
            <div className="settings-page" data-section={id} hidden={section !== id} key={id}>{page(id)}</div>
          ))}
        </div>
      </section>
    </div>
  );
}

/// The 18 pt mark column of the Settings sidebar: the Mac's own symbols, drawn
/// (SettingsView.swift:196-232) and kept in the app's symbol library.
const PAGE_SYMBOLS: Record<string, SymbolName> = {
  appearance: "paintpalette",
  general: "gearshape",
  keyboard: "command",
  mcp: "puzzlepiece.extension",
  agents: "person.2",
  skills: "graduationcap",
  commands: "slash.circle",
  projects: "folder",
  providers: "person.crop.circle",
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

function AppearancePage() {
  return (
    <>
      {/* The Mac's page: the mode first, then the colors, then the messages
          (AppearanceSettings.swift:16-80). */}
      <SettingGroup title="Mode">
        <div className="mode-choices">
          {MODES.map(mode => (
            <button
              key={mode.value}
              id={`mode-${mode.value}`}
              className={`mode-choice ${look.theme === mode.value ? "active" : ""}`}
              aria-pressed={look.theme === mode.value}
              onClick={() => { look.theme = mode.value; applyLook(); render(); }}
            >
              <span className={`mode-thumb ${mode.value}`} aria-hidden="true">
                <span className="mode-thumb-bar" />
                <span className="mode-thumb-card" />
              </span>
              <span className="mode-choice-title">{mode.title}</span>
            </button>
          ))}
        </div>
      </SettingGroup>
      <SettingGroup title="Colors">
        <SettingRow label="Accent" note={lookAccents[look.accent]?.title}>
          <div id="accent-swatches" className="swatches">
            {Object.entries(lookAccents).map(([key, accent]) => (
              <button
                key={key}
                className={`swatch ${look.accent === key ? "selected" : ""}`}
                data-accent={key}
                title={accent.title}
                style={{ background: accent.color || "var(--accent)" }}
                onClick={() => { look.accent = key; applyLook(); render(); }}
              />
            ))}
          </div>
        </SettingRow>
      </SettingGroup>
      <SettingGroup title="Messages">
        <SettingRow label="Text size" note="Messages, replies and the composer.">
          <select id="setting-text-size" value={look.textSize} onChange={event => { look.textSize = event.target.value; applyLook(); render(); }}>
            <option value="13">Small</option>
            <option value="14">Default</option>
          <option value="15.5">Large</option>
          <option value="17">Larger</option>
          </select>
        </SettingRow>
        {/* The Mac's window material (Look.swift:42-46) and its typeface of the
            messages (Look.swift:52-63), with the Mac's own words. */}
        <SettingRow label="Window" note={look.window === "glass" ? "Frosted glass that lets your desktop’s colors through." : "A solid background, with nothing showing through."}>
          <select id="setting-window" value={look.window} onChange={event => { look.window = event.target.value; applyLook(); render(); }}>
            <option value="glass">Glass</option>
            <option value="solid">Solid</option>
          </select>
        </SettingRow>
        <SettingRow label="Typeface" note="Code always stays monospaced.">
          <select id="setting-typeface" value={look.typeface} onChange={event => { look.typeface = event.target.value; applyLook(); render(); }}>
            <option value="system">System</option>
            <option value="rounded">Rounded</option>
            <option value="serif">Serif</option>
            <option value="monospaced">Monospaced</option>
          </select>
        </SettingRow>
        <SettingRow label="Agent’s steps" note={look.steps === "each" ? "Every step the agent takes, as it takes it." : look.steps === "summary" ? "Its steps between replies in a line, like “Ran 6 commands, read 3 files”, that opens to each." : "Only how many steps it took, to open if you want."}>
          <select id="setting-steps" value={look.steps} onChange={event => { look.steps = event.target.value; applyLook(); render(); }}>
            <option value="each">Each Step</option>
            <option value="summary">Summarized</option>
            <option value="minimal">Minimal</option>
          </select>
        </SettingRow>
        <SettingRow label="Motion" note="How much the app moves when something happens.">
          <select id="setting-motion" value={look.motion} onChange={event => { look.motion = event.target.value; applyLook(); render(); }}>
            <option value="full">Full</option>
            <option value="reduced">Reduced</option>
          </select>
        </SettingRow>
      </SettingGroup>
    </>
  );
}

/// General: the app's own ways — updates, starting at login, staying awake — and what
/// opencode already knows that this app could take over.
/// A group of settings, the Mac's grouped form (SettingsControls.swift:350-367): the
/// group's name, and its rows in a card under it.
function SettingGroup({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="setting-group">
      <h3 className="setting-group-title">{title}</h3>
      <div className="setting-group-card">{children}</div>
    </section>
  );
}

/// A row: the setting's name, what it does under it, and the control at the right.
function SettingRow({ label, note, children }: { label: string; note?: string; children?: React.ReactNode }) {
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

function GeneralPage() {
  const [settings, setSettings] = useState<{ updates: boolean; startAtLogin: boolean; keepAwake: boolean; path: string }>({
    updates: true, startAtLogin: false, keepAwake: false, path: "",
  });
  const [imported, setImported] = useState<string[] | null>(null);
  const [missing, setMissing] = useState<string[]>([]);

  useEffect(() => {
    void api<{ updates: boolean; startAtLogin: boolean; keepAwake: boolean; path: string }>("/api/app-settings")
      .then(answer => setSettings(answer))
      .catch(() => {});
  }, []);

  const set = async (next: Partial<typeof settings>) => {
    try {
      const answer = await api<typeof settings>("/api/app-settings", { method: "PUT", body: next });
      setSettings(answer);
    } catch (error) {
      complain(error);
    }
  };

  return (
    <>
      {/* The Mac's Window group (GeneralSettings.swift:12-30): the row at the top. */}
      <SettingGroup title="Window">
        <SettingRow
          label="Show the tab bar"
          note="The row at the top, with the project, its branch and your sessions as tabs. Without it, switch sessions in the sidebar or with Ctrl+K."
        >
          <input
            type="checkbox"
            checked={state.showsTabBar}
            onChange={event => { rememberTabBar(event.target.checked); render(); }}
          />
        </SettingRow>
      </SettingGroup>
      <SettingGroup title="Updates">
        <SettingRow label="Check for updates automatically" note="Updates are signed and come from Kuvo Code's releases.">
          <input type="checkbox" checked={settings.updates} onChange={event => void set({ updates: event.target.checked })} />
        </SettingRow>
      </SettingGroup>
      <SettingGroup title="While Agents Work">
        <SettingRow
          label="Keep this machine awake"
          note="It doesn't go to sleep on its own while an agent works on it; the display still can."
        >
          <input type="checkbox" checked={settings.keepAwake} onChange={event => void set({ keepAwake: event.target.checked })} />
        </SettingRow>
      </SettingGroup>
      <SettingGroup title="Startup">
        <SettingRow label="Start at login" note="Open Kuvo Code when you sign in to this machine.">
          <input type="checkbox" checked={settings.startAtLogin} onChange={event => void set({ startAtLogin: event.target.checked })} />
        </SettingRow>
      </SettingGroup>
      <div className="settings-note">The app's own settings live next to its data ({settings.path || "in the shell's folder"}).</div>
      <h3>Bring over from opencode</h3>
      <div className="settings-row">
        <span>What opencode already knows</span>
        <button
          className="small"
          onClick={async () => {
            try {
              const answer = await api<{ added: string[]; skipped: string[] }>("/api/config/import", { method: "POST", body: {} });
              setImported(answer.added ?? []);
              await bootConfig();
              // Everything may already be here, and a sign-in may still be missing — say which.
              const { integrations } = await api<{ integrations: { id: string; name?: string; connections?: unknown[] }[] }>("/api/integrations")
                .catch(() => ({ integrations: [] as { id: string; name?: string; connections?: unknown[] }[] }));
              setMissing((integrations ?? []).filter(one => !(one.connections ?? []).length).map(one => one.name ?? one.id));
            } catch (error) {
              complain(error);
            }
          }}
        >
          Bring it over
        </button>
      </div>
      {imported ? (
        <div className="settings-note">
          {imported.length
            ? `Brought over: ${imported.join(", ")}.`
            : missing.length
              ? `Everything from opencode is here already, but a sign-in is still missing: ${missing.join(", ")}.`
              : "Everything from opencode is here already."}
        </div>
      ) : null}
      <div className="settings-note">The MCP servers, the agents, the commands and the model that opencode's own settings hold, copied into this app's settings. Your keys stay where they are.</div>
    </>
  );
}

/// The shortcuts, by where they are used — the Mac app's own list, in our key names — and the
/// recorder that changes them. The Mac's page only lists them (the system's own settings
/// change a menu command's shortcut there); Windows has no such place, so the keys are
/// recorded here and kept in this app's settings.
function KeyboardPage() {
  const [search, setSearch] = useState("");
  const needle = search.trim().toLowerCase();
  const groups = SHORTCUT_GROUPS
    .map(([title, shortcuts]) => [title, shortcuts.filter(shortcut => !needle || `${shortcut.keys} ${shortcut.title}`.toLowerCase().includes(needle))] as [string, Shortcut[]])
    .filter(([, shortcuts]) => shortcuts.length > 0);
  return (
    <>
      <div className="settings-row">
        <span>Search</span>
        <input type="text" value={search} placeholder="Search shortcuts" onChange={event => setSearch(event.target.value)} />
      </div>
      {groups.length === 0 ? <div className="settings-note">No shortcut matches.</div> : groups.map(([title, shortcuts]) => (
        <div key={title}>
          <h3>{title}</h3>
          {shortcuts.map(shortcut => (
            <div className="settings-row" key={shortcut.id}><span>{shortcut.title}</span><ShortcutKeys shortcut={shortcut} /></div>
          ))}
        </div>
      ))}
      <div className="settings-note">To change a shortcut, click its keys and press the new ones.</div>
    </>
  );
}

/// The keys of one shortcut, and the recorder that changes them. The recorder takes the
/// press the way the Mac's does: Esc leaves it, Delete clears the shortcut, and a chord
/// needs a real modifier (Ctrl or Alt) — Shift alone would take the typing away.
function ShortcutKeys({ shortcut }: { shortcut: Shortcut }) {
  const [recording, setIsRecording] = useState(false);
  const [refused, setRefused] = useState(false);
  const keys = keysOf(shortcut.id);

  useEffect(() => {
    if (!recording) return;
    const onKey = (event: KeyboardEvent) => {
      event.preventDefault();
      event.stopPropagation();
      const bare = !event.ctrlKey && !event.altKey && !event.shiftKey;
      if (bare && event.key === "Escape") { setIsRecording(false); return; }
      if (bare && (event.key === "Delete" || event.key === "Backspace")) {
        setIsRecording(false);
        void clearShortcut(shortcut.id);
        return;
      }
      const next = specFromEvent(event);
      if (!next) { setRefused(true); return; }
      setRefused(false);
      setIsRecording(false);
      void recordShortcut(shortcut.id, next);
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [recording, shortcut.id]);

  // While the recorder listens, the app's own keys stay quiet — the Mac does the same (it
  // disables the hotkey for as long as the recorder listens).
  useEffect(() => {
    setRecording(recording);
    return () => setRecording(false);
  }, [recording]);

  if (shortcut.plain) {
    return <span className="keycap-row">{keyCaps(keys).map(part => <kbd key={part}>{part}</kbd>)}</span>;
  }

  return (
    <span className="keycap-row">
      <button
        type="button"
        className={`keycap-button ${recording ? "recording" : ""}`}
        title={recording ? "Press the new keys (Esc leaves it)" : "Record Shortcut"}
        onClick={() => { setRefused(false); setIsRecording(value => !value); }}
      >
        {recording ? "Type Shortcut…" : keys}
      </button>
      {!recording && keys.length > 0 ? (
        <button type="button" className="keycap-clear" title="Clear Shortcut" aria-label="Clear Shortcut" onClick={() => void clearShortcut(shortcut.id)}>
          <Symbol name="xmark" size={9} />
        </button>
      ) : null}
      {refused ? <span className="settings-note">A shortcut needs Ctrl or Alt.</span> : null}
    </span>
  );
}

function ProjectsPage() {
  const [projects, setProjects] = useState<string[]>(state.projects);
  useEffect(() => {
    void api<{ projects: string[] }>("/api/projects").then(answer => setProjects(answer.projects ?? [])).catch(() => {});
  }, []);
  return (
    <>
      {projects.map(project => (
        <div className="cfg-row" key={project}>
          <div className="cfg-row-main"><div className="cfg-row-title"><strong>{project}</strong></div></div>
        </div>
      ))}
      <div className="settings-note">The folders this machine has worked in, newest first.</div>
    </>
  );
}

/// Providers: the ones the engine knows, and the ones you add yourself — with their
/// address and their models. The key stays where it is: in your own opencode settings.
function ProvidersPage() {
  const [known, setKnown] = useState<{ id: string; name?: string }[]>([]);
  const [id, setId] = useState("");
  const [name, setName] = useState("");
  const [baseURL, setBaseURL] = useState("");
  const [model, setModel] = useState("");
  const [modelName, setModelName] = useState("");
  const [saved, setSaved] = useState("");

  useEffect(() => {
    void api<{ providers: { id: string; name?: string }[] }>("/api/providers")
      .then(answer => setKnown(answer.providers ?? []))
      .catch(() => {});
  }, []);

  const mine = (cfgGet(["provider"]) as Record<string, Record<string, unknown>>) ?? {};
  const mineIds = Object.keys(mine);

  const add = async () => {
    const fresh = id.trim().toLowerCase().replace(/[^a-z0-9_-]/g, "");
    if (!fresh) { complain(new Error("A provider needs an id: letters, digits, dashes.")); return; }
    if (mine[fresh]) { complain(new Error(`There is already a provider called ${fresh}.`)); return; }
    const entry: Record<string, unknown> = { name: name.trim() || fresh, options: { baseURL: baseURL.trim() } };
    if (model.trim()) entry.models = { [model.trim()]: { name: modelName.trim() || model.trim() } };
    cfgSet(["provider", fresh], entry);
    const ok = await saveConfig();
    if (ok) {
      setSaved(fresh);
      setId(""); setName(""); setBaseURL(""); setModel(""); setModelName("");
    }
  };

  return (
    <>
      <h3>The engine's own</h3>
      <div id="providers-known">
        {known.length === 0 ? <div className="where">Loading…</div> : known.map(provider => (
          <div className="cfg-row" key={provider.id}>
            <div className="cfg-row-main">
              <div className="cfg-row-title"><strong>{provider.name ?? provider.id}</strong><span className="where">{provider.id}</span></div>
            </div>
          </div>
        ))}
      </div>
      <h3>Your own</h3>
      <div id="providers-mine">
        {mineIds.length === 0 ? <div className="where">None yet.</div> : mineIds.map(providerId => (
          <div className="cfg-row" key={providerId}>
            <div className="cfg-row-main">
              <div className="cfg-row-title">
                <strong>{String(mine[providerId]?.name ?? providerId)}</strong>
                <span className="where">{String((mine[providerId]?.options as { baseURL?: string })?.baseURL ?? "")}</span>
              </div>
            </div>
            <button
              className="small"
              onClick={async () => {
                cfgSet(["provider", providerId], null);
                await saveConfig();
              }}
            >
              Remove
            </button>
          </div>
        ))}
      </div>
      <h3>Add a provider</h3>
      <div className="settings-row"><span>Id</span><input type="text" value={id} placeholder="my-provider" onChange={event => setId(event.target.value)} /></div>
      <div className="settings-row"><span>Name</span><input type="text" value={name} placeholder="My provider" onChange={event => setName(event.target.value)} /></div>
      <div className="settings-row"><span>Address</span><input type="text" value={baseURL} placeholder="https://api.example.com/v1" onChange={event => setBaseURL(event.target.value)} /></div>
      <div className="settings-row"><span>Model</span><input type="text" value={model} placeholder="my-model" onChange={event => setModel(event.target.value)} /></div>
      <div className="settings-row"><span>Model name</span><input type="text" value={modelName} placeholder="My model" onChange={event => setModelName(event.target.value)} /></div>
      <div className="settings-editor-buttons">
        <button className="primary" onClick={() => void add()}>Add the provider</button>
        {saved ? <span className="where">{`${saved} is added.`}</span> : null}
      </div>
      <div className="settings-note">A provider you add here is written to the engine's settings with its address and its models. The key is not written here: it stays where opencode keeps it, and the engine finds it as it does in a terminal.</div>
    </>
  );
}

/// What the agent has spent, in this project: the cost and the tokens the engine reports for
/// each session, and the total.
///
/// The Mac app's panel (UsageKit, the menu-bar app) also reads each provider's *own* plan —
/// Copilot, Codex, Grok, OpenRouter, Z.ai — with the keys the engine holds. We do not read
/// those: the keys stay where opencode keeps them, and a provider's plan is the provider's
/// to tell. What the engine ran and what it cost is ours to show.
function UsagePage() {
  const sessions = state.sessions;
  const cost = sessions.reduce((sum, session) => sum + (session.cost ?? 0), 0);
  const tokens = sessions.reduce(
    (sum, session) => ({
      input: sum.input + (session.tokens?.input ?? 0),
      output: sum.output + (session.tokens?.output ?? 0),
      reasoning: sum.reasoning + (session.tokens?.reasoning ?? 0),
    }),
    { input: 0, output: 0, reasoning: 0 },
  );
  const byModel = new Map<string, { name: string; cost: number; sessions: number }>();
  for (const session of sessions) {
    const name = session.model?.id ?? "the model";
    const entry = byModel.get(name) ?? { name, cost: 0, sessions: 0 };
    entry.cost += session.cost ?? 0;
    entry.sessions += 1;
    byModel.set(name, entry);
  }
  const models = [...byModel.values()].sort((left, right) => right.cost - left.cost);

  return (
    <>
      <h3>This project</h3>
      <div className="settings-row"><span>What the agent has spent</span><span>{`$${cost.toFixed(4)}`}</span></div>
      <div className="settings-row"><span>Tokens read</span><span>{tokens.input.toLocaleString()}</span></div>
      <div className="settings-row"><span>Tokens written</span><span>{tokens.output.toLocaleString()}</span></div>
      <div className="settings-row"><span>Tokens thought</span><span>{tokens.reasoning.toLocaleString()}</span></div>
      {models.length === 0 ? <div className="where">No session has run yet.</div> : (
        <>
          <h3>By model</h3>
          {models.map(model => (
            <div className="settings-row" key={model.name}>
              <span>{model.name}</span>
              <span>{`${model.sessions} session${model.sessions === 1 ? "" : "s"} · $${model.cost.toFixed(4)}`}</span>
            </div>
          ))}
        </>
      )}
      <h3>By session</h3>
      {sessions.length === 0 ? <div className="where">No session yet.</div> : sessions.map(session => (
        <div className="settings-row" key={session.id}>
          <span>{session.title?.trim() || "A session"}</span>
          <span>{`$${(session.cost ?? 0).toFixed(4)}`}</span>
        </div>
      ))}
      <div className="settings-note">What the engine ran and what it cost, read from the engine's own sessions. The Mac app's menu-bar panel also follows each provider's plan — that needs the provider's sign-in, which this app deliberately leaves where opencode keeps it.</div>
    </>
  );
}

/// Git: how a branch is named, and how commit and pull-request messages are written —
/// the Mac app's Git settings, ours.
function GitPage() {
  const [git, setGit] = useState({ branchPrefix: "", commitInstructions: "", pullRequestInstructions: "" });
  useEffect(() => {
    void api<{ git?: typeof git }>("/api/app-settings")
      .then(answer => setGit({ branchPrefix: answer.git?.branchPrefix ?? "", commitInstructions: answer.git?.commitInstructions ?? "", pullRequestInstructions: answer.git?.pullRequestInstructions ?? "" }))
      .catch(() => {});
  }, []);

  const set = async (next: Partial<typeof git>) => {
    const merged = { ...git, ...next };
    setGit(merged);
    try {
      await api("/api/app-settings", { method: "PUT", body: { git: merged } });
    } catch (error) {
      complain(error);
    }
  };

  return (
    <>
      <div className="settings-row column">
        <span>Branch prefix</span>
        <input
          type="text"
          value={git.branchPrefix}
          placeholder="kuvo/"
          onChange={event => void set({ branchPrefix: event.target.value })}
        />
        <div className="where">What a session's own branch starts with. It is named after the session once it has a title.</div>
      </div>
      <div className="settings-row column">
        <span>Commit Messages</span>
        <textarea
          rows={3}
          value={git.commitInstructions}
          placeholder="For example: Start with the area changed, like “ui: …”, and never mention tickets."
          onChange={event => void set({ commitInstructions: event.target.value })}
        />
        <div className="where">Added when the Changes panel asks the model for a message.</div>
      </div>
      <div className="settings-row column">
        <span>Pull Requests</span>
        <textarea
          rows={3}
          value={git.pullRequestInstructions}
          placeholder="For example: Add a Testing section, and link the issue if the branch names one."
          onChange={event => void set({ pullRequestInstructions: event.target.value })}
        />
        <div className="where">Added when a pull request is written.</div>
      </div>
    </>
  );
}

/// Notifications: when Kuvo Code tells you about a session, and how (GeneralSettings.swift:166-194).
function NotificationsPage() {
  const [notifies, setNotifies] = useState(() => localStorage.getItem("kuvo-notify-sessions") !== "0");
  const [sound, setSound] = useState(() => localStorage.getItem("kuvo-notify-sound") !== "0");
  const [badge, setBadge] = useState(() => localStorage.getItem("kuvo-notify-badge") !== "0");
  const persist = (key: string, value: boolean) => localStorage.setItem(key, value ? "1" : "0");
  return (
    <>
      <SettingGroup title="Sessions">
        <SettingRow label="Sessions" note="When a session finishes or needs your answer while you're in another app. A permission request can be answered from its notification.">
          <input type="checkbox" checked={notifies} onChange={event => { setNotifies(event.target.checked); persist("kuvo-notify-sessions", event.target.checked); }} />
        </SettingRow>
        <SettingRow label="Play a sound" note="With each notification.">
          <input type="checkbox" checked={sound} disabled={!notifies} onChange={event => { setSound(event.target.checked); persist("kuvo-notify-sound", event.target.checked); }} />
        </SettingRow>
        <SettingRow label="Count on the Dock icon" note="The sessions that finished while you were away, or wait for you.">
          <input type="checkbox" checked={badge} onChange={event => { setBadge(event.target.checked); persist("kuvo-notify-badge", event.target.checked); }} />
        </SettingRow>
      </SettingGroup>
      <SettingGroup title="System">
        <SettingRow label="System notification settings" note="macOS asks the first time there's something to tell. To change how they look, or to allow them again, use System Settings.">
          <button className="small" onClick={() => (window as unknown as { kuvo?: { openExternal?: (url: string) => void } }).kuvo?.openExternal?.("ms-settings:notifications")}>Open…</button>
        </SettingRow>
      </SettingGroup>
    </>
  );
}

/// Privacy: anonymous usage, and where your data is (GeneralSettings.swift:203-230).
function PrivacyPage() {
  const [analytics, setAnalytics] = useState(() => localStorage.getItem("kuvo-analytics") !== "0");
  return (
    <>
      <SettingGroup title="Anonymous Usage">
        <SettingRow label="Share anonymous usage" note="Which features you use and how often, and what kind of trouble you run into, with the app and Windows versions. Never your code, prompts, files or accounts.">
          <input type="checkbox" checked={analytics} onChange={event => { setAnalytics(event.target.checked); localStorage.setItem("kuvo-analytics", event.target.checked ? "1" : "0"); }} />
        </SettingRow>
        <SettingRow label="What's sent">
          <button className="small" onClick={() => (window as unknown as { kuvo?: { openExternal?: (url: string) => void } }).kuvo?.openExternal?.("https://www.kuvo.run/code/docs/privacy/")}>Privacy and Data</button>
        </SettingRow>
      </SettingGroup>
      <SettingGroup title="On This Machine">
        <SettingRow label="Sessions and accounts" note="Kept on this machine, in Kuvo Code's own folder. Messages go only to the model providers you choose.">
          <button className="small" onClick={() => { state.settingsSection = "system"; render(); }}>Storage…</button>
        </SettingRow>
      </SettingGroup>
    </>
  );
}

/// The side panel: what it starts with, and the new tab page (BrowserSettings.swift:5-30).
function PanelPage() {
  const [startsWith, setStartsWith] = useState(() => localStorage.getItem("kuvo-panel-starts") ?? "changes");
  const [reveals, setReveals] = useState(() => localStorage.getItem("kuvo-panel-reveals") !== "0");
  const [tidies, setTidies] = useState(() => localStorage.getItem("kuvo-panel-tidies") !== "0");
  const [tools, setTools] = useState(() => localStorage.getItem("kuvo-panel-tools") !== "0");
  const [suggestions, setSuggestions] = useState(() => localStorage.getItem("kuvo-panel-suggestions") !== "0");
  const [count, setCount] = useState(() => parseInt(localStorage.getItem("kuvo-panel-count") ?? "8", 10));
  const persist = (key: string, value: string | boolean) => localStorage.setItem(key, String(value));
  return (
    <>
      <SettingGroup title="Panel">
        <SettingRow label="Start each panel with" note="The first time you open a session's, bot's or group chat's panel.">
          <select value={startsWith} onChange={event => { setStartsWith(event.target.value); persist("kuvo-panel-starts", event.target.value); }}>
            <option value="changes">Changes</option>
            <option value="files">Files</option>
            <option value="terminal">Terminal</option>
          </select>
        </SettingRow>
        <SettingRow label="Show the panel when the agent browses" note="So you can watch it, and step in.">
          <input type="checkbox" checked={reveals} onChange={event => { setReveals(event.target.checked); persist("kuvo-panel-reveals", event.target.checked); }} />
        </SettingRow>
        <SettingRow label="Close agents' tabs you haven't looked at" note="An hour after an agent last used one, so tabs don't pile up.">
          <input type="checkbox" checked={tidies} onChange={event => { setTidies(event.target.checked); persist("kuvo-panel-tidies", event.target.checked); }} />
        </SettingRow>
      </SettingGroup>
      <SettingGroup title="New Tab Page">
        <SettingRow label="Tools" note="Changes, Terminal and Files, as tiles to open, and a way here.">
          <input type="checkbox" checked={tools} onChange={event => { setTools(event.target.checked); persist("kuvo-panel-tools", event.target.checked); }} />
        </SettingRow>
        <SettingRow label="Suggested sites" note="The sites you visit most in the panel's browser.">
          <input type="checkbox" checked={suggestions} onChange={event => { setSuggestions(event.target.checked); persist("kuvo-panel-suggestions", event.target.checked); }} />
        </SettingRow>
        <SettingRow label="Number of sites">
          <select value={count} disabled={!suggestions} onChange={event => { setCount(parseInt(event.target.value, 10)); persist("kuvo-panel-count", event.target.value); }}>
            {[4, 8, 12, 16].map(number => <option key={number} value={number}>{number}</option>)}
          </select>
        </SettingRow>
      </SettingGroup>
    </>
  );
}

/// Worktrees: where they go, and the ones sessions have, with what each takes (GitSettings.swift:60-136).
function WorktreesPage() {
  const [removing, setRemoving] = useState<string | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const list = worktrees();
  const remove = async (root: string, force = false) => {
    setRemoving(root);
    try { await removeWorktree(root, force); setRemoving(null); render(); } catch (error) { setFailure(String(error)); setRemoving(null); }
  };
  const create = async () => {
    setCreating(true);
    try { await createWorktree(); setCreating(false); render(); } catch (error) { setFailure(String(error)); setCreating(false); }
  };
  return (
    <>
      <SettingGroup title="Worktrees">
        {list.length === 0 ? (
          <div className="settings-note">None yet. Create one to give a session its own copy of the project.</div>
        ) : list.map(item => (
          <SettingRow key={item.root} label={item.branch} note={`${item.project} · ${item.root}`}>
            <button className="small" onClick={() => (window as unknown as { kuvo?: { showInFolder?: (path: string) => void } }).kuvo?.showInFolder?.(item.root)}>Show in Folder</button>
            <button className="small" disabled={removing === item.root} onClick={() => void remove(item.root)}>{removing === item.root ? "Removing…" : "Remove…"}</button>
          </SettingRow>
        ))}
        {failure ? <div className="settings-note" style={{ color: "var(--danger)" }}>{failure}</div> : null}
      </SettingGroup>
      <SettingGroup title="Create">
        <SettingRow label="New worktree" note="A copy of the project on a branch of its own, for a session to work in apart from the rest.">
          <button className="small" disabled={creating || !state.project} onClick={() => void create()}>{creating ? "Creating…" : "Create"}</button>
        </SettingRow>
      </SettingGroup>
    </>
  );
}

/// Storage: where this machine keeps things, and what the engine is running (StorageSettings.swift).
function StoragePage() {
  const [info, setInfo] = useState<{ logPath?: string; logSize?: number; attachments?: { path: string; files: number; bytes: number } | null; engine?: { status: string; version?: string } }>({});
  useEffect(() => {
    void api<typeof info>("/api/storage").then(answer => setInfo(answer)).catch(() => {});
  }, []);
  return (
    <>
      <SettingGroup title="Engine">
        <div className="gauge-line big">{info.engine ? `${info.engine.status}${info.engine.version ? ` · ${info.engine.version}` : ""}` : "—"}</div>
      </SettingGroup>
      <SettingGroup title="Storage">
        <SettingRow label="Log" note={info.logPath ?? ""}>
          <button className="small" onClick={() => (window as unknown as { kuvo?: { showInFolder?: (path: string) => void } }).kuvo?.showInFolder?.(info.logPath ?? "")}>Show in Folder</button>
        </SettingRow>
        <SettingRow label="Attachments" note={info.attachments ? `${info.attachments.files} files · ${info.attachments.bytes} bytes` : "None yet."} />
        <div className="settings-note">Where this machine keeps things, and what the engine is running — what the Mac app's Engine and Storage settings show.</div>
      </SettingGroup>
    </>
  );
}

/// Integrations: services that give the agent more tools.
function IntegrationsPage() {
  const [integrations, setIntegrations] = useState<{ id: string; name?: string; connections?: unknown[] }[]>([]);
  useEffect(() => {
    void api<{ integrations: { id: string; name?: string; connections?: unknown[] }[] }>("/api/integrations")
      .then(answer => setIntegrations(answer.integrations ?? []))
      .catch(() => setIntegrations([]));
  }, []);
  return (
    <>
      <SettingGroup title="Integrations">
        {integrations.length === 0 ? (
          <div className="settings-note">None yet.</div>
        ) : integrations.map(one => (
          <SettingRow key={one.id} label={one.name ?? one.id} note={(one.connections ?? []).length ? "Connected" : "Not connected"}>
            <span className="where">{(one.connections ?? []).length ? "Connected" : "Not connected"}</span>
          </SettingRow>
        ))}
      </SettingGroup>
    </>
  );
}

/// Browser: the panel's browser, its search engine, history and website data (BrowserSettings.swift).
function BrowserPage() {
  const [engine, setEngine] = useState("google");
  const [historyCount, setHistoryCount] = useState(0);
  useEffect(() => {
    const stored = localStorage.getItem("kuvo-browser-engine");
    if (stored) setEngine(stored);
  }, []);
  const set = (value: string) => { setEngine(value); localStorage.setItem("kuvo-browser-engine", value); };
  return (
    <>
      <SettingGroup title="Search">
        <SettingRow label="Search engine" note="For anything you type in the address field that isn't an address.">
          <select value={engine} onChange={event => set(event.target.value)}>
            <option value="google">Google</option>
            <option value="bing">Bing</option>
            <option value="duckduckgo">DuckDuckGo</option>
          </select>
        </SettingRow>
        <SettingRow label="Browsing history" note={historyCount ? `${historyCount} sites, which the new tab page suggests.` : "None yet."}>
          <button className="small" onClick={() => { localStorage.removeItem("kuvo-browser-history"); setHistoryCount(0); }}>Clear</button>
        </SettingRow>
      </SettingGroup>
      <SettingGroup title="Website Data">
        <SettingRow label="Website data" note="Sign-ins, cookies and what sites store, kept apart from your other browsers. Removing a site's data signs you out of it.">
          <button className="small" onClick={() => (window as unknown as { kuvo?: { showInFolder?: (path: string) => void } }).kuvo?.showInFolder?.(localStorage.getItem("kuvo-browser-data") ?? "")}>Remove All…</button>
        </SettingRow>
      </SettingGroup>
    </>
  );
}

/// Passwords: the sign-ins the panel's browser saved (PasswordsSettings.swift).
function PasswordsPage() {
  const [offers, setOffers] = useState(() => localStorage.getItem("kuvo-passwords-offers") !== "0");
  return (
    <>
      <SettingGroup title="Passwords">
        <SettingRow label="Offer to save passwords" note="When you sign in to a site in the panel's browser. Click the key in its toolbar to fill one in.">
          <input type="checkbox" checked={offers} onChange={event => { setOffers(event.target.checked); localStorage.setItem("kuvo-passwords-offers", event.target.checked ? "1" : "0"); }} />
        </SettingRow>
      </SettingGroup>
      <div className="settings-note">Kept in your credential store, where the system lists them too. Kuvo Code fills one in only when you ask, and the agent never sees them.</div>
    </>
  );
}

/// Phone: pairing Kuvo Code for iPhone with this Mac (PhoneSettings.swift).
function PhonePage() {
  return (
    <>
      <SettingGroup title="Pair">
        <div className="settings-note">Pair a phone from the Kuvo Code app on your iPhone: scan the QR code it shows. The phone link is switched on in General.</div>
        <SettingRow label="Pair a Phone…">
          <button className="small" disabled>Pair a Phone…</button>
        </SettingRow>
      </SettingGroup>
      <SettingGroup title="Phones">
        <div className="settings-note">None yet.</div>
      </SettingGroup>
    </>
  );
}

/// Auto: your lists of models, one for bugfixes and one for features (AutoSettings.swift).
function AutoPage() {
  return (
    <>
      <SettingGroup title="Custom Auto">
        <div className="settings-note">Custom Auto runs with the coding agents, which aren't available on this client yet. When they are, your lists of models — one for bugfixes, one for features — go here, each tried in order when one reaches a limit.</div>
      </SettingGroup>
    </>
  );
}

/// Machines: Linux servers whose engine Kuvo Code runs over SSH (MachinesSettings.swift).
function MachinesPage() {
  return (
    <>
      <SettingGroup title="Machines">
        <div className="settings-note">Linux servers you reach with SSH, like a home server or a VPS. Their projects open next to this machine's, and their sessions run there. Kuvo Code installs its engine on each.</div>
        <SettingRow label="Add Machine…">
          <button className="small" disabled>Add Machine…</button>
        </SettingRow>
      </SettingGroup>
    </>
  );
}

/// The sessions that are put away: out of the sidebar, still here, brought back or deleted.
function ArchivedPage() {
  const [sessions, setSessions] = useState<{ id: string; title?: string | null; time?: { updated?: number } }[]>([]);
  const [query, setQuery] = useState("");

  const load = async () => {
    try {
      const { sessions } = await api<{ sessions: { id: string; title?: string | null; time?: { updated?: number; archived?: number }; metadata?: Record<string, unknown> | null }[] }>(`/api/sessions?directory=${encodeURIComponent(state.project ?? "")}`);
      setSessions((sessions ?? []).filter(session => Boolean(session.time?.archived) || session.metadata?.["kuvo.archived"] === true));
    } catch {
      setSessions([]);
    }
  };
  useEffect(() => { void load(); }, [state.project]);

  const shown = sessions.filter(session => !query || (session.title || "").toLowerCase().includes(query.toLowerCase()));
  return (
    <>
      <div className="settings-row">
        <span>Search archived sessions</span>
        <input type="text" value={query} placeholder="Search" onChange={event => setQuery(event.target.value)} />
      </div>
      {shown.length === 0 ? (
        <div className="settings-note">None yet. Put a session away with the archive button beside it, and it comes here.</div>
      ) : shown.map(session => (
        <div className="cfg-row" key={session.id}>
          <div className="cfg-row-main">
            <div className="cfg-row-title"><strong>{session.title || "Untitled"}</strong></div>
          </div>
          <button
            className="small"
            onClick={async () => {
              try {
                await api(`/api/sessions/${encodeURIComponent(session.id)}/archive`, { method: "POST", body: { archived: false } });
                await load();
                await loadSessions();
              } catch (error) { complain(error); }
            }}
          >
            Unarchive
          </button>
          <button
            className="small"
            title="Delete it for good"
            onClick={async () => {
              if (!confirm("Delete it for good?")) return;
              try {
                await api(`/api/sessions/${encodeURIComponent(session.id)}`, { method: "DELETE" });
                await load();
              } catch (error) { complain(error); }
            }}
          >
            <Symbol name="xmark" size={11} />
          </button>
        </div>
      ))}
    </>
  );
}

function PermissionsPage({ permissions, onChange }: {
  permissions: { id: string; action?: string; resource?: string }[];
  onChange: (next: { id: string; action?: string; resource?: string }[]) => void;
}) {
  return (
    <>
      <SettingGroup title="Rules">
        <div id="saved-permissions" className="saved-permissions">
        {permissions.map(rule => (
          <div key={rule.id} className="cfg-row">
            <div className="cfg-row-main">
              <div className="cfg-row-title">
                <strong>{rule.action ?? "rule"}</strong>
                <span className="where">{rule.resource ?? ""}</span>
              </div>
            </div>
            <button
              className="small"
              onClick={async () => {
                try {
                  await api(`/api/permission/saved/${encodeURIComponent(rule.id)}`, { method: "DELETE" });
                  onChange(permissions.filter(item => item.id !== rule.id));
                } catch (error) { complain(error); }
              }}
            >
              Forget
            </button>
          </div>
        ))}
        </div>
        <div className="settings-note">What this session's agent was once told it may always do, as the engine remembers it.</div>
      </SettingGroup>
    </>
  );
}

function SystemPage({ system }: { system: { engine?: string; storage?: string; lists?: string } }) {
  return (
    <>
      <SettingGroup title="Engine">
        <div id="engine-line" className="gauge-line big">{system.engine ?? ""}</div>
      </SettingGroup>
      <SettingGroup title="Storage">
        <div id="storage-log" className="gauge-line">{system.storage ?? ""}</div>
        <div id="storage-attachments" className="gauge-line" />
        <div id="config-lists" className="gauge-line">{system.lists ?? ""}</div>
        <div className="settings-note">Where this machine keeps things, and what the engine is running — what the Mac app's Engine and Storage settings show.</div>
      </SettingGroup>
    </>
  );
}

// ---- MCP ----

function McpPage() {
  const [, refresh] = useState(0);
  const configured = Object.keys((cfgGet(["mcp", "servers"]) as Record<string, unknown>) ?? {});
  const live = state.mcpLive.map(server => server.name);
  const names = [...new Set([...configured, ...live])].filter(name => name !== "kuvo-browser").sort();
  const statusOf = (name: string) => state.mcpLive.find(server => server.name === name)?.status;

  const statusText = (name: string) => {
    const settings = cfgGet(["mcp", "servers", name]) as Record<string, unknown> | undefined;
    if (settings?.disabled === true) return "Off";
    switch (statusOf(name)?.status) {
      case "connected": return "Connected";
      case "pending": return "Connecting…";
      case "needs_auth": return "Needs sign-in";
      case "failed": return `Couldn't connect${statusOf(name)?.error ? ` — ${statusOf(name)?.error}` : ""}`;
      case "disabled": return "Off";
      default: return "Not started";
    }
  };

  return (
    <>
      <div className="cfg-problem" id="mcp-problem" hidden={!state.configProblem}>
        {state.configProblem ? `The settings file (${state.configPath}) has a problem: ${state.configProblem}` : ""}
      </div>
      <h3>Servers</h3>
      <div id="mcp-list">
        {names.length === 0 ? <div className="where">None yet.</div> : names.map(name => {
          const settings = cfgGet(["mcp", "servers", name]) as Record<string, unknown> | undefined;
          const isOn = settings ? settings.disabled !== true : true;
          return (
            <div className="cfg-row" key={name}>
              <div className="cfg-row-main">
                <div className="cfg-row-title"><strong>{name}</strong><span className="where">{statusText(name)}</span></div>
                {settings ? <div className="where">{mcpDetail(settings)}</div> : null}
              </div>
              {isOn && statusOf(name)?.status === "failed" ? (
                <button className="small" onClick={async () => {
                  try { await api(`/api/mcp/${encodeURIComponent(name)}/connect`, { method: "POST", body: {} }); }
                  catch (error) { complain(error); }
                  refresh(value => value + 1);
                }}>Try Again</button>
              ) : null}
              {settings ? (
                <>
                  <button className="small" onClick={() => { state.cfgEditor = { kind: "mcp", id: name }; state.settingsSection = "editor"; render(); }}>Edit…</button>
                  <input
                    type="checkbox"
                    title={`Turn on or off ${name}`}
                    checked={isOn}
                    onChange={async event => {
                      cfgSet(["mcp", "servers", name, "disabled"], event.target.checked ? null : true);
                      await saveConfig();
                    }}
                  />
                </>
              ) : null}
            </div>
          );
        })}
      </div>
      <button id="mcp-add" className="primary" onClick={() => { state.cfgEditor = { kind: "mcp", id: null }; state.settingsSection = "editor"; render(); }}>Add Server…</button>
      <h3>Popular Servers</h3>
      <div id="mcp-catalog">
        {MCP_CATALOG.map(server => {
          const added = (cfgGet(["mcp", "servers", server.id]) as unknown) != null;
          return (
            <div className="cfg-row" key={server.id}>
              <div className="cfg-row-main">
                <div className="cfg-row-title"><strong>{server.title}</strong><span className="where">{server.access}</span></div>
                <div className="where">{server.summary}</div>
              </div>
              {added ? <span className="where">Added</span> : (
                <button className="small" onClick={async () => {
                  cfgSet(["mcp", "servers", server.id], { ...server.settings, codemode: false });
                  await saveConfig();
                }}>Add</button>
              )}
            </div>
          );
        })}
      </div>
      <h3>Timeouts</h3>
      {(["startup", "catalog", "execution"] as const).map(key => (
        <div className="settings-row" key={key}>
          <span>{{ startup: "Time to start, in milliseconds", catalog: "Time to list tools, in milliseconds", execution: "Time for one tool call, in milliseconds" }[key]}</span>
          <input
            type="number"
            value={String(cfgGet(["mcp", "timeout", key]) ?? "")}
            onChange={async event => {
              cfgSet(["mcp", "timeout", key], event.target.value === "" ? null : Number(event.target.value));
              await saveConfig();
            }}
          />
        </div>
      ))}
      <button id="engine-restart" className="secondary" onClick={async () => {
        try { await restartEngineNow(); await bootConfig(); }
        catch (error) { complain(error); }
      }}>Restart the engine</button>
      <h3>From opencode's own settings</h3>
      <OpencodeMcp onDone={() => refresh(value => value + 1)} />
      <div className="settings-note">MCP servers give the agent more tools, like a database, an issue tracker or your design files. A server on this machine runs a command; one on the web is a URL. To keep a key out of the settings file, write {'{env:NAME}'} to use one of your environment variables.</div>
      <ConfigEditor />
    </>
  );
}

function OpencodeMcp({ onDone }: { onDone: () => void }) {
  const theirs = state.opencode?.settings;
  const mcp = theirs && typeof theirs.mcp === "object" && theirs.mcp ? (theirs.mcp as Record<string, unknown>) : {};
  const servers: Record<string, unknown> = {};
  for (const [name, entry] of Object.entries((mcp.servers as Record<string, unknown>) ?? {})) servers[name] = entry;
  for (const [name, entry] of Object.entries(mcp)) {
    if (name === "servers" || !entry || typeof entry !== "object" || Array.isArray(entry)) continue;
    if (!servers[name]) servers[name] = entry;
  }
  const ours = (cfgGet(["mcp", "servers"]) as Record<string, unknown>) ?? {};

  const bring = async (name?: string) => {
    try {
      const answer = await api<{ added: string[]; skipped: string[] }>("/api/config/import", { method: "POST", body: name ? { name } : {} });
      if (answer.added?.length) {
        notify("Kuvo Code", `${answer.added.join(", ")} ${answer.added.length === 1 ? "is" : "are"} here now. The engine reads them in a moment.`);
        await restartEngineNow();
      } else {
        notify("Kuvo Code", "It was already here.");
      }
      await bootConfig();
      onDone();
    } catch (error) {
      complain(error);
    }
  };

  return (
    <>
      <div id="opencode-mcp">
        {Object.keys(servers).length === 0 ? <div className="where">Nothing there yet.</div> : Object.entries(servers).map(([name, entry]) => {
          const here = ours[name] != null;
          return (
            <div className="cfg-row" key={name}>
              <div className="cfg-row-main">
                <div className="cfg-row-title"><strong>{name}</strong>{here ? <span className="where ok">Already here</span> : null}</div>
                <div className="where">{mcpDetail(entry as Record<string, unknown>)}</div>
              </div>
              {here ? null : <button className="small" onClick={() => void bring(name)}>Add here</button>}
            </div>
          );
        })}
      </div>
      <button id="opencode-import-all" className="secondary" hidden={!Object.keys(servers).some(name => ours[name] == null)} onClick={() => void bring()}>
        Bring them all over
      </button>
      <div className="settings-note" id="opencode-path">{state.opencode?.path ? `opencode's own settings: ${state.opencode.path}` : ""}</div>
    </>
  );
}

// ---- The editors ----

function ConfigEditor() {
  const editor = state.cfgEditor;
  if (!editor) return null;
  if (editor.kind === "mcp") return <McpEditor id={editor.id} />;
  if (editor.kind === "agent") return <AgentEditor id={editor.id} />;
  if (editor.kind === "skill") return <SkillEditor id={editor.id} />;
  if (editor.kind === "command") return <CommandEditor id={editor.id} />;
  return null;
}

function EditorShell({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="settings-page" data-section="editor">
      <div id="editor-title" className="settings-detail-title">{title}</div>
      <div id="editor-fields">{children}</div>
      <div className="settings-editor-buttons" id="editor-buttons" />
    </div>
  );
}

function McpEditor({ id }: { id: string | null }) {
  const [name, setName] = useState("");
  if (!id) {
    return (
      <EditorShell title="Add Server">
        <div className="settings-row"><span>Name</span><input type="text" value={name} placeholder="github" onChange={event => setName(event.target.value)} /></div>
        <div className="where">Names use lowercase letters, digits, hyphens and underscores. The server's tools are named after it.</div>
        <div className="settings-editor-buttons">
          <button className="primary" onClick={async () => {
            const fresh = idForName(name);
            if (!fresh) { complain(new Error("A name needs a letter or a number.")); return; }
            if (cfgGet(["mcp", "servers", fresh]) != null) { complain(new Error(`There's a server called ${fresh} already.`)); return; }
            cfgSet(["mcp", "servers", fresh], { type: "local", command: [], disabled: true, codemode: false });
            await saveConfig();
            state.cfgEditor = { kind: "mcp", id: fresh };
            render();
          }}>Create Server</button>
        </div>
      </EditorShell>
    );
  }
  const base = ["mcp", "servers", id];
  const settings = (cfgGet(base) as Record<string, unknown>) ?? {};
  const isRemote = settings.type === "remote";
  const [command, setCommand] = useState(commandLine(settings.command));
  const [url, setUrl] = useState(String(settings.url ?? ""));
  return (
    <EditorShell title={id}>
      <div className="settings-row">
        <span>Runs</span>
        <select
          value={isRemote ? "remote" : "local"}
          onChange={async event => {
            const value = event.target.value;
            if (value === (isRemote ? "remote" : "local")) return;
            if (value === "remote") {
              cfgSet([...base, "command"], null);
              cfgSet([...base, "disabled"], true);
              cfgSet([...base, "type"], "remote");
            } else {
              cfgSet([...base, "url"], null);
              cfgSet([...base, "disabled"], true);
              cfgSet([...base, "type"], "local");
            }
            await saveConfig();
            render();
          }}
        >
          <option value="local">On this machine</option>
          <option value="remote">On the web</option>
        </select>
      </div>
      {isRemote ? (
        <div className="settings-row">
          <span>URL</span>
          <input
            type="text"
            value={url}
            placeholder="https://example.com/mcp"
            onChange={event => setUrl(event.target.value)}
            onBlur={async () => {
              cfgSet([...base, "url"], url === "" ? null : url);
              cfgSet([...base, "disabled"], url === "" ? true : null);
              await saveConfig();
            }}
          />
        </div>
      ) : (
        <div className="settings-row column">
          <span>Command</span>
          <textarea
            rows={2}
            value={command}
            placeholder="npx -y @modelcontextprotocol/server-github"
            onChange={event => setCommand(event.target.value)}
            onBlur={async () => {
              const words = commandWords(command);
              cfgSet([...base, "command"], words);
              cfgSet([...base, "disabled"], words.length ? null : true);
              await saveConfig();
            }}
          />
        </div>
      )}
      <div className="settings-row">
        <span>Let the agent call its tools from code</span>
        <input
          type="checkbox"
          checked={settings.codemode !== false}
          onChange={async event => {
            cfgSet([...base, "codemode"], event.target.checked ? null : false);
            await saveConfig();
          }}
        />
      </div>
      <div className="settings-editor-buttons">
        <button
          className="danger small"
          onClick={async () => {
            if (!confirm("Remove it?")) return;
            cfgSet(base, null);
            await saveConfig();
            state.cfgEditor = null;
            state.settingsSection = "mcp";
            render();
          }}
        >
          Remove Server…
        </button>
        <button className="primary" onClick={() => { state.cfgEditor = null; state.settingsSection = "mcp"; render(); }}>Done</button>
      </div>
    </EditorShell>
  );
}

function AgentEditor({ id }: { id: string | null }) {
  const [name, setName] = useState("");
  if (!id) {
    return (
      <EditorShell title="New Agent">
        <div className="settings-row"><span>Name</span><input type="text" value={name} placeholder="reviewer" onChange={event => setName(event.target.value)} /></div>
        <div className="where">A short name without spaces. It's how the agent is chosen.</div>
        <div className="settings-editor-buttons">
          <button className="primary" onClick={async () => {
            const fresh = lowerIDForName(name);
            if (!fresh) { complain(new Error("A name needs a letter or a number.")); return; }
            if (cfgGet(["agents", fresh]) != null) { complain(new Error(`There's an agent called ${fresh} already.`)); return; }
            cfgSet(["agents", fresh], { mode: "primary", description: "" });
            await saveConfig();
            state.cfgEditor = { kind: "agent", id: fresh };
            render();
          }}>Create Agent</button>
        </div>
      </EditorShell>
    );
  }
  const base = ["agents", id];
  const settings = (cfgGet(base) as Record<string, unknown>) ?? {};
  const live = state.agents.find(agent => agent.id === id);
  const builtIn = AGENTS_BUILTIN.includes(id) || live?.hidden === true;
  return (
    <EditorShell title={id}>
      <div className="where">{`Agent: ${live?.name ?? id}${builtIn ? " (built into the engine)" : ""}`}</div>
      <div className="settings-row column">
        <span>Description</span>
        <textarea
          rows={3}
          defaultValue={String(settings.description ?? "")}
          placeholder="What it's for, so the agent knows when to use it"
          onBlur={async event => {
            cfgSet([...base, "description"], event.target.value === "" ? null : event.target.value);
            await saveConfig();
          }}
        />
      </div>
      <div className="settings-row">
        <span>Use as</span>
        <select
          value={String(settings.mode ?? live?.mode ?? "primary")}
          onChange={async event => {
            cfgSet([...base, "mode"], event.target.value);
            await saveConfig();
          }}
        >
          <option value="primary">Mode</option>
          <option value="subagent">Subagent</option>
          <option value="all">Mode and subagent</option>
        </select>
      </div>
      <div className="settings-row">
        <span>Use this agent</span>
        <input
          type="checkbox"
          checked={settings.disabled !== true}
          onChange={async event => {
            cfgSet([...base, "disabled"], event.target.checked ? null : true);
            await saveConfig();
          }}
        />
      </div>
      <div className="settings-row column">
        <span>Instructions</span>
        <textarea
          rows={8}
          defaultValue={String(settings.system ?? "")}
          placeholder={builtIn ? "Leave empty to keep the engine's own. Anything here replaces them." : "How it should work. The project's AGENTS.md, skills and MCP servers still apply."}
          onBlur={async event => {
            cfgSet([...base, "system"], event.target.value === "" ? null : event.target.value);
            await saveConfig();
          }}
        />
      </div>
      <div className="settings-editor-buttons">
        <button
          className="danger small"
          onClick={async () => {
            if (!confirm("Remove it?")) return;
            cfgSet(base, null);
            await saveConfig();
            state.cfgEditor = null;
            state.settingsSection = "agents";
            render();
          }}
        >
          Remove Agent…
        </button>
        <button className="primary" onClick={() => { state.cfgEditor = null; state.settingsSection = "agents"; render(); }}>Done</button>
      </div>
    </EditorShell>
  );
}

function SkillEditor({ id }: { id: string | null }) {
  const [name, setName] = useState("");
  const [summary, setSummary] = useState("");
  const [body, setBody] = useState("");
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    if (!id || loaded) return;
    void api<{ text: string }>(`/api/skill-file/${id}`)
      .then(answer => {
        const text = answer.text ?? "";
        const header = text.startsWith("---") ? text.indexOf("\n---", 3) : -1;
        const match = header >= 0 ? text.slice(3, header).match(/^description:\s*["']?(.*?)["']?\s*$/m) : null;
        setSummary(match ? match[1] : "");
        setBody(header >= 0 ? text.slice(text.indexOf("\n", header + 4) + 1) : text);
        setLoaded(true);
      })
      .catch(() => setLoaded(true));
  }, [id, loaded]);

  const save = async () => {
    const fresh = id ?? skillNameFrom(name);
    if (!fresh) { complain(new Error("Names use the letters a to z and digits, and this one has none.")); return; }
    try {
      await api(`/api/skill-file/${fresh}`, { method: "PUT", body: { text: skillText(fresh, summary, body) } });
      await bootConfig();
      state.cfgEditor = null;
      state.settingsSection = "skills";
      render();
    } catch (error) {
      complain(error);
    }
  };

  return (
    <EditorShell title={id ?? "New Skill"}>
      <div className="settings-row"><span>Name</span><input type="text" value={id ?? name} placeholder="writing well" disabled={id != null} onChange={event => setName(event.target.value)} /></div>
      <div className="settings-row column">
        <span>Description</span>
        <textarea rows={2} value={summary} placeholder="What it's for: the agent reaches for the skill by this." onChange={event => setSummary(event.target.value)} />
      </div>
      <div className="settings-row column">
        <span>Instructions</span>
        <textarea rows={10} value={body} placeholder="When a task calls for this, the agent loads it: how to do it, step by step." onChange={event => setBody(event.target.value)} />
      </div>
      <div className="settings-editor-buttons">
        {id ? (
          <button
            className="danger small"
            onClick={async () => {
              if (!confirm("Delete this skill?")) return;
              await api(`/api/skill-file/${id}`, { method: "DELETE" }).catch(error => complain(error));
              await bootConfig();
              state.cfgEditor = null;
              state.settingsSection = "skills";
              render();
            }}
          >
            Delete Skill…
          </button>
        ) : null}
        <button className="primary" onClick={() => void save()}>Save Skill</button>
      </div>
    </EditorShell>
  );
}

function CommandEditor({ id }: { id: string | null }) {
  const [name, setName] = useState("");
  const base = id ? ["commands", id] : null;
  const settings = (base ? cfgGet(base) : {}) as Record<string, unknown>;
  return (
    <EditorShell title={id ? `/${id}` : "New Command"}>
      {!id ? (
        <div className="settings-row"><span>Name</span><input type="text" value={name} placeholder="test" onChange={event => setName(event.target.value)} /></div>
      ) : null}
      <div className="settings-row column">
        <span>Description</span>
        <textarea
          rows={3}
          defaultValue={String(settings.description ?? "")}
          placeholder="Shown in the list when you type /"
          onBlur={async event => {
            if (!base) return;
            cfgSet([...base, "description"], event.target.value === "" ? null : event.target.value);
            await saveConfig();
          }}
        />
      </div>
      {base ? (
        <div className="settings-row column">
          <span>Prompt</span>
          <textarea
            rows={9}
            defaultValue={String(settings.template ?? "")}
            placeholder="What the agent gets. $ARGUMENTS is what you type after the command; $1, $2 and so on are its words."
            onBlur={async event => {
              cfgSet([...base, "template"], event.target.value);
              await saveConfig();
            }}
          />
        </div>
      ) : null}
      <div className="settings-editor-buttons">
        {base ? (
          <button
            className="danger small"
            onClick={async () => {
              if (!confirm("Remove it?")) return;
              cfgSet(base, null);
              await saveConfig();
              state.cfgEditor = null;
              state.settingsSection = "commands";
              render();
            }}
          >
            Delete Command…
          </button>
        ) : null}
        <button
          className="primary"
          onClick={async () => {
            if (!id) {
              const fresh = idForName(name);
              if (!fresh) { complain(new Error("A name needs a letter or a number.")); return; }
              if (cfgGet(["commands", fresh]) != null) { complain(new Error(`There's a command called /${fresh} already.`)); return; }
              cfgSet(["commands", fresh], { template: "" });
              await saveConfig();
              state.cfgEditor = { kind: "command", id: fresh };
              render();
              return;
            }
            state.cfgEditor = null;
            state.settingsSection = "commands";
            render();
          }}
        >
          {id ? "Done" : "Create Command"}
        </button>
      </div>
    </EditorShell>
  );
}

// ---- Agents, skills, commands ----

function AgentsPage() {
  const configured = Object.keys((cfgGet(["agents"]) as Record<string, unknown>) ?? {});
  const ids = [...AGENTS_BUILTIN, ...configured].filter((id, index, all) => all.indexOf(id) === index && !["compaction", "title", "summary"].includes(id));
  const primary = state.agents.filter(agent => agent.mode === "primary" && !["build", "compaction", "title", "summary"].includes(agent.id));
  return (
    <>
      <div className="cfg-problem" id="agents-problem" hidden={!state.configProblem} />
      <div className="settings-row">
        <span>Mode for new sessions</span>
        <select
          value={String(cfgGet(["default_agent"]) ?? "")}
          onChange={async event => {
            cfgSet(["default_agent"], event.target.value === "" ? null : event.target.value);
            await saveConfig();
          }}
        >
          <option value="">Build</option>
          {primary.map(agent => <option key={agent.id} value={agent.id}>{agent.name ?? agent.id}</option>)}
        </select>
      </div>
      <div className="settings-row">
        <span>Model for new sessions</span>
        <ModelSelect path={["model"]} empty="The engine's choice" />
      </div>
      <div className="settings-row">
        <span>Model for session titles</span>
        <ModelSelect path={["agents", "title", "model"]} empty="The session's model" />
      </div>
      <h3>Agents</h3>
      <div id="agents-list">
        {ids.map(id => {
          const settings = (cfgGet(["agents", id]) as Record<string, unknown>) ?? {};
          const live = state.agents.find(agent => agent.id === id);
          const mode = String(settings.mode ?? live?.mode ?? "primary");
          return (
            <div className="cfg-row" key={id}>
              <div className="cfg-row-main">
                <div className="cfg-row-title">
                  <strong>{live?.name ?? id}</strong>
                  <span className="where">{mode === "subagent" ? "Subagent" : mode === "all" ? "Mode and subagent" : "Mode"}</span>
                  {settings.disabled === true ? <span className="where warn">Off</span> : null}
                </div>
                {settings.description ? <div className="where">{String(settings.description)}</div> : null}
              </div>
              <button className="small" onClick={() => { state.cfgEditor = { kind: "agent", id }; state.settingsSection = "editor"; render(); }}>Edit…</button>
            </div>
          );
        })}
      </div>
      <button id="agent-new" className="primary" onClick={() => { state.cfgEditor = { kind: "agent", id: null }; state.settingsSection = "editor"; render(); }}>New Agent…</button>
      <div className="settings-note">Modes are the agents you pick in the composer. Subagents are ones the agent hands part of a task to. New sessions use the model you picked last; the upper one is for when there's none. A small, fast model is enough for titles.</div>
    </>
  );
}

function ModelSelect({ path, empty }: { path: string[]; empty: string }) {
  const current = typeof cfgGet(path) === "string" ? String(cfgGet(path)) : "";
  const providers = new Map<string, { id: string; providerID: string; name?: string }[]>();
  for (const model of state.models) {
    if (!providers.has(model.providerID)) providers.set(model.providerID, []);
    providers.get(model.providerID)!.push(model);
  }
  return (
    <select
      value={current}
      onChange={async event => {
        cfgSet(path, event.target.value === "" ? null : event.target.value);
        await saveConfig();
      }}
    >
      <option value="">{empty}</option>
      {[...providers.entries()].map(([provider, models]) => (
        <optgroup key={provider} label={provider}>
          {models.map(model => <option key={`${model.providerID}/${model.id}`} value={`${model.providerID}/${model.id}`}>{model.name ?? model.id}</option>)}
        </optgroup>
      ))}
    </select>
  );
}

function SkillsPage() {
  const skillOn = (id: string) => {
    const items = (cfgGet(["permissions"]) as { action?: string; resource?: string; effect?: string }[]) ?? [];
    return !items.some(item => item?.action === "skill" && item?.resource === id && item?.effect === "deny");
  };
  return (
    <>
      <div className="cfg-problem" id="skills-problem" hidden={!state.configProblem} />
      <h3>Skills the Agent Can Use</h3>
      <div id="skills-list">
        {state.skillsEngine.length === 0 ? <div className="where">None yet.</div> : state.skillsEngine.map(skill => {
          const own = typeof skill.path === "string" && !skill.path.startsWith("/builtin");
          return (
            <div className="cfg-row" key={skill.id}>
              <div className="cfg-row-main">
                <div className="cfg-row-title">
                  <strong>{skill.name ?? skill.id}</strong>
                  <span className="where">{own ? "the skills folder" : "the engine's own"}</span>
                </div>
                {skill.description ? <div className="where">{skill.description}</div> : null}
              </div>
              {own ? <button className="small" onClick={() => { state.cfgEditor = { kind: "skill", id: skill.id }; state.settingsSection = "editor"; render(); }}>Edit…</button> : null}
              <input
                type="checkbox"
                title={`Use ${skill.name ?? skill.id}`}
                checked={skillOn(skill.id)}
                onChange={async event => {
                  const items = ((cfgGet(["permissions"]) as { action?: string; resource?: string; effect?: string }[]) ?? [])
                    .filter(item => !(item?.action === "skill" && item?.resource === skill.id && item?.effect === "deny"));
                  if (!event.target.checked) items.push({ action: "skill", resource: skill.id, effect: "deny" });
                  cfgSet(["permissions"], items.length ? items : null);
                  await saveConfig();
                }}
              />
            </div>
          );
        })}
      </div>
      <button id="skill-new" className="primary" onClick={() => { state.cfgEditor = { kind: "skill", id: null }; state.settingsSection = "editor"; render(); }}>New Skill…</button>
      <div className="settings-note" id="skills-folder" />
      <div className="settings-note">The agent loads a skill when a task calls for it. Skills in ~/.claude/skills and ~/.agents/skills, and in a project's .opencode/skills, are found on their own.</div>
    </>
  );
}

function CommandsPage() {
  const names = Object.keys((cfgGet(["commands"]) as Record<string, unknown>) ?? {}).sort();
  const own = state.commands.filter(command => !names.includes(command.name));
  return (
    <>
      <div className="cfg-problem" id="commands-problem" hidden={!state.configProblem} />
      <h3>Your Commands</h3>
      <div id="commands-list">
        {names.length === 0 ? <div className="where">None yet.</div> : names.map(name => {
          const settings = (cfgGet(["commands", name]) as Record<string, unknown>) ?? {};
          return (
            <div className="cfg-row" key={name}>
              <div className="cfg-row-main">
                <div className="cfg-row-title"><strong>{`/${name}`}</strong></div>
                {settings.description ? <div className="where">{String(settings.description)}</div> : null}
              </div>
              <button className="small" onClick={() => { state.cfgEditor = { kind: "command", id: name }; state.settingsSection = "editor"; render(); }}>Edit…</button>
            </div>
          );
        })}
      </div>
      <button id="command-new" className="primary" onClick={() => { state.cfgEditor = { kind: "command", id: null }; state.settingsSection = "editor"; render(); }}>New Command…</button>
      <h3>The engine's own</h3>
      <div id="commands-others">
        {own.length === 0 ? <div className="where">None.</div> : own.map(command => (
          <div className="cfg-row" key={command.name}>
            <div className="cfg-row-main">
              <div className="cfg-row-title"><strong>{`/${command.name}`}</strong></div>
              {command.description ? <div className="where">{command.description}</div> : null}
            </div>
          </div>
        ))}
      </div>
      <div className="settings-note">Type / and a command's name at the start of a message to run it. What you type after the name fills in $ARGUMENTS; $1, $2 and so on are its words. !`command` puts in a command's output.</div>
    </>
  );
}
