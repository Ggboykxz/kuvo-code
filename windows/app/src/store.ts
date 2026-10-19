// The app's state and what it does. The state is a plain object the way the page has
// always kept it; React redraws when `render()` says so. The parts of the app that are
// pure data (the transcript reducer, the settings file) come from elsewhere.

import { useEffect, useState } from "react";
import { api } from "./api";
import type { Agent, AppState, Attachment, Command, FormRequest, McpServer, Model, SessionDiff, SessionSummary, Transcript, VcsInfo } from "./api";
import { apply, emptyTranscript, fromHistory } from "../../harness/transcript.mjs";

export const state: AppState = {
  project: null,
  engine: null,
  sessions: [],
  session: null,
  transcript: null,
  models: [],
  agents: [],
  commands: [],
  drawerTab: "files",
  sessionQuery: "",
  openSessions: [],
  transcripts: new Map(),
  findQuery: "",
  agent: "",
  split: null,
  projects: [],
  shortcuts: null,
  contextGauge: null,
  inbox: [],
  vcs: null,
  sessionDiff: [],
  config: null,
  configPath: null,
  configProblem: null,
  configLive: null,
  opencode: undefined,
  mcpLive: [],
  skillsEngine: [],
  cfgEditor: null,
  forms: [],
  revert: null,
  files: [],
  openFile: null,
  paletteOpen: false,
  settingsOpen: false,
  settingsSection: "appearance",
  diffOpen: false,
  diffTitle: undefined,
  diffOld: undefined,
  diffNew: undefined,
  drawerOpen: false,
  pickerOpen: false,
  openFileContent: undefined,
  toast: null,
  lineComments: [],
  quote: undefined,
  viewing: null,
  sidebarOpen: true,
};

// ---- The redraw ----

let version = 0;
const listeners = new Set<() => void>();

export const render = () => {
  version += 1;
  for (const listener of listeners) listener();
};

/// The page redraws when the store says so.
export function useStore(): number {
  const [current, setCurrent] = useState(version);
  useEffect(() => {
    const listener = () => setCurrent(version);
    listeners.add(listener);
    return () => { listeners.delete(listener); };
  }, []);
  return current;
}

// ---- The look ----

export const lookAccents: Record<string, { color: string; title: string }> = {
  system: { color: "", title: "Default" },
  blue: { color: "#0a84ff", title: "Blue" },
  purple: { color: "#bf5af2", title: "Purple" },
  pink: { color: "#ff375f", title: "Pink" },
  red: { color: "#ff453a", title: "Red" },
  orange: { color: "#ff9f0a", title: "Orange" },
  yellow: { color: "#ffd60a", title: "Yellow" },
  green: { color: "#32d74b", title: "Green" },
  graphite: { color: "#8e8e93", title: "Graphite" },
};

export const look = { accent: "system", textSize: "14", motion: "full", theme: "system" };

export function applyLook() {
  const root = document.documentElement;
  const accent = lookAccents[look.accent] ?? lookAccents.system;
  if (accent.color) {
    root.style.setProperty("--accent", accent.color);
    // On a dark ground a hover lifts the colour, on a light one it deepens it.
    const dark = look.theme === "dark" || (look.theme === "system" && window.matchMedia("(prefers-color-scheme: dark)").matches);
    root.style.setProperty("--accent-hover", `color-mix(in oklab, ${accent.color}, ${dark ? "white" : "black"} 12%)`);
  } else {
    root.style.removeProperty("--accent");
    root.style.removeProperty("--accent-hover");
  }
  root.dataset.theme = look.theme === "system" ? "" : look.theme;
  root.style.setProperty("--text-base", `${look.textSize}px`);
  root.style.setProperty("--motion-base", look.motion === "reduced" ? "1ms" : "320ms");
  root.style.setProperty("--motion-fast", look.motion === "reduced" ? "1ms" : "200ms");
  try { localStorage.setItem("kuvo-look", JSON.stringify(look)); } catch {}
  for (const swatch of document.querySelectorAll("#accent-swatches .swatch")) {
    swatch.classList.toggle("selected", (swatch as HTMLElement).dataset.accent === look.accent);
  }
}

export function loadLook() {
  try {
    const stored = JSON.parse(localStorage.getItem("kuvo-look") ?? "{}");
    if (stored.accent in lookAccents) look.accent = stored.accent;
    if (["13", "14", "16"].includes(stored.textSize)) look.textSize = stored.textSize;
    if (["full", "reduced"].includes(stored.motion)) look.motion = stored.motion;
    if (["system", "light", "dark"].includes(stored.theme)) look.theme = stored.theme;
  } catch {}
  applyLook();
}

// ---- Saying what went wrong ----

export function complain(error: unknown) {
  const message = error instanceof Error ? error.message : String(error);
  state.toast = { title: "Kuvo Code", body: message };
  render();
}

export function notify(title: string, body: string) {
  state.toast = { title, body };
  render();
  try {
    if (typeof Notification === "undefined") return;
    if (Notification.permission === "default") void Notification.requestPermission().catch(() => {});
    if (Notification.permission === "granted") new Notification(title, { body });
  } catch {}
}

// ---- Sessions ----

export async function loadSessions() {
  if (!state.project) {
    state.sessions = [];
    render();
    return;
  }
  const { sessions } = await api<{ sessions: SessionSummary[] }>(`/api/sessions?directory=${encodeURIComponent(state.project)}`);
  state.sessions = sessions;
  render();
}

export async function openSession(id: string) {
  try {
    const detail = await api<{ session: SessionSummary; messages: unknown[]; permissions: unknown[]; running: boolean; revert?: { messageID: string } }>(
      `/api/sessions/${encodeURIComponent(id)}`,
    );
    state.session = detail.session;
    state.transcript = fromHistory(id, detail.messages as never[], detail.permissions as never[], detail.running);
    state.revert = detail.revert ?? null;
    if (!state.openSessions.includes(id)) state.openSessions.push(id);
    render();
    await Promise.all([loadInbox(), loadVcs(), loadSessionDiff(), loadForms()]);
  } catch (error) {
    complain(error);
  }
}

export function closeSessionTab(id: string) {
  state.openSessions = state.openSessions.filter(s => s !== id);
  state.transcripts.delete(id);
  if (state.session && state.session.id === id) {
    const next = state.openSessions[state.openSessions.length - 1];
    if (next) openSession(next);
    else { state.session = null; state.transcript = null; render(); }
  } else {
    render();
  }
}

export async function deleteSession(session: SessionSummary) {
  try {
    if (!confirm(`Delete “${session.title || "Untitled"}”?`)) return;
    await api(`/api/sessions/${encodeURIComponent(session.id)}`, { method: "DELETE" });
    if (state.session?.id === session.id) {
      state.session = null;
      state.transcript = null;
    }
    await loadSessions();
  } catch (error) {
    complain(error);
  }
}

// ---- The engine's events ----

let source: EventSource | null = null;

export function connectEvents() {
  if (source) source.close();
  source = new EventSource("/api/events");
  source.onmessage = event => {
    try {
      const payload = JSON.parse(event.data);
      handleEvent(payload);
    } catch {}
  };
  source.onerror = () => {};
}

function handleEvent(event: { type: string; data?: unknown }) {
  const properties = (event.data ?? {}) as Record<string, unknown>;
  if (!state.transcript) return;
  if (event.type === "message.part.updated" || event.type === "message.updated") {
    state.transcript = apply(state.transcript, event as never);
    render();
  } else if (event.type === "session.idle" || event.type === "session.error") {
    const transcript = apply(state.transcript, event as never);
    transcript.running = false;
    state.transcript = transcript;
    render();
    void (async () => {
      await openSession(state.session!.id);
      await loadSessions();
    })();
  } else if (event.type === "permission.updated" || event.type === "permission.asked") {
    state.transcript = apply(state.transcript, event as never);
    render();
  }
  void properties;
}

// ---- The conversation's own reads ----

export async function loadVcs() {
  try {
    state.vcs = await api<VcsInfo>("/api/vcs");
  } catch {
    state.vcs = null;
  }
  render();
}

export async function loadSessionDiff() {
  if (!state.session) { state.sessionDiff = []; render(); return; }
  try {
    const { diff } = await api<{ diff: SessionDiff[] }>(`/api/sessions/${encodeURIComponent(state.session.id)}/diff`);
    state.sessionDiff = Array.isArray(diff) ? diff : [];
  } catch {
    state.sessionDiff = [];
  }
  render();
}

export async function loadInbox() {
  if (!state.session || !state.transcript) { state.inbox = []; render(); return; }
  try {
    const { inbox } = await api<{ inbox: AppState["inbox"] }>(`/api/sessions/${encodeURIComponent(state.session.id)}/inbox`);
    state.inbox = Array.isArray(inbox) ? inbox : [];
  } catch {
    state.inbox = [];
  }
  render();
}

export async function loadForms() {
  if (!state.session) { state.forms = []; render(); return; }
  try {
    const { forms } = await api<{ forms: FormRequest[] }>(`/api/sessions/${encodeURIComponent(state.session.id)}/forms`);
    state.forms = Array.isArray(forms) ? forms : [];
  } catch {
    state.forms = [];
  }
  render();
}

export async function loadModels() {
  try {
    const { models } = await api<{ models: Model[] }>("/api/models");
    state.models = Array.isArray(models) ? models : [];
  } catch {
    state.models = [];
  }
  render();
}

export async function loadAgents() {
  try {
    const { agents } = await api<{ agents: Agent[] }>("/api/agents");
    state.agents = Array.isArray(agents) ? agents : [];
  } catch {
    state.agents = [];
  }
  render();
}

export async function loadCommands() {
  try {
    const { commands } = await api<{ commands: Command[] }>("/api/commands");
    state.commands = Array.isArray(commands) ? commands : [];
  } catch {
    state.commands = [];
  }
  render();
}

export async function loadProjects() {
  try {
    const { projects } = await api<{ projects: string[] }>("/api/projects");
    state.projects = Array.isArray(projects) ? projects : [];
  } catch {
    state.projects = [];
  }
  render();
}

// ---- The settings file ----

export const cfgGet = (path: string[]): unknown =>
  path.reduce<unknown>((node, key) => (node && typeof node === "object" ? (node as Record<string, unknown>)[key] : undefined), state.config);

export const cfgSet = (path: string[], value: unknown) => {
  if (!state.config) return;
  let node = state.config as Record<string, unknown>;
  for (const key of path.slice(0, -1)) {
    if (typeof node[key] !== "object" || node[key] === null) node[key] = {};
    node = node[key] as Record<string, unknown>;
  }
  const key = path[path.length - 1];
  if (value === null) delete node[key];
  else node[key] = value;
};

export async function saveConfig() {
  try {
    await api("/api/config", { method: "PUT", body: { settings: state.config } });
    notify("Kuvo Code", "Saved to the engine's settings.");
    await bootConfig();
    return true;
  } catch (error) {
    complain(error);
    return false;
  }
}

export async function bootConfig() {
  const [cfg, mcp, skills] = await Promise.all([
    api<{ settings: Record<string, unknown> | null; path: string; problem: string | null; live?: unknown; opencode?: AppState["opencode"] }>("/api/config").catch(() => null),
    api<{ servers: McpServer[] }>("/api/mcp").catch(() => null),
    api<{ skills: AppState["skillsEngine"]; folder: string }>("/api/skills").catch(() => null),
  ]);
  if (cfg) {
    state.config = cfg.settings && typeof cfg.settings === "object" ? cfg.settings : {};
    state.configPath = cfg.path;
    state.configProblem = cfg.problem ?? null;
    state.configLive = cfg.live ?? null;
    state.opencode = cfg.opencode ?? undefined;
  }
  state.mcpLive = mcp?.servers ?? [];
  state.skillsEngine = skills?.skills ?? [];
  render();
  void loadCommands();
  void loadAgents();
}

export async function restartEngineNow() {
  const { version } = await api<{ version: string }>("/api/engine/restart", { method: "POST", body: {} });
  notify("Kuvo Code", `The engine is back (${version}).`);
  await loadSessions();
  if (state.session) await openSession(state.session.id);
}

// ---- Sending ----

export async function sendPrompt(text: string, files: Attachment[] = []) {
  if (!state.session) return;
  try {
    const body: Record<string, unknown> = { text };
    if (files.length) body.files = files;
    await api(`/api/sessions/${encodeURIComponent(state.session.id)}/prompt`, { method: "POST", body });
    const transcript = state.transcript ?? emptyTranscript();
    transcript.pending = [...transcript.pending, { id: `local_${Date.now()}`, text, files }];
    state.transcript = transcript;
    render();
  } catch (error) {
    complain(error);
  }
}

export async function stopRun() {
  if (!state.session) return;
  try {
    await api(`/api/sessions/${encodeURIComponent(state.session.id)}/interrupt`, { method: "POST", body: {} });
  } catch (error) {
    complain(error);
  }
}

export async function undoFromHere(entry: { id?: string; text?: string }) {
  if (!state.session || !entry.id) return;
  try {
    if (state.transcript?.running) {
      await api(`/api/sessions/${encodeURIComponent(state.session.id)}/interrupt`, { method: "POST", body: {} }).catch(() => {});
    }
    const { revert } = await api<{ revert: { messageID: string } }>(`/api/sessions/${encodeURIComponent(state.session.id)}/revert`, {
      method: "POST",
      body: { messageID: entry.id },
    });
    state.revert = revert ?? { messageID: entry.id };
    localStorage.setItem("kuvo-undo-draft", entry.text ?? "");
    await openSession(state.session.id);
  } catch (error) {
    complain(error);
  }
}

export async function redoNow() {
  if (!state.session) return;
  try {
    await api(`/api/sessions/${encodeURIComponent(state.session.id)}/revert`, { method: "DELETE" });
    state.revert = null;
    render();
    await openSession(state.session.id);
  } catch (error) {
    complain(error);
  }
}

export async function answerPermission(request: { id: string; sessionID: string }, decision: string) {
  try {
    await api(`/api/sessions/${encodeURIComponent(request.sessionID)}/permission/${encodeURIComponent(request.id)}`, { method: "POST", body: { decision } });
    if (state.transcript) state.transcript.permissions = state.transcript.permissions.filter(item => item.id !== request.id);
    render();
  } catch (error) {
    complain(error);
  }
}

export async function replyForm(form: FormRequest, answer: Record<string, unknown>) {
  try {
    await api(`/api/sessions/${encodeURIComponent(state.session!.id)}/forms/${encodeURIComponent(form.id)}/reply`, { method: "POST", body: { answer } });
    state.forms = state.forms.filter(item => item.id !== form.id);
    render();
  } catch (error) {
    complain(error);
  }
}

export async function dismissForm(form: FormRequest) {
  try {
    await api(`/api/sessions/${encodeURIComponent(state.session!.id)}/forms/${encodeURIComponent(form.id)}?message=`, { method: "DELETE" });
    state.forms = state.forms.filter(item => item.id !== form.id);
    render();
  } catch (error) {
    complain(error);
  }
}

// ---- Starting up ----

export async function boot() {
  const info = await api<{ project: string | null; engine: AppState["engine"] }>("/api/state");
  state.project = info.project;
  state.engine = info.engine;
  render();
  connectEvents();
  if (state.project) {
    await loadSessions();
    const newest = state.sessions[0];
    if (newest) await openSession(newest.id);
  }
  void loadModels();
  void loadAgents();
  void loadCommands();
  void loadProjects();
  setInterval(() => {
    void api<{ project: string | null; engine: AppState["engine"] }>("/api/state")
      .then(next => { state.engine = next.engine; render(); })
      .catch(() => {});
  }, 4000);
}

export type { Transcript };
