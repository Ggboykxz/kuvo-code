import { useEffect, useState } from "react";
import { Symbol } from "./components/symbols";
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
  cfgGet,
  cfgSet,
  complain,
  look,
  lookAccents,
  rememberTabBar,
  render,
  saveConfig,
  setSounds,
  state,
} from "./store";
import {
  MODES,
  SettingGroup,
  SettingRow,
  SkeletonRows,
} from "./SettingsShared";

export function AppearancePage() {
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
                aria-label={accent.title}
                aria-pressed={look.accent === key}
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
      <SettingGroup title="Sound">
        <SettingRow label="Interface sounds" note="A quiet cue when a message is sent, a run finishes or something fails. Off unless you ask for it; the sounds are made here, not downloaded.">
          <select id="setting-sounds" value={state.sounds} onChange={event => setSounds(event.target.value as "off" | "subtle")}>
            <option value="off">Off</option>
            <option value="subtle">Subtle</option>
          </select>
        </SettingRow>
      </SettingGroup>
    </>
  );
}

export function GeneralPage() {
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
export function KeyboardPage() {
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
export function ShortcutKeys({ shortcut }: { shortcut: Shortcut }) {
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

export function ProjectsPage() {
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
export function ProvidersPage() {
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
export function UsagePage() {
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
      <div className="settings-note">What the engine ran and what it cost, read from the engine's own sessions.</div>
      <h3>Plans</h3>
      <PlansSection />
    </>
  );
}

export function PlansSection() {
  const [plans, setPlans] = useState<{ provider: string; kind: string; data?: unknown; error?: string; status?: string }[]>([]);
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    void api<{ plans: { provider: string; kind: string; data?: unknown; error?: string; status?: string }[] }>("/api/usage/plans")
      .then(answer => { setPlans(answer.plans ?? []); setLoading(false); })
      .catch(() => { setPlans([]); setLoading(false); });
  }, []);
  if (loading) return <SkeletonRows label="Loading permissions" />;
  if (plans.length === 0) return <div className="where">No connected account with a plan to follow. Sign in under Providers.</div>;
  return (
    <>
      {plans.map((plan, index) => (
        <div className="settings-row" key={index}>
          <span>{plan.provider}</span>
          <span className="where">
            {plan.error ? `Couldn't read: ${plan.error}`
              : plan.status === "not-yet-supported" ? "Plan read not implemented yet for this provider."
              : JSON.stringify(plan.data).slice(0, 120)}
          </span>
        </div>
      ))}
      <div className="settings-note">Plan limits and pace come from each provider's own API, with the credentials the engine holds. They stay on this machine.</div>
    </>
  );
}

/// Git: how a branch is named, and how commit and pull-request messages are written —
/// the Mac app's Git settings, ours.
export function GitPage() {
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

/// Notifications: not on Windows yet. The Mac tells you when a session finishes or needs an
/// answer; the Windows client has no notifier, so this page says so rather than keeping
/// switches nothing reads.
export function NotificationsPage() {
  return (
    <SettingGroup title="Notifications">
      <div className="settings-note">Kuvo Code for Windows doesn't show notifications yet. When it does, these switches will decide what it tells you about a session finishing or waiting for an answer.</div>
    </SettingGroup>
  );
}

/// Privacy: what the app does with what it is told (GeneralSettings.swift:203-230). The
/// Windows client sends nothing anywhere, so there is no usage setting to offer.
export function PrivacyPage() {
  return (
    <>
      <SettingGroup title="Anonymous Usage">
        <div className="settings-note">Kuvo Code for Windows collects nothing and reports nothing anywhere. The engine runs on this machine, and its words go only to the model providers you choose.</div>
      </SettingGroup>
      <SettingGroup title="On This Machine">
        <SettingRow label="Sessions and accounts" note="Kept on this machine, in Kuvo Code's own folder. Messages go only to the model providers you choose.">
          <button className="small" onClick={() => { state.settingsSection = "system"; render(); }}>Storage…</button>
        </SettingRow>
      </SettingGroup>
    </>
  );
}

/// The side panel: the Mac's choices (BrowserSettings.swift:5-30). The Windows panel doesn't
/// read them yet, so this page describes what comes instead of keeping switches nothing reads.
export function PanelPage() {
  return (
    <SettingGroup title="The Side Panel">
      <div className="settings-note">Kuvo Code for Windows opens the panel on Changes, Files and Terminal. The Mac's choices — what a panel starts with, its new tab page, closing agents' tabs you haven't looked at — arrive with the browser work.</div>
    </SettingGroup>
  );
}

/// Worktrees: where they go, and the ones sessions have, with what each takes (GitSettings.swift:60-136).
