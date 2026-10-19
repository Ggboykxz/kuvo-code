// The settings: the Mac app's pages, edited the same way — values in, changes into the
// engine's settings file, saved whole as they are made.

import { useEffect, useState } from "react";
import { api } from "./api";
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
  render,
  restartEngineNow,
  saveConfig,
  state,
  useStore,
} from "./store";

const PAGES = [
  ["appearance", "Appearance"],
  ["general", "General"],
  ["keyboard", "Keyboard"],
  ["mcp", "MCP servers"],
  ["agents", "Agents"],
  ["skills", "Skills"],
  ["commands", "Commands"],
  ["projects", "Projects"],
  ["archived", "Archived sessions"],
  ["permissions", "Permissions"],
  ["system", "Engine & storage"],
] as const;

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
      case "archived": return <ArchivedPage />;
      case "permissions": return <PermissionsPage permissions={savedPermissions} onChange={setSavedPermissions} />;
      default: return <SystemPage system={system} />;
    }
  };

  return (
    <div id="settings-modal" className={`settings ${state.settingsOpen ? "shown" : ""}`} hidden={!state.settingsOpen} onClick={event => { if (event.target === event.currentTarget) { state.settingsOpen = false; render(); } }}>
      <div className="settings-card wide">
        <div className="settings-shell">
          <nav className="settings-nav">
            {PAGES.map(([id, title]) => (
              <button key={id} data-section={id} className={section === id ? "active" : ""} onClick={() => { state.settingsSection = id; render(); }}>{title}</button>
            ))}
          </nav>
          <div className="settings-pages">
            {PAGES.map(([id]) => (
              <div className="settings-page" data-section={id} hidden={section !== id} key={id}>{page(id)}</div>
            ))}
          </div>
        </div>
      </div>
      <button id="settings-close" className="primary" onClick={() => { state.settingsOpen = false; render(); }}>Done</button>
    </div>
  );
}

function AppearancePage() {
  return (
    <>
      <div className="settings-row">
        <span>Accent</span>
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
      </div>
      <div className="settings-row">
        <span>Mode</span>
        <select id="setting-theme" value={look.theme} onChange={event => { look.theme = event.target.value; applyLook(); render(); }}>
          <option value="system">System</option>
          <option value="light">Light</option>
          <option value="dark">Dark</option>
        </select>
      </div>
      <div className="settings-row">
        <span>Text size</span>
        <select id="setting-text-size" value={look.textSize} onChange={event => { look.textSize = event.target.value; applyLook(); render(); }}>
          <option value="13">Small</option>
          <option value="14">Default</option>
          <option value="16">Large</option>
        </select>
      </div>
      <div className="settings-row">
        <span>Motion</span>
        <select id="setting-motion" value={look.motion} onChange={event => { look.motion = event.target.value; applyLook(); render(); }}>
          <option value="full">Full</option>
          <option value="reduced">Reduced</option>
        </select>
      </div>
      <div className="settings-note">The look is bound to OpenDesign's design direction "modern minimal — Linear / Vercel": system fonts, hairline borders, one accent. The accent you pick here is the one colour the app uses; everything else stays quiet.</div>
    </>
  );
}

/// General: the app's own ways — updates, starting at login, staying awake — and what
/// opencode already knows that this app could take over.
function GeneralPage() {
  const [settings, setSettings] = useState<{ updates: boolean; startAtLogin: boolean; keepAwake: boolean; path: string }>({
    updates: true, startAtLogin: false, keepAwake: false, path: "",
  });
  const [imported, setImported] = useState<string[] | null>(null);

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
      <div className="settings-row">
        <span>Automatic updates</span>
        <input type="checkbox" checked={settings.updates} onChange={event => void set({ updates: event.target.checked })} />
      </div>
      <div className="settings-row">
        <span>Start at login</span>
        <input type="checkbox" checked={settings.startAtLogin} onChange={event => void set({ startAtLogin: event.target.checked })} />
      </div>
      <div className="settings-row">
        <span>Keep this machine awake</span>
        <input type="checkbox" checked={settings.keepAwake} onChange={event => void set({ keepAwake: event.target.checked })} />
      </div>
      <div className="settings-note">The app's own settings live next to its data ({settings.path || "in the shell's folder"}). Keeping the machine awake stops the screen from sleeping while a long run is going.</div>
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
          {imported.length ? `Brought over: ${imported.join(", ")}.` : "Nothing new — it is all here already."}
        </div>
      ) : null}
      <div className="settings-note">The MCP servers, the agents, the commands and the model that opencode's own settings hold, copied into this app's settings. Your keys stay where they are.</div>
    </>
  );
}

/// Every keyboard shortcut, by where it's used — the Mac app's own list, for ours.
const SHORTCUT_GROUPS: [string, [string, string][]][] = [
  ["General", [
    ["Ctrl+K", "The command palette: commands, sessions and files"],
    ["Ctrl+N", "A new session"],
    ["Ctrl+S", "Save the conversation as Markdown"],
    ["Ctrl+,", "These settings"],
    ["Esc", "Close what is open"],
  ]],
  ["Sessions", [
    ["Ctrl+F", "Find in the conversation"],
    ["Ctrl+.", "Stop the agent"],
    ["Ctrl+1 – 8", "That session tab"],
  ]],
  ["Side panel", [
    ["Ctrl+Shift+F", "Files and terminal"],
    ["Ctrl+Shift+C", "The changes of this session"],
  ]],
  ["Composer", [
    ["Return", "Send"],
    ["Shift+Return", "A new line"],
    ["/", "At the start: a command"],
    ["@", "Mention a file"],
  ]],
];

function KeyboardPage() {
  const [search, setSearch] = useState("");
  const needle = search.trim().toLowerCase();
  const groups = SHORTCUT_GROUPS
    .map(([title, shortcuts]) => [title, shortcuts.filter(([keys, what]) => !needle || `${keys} ${what}`.toLowerCase().includes(needle))] as [string, [string, string][]])
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
          {shortcuts.map(([keys, what]) => (
            <div className="settings-row" key={keys}><span>{what}</span><kbd>{keys}</kbd></div>
          ))}
        </div>
      ))}
    </>
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
        <div className="settings-note">None yet. Put a session away with the ⇩ button beside it, and it comes here.</div>
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
            ✕
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
    </>
  );
}

function SystemPage({ system }: { system: { engine?: string; storage?: string; lists?: string } }) {
  return (
    <>
      <div id="engine-line" className="gauge-line big">{system.engine ?? ""}</div>
      <div id="storage-log" className="gauge-line">{system.storage ?? ""}</div>
      <div id="storage-attachments" className="gauge-line" />
      <div id="config-lists" className="gauge-line">{system.lists ?? ""}</div>
      <div className="settings-note">Where this machine keeps things, and what the engine is running — what the Mac app's Engine and Storage settings show.</div>
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
