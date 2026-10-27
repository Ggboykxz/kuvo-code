import {
  useEffect,
  useState
} from "react";

import {
  api
} from "./api";
import { ConfirmAction } from "./components/confirm-action";

import {
  bootConfig,
  cfgGet,
  cfgSet,
  complain,
  notify,
  render,
  restartEngineNow,
  saveConfig,
  state
} from "./store";
import {
  MCP_CATALOG,
  AGENTS_BUILTIN,
  idForName,
  lowerIDForName,
  skillNameFrom,
  commandWords,
  commandLine,
  mcpDetail,
  skillText
} from "./SettingsShared";
import {
  type ReactNode
} from "react";

export function McpPage() {
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

export function OpencodeMcp({ onDone }: { onDone: () => void }) {
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

export function ConfigEditor() {
  const editor = state.cfgEditor;
  if (!editor) return null;
  if (editor.kind === "mcp") return <McpEditor id={editor.id} />;
  if (editor.kind === "agent") return <AgentEditor id={editor.id} />;
  if (editor.kind === "skill") return <SkillEditor id={editor.id} />;
  if (editor.kind === "command") return <CommandEditor id={editor.id} />;
  return null;
}

export function EditorShell({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="settings-page" data-section="editor">
      <div id="editor-title" className="settings-detail-title">{title}</div>
      <div id="editor-fields">{children}</div>
      <div className="settings-editor-buttons" id="editor-buttons" />
    </div>
  );
}

export function McpEditor({ id }: { id: string | null }) {
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
        <ConfirmAction
          className="danger small"
          question="Remove this server?"
          confirmLabel="Remove"
          onConfirm={async () => {
            cfgSet(base, null);
            await saveConfig();
            state.cfgEditor = null;
            state.settingsSection = "mcp";
            render();
          }}
        >
          Remove Server…
        </ConfirmAction>
        <button className="primary" onClick={() => { state.cfgEditor = null; state.settingsSection = "mcp"; render(); }}>Done</button>
      </div>
    </EditorShell>
  );
}

export function AgentEditor({ id }: { id: string | null }) {
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
        <ConfirmAction
          className="danger small"
          question="Remove this agent?"
          confirmLabel="Remove"
          onConfirm={async () => {
            cfgSet(base, null);
            await saveConfig();
            state.cfgEditor = null;
            state.settingsSection = "agents";
            render();
          }}
        >
          Remove Agent…
        </ConfirmAction>
        <button className="primary" onClick={() => { state.cfgEditor = null; state.settingsSection = "agents"; render(); }}>Done</button>
      </div>
    </EditorShell>
  );
}

export function SkillEditor({ id }: { id: string | null }) {
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
          <ConfirmAction
            className="danger small"
            question="Delete this skill?"
            confirmLabel="Delete"
            onConfirm={async () => {
              await api(`/api/skill-file/${id}`, { method: "DELETE" }).catch(error => complain(error));
              await bootConfig();
              state.cfgEditor = null;
              state.settingsSection = "skills";
              render();
            }}
          >
            Delete Skill…
          </ConfirmAction>
        ) : null}
        <button className="primary" onClick={() => void save()}>Save Skill</button>
      </div>
    </EditorShell>
  );
}

export function CommandEditor({ id }: { id: string | null }) {
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
          <ConfirmAction
            className="danger small"
            question="Delete this command?"
            confirmLabel="Delete"
            onConfirm={async () => {
              cfgSet(base, null);
              await saveConfig();
              state.cfgEditor = null;
              state.settingsSection = "commands";
              render();
            }}
          >
            Delete Command…
          </ConfirmAction>
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

