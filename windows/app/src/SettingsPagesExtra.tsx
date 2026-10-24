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

/// Browser: the panel's browser, its search engine, history and website data
/// (BrowserSettings.swift). The Windows client has no browser surface yet, so this page says
/// so rather than keeping settings nothing reads.
export function BrowserPage() {
  return (
    <SettingGroup title="The Panel's Browser">
      <div className="settings-note">Kuvo Code for Windows doesn't have the panel's browser yet. When it arrives, its search engine, history and website data will be set here.</div>
    </SettingGroup>
  );
}


/// Passwords: the sign-ins the panel's browser saved (PasswordsSettings.swift). Without the
/// browser there is nothing to keep, so this page says what comes rather than storing secrets
/// nothing can fill in.
export function PasswordsPage() {
  return (
    <SettingGroup title="Passwords">
      <div className="settings-note">Kuvo Code for Windows doesn't have the panel's browser yet, so there are no saved sign-ins to list. When it arrives they'll be kept in Windows Credential Manager, never in the page.</div>
    </SettingGroup>
  );
}


export function PhonePage() {
  return (
    <SettingGroup title="Phone">
      <div className="settings-note">The phone link isn't part of Kuvo Code for Windows yet. On the Mac, Kuvo Code for iPhone reaches its engine, and your machines', through an encrypted relay; pairing will live here when it arrives.</div>
    </SettingGroup>
  );
}

/// Auto: the coding agents found on this computer (AutoSettings.swift). Detection is real;
/// running a session through them on Windows arrives with the coding agents work.
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
        <div className="settings-note">Kuvo Code for Windows finds these agents on this computer, but doesn't run sessions through them yet. That arrives with the coding agents work; until then this page only reports what's installed.</div>
      </SettingGroup>
      <SettingGroup title="Custom Auto">
        <div className="settings-note">Not here yet. On the Mac, Auto tries your models in order — one list for bugfixes, one for features — and moves on when one reaches a limit.</div>
      </SettingGroup>
    </>
  );
}

export function MachinesPage() {
  const [machines, setMachines] = useState<Array<{ id: string; name: string; destination: string; status?: string }>>([]);
  const [name, setName] = useState("");
  const [destination, setDestination] = useState("");
  const [testing, setTesting] = useState<string | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
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
    setFailure(null);
    try {
      const { machine } = await api<{ machine: { id: string; name: string; destination: string; status: string } }>("/api/machines", { method: "POST", body: { name: name.trim(), destination: destination.trim() } });
      setMachines(current => [...current, machine]);
      setName(""); setDestination("");
    } catch (error) { setFailure(error instanceof Error ? error.message : String(error)); }
  };

  const remove = async (id: string) => {
    try {
      await api(`/api/machines/${encodeURIComponent(id)}`, { method: "DELETE" });
      setMachines(current => current.filter(machine => machine.id !== id));
    } catch (error) { setFailure(error instanceof Error ? error.message : String(error)); }
  };

  const test = async (id: string) => {
    setTesting(id);
    try {
      const { status } = await api<{ status: string }>(`/api/machines/${encodeURIComponent(id)}/test`, { method: "POST" });
      setMachines(current => current.map(machine => machine.id === id ? { ...machine, status } : machine));
    } catch (error) { setFailure(error instanceof Error ? error.message : String(error)); }
    setTesting(null);
  };

  if (loading) return <SettingGroup title="Machines"><div className="settings-note">Loading…</div></SettingGroup>;

  return (
    <>
      <SettingGroup title="Machines">
        <div className="settings-note">Computers you reach with SSH, like a home server or a VPS. Test asks this computer's own ssh whether it gets in; running a session there arrives with the machines work.</div>
        {machines.length === 0 ? <div className="settings-note">None yet.</div> : machines.map(machine => (
          <SettingRow key={machine.id} label={machine.name} note={`${machine.destination}${machine.status ? ` · ${machine.status}` : ""}`}>
            <button className="small" disabled={testing === machine.id} onClick={() => void test(machine.id)}>{testing === machine.id ? "Testing…" : "Test"}</button>
            <button className="small" onClick={() => void remove(machine.id)}>Remove</button>
          </SettingRow>
        ))}
      </SettingGroup>
      <SettingGroup title="Add a Machine">
        <div className="settings-row"><span>Name</span><input type="text" value={name} onChange={event => setName(event.target.value)} /></div>
        <div className="settings-row"><span>SSH destination</span><input type="text" value={destination} placeholder="user@host" onChange={event => setDestination(event.target.value)} /></div>
        <div className="settings-editor-buttons">
          <button className="primary" disabled={!name.trim() || !destination.trim()} onClick={() => void add()}>Add Machine…</button>
        </div>
        {failure ? <div className="settings-note">{failure}</div> : null}
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

/// Bots: the ones that live on this computer, as their folders describe them (BotEditor.swift).
/// Kuvo Code on a Mac makes and changes them; this side lists them.
type HarnessBot = {
  id: string;
  session: string;
  name: string;
  job?: string;
  model?: { id?: string; providerID?: string } | null;
  paused?: boolean;
  wakes?: number;
  watching?: number;
  agents?: boolean;
};

export function BotsPage() {
  const [bots, setBots] = useState<HarnessBot[]>([]);
  const [failure, setFailure] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    void load();
  }, []);

  const load = async () => {
    try {
      const { bots: loaded } = await api<{ bots: HarnessBot[] }>("/api/bots");
      setBots(loaded);
    } catch (error) {
      setFailure(error instanceof Error ? error.message : String(error));
    }
    setLoading(false);
  };

  if (loading) return <SettingGroup title="Bots"><div className="settings-note">Loading…</div></SettingGroup>;

  return (
    <>
      <SettingGroup title="Bots">
        {bots.length === 0 ? <div className="settings-note">None on this computer.</div> : bots.map(bot => {
          const where = [
            bot.model?.id ? bot.model.id : null,
            bot.agents ? "runs with the coding agents" : null,
            bot.paused ? "paused" : null,
            bot.wakes ? `${bot.wakes} wake-up${bot.wakes === 1 ? "" : "s"}` : null,
            bot.watching ? `watching ${bot.watching}` : null,
          ].filter(Boolean).join(" · ");
          return <SettingRow key={bot.id} label={bot.name} note={where || bot.job || bot.session} />;
        })}
        {failure ? <div className="settings-note">{failure}</div> : null}
      </SettingGroup>
      <div className="settings-note">A bot is made and changed in Kuvo Code on a Mac, which writes what it is told. This computer keeps the ones that live here, and lists them above.</div>
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

