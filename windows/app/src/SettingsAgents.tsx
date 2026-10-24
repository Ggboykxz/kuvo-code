

import {
  cfgGet,
  cfgSet,
  render,
  saveConfig,
  state
} from "./store";
import {
  AGENTS_BUILTIN
} from "./SettingsShared";

export function AgentsPage() {
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

export function ModelSelect({ path, empty }: { path: string[]; empty: string }) {
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

export function SkillsPage() {
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

export function CommandsPage() {
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
