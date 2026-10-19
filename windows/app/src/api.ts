// The harness's API, typed. The routes and payloads are the same ones the Mac app's
// OpenCodeAPI speaks; the shapes here are what this side uses.

export type Json = unknown;

export interface SessionSummary {
  id: string;
  title?: string | null;
  time?: { created?: number; updated?: number; idle?: number; viewed?: number; archived?: number };
  metadata?: Record<string, unknown> | null;
  tokens?: { input?: number; output?: number; reasoning?: number; total?: number };
  model?: { providerID?: string; id?: string } | null;
  parentID?: string | null;
  cost?: number;
}

export interface MessagePart {
  type: string;
  text?: string;
  name?: string;
  status?: string;
  input?: Record<string, unknown>;
  inputText?: string;
  output?: unknown;
  error?: unknown;
}

export interface TranscriptEntry {
  kind: "user" | "assistant" | "notice" | "shell" | "idle";
  id?: string;
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

export interface AppState {
  project: string | null;
  engine: EngineState | null;
  sessions: SessionSummary[];
  session: SessionSummary | null;
  transcript: Transcript | null;
  models: Model[];
  agents: Agent[];
  commands: Command[];
  drawerTab: "files" | "terminal" | "changes";
  sessionQuery: string;
  openSessions: string[];
  transcripts: Map<string, Transcript>;
  findQuery: string;
  agent: string;
  split: string | null;
  projects: string[];
  shortcuts: unknown;
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
  lineComments?: { file: string; line: number; text: string }[];
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
