import {
  useEffect,
  useState
} from "react";
import {
  Symbol
} from "./components/symbols";
import {
  api
} from "./api";

import {
  loadSessions,
  complain,
  render,
  state,
  worktrees,
  createWorktree,
  removeWorktree
} from "./store";
import {
  SettingGroup,
  SettingRow
} from "./SettingsShared";

export function WorktreesPage() {
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
export function StoragePage() {
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
export function IntegrationsPage() {
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
export function BrowserPage() {
  const [engine, setEngine] = useState("google");
  const [historyCount, setHistoryCount] = useState(0);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    void load();
  }, []);

  const load = async () => {
    try {
      const { engine: loaded } = await api<{ engine: string }>("/api/browser/search-engine");
      setEngine(loaded);
    } catch { setEngine("google"); }
    try {
      const { count } = await api<{ count: number }>("/api/browser/history");
      setHistoryCount(count);
    } catch { setHistoryCount(0); }
    setLoading(false);
  };

  const set = async (value: string) => {
    try {
      await api("/api/browser/search-engine", { method: "POST", body: { engine: value } });
      setEngine(value);
    } catch (error) { complain(error); }
  };

  const clearHistory = async () => {
    try {
      await api("/api/browser/history", { method: "DELETE" });
      setHistoryCount(0);
    } catch (error) { complain(error); }
  };

  const clearCookies = async () => {
    try {
      await api("/api/browser/cookies", { method: "DELETE" });
    } catch (error) { complain(error); }
  };

  if (loading) return <SettingGroup title="Search"><div className="settings-note">Loading…</div></SettingGroup>;

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
          <button className="small" onClick={clearHistory}>Clear</button>
        </SettingRow>
      </SettingGroup>
      <SettingGroup title="Website Data">
        <SettingRow label="Website data" note="Sign-ins, cookies and what sites store, kept apart from your other browsers. Removing a site's data signs you out of it.">
          <button className="small" onClick={clearCookies}>Remove All…</button>
        </SettingRow>
      </SettingGroup>
    </>
  );
}


/// Passwords: the sign-ins the panel's browser saved (PasswordsSettings.swift).
export function PasswordsPage() {
  const [offers, setOffers] = useState(() => localStorage.getItem("kuvo-passwords-offers") !== "0");
  const [credentials, setCredentials] = useState<Array<{ target: string; username: string; created: string }>>([]);
  const [loading, setLoading] = useState(true);
  const [newTarget, setNewTarget] = useState("");
  const [newUsername, setNewUsername] = useState("");
  const [newPassword, setNewPassword] = useState("");

  useEffect(() => {
    void load();
  }, []);

  const load = async () => {
    try {
      const { credentials: loaded } = await api<{ credentials: Array<{ target: string; username: string; created: string; hasPassword: boolean }> }>("/api/credentials");
      setCredentials(loaded);
    } catch { setCredentials([]); }
    setLoading(false);
  };

  const add = async () => {
    if (!newTarget.trim() || !newUsername.trim() || !newPassword) return;
    try {
      await api("/api/credentials", { method: "POST", body: { target: newTarget.trim(), username: newUsername.trim(), password: newPassword } });
      setNewTarget(""); setNewUsername(""); setNewPassword("");
      await load();
    } catch (error) { complain(error); }
  };

  const remove = async (target: string) => {
    try {
      await api(`/api/credentials/${encodeURIComponent(target)}`, { method: "DELETE" });
      await load();
    } catch (error) { complain(error); }
  };

  if (loading) return <SettingGroup title="Passwords"><div className="settings-note">Loading…</div></SettingGroup>;

  return (
    <>
      <SettingGroup title="Passwords & API Keys">
        <div className="settings-note">Kept in Windows Credential Manager, where the system lists them too. Kuvo Code fills one in only when you ask, and the agent never sees them.</div>
        <SettingRow label="Offer to save passwords">
          <input type="checkbox" checked={offers} onChange={event => { setOffers(event.target.checked); localStorage.setItem("kuvo-passwords-offers", event.target.checked ? "1" : "0"); }} />
        </SettingRow>
        {credentials.length === 0 ? <div className="settings-note">None yet.</div> : credentials.map(cred => (
          <SettingRow key={cred.target} label={cred.target} note={`${cred.username} · ${new Date(cred.created).toLocaleDateString()}`}>
            <button className="small" onClick={() => remove(cred.target)}>Remove</button>
          </SettingRow>
        ))}
      </SettingGroup>
      <SettingGroup title="Add a Credential">
        <div className="settings-row"><span>Target (e.g. github.com, api.openai.com)</span><input type="text" value={newTarget} onChange={event => setNewTarget(event.target.value)} /></div>
        <div className="settings-row"><span>Username / Key name</span><input type="text" value={newUsername} onChange={event => setNewUsername(event.target.value)} /></div>
        <div className="settings-row"><span>Password / API Key</span><input type="password" value={newPassword} onChange={event => setNewPassword(event.target.value)} /></div>
        <div className="settings-editor-buttons">
          <button className="primary" disabled={!newTarget.trim() || !newUsername.trim() || !newPassword} onClick={add}>Save</button>
        </div>
      </SettingGroup>
    </>
  );
}


export function PhonePage() {
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
export function AutoPage() {
  const [agents, setAgents] = useState<{ id: string; name: string; installed: boolean }[]>([]);
  useEffect(() => {
    void api<{ agents: { id: string; name: string; installed: boolean }[] }>("/api/agents/detect")
      .then(answer => setAgents(answer.agents ?? []))
      .catch(() => setAgents([]));
  }, []);
  return (
    <>
      <SettingGroup title="Coding Agents on This Machine">
        {agents.length === 0 ? <div className="settings-note">Detecting…</div> : agents.map(agent => (
          <SettingRow key={agent.id} label={agent.name} note={agent.installed ? "Installed" : "Not found"}>
            <span className="where">{agent.installed ? "Installed" : "Not found"}</span>
          </SettingRow>
        ))}
        <div className="settings-note">Custom Auto runs with these coding agents, each on its own account. A session on Auto tries the models in your list in order, and moves on when one reaches a limit.</div>
      </SettingGroup>
      <SettingGroup title="Custom Auto">
        <div className="settings-note">Your lists of models — one for bugfixes, one for features — go here, each tried in order when one reaches a limit. Editing the lists needs the coding agents above.</div>
      </SettingGroup>
    </>
  );
}

/// Machines: Linux servers whose engine Kuvo Code runs over SSH (MachinesSettings.swift).
export function MachinesPage() {
  const [machines, setMachines] = useState<Array<{ id: string; name: string; destination: string; status?: string }>>([]);
  const [name, setName] = useState("");
  const [destination, setDestination] = useState("");
  const [testing, setTesting] = useState<string | null>(null);
  const [installing, setInstalling] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    void load();
  }, []);

  const load = async () => {
    try {
      const { machines: loaded } = await api<{ machines: Array<{ id: string; name: string; destination: string; status?: string }> }>("/api/machines");
      setMachines(loaded);
    } catch { setMachines([]); }
    setLoading(false);
  };

  

  const add = async () => {
    if (!name.trim() || !destination.trim()) return;
    try {
      const { machine } = await api<{ machine: { id: string; name: string; destination: string; status: string } }>("/api/machines", { method: "POST", body: { name: name.trim(), destination: destination.trim() } });
      setMachines([...machines, machine]);
      setName(""); setDestination("");
    } catch (error) { complain(error); }
  };

  const remove = async (id: string) => {
    try {
      await api(`/api/machines/${encodeURIComponent(id)}`, { method: "DELETE" });
      setMachines(machines.filter(m => m.id !== id));
    } catch (error) { complain(error); }
  };

  const test = async (id: string) => {
    setTesting(id);
    try {
      const { status } = await api<{ status: string }>(`/api/machines/${encodeURIComponent(id)}/test`, { method: "POST" });
      setMachines(machines.map(m => m.id === id ? { ...m, status } : m));
    } catch (error) { complain(error); }
    setTesting(null);
  };

  const install = async (id: string) => {
    setInstalling(id);
    try {
      const { status } = await api<{ status: string }>(`/api/machines/${encodeURIComponent(id)}/install`, { method: "POST" });
      setMachines(machines.map(m => m.id === id ? { ...m, status } : m));
    } catch (error) { complain(error); }
    setInstalling(null);
  };

  if (loading) return <SettingGroup title="Machines"><div className="settings-note">Loading…</div></SettingGroup>;

  return (
    <>
      <SettingGroup title="Machines">
        <div className="settings-note">Linux servers you reach with SSH, like a home server or a VPS. Test reachability, install the engine, and run sessions there.</div>
        {machines.length === 0 ? <div className="settings-note">None yet.</div> : machines.map(machine => (
          <SettingRow key={machine.id} label={machine.name} note={`${machine.destination}${machine.status ? ` · ${machine.status}` : ""}`}>
            <button className="small" disabled={testing === machine.id} onClick={() => void test(machine.id)}>{testing === machine.id ? "Testing…" : "Test"}</button>
            <button className="small" disabled={installing === machine.id} onClick={() => void install(machine.id)}>{installing === machine.id ? "Installing…" : "Install Engine"}</button>
            <button className="small" onClick={() => remove(machine.id)}>Remove</button>
          </SettingRow>
        ))}
      </SettingGroup>
      <SettingGroup title="Add a Machine">
        <div className="settings-row"><span>Name</span><input type="text" value={name} onChange={event => setName(event.target.value)} /></div>
        <div className="settings-row"><span>SSH destination</span><input type="text" value={destination} placeholder="user@host" onChange={event => setDestination(event.target.value)} /></div>
        <div className="settings-editor-buttons">
          <button className="primary" disabled={!name.trim() || !destination.trim()} onClick={add}>Add Machine…</button>
        </div>
      </SettingGroup>
    </>
  );
}


export function AccountsPage() {
  const [integrations, setIntegrations] = useState<{ id: string; name?: string; connections?: unknown[] }[]>([]);
  const [loaded, setLoaded] = useState(false);
  useEffect(() => {
    void api<{ integrations: { id: string; name?: string; connections?: unknown[] }[] }>("/api/integrations")
      .then(answer => setIntegrations(answer.integrations ?? []))
      .catch(() => setIntegrations([]))
      .finally(() => setLoaded(true));
  }, []);
  return (
    <>
      <SettingGroup title="Accounts">
        {!loaded ? <div className="settings-note">Loading…</div> : integrations.length === 0 ? <div className="settings-note">The engine did not report any integrations.</div> : integrations.map(one => (
          <SettingRow key={one.id} label={one.name ?? one.id} note={(one.connections ?? []).length ? "Connected" : "Not connected"}>
            {(one.connections ?? []).length ? (
              <span className="where">Connected</span>
            ) : (
              <button className="small" onClick={() => { state.settingsSection = "providers"; render(); }}>Set up in Providers</button>
            )}
          </SettingRow>
        ))}
      </SettingGroup>
      <div className="settings-note">Sign in with a subscription you already have, or add an API key. Credentials stay on this machine. This page lists the engine's integrations; signing in to them from here comes next, and Providers is where you add your own today.</div>
    </>
  );
}

/// Bots: your own, a name, a job, and the model that does it (BotEditor.swift).
export function BotsPage() {
  const [bots, setBots] = useState<Array<{ id: string; name: string; personality: string; model: string; look?: { color: string; shape: string; face: string } }>>([]);
  const [editing, setEditing] = useState<{ id: string; name: string; personality: string; model: string; look?: { color: string; shape: string; face: string } } | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    void load();
  }, [state.project]);

  const load = async () => {
    if (!state.project) { setBots([]); setLoading(false); return; }
    try {
      const { bots: loaded } = await api<{ bots: Array<{ id: string; name: string; job: string; model: { id: string }; look: { color: string; shape: string; face: string } }> }>(`/api/bots`);
      setBots(loaded.map(b => ({ id: b.id, name: b.name, personality: b.job, model: b.model.id, look: b.look })));
    } catch { setBots([]); }
    setLoading(false);
  };

  const saveBot = async (bot: typeof editing) => {
    if (!bot) return;
    try {
      await api(`/api/bots`, { method: "POST", body: bot });
      setEditing(null);
      await load();
    } catch (error) { complain(error); }
  };

  const removeBot = async (id: string) => {
    try {
      await api(`/api/bots/${encodeURIComponent(id)}`, { method: "DELETE" });
      await load();
    } catch (error) { complain(error); }
  };

  if (loading) return <SettingGroup title="Bots"><div className="settings-note">Loading…</div></SettingGroup>;

  return (
    <>
      <SettingGroup title="Bots">
        {bots.length === 0 ? <div className="settings-note">None yet. A bot is an agent of your own: a name, a job, and the model that does it.</div> : bots.map(bot => (
          <SettingRow key={bot.id} label={bot.name} note={bot.personality || bot.model}>
            <button className="small" onClick={() => setEditing(bot)}>Edit</button>
            <button className="small" onClick={() => removeBot(bot.id)}>Remove</button>
          </SettingRow>
        ))}
        <SettingRow label="New Bot">
          <button className="small" onClick={() => setEditing({ id: `bot-${Date.now()}`, name: "", personality: "", model: "", look: { color: "sky", shape: "round", face: "calm" } })}>New Bot…</button>
        </SettingRow>
      </SettingGroup>
      {editing ? (
        <div className="settings-row column">
          <span>Name</span>
          <input type="text" value={editing.name} onChange={event => setEditing({ ...editing, name: event.target.value })} />
          <span>Personality</span>
          <textarea value={editing.personality} onChange={event => setEditing({ ...editing, personality: event.target.value })} />
          <span>Model (provider/model)</span>
          <input type="text" value={editing.model} placeholder="anthropic/claude-3-sonnet" onChange={event => setEditing({ ...editing, model: event.target.value })} />
          <span>Look</span>
          <div className="settings-row">
            <span>Color</span>
            <select value={editing.look?.color || "sky"} onChange={event => setEditing({ ...editing, look: { color: event.target.value, shape: editing.look?.shape || "round", face: editing.look?.face || "calm" } })}>)
              <option value="sky">Sky</option>
              <option value="rose">Rose</option>
              <option value="amber">Amber</option>
              <option value="emerald">Emerald</option>
              <option value="violet">Violet</option>
              <option value="slate">Slate</option>
            </select>
          </div>
          <div className="settings-row">
            <span>Shape</span>
            <select value={editing.look?.shape || "round"} onChange={event => setEditing({ ...editing, look: { shape: event.target.value, color: (editing.look?.color ?? "sky"), face: (editing.look?.face ?? "calm") } })}>)
              <option value="round">Round</option>
              <option value="square">Square</option>
              <option value="hexagon">Hexagon</option>
            </select>
          </div>
          <div className="settings-row">
            <span>Face</span>
            <select value={editing.look?.face || "calm"} onChange={event => setEditing({ ...editing, look: { face: event.target.value, color: (editing.look?.color ?? "sky"), shape: (editing.look?.shape ?? "round") } })}>)
              <option value="calm">Calm</option>
              <option value="happy">Happy</option>
              <option value="focused">Focused</option>
            </select>
          </div>
          <div className="settings-editor-buttons">
            <button className="primary" onClick={() => editing && saveBot(editing)}>Save</button>
            <button className="small" onClick={() => setEditing(null)}>Cancel</button>
          </div>
        </div>
      ) : null}
    </>
  );
}


/// The sessions that are put away: out of the sidebar, still here, brought back or deleted.
export function ArchivedPage() {
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

export function PermissionsPage({ permissions, onChange }: {
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

export function SystemPage({ system }: { system: { engine?: string; storage?: string; lists?: string } }) {
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

