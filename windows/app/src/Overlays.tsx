// What floats over the conversation: the command palette, the files and terminal drawer,
// the changes of a session, and the little note that says what happened.

import { useEffect, useMemo, useRef, useState } from "react";
import { api } from "./api";
import { errorText } from "./lib";
import { ChangesPanel } from "./Changes";
import { complain, loadProjectFiles, loadSessions, notify, openProjectFile, openSession, projectName, projectRun, render, setProjectSettings, state, useStore, newSession, exportConversation, stopRun } from "./store";
import { keysOf } from "./shortcuts";
import { useDialogFocus } from "./focus";
import { buildTree, type TreeNode } from "./filetree.mjs";
import { openQuicklyMatches } from "./open-quickly.mjs";
import { terminalSelectionBlock, terminalSocketUrl } from "./terminal.mjs";
import { Symbol } from "./components/symbols";
import { ContextMenu } from "./components/context-menu";

// ---- The command palette ----

type PaletteKind = "action" | "command" | "session" | "file";
type PaletteRow = {
  id: string;
  kind: PaletteKind;
  title: string;
  detail?: string;
  shortcut?: string;
  run: () => void | Promise<void>;
};
type PaletteSection = { title: string; items: PaletteRow[] };

/// The Mac palette's loose matching (CommandPalette.swift:190-211): the start, then the
/// start of a word, then the words' first letters, then anywhere, then each word.
function fuzzyRank(query: string, text: string): number | null {
  const q = query.toLowerCase().trim();
  const t = text.toLowerCase();
  if (!q) return null;
  const words = t.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  if (t.startsWith(q)) return 0;
  if (words.some(word => word.startsWith(q))) return 1;
  if (q.length > 1 && !q.includes(" ") && words.map(word => word[0]).join("").startsWith(q)) return 2;
  if (t.includes(q)) return 3;
  const parts = q.split(/\s+/);
  if (parts.length > 1 && parts.every(part => words.some(word => word.startsWith(part)))) return 4;
  return null;
}

function paletteIcon(kind: PaletteKind) {
  if (kind === "session") {
    return (
      <svg viewBox="0 0 16 16" width="16" height="16" fill="none" aria-hidden="true">
        <path d="M2.7 3.4h10.6v6.7H8.2l-3.2 2.5v-2.5H2.7z" stroke="currentColor" strokeWidth="1.2" strokeLinejoin="round" />
      </svg>
    );
  }
  if (kind === "file") {
    return (
      <svg viewBox="0 0 16 16" width="16" height="16" fill="none" aria-hidden="true">
        <path d="M4 2.2h5.1L12.8 6v7.8H4z" stroke="currentColor" strokeWidth="1.2" strokeLinejoin="round" />
        <path d="M9 2.4V6h3.6" stroke="currentColor" strokeWidth="1.2" strokeLinejoin="round" />
      </svg>
    );
  }
  if (kind === "command") {
    return (
      <svg viewBox="0 0 16 16" width="16" height="16" fill="none" aria-hidden="true">
        <rect x="2.2" y="3.2" width="11.6" height="9.6" rx="2" stroke="currentColor" strokeWidth="1.2" />
        <path d="M5 6.2l2.1 1.9L5 10M8.5 10.2h2.7" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    );
  }
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" fill="none" aria-hidden="true">
      <path d="M2.8 8h9.7M8.8 4.3L12.5 8l-3.7 3.7" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

export function Palette() {
  useStore();
  const [query, setQuery] = useState("");
  const [index, setIndex] = useState(0);
  const [files, setFiles] = useState<{ path: string; name: string; relative: string }[]>([]);
  const inputRef = useRef<HTMLInputElement>(null);
  const paletteRef = useRef<HTMLDivElement>(null);
  useDialogFocus(state.paletteOpen, paletteRef, "#palette-input");

  useEffect(() => {
    if (state.paletteOpen) {
      setQuery("");
      setIndex(0);
    }
  }, [state.paletteOpen]);

  const needle = query.trim().toLowerCase();
  useEffect(() => {
    if (!state.paletteOpen || !state.project || !needle) { setFiles([]); return; }
    void api<{ files: { path: string; name: string; relative: string }[] }>(`/api/search?q=${encodeURIComponent(needle)}`)
      .then(answer => setFiles((answer.files ?? []).slice(0, 5)))
      .catch(() => setFiles([]));
  }, [state.paletteOpen, needle, state.project]);

  const folder = state.project ? state.project.replace(/[\\/]+$/, "").split(/[\\/]/).pop() ?? "" : "";
  // The Mac's palette actions, in its order (MainView.swift:1418-1462): the usual ones
  // first, and the ones this client has no business of.
  const coreActions: PaletteRow[] = [
    { id: "action:new-session", kind: "action", title: "New Session", shortcut: keysOf("new-session"), run: async () => { await newSession(); } },
    ...(folder ? [{ id: "action:run", kind: "action" as const, title: "Run", detail: projectRun(folder) || undefined, shortcut: keysOf("run"), run: () => { runTheProject(); } }] : []),
    { id: "action:terminal", kind: "action", title: "New Terminal", shortcut: keysOf("terminal"), run: () => { state.drawerOpen = true; state.drawerTab = "terminal"; render(); } },
    { id: "action:changes", kind: "action", title: "Show Changes", shortcut: keysOf("changes"), run: () => { state.drawerOpen = true; state.drawerTab = "changes"; render(); } },
    { id: "action:files", kind: "action", title: "Show Files", shortcut: keysOf("files"), run: () => { state.drawerOpen = true; state.drawerTab = "files"; render(); } },
    { id: "action:panel", kind: "action", title: state.drawerOpen ? "Hide Panel" : "Show Panel", shortcut: keysOf("panel"), run: () => { state.drawerOpen = !state.drawerOpen; render(); } },
    { id: "action:sidebar", kind: "action", title: state.sidebarOpen === false ? "Show Sessions" : "Hide Sessions", shortcut: keysOf("sidebar"), run: () => { state.sidebarOpen = state.sidebarOpen === false; render(); } },
    ...(folder ? [{ id: "action:edit-project", kind: "action" as const, title: "Edit Project…", detail: projectName(folder), run: () => { state.editingProject = folder; render(); } }] : []),
    { id: "action:find", kind: "action", title: "Find in Conversation…", shortcut: keysOf("find"), run: () => { (document.getElementById("find") as HTMLInputElement | null)?.focus(); } },
    { id: "action:rename", kind: "action", title: "Rename this session", run: async () => {
      const title = prompt("Name this session", state.session?.title ?? "");
      if (!title) return;
      await api(`/api/sessions/${encodeURIComponent(state.session!.id)}/rename`, { method: "POST", body: { title } });
      await loadSessions();
    } },
    { id: "action:settings", kind: "action", title: "Settings", shortcut: keysOf("settings"), run: () => { state.settingsOpen = true; state.settingsSection = "appearance"; render(); } },
    // And the ones that are this client's own.
    { id: "action:stop", kind: "action", title: "Stop", shortcut: keysOf("stop"), run: async () => { await stopRun(); } },
    { id: "action:save", kind: "action", title: "Save the conversation as Markdown", shortcut: keysOf("save"), run: async () => { await exportConversation(); } },
    { id: "action:refresh", kind: "action", title: "Refresh sessions", run: async () => { await loadSessions(); notify("Kuvo Code", "Sessions refreshed."); } },
  ];
  const commandActions: PaletteRow[] = state.commands.map(command => ({
    id: `command:${command.name}`,
    kind: "command",
    title: `/${command.name}`,
    detail: command.description,
    run: () => {
      const prompt = document.getElementById("prompt") as HTMLTextAreaElement | null;
      if (prompt) {
        prompt.value = `/${command.name} `;
        prompt.dispatchEvent(new Event("input", { bubbles: true }));
        prompt.focus();
      }
    },
  }));
  const sessionRows: PaletteRow[] = state.sessions.map(session => ({
    id: `session:${session.id}`,
    kind: "session",
    title: session.title || "New Session",
    detail: folder,
    run: async () => { state.settingsOpen = false; await openSession(session.id); },
  }));
  const actionRows = [...coreActions, ...commandActions];
  const fileRows: PaletteRow[] = files.map(file => {
    const relative = file.relative || file.path;
    const cut = relative.lastIndexOf("/");
    return {
      id: `file:${file.path}`,
      kind: "file",
      title: file.name,
      detail: cut > 0 ? relative.slice(0, cut) : undefined,
      run: async () => { await openProjectFile(relative); },
    };
  });

  const best = (rows: PaletteRow[], limit: number) => rows
    .map((row, order) => ({ row, rank: fuzzyRank(needle, row.title), order }))
    .filter((item): item is { row: PaletteRow; rank: number; order: number } => item.rank !== null)
    .sort((a, b) => a.rank - b.rank || a.order - b.order)
    .slice(0, limit)
    .map(item => item.row);
  const sections: PaletteSection[] = needle
    ? [
        { title: "Actions", items: best(actionRows, 5) },
        { title: "Sessions", items: best(sessionRows, 5) },
        { title: "Files", items: fileRows },
      ].filter(section => section.items.length > 0)
    : [
        { title: "Recent Sessions", items: sessionRows.slice(0, 5) },
        { title: "Actions", items: actionRows.slice(0, 7) },
      ].filter(section => section.items.length > 0);
  const rows = sections.flatMap(section => section.items);
  const current = rows.length ? Math.min(index, rows.length - 1) : 0;
  const total = rows.length;
  const run = async (action: () => void | Promise<void>) => {
    state.paletteOpen = false;
    render();
    await action();
  };

  return (
    <div
      id="palette"
      ref={paletteRef}
      role="dialog"
      aria-modal="true"
      aria-label="Command palette"
      tabIndex={-1}
      className={`palette ${state.paletteOpen ? "shown" : ""}`}
      hidden={!state.paletteOpen}
      onClick={event => { if (event.target === event.currentTarget) { state.paletteOpen = false; render(); } }}
    >
      {/* The palette is one card of glass: a 48 pt search, then the list (CommandPalette.swift:81-111). */}
      <div className="palette-card">
        <div className="palette-search">
          <svg viewBox="0 0 16 16" width="15" height="15" fill="none" aria-hidden="true">
            <circle cx="6.8" cy="6.8" r="4.1" stroke="currentColor" strokeWidth="1.3" />
            <path d="M9.9 9.9L13.4 13.4" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
          </svg>
          <input
            id="palette-input"
            placeholder={state.project ? "Search sessions, files and actions" : "Search sessions and actions"}
            aria-label="Search commands, sessions, and files"
            role="combobox"
            aria-expanded={sections.length > 0}
            aria-controls="palette-list"
            spellCheck={false}
            autoComplete="off"
            value={query}
            ref={inputRef}
            onChange={event => { setQuery(event.target.value); setIndex(0); }}
            onKeyDown={event => {
              if (event.key === "ArrowDown") { event.preventDefault(); setIndex(current => (current + 1) % Math.max(total, 1)); return; }
              if (event.key === "ArrowUp") { event.preventDefault(); setIndex(current => (current - 1 + total) % Math.max(total, 1)); return; }
              // Escape closes the palette, and stops there: the window's own handler
              // would otherwise take it as a step further back.
              if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); state.paletteOpen = false; render(); return; }
              if (event.key === "Enter") {
                event.preventDefault();
                const chosen = rows[current];
                if (chosen) void run(chosen.run);
              }
            }}
          />
        </div>
        {sections.length ? (
          <div id="palette-list" className="palette-list" role="listbox" aria-label="Matches">
            {sections.map(section => (
              <div className="palette-section" key={section.title}>
                <div className="palette-title">{section.title}</div>
                {section.items.map(item => {
                  const position = rows.indexOf(item);
                  return (
                    <div
                      key={item.id}
                      role="option"
                      aria-selected={position === current}
                      className={`palette-item ${position === current ? "selected" : ""}`}
                      onClick={() => void run(item.run)}
                    >
                      <span className={`palette-icon ${item.kind}`} aria-hidden="true">{paletteIcon(item.kind)}</span>
                      <span className="palette-name">{item.title}</span>
                      {item.detail ? <span className="palette-detail">{item.detail}</span> : null}
                      {item.shortcut ? <span className="palette-keys">{item.shortcut}</span> : null}
                    </div>
                  );
                })}
              </div>
            ))}
          </div>
        ) : (
          <div className="palette-empty">Nothing matches.</div>
        )}
      </div>
    </div>
  );
}

// ---- Open Quickly ----

/// Open Quickly (Shift+Command+O on the Mac): type part of a file's name to find it in the project, and open it
/// in the side panel. The Mac's own palette (OpenQuickly.swift:4-104): 560 wide, a 48 pt
/// search, 30 pt rows, the newest files before anything is typed, and ten matches at most.
export function OpenQuickly() {
  useStore();
  const [query, setQuery] = useState("");
  const [index, setIndex] = useState(0);
  const [files, setFiles] = useState<{ path: string; name: string; relative: string }[]>([]);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!state.openQuickly) return;
    setQuery("");
    setIndex(0);
    setTimeout(() => inputRef.current?.focus(), 0);
    if (!state.project) { setFiles([]); return; }
    let current = true;
    // The Mac lists the project's files newest first (ProjectFiles.newestFirst), so the
    // ones changed most recently are what the palette opens with.
    void api<{ files: { path: string; name: string; relative: string }[] }>("/api/files?sort=recent&limit=2000")
      .then(answer => { if (current) setFiles(answer.files ?? []); })
      .catch(() => { if (current) setFiles([]); });
    return () => { current = false; };
  }, [state.openQuickly, state.project]);

  const matches = useMemo(() => openQuicklyMatches(query, files), [query, files]);
  const current = matches.length ? Math.min(index, matches.length - 1) : 0;
  const choose = (file: { relative?: string; path?: string } | undefined) => {
    const relative = file?.relative || file?.path || "";
    if (!relative) return;
    state.openQuickly = false;
    render();
    void openProjectFile(relative);
  };

  return (
    <div
      id="open-quickly"
      className={`open-quickly ${state.openQuickly ? "shown" : ""}`}
      hidden={!state.openQuickly}
      onClick={event => { if (event.target === event.currentTarget) { state.openQuickly = false; render(); } }}
    >
      <div className="open-quickly-card" role="dialog" aria-label="Open Quickly">
        <div className="open-quickly-search">
          <svg viewBox="0 0 16 16" width="15" height="15" fill="none" aria-hidden="true">
            <circle cx="6.8" cy="6.8" r="4.1" stroke="currentColor" strokeWidth="1.3" />
            <path d="M9.9 9.9L13.4 13.4" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
          </svg>
          <input
            id="open-quickly-input"
            placeholder="Open a file in the project"
            spellCheck={false}
            autoComplete="off"
            value={query}
            ref={inputRef}
            onChange={event => { setQuery(event.target.value); setIndex(0); }}
            onKeyDown={event => {
              if (event.key === "ArrowDown") { event.preventDefault(); setIndex(matches.length ? Math.min(matches.length - 1, current + 1) : 0); return; }
              if (event.key === "ArrowUp") { event.preventDefault(); setIndex(Math.max(0, current - 1)); return; }
              if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); state.openQuickly = false; render(); return; }
              if (event.key === "Enter") { event.preventDefault(); choose(matches[current]); }
            }}
          />
        </div>
        {matches.length ? (
          <div id="open-quickly-list" className="open-quickly-list" role="listbox" aria-label="Project files">
            {matches.map((file, row) => {
              const relative = file.relative || file.path || "";
              const cut = relative.lastIndexOf("/");
              return (
                <button
                  key={file.path || relative}
                  className={`open-quickly-row ${row === current ? "selected" : ""}`}
                  role="option"
                  aria-selected={row === current}
                  onClick={() => choose(file)}
                >
                  <Symbol name="doc" size={16} />
                  <span className="open-quickly-name">{file.name}</span>
                  {cut > 0 ? <span className="open-quickly-folder">{relative.slice(0, cut)}</span> : null}
                </button>
              );
            })}
          </div>
        ) : null}
      </div>
    </div>
  );
}

/// What the terminal's own library gives us: the bits we use.
interface Xterm {
  open(container: HTMLElement): void;
  write(data: string): void;
  paste(data: string): void;
  focus(): void;
  onData(handler: (data: string) => void): void;
  loadAddon(addon: XtermAddon): void;
  getSelection(): string;
  dispose(): void;
  cols: number;
  rows: number;
  options: { theme?: Record<string, string> };
}

interface XtermAddon {
  fit(): void;
  dispose?(): void;
}

// ---- The folder picker ----

export function Picker() {
  useStore();
  const [shown, setShown] = useState<string>("");
  const [parent, setParent] = useState<string | null>(null);
  const [folders, setFolders] = useState<{ name: string; path: string }[]>([]);
  const [note, setNote] = useState("");
  const [typed, setTyped] = useState("");

  const browse = async (folder: string | null) => {
    try {
      const answer = await api<{ path: string; parent: string | null; folders: { name: string; path: string }[] }>(
        `/api/browse?path=${encodeURIComponent(folder ?? "")}`,
      );
      setShown(answer.path);
      setParent(answer.parent);
      setFolders(answer.folders ?? []);
      setTyped(answer.path);
      setNote((answer.folders ?? []).length === 0 ? "No folders inside." : "");
    } catch (error) {
      setNote(error instanceof Error ? error.message : String(error));
    }
  };

  useEffect(() => {
    if (!state.pickerOpen) return;
    void browse(state.project ?? null);
  }, [state.pickerOpen]);

  return (
    <div id="picker" className={`picker-modal ${state.pickerOpen ? "shown" : ""}`} hidden={!state.pickerOpen}>
      <div className="picker-card">
        <div className="settings-row">
          <span>Folder</span>
          <input id="picker-path" value={typed} onChange={event => setTyped(event.target.value)} onKeyDown={event => { if (event.key === "Enter") void browse(typed); }} />
        </div>
        <ul id="picker-folders">
          {folders.map(child => (
            <li key={child.path}>
              <button onClick={() => void browse(child.path)}>{`${child.name}/`}</button>
            </li>
          ))}
        </ul>
        <div id="picker-note" className="where">{note}</div>
        <div className="settings-editor-buttons">
          <button id="picker-up" className="small" title="Up one folder" aria-label="Up one folder" disabled={parent === null} onClick={() => parent && void browse(parent)}>
            <Symbol name="chevron.up" size={12} />
          </button>
          <button id="picker-go" className="small" onClick={() => void browse(typed)}>Go</button>
          <button id="picker-use" className="primary" onClick={async () => {
            try {
              await api("/api/project", { method: "POST", body: { directory: shown } });
              state.project = shown;
              state.session = null;
              state.transcript = null;
              state.pickerOpen = false;
              await loadSessions();
              await loadProjectFiles();
            } catch (error) {
              setNote(error instanceof Error ? error.message : String(error));
            }
          }}>Use this folder</button>
          <button id="picker-close" className="small" onClick={() => { state.pickerOpen = false; render(); }}>Close</button>
        </div>
      </div>
    </div>
  );
}

/// The project's own command, run in the panel's terminal — the Mac's Run (MainView.swift:1479-1491).
/// Without a command yet, the project's editor opens on the run field.
export function runTheProject() {
  const folder = state.project ?? "";
  const command = folder ? projectRun(folder) : "";
  if (!command) {
    state.editingProject = folder || null;
    render();
    return;
  }
  runInTerminal(command, folder);
}

/// A project's own name, changed where the Mac changes it: over the window, in a small
/// card (the Mac's ProjectEditor, ProjectEditor.swift:8-13 — its name and its folders;
/// the folders the agent works in besides the first are the engine's own).
export function ProjectEditor() {
  useStore();
  const [name, setName] = useState("");
  const [run, setRun] = useState("");
  const [folders, setFolders] = useState<string[]>([]);
  const [typedFolder, setTypedFolder] = useState("");
  const folder = state.editingProject;

  useEffect(() => {
    if (!folder) return;
    setName(state.projectNames[folder] ?? "");
    setRun(state.projectRuns[folder] ?? "");
    setFolders(state.projectFolderList[folder] ?? []);
    setTypedFolder("");
  }, [folder]);

  const addFolder = () => {
    const typed = typedFolder.trim();
    if (!typed) return;
    if (!folders.includes(typed)) setFolders([...folders, typed]);
    setTypedFolder("");
  };

  if (!folder) return null;
  return (
    <div id="project-editor" className="picker-modal shown">
      <div className="picker-card">
        <h3>Edit Project…</h3>
        <div className="settings-row">
          <span>Name</span>
          <input
            id="project-name"
            value={name}
            placeholder={folder.replace(/[/\\]+$/, "").split(/[/\\]/).pop() ?? folder}
            onChange={event => setName(event.target.value)}
            onKeyDown={event => { if (event.key === "Enter") { event.preventDefault(); void save(); } }}
          />
        </div>
        <div className="settings-row">
          <span>Folder</span>
          <input id="project-folder" value={folder} readOnly />
        </div>
        {/* The Mac's Folders section (ProjectEditor.swift:129-131): the project's other
            folders, where the agent may work too. */}
        <div className="settings-row">
          <span>Folders</span>
          <div className="project-folders">
            {folders.map((one, index) => (
              <div className="cfg-row" key={one}>
                <div className="cfg-row-main"><div className="cfg-row-title"><strong>{one}</strong></div></div>
                {index > 0 ? (
                  <button className="small" onClick={() => setFolders(folders.filter(other => other !== one))}>Remove</button>
                ) : null}
              </div>
            ))}
            <div className="settings-row">
              <span />
              <input
                id="project-folder-add"
                value={typedFolder}
                placeholder="Another folder"
                onChange={event => setTypedFolder(event.target.value)}
                onKeyDown={event => { if (event.key === "Enter") { event.preventDefault(); addFolder(); } }}
              />
              <button className="small" id="project-folder-add-button" onClick={addFolder}>Add</button>
            </div>
          </div>
        </div>
        <div className="settings-note">Sessions run in the primary folder; the agent can work in the others too.</div>
        <div className="settings-row">
          <span>Run</span>
          <input
            id="project-run"
            value={run}
            placeholder="npm run dev"
            onChange={event => setRun(event.target.value)}
            onKeyDown={event => { if (event.key === "Enter") { event.preventDefault(); void save(); } }}
          />
        </div>
        <div className="settings-editor-buttons">
          <button
            id="project-save"
            className="primary"
            onClick={async () => {
              await save();
            }}
          >Save</button>
          <button id="project-cancel" className="small" onClick={() => { state.editingProject = null; render(); }}>Cancel</button>
        </div>
      </div>
    </div>
  );

  async function save() {
    if (!folder) return;
    state.editingProject = null;
    await setProjectSettings(folder, { name, run, folders });
    render();
  }
}

// ---- The drawer: files and terminal ----

/// The terminal the shell opened, and the command waiting for it: the Mac runs a
/// project's run command in the panel's terminal (MainView.swift:1479-1491).
let terminalSocket: WebSocket | null = null;
let terminalWaiting: string | null = null;
let terminalNeedsRestart = false;
let terminalRestart: (() => void) | null = null;
let terminalRun = 0;

/// New Terminal (⌃`), from the Mac's menu. One shell is enough for this panel; a dead
/// shell is restarted rather than opening a second tab that has nowhere to live.
export function openTerminal() {
  state.drawerOpen = true;
  state.drawerTab = "terminal";
  render();
  if (terminalNeedsRestart) terminalRestart?.();
}

/// A command run in the terminal, in the project's folder: the Mac's own Run. A command
/// already running is interrupted first, as TerminalSession.run does (Ctrl-C, 300 ms),
/// rather than the new text being typed into the program that is still running.
export function runInTerminal(command: string, folder: string) {
  openTerminal();
  // Single quotes are literal in PowerShell, the shell the server starts: a project
  // folder with a `$` in its name cannot be expanded. An apostrophe is doubled, which is
  // how PowerShell writes one inside a single-quoted string.
  const quoted = folder.replace(/'/g, "''");
  const line = folder ? `cd '${quoted}'\r\n${command}\r\n` : `${command}\r\n`;
  const run = ++terminalRun;
  if (terminalSocket && terminalSocket.readyState === WebSocket.OPEN) {
    terminalSocket.send("\x03");
    window.setTimeout(() => {
      // A second Run in the 300 ms window replaces this one, rather than both commands
      // arriving at the shell.
      if (run !== terminalRun) return;
      if (terminalSocket && terminalSocket.readyState === WebSocket.OPEN) terminalSocket.send(line);
      else terminalWaiting = line;
    }, 300);
    return;
  }
  terminalWaiting = line;
  if (terminalNeedsRestart) terminalRestart?.();
}

/// A file, as the Mac shows it: the code, numbered in a ruler beside it
/// (CodeTextView.swift:4-6, 119-168). The ruler is as wide as the widest number needs,
/// and 20 more (CodeTextView.swift:142).
///
/// The lines that are picked can be sent to the composer, as the Mac's own menu does
/// (*Add to Message*, `CodeTextView.swift:91-111`, `FilesView.swift:389-392`).
function FileView({ content, path }: { content: string; path: string }) {
  const lines = content.split("\n");
  // A file that ends with a newline has no last line of its own.
  if (lines.length > 1 && lines[lines.length - 1] === "") lines.pop();
  const digits = String(lines.length).length;
  const codeRef = useRef<HTMLPreElement | null>(null);
  const [menu, setMenu] = useState<{ x: number; y: number; range: string } | null>(null);

  /// The lines the selection covers, as the Mac counts them (CodeTextView.swift:99-105).
  const selectedLines = () => {
    const selection = window.getSelection();
    const code = codeRef.current;
    if (!selection || selection.isCollapsed || !selection.rangeCount || !code) return null;
    const range = selection.getRangeAt(0);
    const offsetOf = (node: Node, offset: number) => {
      const before = document.createRange();
      before.selectNodeContents(code);
      before.setEnd(node, offset);
      return before.toString().length;
    };
    const lineAt = (offset: number) => {
      let line = 1;
      const text = code.textContent ?? "";
      for (let index = 0; index < offset && index < text.length; index += 1) {
        if (text[index] === "\n") line += 1;
      }
      return line;
    };
    const first = lineAt(offsetOf(range.startContainer, range.startOffset));
    const last = lineAt(offsetOf(range.endContainer, range.endOffset));
    if (first === last) return `${first}`;
    return `${first}-${last}`;
  };

  return (
    <div className="file-view" style={{ "--ruler": `${digits * 7.5 + 20}px` } as React.CSSProperties}>
      <div className="file-numbers" aria-hidden="true">
        {lines.map((_, index) => <span key={index}>{index + 1}</span>)}
      </div>
      <pre
        className="file-code"
        ref={codeRef}
        onContextMenu={event => {
          // The menu is the Mac's: it holds what a menu holds (RightClickMenu.swift:4-65).
          const range = selectedLines();
          if (!range) return;
          event.preventDefault();
          setMenu({ x: event.clientX, y: event.clientY, range });
        }}
      >{content}</pre>
      {menu ? (
        <ContextMenu
          x={menu.x}
          y={menu.y}
          onClose={() => setMenu(null)}
          items={[
            {
              label: "Add to Message",
              run: () => {
                // The file is named as a message names it: its path in the project, and the
                // lines that were picked (FilesView.swift:38-45, 389-392).
                const root = (state.project ?? "").replace(/[\\/]+$/, "");
                const relative = root && path.startsWith(root) ? path.slice(root.length + 1) : path;
                state.addition = `@${relative}:${menu.range}`;
                render();
              },
            },
          ]}
        />
      ) : null}
    </div>
  );
}

type TerminalHandle = {
  term: Xterm;
  fit: XtermAddon | null;
  socket: WebSocket;
};

/// The terminal is part of the card: it takes the card's own background, and an ANSI palette
/// that stays readable on it, the way TerminalSession.apply does (TerminalSession.swift:108-124).
function terminalIsDark(): boolean {
  const theme = document.documentElement.dataset.theme;
  if (theme === "dark") return true;
  if (theme === "light") return false;
  return window.matchMedia("(prefers-color-scheme: dark)").matches;
}

function resolveColor(value: string): string {
  const probe = document.createElement("span");
  probe.style.color = value;
  document.body.appendChild(probe);
  const resolved = getComputedStyle(probe).color;
  probe.remove();
  return resolved || value;
}

function terminalPalette(dark: boolean): string[] {
  return dark
    ? ["#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5", "#666666", "#f14c4c", "#23d18b", "#f5f543", "#3b8eea", "#d670d6", "#29b8db", "#ffffff"]
    : ["#000000", "#cd3131", "#107c10", "#949800", "#0451a5", "#bc05bc", "#0598bc", "#555555", "#666666", "#cd3131", "#14a314", "#b5ba00", "#0451a5", "#bc05bc", "#0598bc", "#a5a5a5"];
}

function terminalTheme(): { background: string; foreground: string; cursor: string; ansi: string[] } {
  const dark = terminalIsDark();
  return {
    background: resolveColor("var(--panel)"),
    foreground: resolveColor("var(--ink)"),
    cursor: resolveColor("var(--accent)"),
    ansi: terminalPalette(dark),
  };
}

function applyTerminalTheme(term: Xterm) {
  const theme = terminalTheme();
  term.options.theme = {
    background: theme.background,
    foreground: theme.foreground,
    cursor: theme.cursor,
    black: theme.ansi[0], red: theme.ansi[1], green: theme.ansi[2], yellow: theme.ansi[3],
    blue: theme.ansi[4], magenta: theme.ansi[5], cyan: theme.ansi[6], white: theme.ansi[7],
    brightBlack: theme.ansi[8], brightRed: theme.ansi[9], brightGreen: theme.ansi[10], brightYellow: theme.ansi[11],
    brightBlue: theme.ansi[12], brightMagenta: theme.ansi[13], brightCyan: theme.ansi[14], brightWhite: theme.ansi[15],
  };
}

export function Drawer() {
  useStore();
  const terminalRef = useRef<HTMLDivElement>(null);
  const terminal = useRef<TerminalHandle | null>(null);
  const [terminalAttempt, setTerminalAttempt] = useState(0);
  const [terminalNote, setTerminalNote] = useState("");
  const [terminalMenu, setTerminalMenu] = useState<{ x: number; y: number; selection: string } | null>(null);
  const [fileQuery, setFileQuery] = useState("");
  const [fileMatches, setFileMatches] = useState<{ path: string; hits: { snippet: string }[] }[]>([]);

  // What is written in the project's files, found by its words.
  useEffect(() => {
    const query = fileQuery.trim();
    if (query.length < 2) { setFileMatches([]); return; }
    const timer = setTimeout(() => {
      void api<{ matches: { path: string; hits: { snippet: string }[] }[] }>(`/api/search?q=${encodeURIComponent(query)}`)
        .then(answer => setFileMatches(answer.matches ?? []))
        .catch(() => setFileMatches([]));
    }, 250);
    return () => clearTimeout(timer);
  }, [fileQuery, state.project]);

  /// Fit the terminal to the space it actually has, and tell the shell. The old code
  /// waited for a window resize, so the PTY stayed 80×24 while the panel was wider.
  const fitTerminal = () => {
    const current = terminal.current;
    const container = terminalRef.current;
    if (!current || !container || container.offsetWidth === 0 || container.offsetHeight === 0) return;
    current.fit?.fit();
    if (current.socket.readyState === WebSocket.OPEN) {
      current.socket.send(JSON.stringify({ type: "resize", cols: current.term.cols, rows: current.term.rows }));
    }
  };

  const restartTerminal = () => {
    const current = terminal.current;
    // Forget the old handle first: its close handler must not put a note on the fresh
    // terminal that is about to replace it.
    terminal.current = null;
    terminalSocket = null;
    terminalNeedsRestart = false;
    if (current) {
      try { current.socket.close(); } catch { /* already closed */ }
      try { current.fit?.dispose?.(); } catch { /* already disposed */ }
      try { current.term.dispose(); } catch { /* already disposed */ }
    }
    terminalRef.current?.replaceChildren();
    setTerminalNote("");
    setTerminalAttempt(value => value + 1);
  };

  // The terminal stays alive when the panel is hidden or another tab is chosen: its
  // shell is the same one when it comes back, as the Mac's terminal tab does.
  useEffect(() => {
    if (!state.drawerOpen || state.drawerTab !== "terminal") return;
    const container = terminalRef.current;
    if (!container) return;
    const current = terminal.current;
    if (current) {
      // A live or connecting socket is kept, not replaced on every tab change. A dead
      // one stays dead until Restart, so its last output can be read.
      if (current.socket.readyState === WebSocket.OPEN || current.socket.readyState === WebSocket.CONNECTING) {
        requestAnimationFrame(fitTerminal);
      }
      return;
    }

    const port = (window as unknown as { kuvo?: { terminalPort?: number } }).kuvo?.terminalPort
      || new URLSearchParams(window.location.search).get("terminalPort");
    if (!port) { setTerminalNote("Terminal is available when running inside the Kuvo Code shell."); return; }
    const TerminalClass = (window as unknown as { Terminal?: new (options: unknown) => Xterm }).Terminal;
    if (!TerminalClass) { setTerminalNote("Terminal library failed to load."); return; }
    const term = new TerminalClass({
      cursorBlink: true,
      fontSize: 13,
      fontFamily: '"Cascadia Mono", "Cascadia Code", Consolas, monospace',
      scrollback: 10000,
    });
    applyTerminalTheme(term);
    // addon-fit's browser build exposes the namespace, `{ FitAddon }`, not the class
    // itself; keeping both shapes working means a future build cannot break the fit.
    const fitNamespace = (window as unknown as { FitAddon?: { FitAddon?: new () => XtermAddon } | (new () => XtermAddon) }).FitAddon;
    const FitAddonClass = typeof fitNamespace === "function" ? fitNamespace : fitNamespace?.FitAddon;
    let fitAddon: XtermAddon | null = null;
    if (FitAddonClass) {
      fitAddon = new FitAddonClass();
      term.loadAddon(fitAddon);
    }
    term.open(container);
    fitAddon?.fit();
    const socket = new WebSocket(terminalSocketUrl(Number(port), state.project ?? "", term.cols, term.rows));
    const handle: TerminalHandle = { term, fit: fitAddon, socket };
    terminal.current = handle;
    terminalSocket = socket;
    terminalNeedsRestart = false;

    socket.onopen = () => {
      if (terminal.current !== handle) return;
      terminalNeedsRestart = false;
      setTerminalNote("");
      requestAnimationFrame(() => {
        fitTerminal();
        term.focus();
      });
      // A command asked for before the terminal was there runs now.
      if (terminalWaiting) {
        socket.send(terminalWaiting);
        terminalWaiting = null;
      }
    };
    socket.onmessage = event => {
      if (terminal.current === handle) term.write(typeof event.data === "string" ? event.data : "");
    };
    socket.onclose = event => {
      if (terminal.current !== handle) return;
      terminalSocket = null;
      terminalNeedsRestart = true;
      setTerminalNote(event.reason || "Terminal closed.");
    };
    term.onData(data => { if (socket.readyState === WebSocket.OPEN) socket.send(data); });

    // The terminal is part of the card: its colours follow the card's, in light or dark.
    const onThemeChange = () => { if (terminal.current === handle) applyTerminalTheme(term); };
    const themeObserver = new MutationObserver(onThemeChange);
    themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme", "style"] });
    const mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
    mediaQuery.addEventListener("change", onThemeChange);

    return () => {
      themeObserver.disconnect();
      mediaQuery.removeEventListener("change", onThemeChange);
    };
  }, [state.drawerOpen, state.drawerTab, terminalAttempt]);

  // The drawer's own size changes when the panel is resized, not only the window's.
  useEffect(() => {
    const container = terminalRef.current;
    if (!container || typeof ResizeObserver === "undefined") return;
    let frame = 0;
    const observer = new ResizeObserver(() => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(fitTerminal);
    });
    observer.observe(container);
    return () => { cancelAnimationFrame(frame); observer.disconnect(); };
  }, []);

  // Coming back to a hidden terminal: fit it to the space it now has and put the caret
  // back, without touching its shell.
  useEffect(() => {
    if (!state.drawerOpen) return;
    const frame = requestAnimationFrame(() => {
      if (state.drawerTab === "terminal") {
        fitTerminal();
        terminal.current?.term.focus();
      } else if (state.drawerTab === "files") {
        document.getElementById("files-search")?.focus();
      }
    });
    return () => cancelAnimationFrame(frame);
  }, [state.drawerOpen, state.drawerTab, terminalAttempt]);

  useEffect(() => {
    terminalRestart = restartTerminal;
  });

  // The app closing is the one time hiding the panel does end the shell.
  useEffect(() => () => {
    terminalRestart = null;
    terminalNeedsRestart = false;
    const current = terminal.current;
    terminal.current = null;
    terminalSocket = null;
    if (current) {
      try { current.socket.close(); } catch { /* already closed */ }
      try { current.term.dispose(); } catch { /* already disposed */ }
    }
  }, []);

  useEffect(() => {
    if (!state.drawerOpen || state.drawerTab !== "files" || !state.project) return;
    void api<{ files: { path: string; name: string; kind: string }[] }>(`/api/files?directory=${encodeURIComponent(state.project)}`)
      .then(answer => { state.files = answer.files ?? []; render(); })
      .catch(() => { state.files = []; render(); });
  }, [state.drawerOpen, state.drawerTab, state.project]);

  return (
    <section id="drawer" className={`drawer utility-pane card ${state.drawerOpen ? "shown" : ""}`} hidden={!state.drawerOpen} aria-label="Panel">
      <div className="drawer-head">
        <div className="drawer-tabs" role="tablist" aria-label="Panel tabs">
          <button className={`drawer-tab ${state.drawerTab === "files" ? "active" : ""}`} role="tab" aria-selected={state.drawerTab === "files"} onClick={() => { state.drawerTab = "files"; render(); }}>
            <svg viewBox="0 0 16 16" width="12" height="12" fill="none" aria-hidden="true">
              <path d="M2 4.5A1.5 1.5 0 0 1 3.5 3h2.2l1.4 1.5H12.5A1.5 1.5 0 0 1 14 6v5.5a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 11.5z" stroke="currentColor" strokeWidth="1.2" strokeLinejoin="round" />
            </svg>
            <span>Files</span>
          </button>
          <button className={`drawer-tab ${state.drawerTab === "changes" ? "active" : ""}`} role="tab" aria-selected={state.drawerTab === "changes"} onClick={() => { state.drawerTab = "changes"; render(); }}>
            <svg viewBox="0 0 16 16" width="12" height="12" fill="none" aria-hidden="true">
              <path d="M8 2.5v11M2.5 8h11" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
            </svg>
            <span>Changes</span>
          </button>
          <button className={`drawer-tab ${state.drawerTab === "terminal" ? "active" : ""}`} role="tab" aria-selected={state.drawerTab === "terminal"} onClick={() => { state.drawerTab = "terminal"; render(); }}>
            <svg viewBox="0 0 16 16" width="12" height="12" fill="none" aria-hidden="true">
              <rect x="2.2" y="3" width="11.6" height="10" rx="2" stroke="currentColor" strokeWidth="1.2" />
              <path d="M5 6l2 2-2 2M8.3 10h2.8" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
            <span>Terminal</span>
          </button>
        </div>
        {state.drawerTab === "terminal" ? (
          <button id="terminal-restart" className="titlebar-icon panel-action" title="Restart Terminal" aria-label="Restart Terminal" onClick={restartTerminal}>
            <svg viewBox="0 0 16 16" width="13" height="13" fill="none" aria-hidden="true">
              <path d="M13 8a5 5 0 1 1-1.4-3.5" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
              <path d="M13 3.1v3.2H9.8" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </button>
        ) : null}
        <button id="drawer-close" className="titlebar-icon panel-action" title="Hide Panel" aria-label="Hide Panel" onClick={() => { state.drawerOpen = false; render(); }}>
          <svg viewBox="0 0 16 16" width="13" height="13" fill="none" aria-hidden="true">
            <path d="M3.5 3.5l9 9M12.5 3.5l-9 9" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
          </svg>
        </button>
      </div>
      <div id="drawer-files" className="drawer-body" hidden={state.drawerTab !== "files"}>
        <label className="search-well">
          <svg viewBox="0 0 16 16" width="12" height="12" fill="none" aria-hidden="true">
            <circle cx="6.9" cy="6.9" r="4" stroke="currentColor" strokeWidth="1.2" />
            <path d="M9.9 9.9l3.2 3.2" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
          </svg>
          <input
            id="files-search"
            className="file-search"
            placeholder="Search in files…"
            spellCheck={false}
            value={fileQuery}
            onChange={event => setFileQuery(event.target.value)}
          />
        </label>
        <div id="files-search-results" className="search-results" hidden={!fileMatches.length}>
          {fileMatches.map(match => (
            <div className="hit" key={match.path}>
              <div>{match.path.replace(state.project ?? "", "").replace(/^[/\\]/, "")}</div>
              {match.hits.map((hit, index) => <div className="where" key={index}>{hit.snippet}</div>)}
            </div>
          ))}
        </div>
        <FileTree files={state.files} onOpen={async path => {
          try {
            const { content } = await api<{ content: string }>(`/api/file?path=${encodeURIComponent(path)}`);
            state.openFile = path;
            state.openFileContent = content;
            render();
          } catch (error) { complain(error); }
        }} />
        {state.openFile ? <FileView content={state.openFileContent ?? ""} path={state.openFile} /> : null}
      </div>
      <div id="drawer-changes" className="drawer-body" hidden={state.drawerTab !== "changes"}>
        <ChangesPanel />
      </div>
      <div id="drawer-terminal" className="drawer-body" hidden={state.drawerTab !== "terminal"}>
        <div
          id="terminal"
          ref={terminalRef}
          className="terminal"
          onContextMenu={event => {
            event.preventDefault();
            setTerminalMenu({ x: event.clientX, y: event.clientY, selection: terminal.current?.term.getSelection() ?? "" });
          }}
        />
        {terminalMenu ? (
          <ContextMenu
            x={terminalMenu.x}
            y={terminalMenu.y}
            // The menu is the Mac's, and it takes the caret back when it closes: the
            // keys typed after it belong to the shell.
            onClose={() => {
              setTerminalMenu(null);
              requestAnimationFrame(() => terminal.current?.term.focus());
            }}
            items={[
              {
                label: "Add to Message",
                disabled: !terminalMenu.selection.trim(),
                run: () => {
                  const block = terminalSelectionBlock(terminalMenu.selection);
                  if (!block) return;
                  state.addition = block;
                  render();
                },
              },
              { label: "", separator: true },
              {
                label: "Copy",
                disabled: !terminalMenu.selection,
                run: () => { void navigator.clipboard.writeText(terminalMenu.selection).catch(error => complain(error)); },
              },
              {
                label: "Paste",
                run: () => {
                  void navigator.clipboard.readText()
                    .then(text => { if (text) terminal.current?.term.paste(text); })
                    .catch(error => complain(error));
                },
              },
            ]}
          />
        ) : null}
        <div id="terminal-note" className="where terminal-note" hidden={!terminalNote}>
          <span>{terminalNote}</span>
          {terminalNeedsRestart ? <button className="small" onClick={restartTerminal}>Restart Terminal</button> : null}
        </div>
      </div>
    </section>
  );
}

// ---- The files of the project, as a tree ----

/// The project's files, as the Mac's panel shows them (FilesView.swift:250-275): the
/// folders with a chevron that turns, the files with their own mark, the name in the
/// middle, and the tree in the project's own ink.
function FileTree({ files, onOpen }: {
  files: { path: string; name: string; kind: string }[];
  onOpen: (path: string) => void;
}) {
  const [open, setOpen] = useState<Record<string, boolean>>({});
  const project = state.project ?? "";
  const root = useMemo(() => buildTree(files, project), [files, project]);
  const draw = (nodes: TreeNode[], depth: number) => nodes.map(node => (
    <div className="file-node" key={node.path}>
      <button
        className={`file-row ${node.kind === "dir" ? "dir" : ""}`}
        style={{ paddingLeft: 6 + depth * 14 }}
        onClick={() => {
          if (node.kind === "dir") {
            setOpen(current => ({ ...current, [node.path]: !current[node.path] }));
            return;
          }
          void onOpen(node.path);
        }}
      >
        {node.kind === "dir"
          ? <Symbol name="chevron.right" size={10} className={open[node.path] ? "turned" : ""} />
          : <Symbol name="doc" size={13} />}
        <span className="file-name">{node.name}</span>
      </button>
      {node.kind === "dir" && open[node.path] ? draw(node.children ?? [], depth + 1) : null}
    </div>
  ));
  return <div className="file-tree">{draw(root, 0)}</div>;
}

// ---- The changes of a session ----

export function DiffModal() {
  useStore();
  return (
    <div id="diff-modal" className={`diff-modal ${state.diffOpen ? "shown" : ""}`} hidden={!state.diffOpen} onClick={event => { if (event.target === event.currentTarget) { state.diffOpen = false; render(); } }}>
      <div className="diff-card">
        <div className="diff-head">
          <strong id="diff-title">{state.diffTitle ?? "Changes in this session"}</strong>
          <button className="small" title="Close" aria-label="Close" onClick={() => { state.diffOpen = false; render(); }}>
            <Symbol name="xmark" size={11} />
          </button>
        </div>
        <div id="diff-body" className="diff-body">
          {state.sessionDiff.map(file => (
            <div key={file.file}>
              <div className="diff-file">
                <strong>{file.file}</strong>
                <span className="where">{`+${file.additions ?? 0} −${file.deletions ?? 0}${file.status ? ` · ${file.status}` : ""}`}</span>
              </div>
              {String(file.patch ?? "").split("\n").filter(line => line !== "").map((line, index) => (
                <div key={index} className={line.startsWith("+") ? "add" : line.startsWith("-") ? "del" : "ctx"}>{line}</div>
              ))}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

// ---- The little note ----

export function Toast() {
  useStore();
  if (!state.toast) return null;
  return (
    <div className="toast" role="status" onClick={() => { state.toast = null; render(); }}>
      <strong>{state.toast.title}</strong>
      <span>{state.toast.body}</span>
    </div>
  );
}

export { errorText };
