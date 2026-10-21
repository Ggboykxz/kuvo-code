// The harness's API, typed. The routes and payloads are the same ones the Mac app's
// OpenCodeAPI speaks; the shapes here are what this side uses.

export type Json = unknown;

export interface SessionSummary {
  id: string;
  title?: string | null;
  time?: { created?: number; updated?: number; idle?: number; viewed?: number; archived?: number };
  metadata?: Record<string, unknown> | null;
  tokens?: { input?: number; output?: number; reasoning?: number; total?: number };
  /** The session's own rules: what the agent may do without asking
   *  (OpenCodeKit's PermissionRule, Models/Session.swift:54-68). */
  permissions?: { action?: string; resource?: string; effect?: string }[];
  /** The session's model: the provider, the id, and the effort it is asked for
   *  (OpenCodeKit's ModelRef, Models/Common.swift:70-83). */
  model?: { providerID?: string; id?: string; variant?: string } | null;
  parentID?: string | null;
  cost?: number;
  /** Where the session runs: the folder of its project (Workspace.Project.directory). */
  location?: { directory?: string };
}

export interface MessagePart {
  type: string;
  id?: string;
  text?: string;
  created?: number;
  completed?: number;
  name?: string;
  status?: string;
  input?: Record<string, unknown>;
  inputText?: string;
  output?: unknown;
  error?: unknown;
  /** The call's own metadata — the engine keeps the files a call changed there, which is
      the only place the Mac reads the diff stat from (ToolCallView.swift:358-366). */
  metadata?: Record<string, unknown> | null;
}

export interface TranscriptEntry {
  kind: "user" | "assistant" | "notice" | "shell" | "idle";
  id?: string;
  /** When the message began, in milliseconds — the Mac's "Working…" counts from it. */
  created?: number;
  text?: string;
  parts?: MessagePart[];
  files?: Attachment[];
  command?: string;
  output?: string;
  exit?: number;
  outcome?: string;
  error?: unknown;
  running?: boolean;
  retry?: { attempt?: number } | null;
  cost?: number;
  model?: string;
}

export interface Attachment {
  name?: string;
  mime?: string;
  data?: string;
  uri?: string;
}

export interface PendingMessage {
  id: string;
  text: string;
  delivery?: string;
  files?: Attachment[];
}

export interface PermissionRequest {
  id: string;
  sessionID: string;
  action?: string;
  resources?: string[];
  message?: string;
}

export interface Transcript {
  entries: TranscriptEntry[];
  pending: PendingMessage[];
  permissions: PermissionRequest[];
  running: boolean;
}

export interface FormField {
  key: string;
  title?: string;
  description?: string;
  required?: boolean;
  hidden?: boolean;
  type?: string;
  default?: unknown;
  placeholder?: string;
  minimum?: number;
  maximum?: number;
  url?: string;
  options?: { value: string; label?: string }[];
}

export interface FormRequest {
  id: string;
  sessionID?: string;
  title?: string;
  metadata?: { kind?: string; server?: string; message?: string } | null;
  fields?: FormField[];
}

export interface McpServer {
  name: string;
  status?: { status?: string; error?: string };
  integrationID?: string;
}

export interface Model {
  id: string;
  providerID: string;
  name?: string;
  /** The family the engine knows it by; a model only the settings name has none. */
  family?: string;
  /** The levels the model has — the effort it can be asked for (ModelPicker.swift:5-14). */
  variants?: { id: string }[];
  limit?: { context?: number };
}

export interface Agent {
  id: string;
  name?: string;
  mode?: string;
  description?: string;
  hidden?: boolean;
}

export interface Command {
  name: string;
  description?: string;
}

export interface VcsInfo {
  branch?: { current?: string; provider?: string };
}

export interface SessionDiff {
  file: string;
  patch?: string;
  additions?: number;
  deletions?: number;
  status?: string;
}

export interface ConfigFile {
  settings: Record<string, unknown> | null;
  problem: string | null;
  path: string;
  live?: unknown;
  opencode?: { settings: Record<string, unknown> | null; problem: string | null; path: string; exists?: boolean };
}

export interface EngineState {
  status: string;
  version?: string | null;
}

/** A comment on a line of the changes, the Mac's own (ReviewComments.swift:6-18). */
export type ReviewComment = {
  /** The comment's own name, so the panel can tell two apart. */
  id: string;
  /** The file the comment is on, as the panel names it. */
  file: string;
  /** The line's number, on the side the comment was written on. */
  line: number;
  /** Which side of the change the line is on. */
  side: "new" | "old";
  /** The line as it read when the comment was written. */
  snippet: string;
  /** What the comment says. */
  text: string;
};

export interface AppState {
  project: string | null;
  engine: EngineState | null;
  sessions: SessionSummary[];
  session: SessionSummary | null;
  transcript: Transcript | null;
  models: Model[];
  /** The engine's own default model (Catalog.swift:221-225). */
  defaultModel: { providerID: string; id: string } | null;
  agents: Agent[];
  commands: Command[];
  drawerTab: "files" | "terminal" | "changes";
  sessionQuery: string;
  openSessions: string[];
  transcripts: Map<string, Transcript>;
  findQuery: string;
  /** Whether the find bar is open (FindBar.swift:251-291). */
  findOpen: boolean;
  agent: string;
  split: string | null;
  projects: string[];
  /** The projects' own names, by their folder (the Mac's Workspace.Project.name). */
  projectNames: Record<string, string>;
  /** The projects' run commands, by their folder (the Mac's Workspace.ProjectSettings.run). */
  projectRuns: Record<string, string>;
  /** The projects' other folders, by their folder (the Mac's Workspace.ProjectSettings.folders). */
  projectFolderList: Record<string, string[]>;
  /** The project being named, in the editor over the window. */
  editingProject: string | null;
  /** The sessions of every project, by its folder (SidebarView.swift:194). */
  sessionsByProject: Record<string, SessionSummary[]>;
  /** What the user folded away: the sections' names and the projects' folders
   *  (SidebarView.swift:33-37). */
  collapsed: Record<string, boolean>;
  /** Whether the row at the top — the project, its branch and the sessions as tabs —
   *  is shown (TabBar.showsKey, MainView.swift:22). */
  showsTabBar: boolean;
  contextGauge: unknown;
  inbox: { id: string; delivery?: string; payload?: { text?: string } }[];
  vcs: VcsInfo | null;
  sessionDiff: SessionDiff[];
  config: Record<string, unknown> | null;
  configPath: string | null;
  configProblem: string | null;
  configLive: unknown;
  opencode: ConfigFile["opencode"];
  mcpLive: McpServer[];
  skillsEngine: { id: string; name?: string; description?: string; path?: string }[];
  cfgEditor: { kind: string; id: string | null } | null;
  forms: FormRequest[];
  revert: { messageID: string } | null;
  files: { path: string; name: string; kind: string }[];
  projectFiles: string[];
  openFile: string | null;
  paletteOpen: boolean;
  settingsOpen: boolean;
  settingsSection: string;
  diffOpen: boolean;
  diffTitle?: string;
  diffOld?: string;
  diffNew?: string;
  drawerOpen: boolean;
  pickerOpen: boolean;
  openFileContent?: string;
  toast: { title: string; body: string } | null;
  /** A comment on a line of the changes, the Mac's own (ReviewComments.swift:6-18). */
  lineComments?: ReviewComment[];
  quote?: string;
  /** The picture in view, and the ones of the same message beside it (the Mac's viewer
   *  steps through them, ImageViewer.swift:128-131, 209-221). */
  viewing?: { items: { source: string; name: string; detail?: string }[]; index: number } | null;
  sidebarOpen?: boolean;
  /** The widths the panes ask for, before the window has its say (MainView.swift:38-40,
   *  90): the sessions 280, the panel 420, the split 560. The layout sets what fits. */
  sessionsWidth: number;
  changesWidth: number;
  splitWidth: number;
}

/// One fetch, the way the page talks to the harness.
export async function api<T = Record<string, never>>(
  path: string,
  options: { method?: string; body?: unknown; headers?: Record<string, string> } = {},
): Promise<T> {
  const response = await fetch(path, {
    method: options.method ?? "GET",
    headers: { "content-type": "application/json", ...options.headers },
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
  });
  const text = await response.text();
  const data = text === "" ? {} : JSON.parse(text);
  if (!response.ok) throw new Error((data as { error?: string }).error ?? `HTTP ${response.status}`);
  return data as T;
}
