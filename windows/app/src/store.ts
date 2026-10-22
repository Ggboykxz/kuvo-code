// The app's state and what it does. The state is a plain object the way the page has
// always kept it; React redraws when `render()` says so. The parts of the app that are
// pure data (the transcript reducer, the settings file) come from elsewhere.

import { useEffect, useState } from "react";
import { api } from "./api";
import type { Agent, AppState, Attachment, Command, FormRequest, McpServer, Model, SessionDiff, SessionSummary, Transcript, VcsInfo } from "./api";
import { apply, emptyTranscript, fromHistory, sessionOf } from "../../harness/transcript.mjs";
import { conversationMarkdown } from "../../harness/markdown.mjs";
import { toolSummary } from "./components/tool-call";
import { compatibilitySettings, copilotClaude } from "./compatibility.mjs";
import { cycledTab, rememberClosed, tabAfterClose, tabAt, takeClosed } from "./tab-history.mjs";

// ---- What the window remembers ----

/// The window's own state, kept between runs: the panes' widths, what is folded away and
/// the row at the top (the Mac's own AppStorage: sessionsWidth, changesWidth, splitWidth,
/// collapsedSections, collapsedProjects, showsTabBar).
const remembered = {
  sessionsWidth: "kuvo-sessionsWidth",
  changesWidth: "kuvo-changesWidth",
  splitWidth: "kuvo-splitWidth",
  collapsed: "kuvo-collapsed",
  showsTabBar: "kuvo-showsTabBar",
};

const tabBarShown = () => {
  try {
    return localStorage.getItem(remembered.showsTabBar) !== "off";
  } catch {
    return true;
  }
};

const width = (key: string, fallback: number) => {
  try {
    const stored = Number(localStorage.getItem(key));
    return Number.isFinite(stored) && stored > 0 ? stored : fallback;
  } catch {
    return fallback;
  }
};

/// The window's own state, read when the app starts (MainView.swift:38-40, 90;
/// SidebarView.swift:32-34; TabBar.showsKey).
export function rememberWindow() {
  state.sessionsWidth = width(remembered.sessionsWidth, state.sessionsWidth);
  state.changesWidth = width(remembered.changesWidth, state.changesWidth);
  state.splitWidth = width(remembered.splitWidth, state.splitWidth);
  try {
    const folded = JSON.parse(localStorage.getItem(remembered.collapsed) ?? "{}");
    if (folded && typeof folded === "object") state.collapsed = folded as Record<string, boolean>;
    state.showsTabBar = localStorage.getItem(remembered.showsTabBar) !== "off";
  } catch {}
}

/// A pane's width, dragged.
export function setPaneWidth(pane: "sessions" | "changes" | "split", next: number) {
  if (pane === "sessions") state.sessionsWidth = next;
  else if (pane === "changes") state.changesWidth = next;
  else state.splitWidth = next;
}

/// A pane's width, kept for the next time the window opens.
export function savePaneWidth(pane: "sessions" | "changes" | "split") {
  const key = pane === "sessions" ? remembered.sessionsWidth : pane === "changes" ? remembered.changesWidth : remembered.splitWidth;
  const now = pane === "sessions" ? state.sessionsWidth : pane === "changes" ? state.changesWidth : state.splitWidth;
  try { localStorage.setItem(key, String(now)); } catch {}
}

/// What is folded away, kept for the next time the window opens.
export function rememberFolded(key: string, folded: boolean) {
  state.collapsed = { ...state.collapsed, [key]: folded };
  try { localStorage.setItem(remembered.collapsed, JSON.stringify(state.collapsed)); } catch {}
}

/// The row at the top, kept for the next time the window opens.
export function rememberTabBar(shows: boolean) {
  state.showsTabBar = shows;
  try { localStorage.setItem(remembered.showsTabBar, shows ? "on" : "off"); } catch {}
}

export const state: AppState = {
  project: null,
  engine: null,
  sessions: [],
  session: null,
  transcript: null,
  models: [],
  defaultModel: null as { providerID: string; id: string } | null,
  agents: [],
  commands: [],
  drawerTab: "files",
  sessionQuery: "",
  openSessions: [],
  transcripts: new Map(),
  findQuery: "",
  findOpen: false,
  agent: "",
  split: null,
  projects: [],
  projectNames: {} as Record<string, string>,
  projectRuns: {} as Record<string, string>,
  projectFolderList: {} as Record<string, string[]>,
  editingProject: null as string | null,
  sessionsByProject: {} as Record<string, SessionSummary[]>,
  collapsed: {} as Record<string, boolean>,
  showsTabBar: tabBarShown(),
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
  projectFiles: [] as string[],
  openFile: null,
  paletteOpen: false,
  openQuickly: false,
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
  sessionsWidth: width(remembered.sessionsWidth, 280),
  changesWidth: width(remembered.changesWidth, 420),
  splitWidth: width(remembered.splitWidth, 560),
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
  system: { color: "", title: "System Accent" },
  blue: { color: "#0a84ff", title: "Blue" },
  purple: { color: "#bf5af2", title: "Purple" },
  pink: { color: "#ff375f", title: "Pink" },
  red: { color: "#ff453a", title: "Red" },
  orange: { color: "#ff9f0a", title: "Orange" },
  yellow: { color: "#ffd60a", title: "Yellow" },
  green: { color: "#32d74b", title: "Green" },
  graphite: { color: "#8e8e93", title: "Graphite" },
};

export const look = { accent: "system", textSize: "14", motion: "full", theme: "system", window: "glass", typeface: "system", steps: "summary" };

/// The typeface of the messages, as the Mac's four (Look.swift:52-63). Windows has no
/// SF Pro Rounded: the closest it has is Candara, whose terminals are round.
const typefaces: Record<string, string> = {
  system: "",
  rounded: 'Candara, "Segoe UI", sans-serif',
  serif: 'Georgia, "Times New Roman", serif',
  monospaced: 'var(--font-mono)',
};

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
  // The Mac's text size applies to the conversation, not to the chrome.
  root.style.setProperty("--message-size", `${look.textSize}px`);
  root.style.setProperty("--motion-base", look.motion === "reduced" ? "1ms" : "320ms");
  root.style.setProperty("--motion-fast", look.motion === "reduced" ? "1ms" : "120ms");
  // The window's own material (Look.swift:42-46: the glass, or a solid ground).
  root.dataset.window = look.window;
  // The typeface of the messages (Look.swift:52-63). The code stays monospaced.
  root.style.setProperty("--message-font", typefaces[look.typeface] ?? "");
  try { localStorage.setItem("kuvo-look", JSON.stringify(look)); } catch {}
  for (const swatch of document.querySelectorAll("#accent-swatches .swatch")) {
    swatch.classList.toggle("selected", (swatch as HTMLElement).dataset.accent === look.accent);
  }
}

export function loadLook() {
  try {
    const stored = JSON.parse(localStorage.getItem("kuvo-look") ?? "{}");
    if (stored.accent in lookAccents) look.accent = stored.accent;
    if (["13", "14", "15.5", "17"].includes(stored.textSize)) look.textSize = stored.textSize;
    if (["full", "reduced"].includes(stored.motion)) look.motion = stored.motion;
    if (["system", "light", "dark"].includes(stored.theme)) look.theme = stored.theme;
    if (["glass", "solid"].includes(stored.window)) look.window = stored.window;
    if (["system", "rounded", "serif", "monospaced"].includes(stored.typeface)) look.typeface = stored.typeface;
    if (["each", "summary", "minimal"].includes(stored.steps)) look.steps = stored.steps;
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
  // The session in view is the list's own: the engine names a session a moment after its
  // first words, and the conversation's card is to show the name it has now.
  const current = state.session ? sessions.find(session => session.id === state.session?.id) : null;
  if (current) state.session = current;
  render();
}

/// A file of the project, opened in the side panel — the Mac app's file links.
export async function openProjectFile(relative: string) {
  if (!state.project || !relative) return;
  try {
    const { content } = await api<{ content: string }>(`/api/file?path=${encodeURIComponent(relative)}`);
    state.openFile = relative;
    state.openFileContent = content;
    state.drawerOpen = true;
    state.drawerTab = "files";
    render();
  } catch (error) {
    complain(error);
  }
}

/// The project's files, by their path in it: the file links of a reply ask which of them
/// are real, the Mac app's way.
export async function loadProjectFiles() {
  if (!state.project) {
    state.projectFiles = [];
    render();
    return;
  }
  const { files } = await api<{ files: string[] }>("/api/project-files").catch(() => ({ files: [] }));
  state.projectFiles = files ?? [];
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
    // The project's folders are the session's, as they are on the Mac (SessionModel.swift:1379).
    void syncFolders(detail.session);
    await Promise.all([loadInbox(), loadVcs(), loadSessionDiff(), loadForms()]);
  } catch (error) {
    complain(error);
  }
}

/// The conversation beside the one in view: read once when it opens (the events keep it
/// current from then on), and re-read when its turn ends or the line reconnects.
export async function openSplit(id: string, force = false) {
  if (!id) return;
  if (!force && state.transcripts.has(id)) return;
  try {
    const detail = await api<{ session: SessionSummary; messages: unknown[]; permissions: unknown[]; running: boolean }>(
      `/api/sessions/${encodeURIComponent(id)}`,
    );
    state.transcripts.set(id, fromHistory(id, detail.messages as never[], detail.permissions as never[], detail.running));
    render();
  } catch (error) {
    complain(error);
  }
}

/// Tabs the user closed, last one last, with where they were: the Mac's closedTabs
/// (MainView.swift:51-52, 1198-1232). Reopen Closed Tab walks it back.
let closedTabs: { id: string; index: number }[] = [];

/// A session by id, wherever the window has it: the sidebar's list, a project's list, or
/// the one in view. The Mac asks the workspace the same way (MainView.swift:1214-1219).
function knownSession(id: string) {
  return state.session?.id === id
    || state.sessions.some(session => session.id === id)
    || Object.values(state.sessionsByProject).some(list => list.some(session => session.id === id));
}

export function canReopenTab() {
  return takeClosed(closedTabs, state.openSessions, knownSession).entry !== null;
}

/// The Mac's Reopen Closed Tab (MainView.swift:1214-1232): the tab closed last comes back
/// where it was, skipping the ones open again or deleted since.
export function reopenClosedTab() {
  const taken = takeClosed(closedTabs, state.openSessions, knownSession);
  closedTabs = taken.closed;
  if (!taken.entry) return;
  const index = Math.min(taken.entry.index, state.openSessions.length);
  state.openSessions.splice(index, 0, taken.entry.id);
  void openSession(taken.entry.id);
}

/// Close Tab (⌘W on the Mac, Ctrl+W here): the tab on the right takes its place.
export function closeSessionTab(id: string) {
  const index = state.openSessions.indexOf(id);
  if (index < 0) return;
  closedTabs = rememberClosed(closedTabs, [{ id, index }]);
  state.openSessions = state.openSessions.filter(session => session !== id);
  state.transcripts.delete(id);
  if (state.session && state.session.id === id) {
    const next = tabAfterClose(state.openSessions, index);
    if (next) void openSession(next);
    else { state.session = null; state.transcript = null; render(); }
  } else {
    render();
  }
}

/// The Mac's "Close Other Tabs" and "Close All Tabs" (TitleBar.swift:223-229): every tab
/// but the one named, or every tab at all. The Mac remembers them reversed, so the
/// leftmost comes back last (MainView.swift:1186-1196).
export function closeTabs(keep: string | null) {
  const closing = state.openSessions
    .map((id, index) => ({ id, index }))
    .filter(tab => tab.id !== keep);
  if (!closing.length) return;
  closedTabs = rememberClosed(closedTabs, [...closing].reverse());
  const closingIDs = closing.map(tab => tab.id);
  state.openSessions = state.openSessions.filter(id => id === keep);
  for (const id of closingIDs) state.transcripts.delete(id);
  if (state.session && !state.openSessions.includes(state.session.id)) {
    const next = state.openSessions[state.openSessions.length - 1];
    if (next) void openSession(next);
    else { state.session = null; state.transcript = null; render(); }
  } else {
    render();
  }
}

/// The Mac's next and previous tab keys (MainView.swift:1357-1358): around the strip.
export function cycleTab(step: 1 | -1) {
  // The Mac cycles the settings' own tabs while settings are showing (MainView.swift:1290);
  // this client has one settings page, so there is nothing there to cycle.
  if (state.settingsOpen) return;
  const next = cycledTab(state.openSessions, state.session?.id ?? null, step);
  if (next) void openSession(next);
}

/// The Mac's Show Tab menu (MainView.swift:1376-1385): a number names a session tab, or a
/// settings tab while settings are showing. There is one settings page here, so no-op.
export function showTab(number: number) {
  if (state.settingsOpen) return;
  const next = tabAt(state.openSessions, number);
  if (next) void openSession(next);
}

/// A session's name, changed: the sidebar's row and the tab's own field both write here
/// (the Mac's rename, in the row and in the tab).
export async function renameSession(id: string, title: string) {
  const name = title.trim();
  const known = [...state.sessions, ...Object.values(state.sessionsByProject).flat()].find(session => session.id === id);
  if (!name || name === (known?.title ?? "")) return;
  try {
    await api(`/api/sessions/${encodeURIComponent(id)}/rename`, { method: "POST", body: { title: name } });
    await loadSessions();
    await loadProjectSessions();
  } catch (error) {
    complain(error);
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
    await loadProjectSessions();
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
  // Missed events are not replayed, so at a connection the Mac re-reads everything on
  // screen — the catalog and every open session (AppModel.swift:448-459 →
  // Workspace.resync, Workspace.swift:1347-1359). The page does the same with the three
  // reads it already trusts: the list, the conversation in view, the one beside it.
  source.onopen = () => { void resync(); };
  source.onerror = () => {};
}

/// After a connection: what the engine has now — a session made or put away while the
/// line was down is in the list again, and the conversations open on screen are read from
/// the engine's own messages, their words and their asks as they stand.
async function resync() {
  try {
    await loadSessions();
    if (state.session) await openSession(state.session.id);
    if (state.split) await openSplit(state.split, true);
  } catch (error) {
    complain(error);
  }
}

/// The events the engine sends, and the transcript's own names for them
/// (OpenCodeKit's `Transcript`, the Mac app's). The names here are the engine's: the
/// words of a reply come as `session.text.delta`, the run's end as
/// `session.execution.succeeded`.
const CONVERSATION_EVENTS = new Set([
  "session.execution.started",
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
  "session.step.started",
  "session.step.streamed",
  "session.step.ended",
  "session.step.failed",
  "session.retry.scheduled",
  "session.text.started",
  "session.text.delta",
  "session.text.ended",
  "session.reasoning.started",
  "session.reasoning.delta",
  "session.reasoning.ended",
  "session.tool.input.started",
  "session.tool.input.delta",
  "session.tool.input.ended",
  "session.tool.called",
  "session.tool.progress",
  "session.tool.success",
  "session.tool.failed",
  "session.agent.selected",
  "session.model.selected",
  "session.synthetic",
]);

/// The asks the agent is waiting on — the permissions and the forms. They are the
/// Mac's own kind of thing (a form, a permission), not rows of the conversation, so they
/// are read again when the engine says one has changed.
const ASK_EVENTS = new Set([
  "permission.asked",
  "permission.replied",
  "form.created",
  "form.replied",
  "form.cancelled",
]);

function handleEvent(event: { type: string; data?: unknown }) {
  const properties = (event.data ?? {}) as Record<string, unknown>;
  if (!state.transcript) return;
  if (ASK_EVENTS.has(event.type)) {
    // The agent is asking, or the ask is answered: read the asks again.
    void loadForms();
    void openSession(state.session!.id);
    return;
  }
  if (CONVERSATION_EVENTS.has(event.type)) {
    state.transcript = apply(state.transcript, event as never);
    // The session beside it keeps its own transcript current the same way: the Mac routes
    // every event to the model of the session it names (Workspace.swift:1458, `models[id]`),
    // so a conversation open beside the one in view keeps writing while you watch the
    // other. An event for another session changes nothing (transcript.mjs filters by id).
    state.transcripts.forEach((transcript, id) => {
      state.transcripts.set(id, apply(transcript, event as never));
    });
    render();
    // The run is over: read it back, the way the Mac does when the engine says the
    // turn ended (SessionModel.swift:640-655) — the words it has now are the words
    // there are.
    if (event.type === "session.execution.succeeded" || event.type === "session.execution.failed" || event.type === "session.execution.interrupted") {
      const ended = sessionOf(event as never);
      void (async () => {
        await openSession(state.session!.id);
        await loadSessions();
        // The words the split has now too, when its turn is the one that ended.
        if (state.split && ended === state.split) await openSplit(state.split, true);
      })();
    }
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
  void applyProviderCompatibility();
}

/// The Mac app's ProviderCompatibility: GitHub Copilot's Claude models from 5.1 on reject the
/// thinking.block_binding the engine adds for Claude 5.1 and later, and the engine leaves it
/// out only for the models named in its settings — so the app names them, in the settings
/// the engine reads. Nothing else is touched.
async function applyProviderCompatibility() {
  try {
    // What the engine's own list says, kept as the Mac keeps it.
    const copilot = state.models.filter(model => model.providerID === "github-copilot");
    if (copilot.length > 0) {
      const learned = copilotClaude(state.models);
      if (learned.length > 0) localStorage.setItem("copilotClaudeModels", JSON.stringify(learned));
    }
    let learned: string[] = [];
    try { learned = JSON.parse(localStorage.getItem("copilotClaudeModels") ?? "[]") ?? []; } catch { learned = []; }
    const settings = compatibilitySettings(learned);
    if (!settings || !state.config) return;
    let changed = false;
    for (const model of Object.keys(settings.providers["github-copilot"].models)) {
      const path = ["providers", "github-copilot", "models", model, "compatibility", "supportsThinkingBlockBinding"];
      if (cfgGet(path) !== false) {
        cfgSet(path, false);
        changed = true;
      }
    }
    if (changed) await saveConfig();
  } catch {
    // The engine's settings are the app's own; if they cannot be written, the app goes on.
  }
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
    const { projects, names, runs, folders } = await api<{ projects: string[]; names?: Record<string, string>; runs?: Record<string, string>; folders?: Record<string, string[]> }>("/api/projects");
    // The project that is open is one of them, as it is on the Mac (Workspace.projects).
    state.projects = Array.from(new Set([...(Array.isArray(projects) ? projects : []), ...(state.project ? [state.project] : [])]));
    state.projectNames = names && typeof names === "object" ? names : {};
    state.projectRuns = runs && typeof runs === "object" ? runs : {};
    state.projectFolderList = folders && typeof folders === "object" ? folders : {};
  } catch {
    state.projects = state.project ? [state.project] : [];
  }
  render();
  await loadProjectSessions();
}

/// A project's own name, shown instead of the folder's (the Mac's Workspace.Project.name,
/// Workspace.swift:186).
export function projectName(folder: string): string {
  const named = state.projectNames[folder];
  if (named) return named;
  return folder.replace(/[/\\]+$/, "").split(/[/\\]/).pop() ?? folder;
}

/// A project's own name and its run command, set or taken away (the Mac's ProjectEditor,
/// ProjectEditor.swift:24).
export async function setProjectSettings(folder: string, settings: { name?: string; run?: string; folders?: string[] }) {
  try {
    await api("/api/projects/settings", { method: "POST", body: { path: folder, ...settings } });
    await loadProjects();
  } catch (error) {
    complain(error);
  }
}

/// The command a project's run button runs (the Mac's Workspace.ProjectSettings.run,
/// Workspace.swift:198).
export function projectRun(folder: string): string {
  return state.projectRuns[folder] ?? "";
}

/// A project's other folders — the ones the agent may work in besides the first (the
/// Mac's Workspace.ProjectSettings.folders, Workspace.swift:196).
export function projectFolders(folder: string): string[] {
  return state.projectFolderList[folder] ?? [];
}

/// The rules that let the agent work in those folders (the Mac's ProjectFolders.rules,
/// ProjectFolders.swift:20-27): a rule per folder, so working there is not leaving the
/// project.
export function folderRules(folders: string[]): { action: string; resource: string; effect: string }[] {
  return folders.map(folder => ({
    action: "external_directory",
    resource: `${folder.replace(/[/\\]+$/, "")}/*`,
    effect: "allow",
  }));
}

/// What the agent is told about the project spanning several folders (the Mac's
/// ProjectFolders.instructions, ProjectFolders.swift:36-46).
export function folderInstruction(primary: string, folders: string[]): string {
  const name = (path: string) => path.replace(/[/\\]+$/, "").split(/[/\\]/).pop() ?? path;
  const list = folders.map(folder => `- ${name(folder)}: ${folder}`).join("\n");
  return `This project spans several folders. You work in its primary folder, ${name(primary)} (${primary}). These folders belong to the project too, and you can read, search and change files in them the same way:\n${list}\nWhen the user mentions one of these folders by name, they mean that folder.`;
}

/// Gives a session the project's folders: the rules that allow them, and the note that
/// names them (the Mac's SessionModel.syncFolders, SessionModel.swift:1379-1405).
export async function syncFolders(session: SessionSummary) {
  const primary = session.location?.directory ?? "";
  if (!primary) return;
  const folders = projectFolders(primary);
  try {
    const current = (session.permissions ?? []) as { action?: string; resource?: string; effect?: string }[];
    // The folder rules are the project's own: the rest of the session's rules stay.
    const kept = current.filter(rule => !(rule.action === "external_directory" && rule.effect === "allow" && String(rule.resource ?? "").endsWith("/*")));
    const permissions = [...kept, ...folderRules(folders)];
    await api(`/api/sessions/${encodeURIComponent(session.id)}/permissions`, { method: "POST", body: { permissions } });
    if (folders.length) {
      await api(`/api/sessions/${encodeURIComponent(session.id)}/instruction`, { method: "POST", body: { key: "kuvo.project-folders", value: folderInstruction(primary, folders) } });
    }
  } catch (error) {
    complain(error);
  }
}

/// The sessions of every project, by its folder (SidebarView.swift:194-196): the sidebar
/// shows them all, each under its own project.
export async function loadProjectSessions() {
  const folders = [...state.projects];
  const pairs = await Promise.all(folders.map(async folder => {
    try {
      const { sessions } = await api<{ sessions: SessionSummary[] }>(`/api/sessions?directory=${encodeURIComponent(folder)}`);
      return [folder, sessions] as const;
    } catch {
      return [folder, [] as SessionSummary[]] as const;
    }
  }));
  state.sessionsByProject = Object.fromEntries(pairs);
  render();
}

/// Another project: the harness serves it from now on, and the app follows (the Mac's
/// workspace opens the project the session belongs to).
export async function openProject(folder: string, sessionId?: string) {
  if (!folder) return;
  if (folder !== state.project) {
    try {
      await api("/api/project", { method: "POST", body: { directory: folder } });
    } catch (error) {
      complain(error);
      return;
    }
    state.project = folder;
    // The shell remembers it too, so the app opens here next time.
    (window as unknown as { kuvo?: { rememberProject?: (folder: string) => void } }).kuvo?.rememberProject?.(folder);
    await loadSessions();
    await loadProjectSessions();
  }
  if (sessionId) await openSession(sessionId);
}

/// A project away from the sidebar (SidebarView.swift:375): the Mac keeps it in the
/// workspace's own list of folders, and the harness in its list of recent ones.
export async function removeProject(folder: string) {
  try {
    await api("/api/projects", { method: "DELETE", body: { path: folder } });
    state.projects = state.projects.filter(item => item !== folder);
    delete state.sessionsByProject[folder];
    render();
  } catch (error) {
    complain(error);
  }
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
    // What was just written is what the app keeps: reading it back could hand the page the
    // file as it was a moment ago, and a shortcut recorded a second ago would answer to its
    // old keys (the file is written by the engine, in its own time).
    await bootConfig(true);
    return true;
  } catch (error) {
    complain(error);
    return false;
  }
}

export async function bootConfig(keepsSettings = false) {
  const [cfg, mcp, skills] = await Promise.all([
    api<{ settings: Record<string, unknown> | null; path: string; problem: string | null; live?: unknown; opencode?: AppState["opencode"] }>("/api/config").catch(() => null),
    api<{ servers: McpServer[] }>("/api/mcp").catch(() => null),
    api<{ skills: AppState["skillsEngine"]; folder: string }>("/api/skills").catch(() => null),
  ]);
  if (cfg) {
    if (!keepsSettings) state.config = cfg.settings && typeof cfg.settings === "object" ? cfg.settings : {};
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

export async function sendPrompt(text: string, files: Attachment[] = [], delivery: "steer" | "queue" = "steer") {
  if (!state.session) return false;
  try {
    const body: Record<string, unknown> = { text };
    if (files.length) body.files = files;
    // ⌘Return on the Mac queues the message for after the run; here it is the same key.
    if (delivery === "queue") body.delivery = "queue";
    await api(`/api/sessions/${encodeURIComponent(state.session.id)}/prompt`, { method: "POST", body });
    const transcript = state.transcript ?? emptyTranscript();
    transcript.pending = [...transcript.pending, { id: `local_${Date.now()}`, text, files }];
    state.transcript = transcript;
    render();
    return true;
  } catch (error) {
    complain(error);
    return false;
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

/// A new session, in the project that is open — or in another one, as the Mac does from
/// a project's row (SidebarView.swift:358-361).
export async function newSession(directory?: string) {
  try {
    // A new session starts with the model picked last, as the Mac's does
    // (SessionView.swift:459-490).
    const model = lastModel();
    const { session } = await api<{ session: { id: string } }>("/api/sessions", {
      method: "POST",
      body: { ...(directory ? { directory } : {}), ...(model ? { model } : {}) },
    });
    if (directory && directory !== state.project) {
      state.project = directory;
      (window as unknown as { kuvo?: { rememberProject?: (folder: string) => void } }).kuvo?.rememberProject?.(directory);
    }
    await loadSessions();
    await loadProjectSessions();
    await openSession(session.id);
  } catch (error) {
    complain(error);
  }
}

/// The conversation as Markdown, the way the Mac app writes it out
/// (ConversationExport.swift:9-69): the title over it, "You" and "Agent" as the speakers,
/// the agent's steps listed together. Any session, not only the one in view: the Mac
/// reads the session's own history (Workspace.swift:462-466).
export async function markdownOf(session: SessionSummary): Promise<string> {
  const detail = await api<{ session: SessionSummary; messages: unknown[]; permissions: unknown[]; running: boolean; revert?: { messageID: string } }>(
    `/api/sessions/${encodeURIComponent(session.id)}`,
  );
  const messages = [...((detail.messages ?? []) as { id?: string }[])];
  // What an undo took back is not in the export (ConversationExport.swift:81-83).
  const undone = detail.revert?.messageID ? messages.findIndex(message => message?.id === detail.revert?.messageID) : -1;
  if (undone >= 0) messages.splice(undone);
  const transcript = fromHistory(session.id, messages as never[], (detail.permissions ?? []) as never[], detail.running);
  const directory = session.location?.directory ?? "";
  return conversationMarkdown(session.title || "New Session", transcript, {
    directory,
    summary: part => toolSummary(part.name, part.input, false, directory),
  });
}

/// The conversation written out, as a file the user chooses where to put: the Mac asks
/// with a save panel, and the download asks the shell for one.
export async function exportMarkdownOf(session: SessionSummary) {
  try {
    const text = await markdownOf(session);
    const blob = new Blob([text], { type: "text/markdown" });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    // The Mac's own name for the file (Workspace.swift:572): the session's name, with the
    // slashes a name cannot hold turned into dashes.
    anchor.download = `${(session.title || "Conversation").replace(/\//g, "-")}.md`;
    anchor.click();
    URL.revokeObjectURL(url);
  } catch (error) {
    complain(error);
  }
}

/// The conversation on the clipboard, as Markdown (the Mac's "Copy as Markdown",
/// SidebarView.swift:626-634).
export async function copyMarkdown(session: SessionSummary) {
  try {
    const text = await markdownOf(session);
    await navigator.clipboard?.writeText(text);
  } catch (error) {
    complain(error);
  }
}

export async function exportConversation() {
  const session = state.session;
  if (!session) return;
  await exportMarkdownOf(session);
}

/// ---- The choices the Mac keeps ----

/// The approval: the tools run without asking, or the edits and the commands wait for an
/// OK (the Mac's ToolApproval, ComposerMenus.swift:6-26).
export type Approval = "approveAll" | "askFirst";

/// The actions that wait for an OK when the user asked first
/// (PermissionsSettings.swift:22-31: the edits, the commands, the pages and the searches).
const ASK_FIRST = ["edit", "shell", "webfetch", "websearch"];

/// The approval as it was left.
export function approval(): Approval {
  try {
    return localStorage.getItem("kuvo-toolApproval") === "askFirst" ? "askFirst" : "approveAll";
  } catch {
    return "approveAll";
  }
}

/// The approval the user picks, and the session's own rules made from it
/// (ComposerMenus.swift:45-53: the rules that ask become rules that allow, and the ones
/// that are denied stay denied).
export async function setApproval(next: Approval) {
  try { localStorage.setItem("kuvo-toolApproval", next); } catch {}
  const session = state.session;
  if (!session) return;
  const effect = next === "askFirst" ? "ask" : "allow";
  const permissions = ASK_FIRST.map(action => ({ action, resource: "*", effect }));
  try {
    await api(`/api/sessions/${encodeURIComponent(session.id)}/permissions`, { method: "POST", body: { permissions } });
  } catch (error) {
    complain(error);
  }
}

/// The model picked last, so a new session starts with it (the Mac's LastModel,
/// SessionView.swift:459-490). It is kept whole: a model's id can have slashes in it
/// (OpenRouter's "anthropic/claude-sonnet-4.5").
export function lastModel(): { providerID: string; id: string } | null {
  try {
    const stored = localStorage.getItem("kuvo-lastModel");
    if (!stored) return null;
    const parsed = JSON.parse(stored) as { providerID?: string; id?: string };
    if (!parsed.providerID || !parsed.id) return null;
    return { providerID: parsed.providerID, id: parsed.id };
  } catch {
    return null;
  }
}

/// The model picked last, kept.
export function rememberModel(model: { providerID: string; id: string }) {
  try { localStorage.setItem("kuvo-lastModel", JSON.stringify(model)); } catch {}
}

/// The engine's own default model, read once at the start (the Mac's catalog knows it too,
/// Catalog.swift:221-225).
export async function loadDefaultModel() {
  try {
    const answer = await api<{ model: { providerID?: string; id?: string } | null }>("/api/models/default");
    const model = answer.model;
    if (model?.providerID && model?.id) state.defaultModel = { providerID: model.providerID, id: model.id };
  } catch {}
  render();
}

/// The model the conversation would use: the one the session has, else the one picked
/// last, else the engine's default, else the first of the list (the Mac's startingModel,
/// Catalog.swift:219-226).
export function modelInView(): { providerID: string; id: string; variant?: string } | null {
  const session = state.session?.model;
  if (session?.providerID && session?.id) return { providerID: session.providerID, id: session.id, variant: session.variant };
  const last = lastModel();
  if (last) return last;
  const fallback = state.defaultModel ?? (state.models[0] ? { providerID: state.models[0].providerID, id: state.models[0].id } : null);
  return fallback;
}

/// The models the user keeps — the Mac's starred models (ModelPicker.swift:40, 436-440),
/// kept whole: a model's id can have slashes in it.
export function favoriteModels(): { providerID: string; id: string }[] {
  try {
    const stored = JSON.parse(localStorage.getItem("kuvo-favoriteModels") ?? "[]");
    if (!Array.isArray(stored)) return [];
    return stored.filter(model => model && typeof model.providerID === "string" && typeof model.id === "string");
  } catch {
    return [];
  }
}

/// A model kept, or taken off the list.
export function rememberFavorite(model: { providerID: string; id: string }, on: boolean) {
  const kept = favoriteModels().filter(one => !(one.providerID === model.providerID && one.id === model.id));
  if (on) kept.push(model);
  try { localStorage.setItem("kuvo-favoriteModels", JSON.stringify(kept)); } catch {}
}

/// A session pinned to the top of the sidebar, or taken off (the Mac's
/// Workspace.swift:360-364, the mark "kuvo.pinned").
export async function pinSession(session: SessionSummary, pinned: boolean) {
  try {
    await api(`/api/sessions/${encodeURIComponent(session.id)}/pin`, { method: "POST", body: { pinned } });
    await loadSessions();
    await loadProjectSessions();
  } catch (error) {
    complain(error);
  }
}

/// A session put away, or brought back (the Mac's Workspace.swift:351-355).
export async function archiveSession(session: SessionSummary, archived: boolean) {
  try {
    await api(`/api/sessions/${encodeURIComponent(session.id)}/archive`, { method: "POST", body: { archived } });
    if (archived && state.session?.id === session.id) {
      state.session = null;
      state.transcript = null;
    }
    await loadSessions();
    await loadProjectSessions();
  } catch (error) {
    complain(error);
  }
}

/// The folder a session works in, opened where the user can see it: the Mac's "Show in
/// Finder" is the Explorer here (SidebarView.swift:616).
export function showInFolder(directory: string) {
  if (!directory) return;
  (window as unknown as { kuvo?: { showInFolder?: (path: string) => void } }).kuvo?.showInFolder?.(directory);
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
  // The window's own state, from the last time it was open: the panes' widths, what was
  // folded away, and the row at the top.
  rememberWindow();
  // The project that is open is a project of its own from the start: its sessions are
  // listed under it, before the rest of the projects are known (SidebarView.swift:194).
  state.projects = info.project ? [info.project] : [];
  render();
  connectEvents();
  if (state.project) {
    await loadSessions();
    // The projects, with their own names and folders: the session in view is given them
    // (the Mac's Workspace.syncFolders, SessionModel.swift:1379-1405).
    await loadProjects();
    await loadProjectFiles();
    const newest = state.sessions[0];
    if (newest) await openSession(newest.id);
  }
  void loadModels();
  void loadDefaultModel();
  void loadAgents();
  void loadCommands();
  // The app's own settings, the engine's too: the settings page reads them, and the
  // provider's compatibility is written in them.
  void bootConfig().then(() => applyProviderCompatibility());
  setInterval(() => {
    void api<{ project: string | null; engine: AppState["engine"] }>("/api/state")
      .then(next => { state.engine = next.engine; render(); })
      .catch(() => {});
  }, 4000);
}

export type { Transcript };

/// Worktrees: a git worktree of a project, where a session runs apart (Workspace.swift:201-216).
/// Tracked on this machine, since the engine makes them but does not list them.
export type Worktree = { project: string; root: string; branch: string };

export function worktrees(): Worktree[] {
  try { return JSON.parse(localStorage.getItem("kuvo-worktrees") ?? "[]"); } catch { return []; }
}

function saveWorktrees(list: Worktree[]) {
  localStorage.setItem("kuvo-worktrees", JSON.stringify(list));
}

export async function createWorktree(directory?: string): Promise<string | null> {
  const project = directory ?? state.project;
  if (!project) return null;
  try {
    const location = await api<{ project: { id: string } }>(`/api/location?directory=${encodeURIComponent(project)}`);
    const projectId = location.project?.id;
    if (!projectId) throw new Error("No project for this folder.");
    const { directory: root } = await api<{ directory: string }>("/api/worktree", { method: "POST", body: { projectID: projectId } });
    // The engine leaves the worktree on no branch; give it one of its own, the Mac's way.
    const branch = `kuvo/${root.replace(/[/\\]+$/, "").split(/[/\\]/).pop() ?? "worktree"}`;
    try { await api("/api/git/branch", { method: "POST", body: { name: branch, directory: root } }); } catch { /* branch creation is best-effort */ }
    const list = worktrees();
    if (!list.some(item => item.root === root)) list.push({ project, root, branch });
    saveWorktrees(list);
    return root;
  } catch (error) {
    complain(error);
    return null;
  }
}

export async function removeWorktree(root: string, force = false): Promise<void> {
  const list = worktrees();
  const entry = list.find(item => item.root === root);
  try {
    if (entry) {
      const location = await api<{ project: { id: string } }>(`/api/location?directory=${encodeURIComponent(entry.project)}`);
      if (location.project?.id) await api("/api/worktree", { method: "DELETE", body: { projectID: location.project.id, directory: root, force } });
    }
    saveWorktrees(list.filter(item => item.root !== root));
  } catch (error) {
    complain(error);
  }
}
