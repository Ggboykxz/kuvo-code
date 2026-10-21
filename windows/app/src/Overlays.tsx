// What floats over the conversation: the command palette, the files and terminal drawer,
// the changes of a session, and the little note that says what happened.

import { useEffect, useMemo, useRef, useState } from "react";
import { api } from "./api";
import { errorText } from "./lib";
import { ChangesPanel } from "./Changes";
import { complain, loadProjectFiles, loadSessions, notify, openProjectFile, openSession, render, setProjectName, state, useStore, newSession, exportConversation, stopRun } from "./store";
import { keysOf } from "./shortcuts";
import { Symbol } from "./components/symbols";

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

  useEffect(() => {
    if (state.paletteOpen) {
      setQuery("");
      setIndex(0);
      setTimeout(() => inputRef.current?.focus(), 0);
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
  const coreActions: PaletteRow[] = [
    { id: "action:new-session", kind: "action", title: "New Session", shortcut: keysOf("new-session"), run: async () => { await newSession(); } },
    { id: "action:stop", kind: "action", title: "Stop", shortcut: keysOf("stop"), run: async () => { await stopRun(); } },
    { id: "action:find", kind: "action", title: "Find in Conversation…", shortcut: keysOf("find"), run: () => { (document.getElementById("find") as HTMLInputElement | null)?.focus(); } },
    { id: "action:save", kind: "action", title: "Save the conversation as Markdown", shortcut: keysOf("save"), run: async () => { await exportConversation(); } },
    { id: "action:files", kind: "action", title: "Show Files", shortcut: keysOf("files"), run: () => { state.drawerOpen = true; state.drawerTab = "files"; render(); } },
    { id: "action:changes", kind: "action", title: "Show Changes", shortcut: keysOf("changes"), run: () => { state.drawerOpen = true; state.drawerTab = "changes"; render(); } },
    { id: "action:terminal", kind: "action", title: "New Terminal", shortcut: keysOf("terminal"), run: () => { state.drawerOpen = true; state.drawerTab = "terminal"; render(); } },
    { id: "action:panel", kind: "action", title: state.drawerOpen ? "Hide Panel" : "Show Panel", shortcut: keysOf("panel"), run: () => { state.drawerOpen = !state.drawerOpen; render(); } },
    { id: "action:sidebar", kind: "action", title: state.sidebarOpen === false ? "Show Sessions" : "Hide Sessions", shortcut: keysOf("sidebar"), run: () => { state.sidebarOpen = state.sidebarOpen === false; render(); } },
    { id: "action:settings", kind: "action", title: "Settings", shortcut: keysOf("settings"), run: () => { state.settingsOpen = true; state.settingsSection = "appearance"; render(); } },
    { id: "action:rename", kind: "action", title: "Rename this session", run: async () => {
      const title = prompt("Name this session", state.session?.title ?? "");
      if (!title) return;
      await api(`/api/sessions/${encodeURIComponent(state.session!.id)}/rename`, { method: "POST", body: { title } });
      await loadSessions();
    } },
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
    <div id="palette" className={`palette ${state.paletteOpen ? "shown" : ""}`} hidden={!state.paletteOpen} onClick={event => { if (event.target === event.currentTarget) { state.paletteOpen = false; render(); } }}>
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
          <div id="palette-list" className="palette-list">
            {sections.map(section => (
              <div className="palette-section" key={section.title}>
                <div className="palette-title">{section.title}</div>
                {section.items.map(item => {
                  const position = rows.indexOf(item);
                  return (
                    <div
                      key={item.id}
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

/// What the terminal's own library gives us: the bits we use.
interface Xterm {
  open(container: HTMLElement): void;
  write(data: string): void;
  focus(): void;
  onData(handler: (data: string) => void): void;
  loadAddon(addon: XtermAddon): void;
  cols: number;
  rows: number;
}

interface XtermAddon {
  fit(): void;
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

/// A project's own name, changed where the Mac changes it: over the window, in a small
/// card (the Mac's ProjectEditor, ProjectEditor.swift:8-13 — its name and its folders;
/// the folders the agent works in besides the first are the engine's own).
export function ProjectEditor() {
  useStore();
  const [name, setName] = useState("");
  const folder = state.editingProject;

  useEffect(() => {
    if (!folder) return;
    setName(state.projectNames[folder] ?? "");
  }, [folder]);

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
    await setProjectName(folder, name);
    render();
  }
}

// ---- The drawer: files and terminal ----

export function Drawer() {
  useStore();
  const terminalRef = useRef<HTMLDivElement>(null);
  const [terminalNote, setTerminalNote] = useState("");
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

  // The terminal: the shell's ConPTY, over a WebSocket on the port it passed.
  useEffect(() => {
    if (!state.drawerOpen || state.drawerTab !== "terminal") return;
    const container = terminalRef.current;
    if (!container || container.dataset.ready === "1") return;
    container.dataset.ready = "1";
    const port = (window as unknown as { kuvo?: { terminalPort?: number } }).kuvo?.terminalPort
      || new URLSearchParams(window.location.search).get("terminalPort");
    if (!port) { setTerminalNote("Terminal is available when running inside the Kuvo Code shell."); return; }
    const TerminalClass = (window as unknown as { Terminal?: new (options: unknown) => Xterm }).Terminal;
    if (!TerminalClass) { setTerminalNote("Terminal library failed to load."); return; }
    const term = new TerminalClass({ convertEol: true, fontSize: 13, theme: { background: "#121316", foreground: "#d0d6e0" } });
    const FitAddonClass = (window as unknown as { FitAddon?: new () => XtermAddon }).FitAddon;
    let fitAddon: XtermAddon | null = null;
    if (FitAddonClass) {
      fitAddon = new FitAddonClass();
      term.loadAddon(fitAddon);
    }
    term.open(container);
    fitAddon?.fit();
    const socket = new WebSocket(`ws://127.0.0.1:${port}`);
    socket.onopen = () => { setTerminalNote(""); term.focus(); };
    socket.onmessage = event => term.write(typeof event.data === "string" ? event.data : "");
    socket.onclose = event => setTerminalNote(event.reason || "Terminal closed.");
    term.onData(data => { if (socket.readyState === WebSocket.OPEN) socket.send(data); });
    const onResize = () => {
      fitAddon?.fit();
      if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: "resize", cols: term.cols, rows: term.rows }));
    };
    window.addEventListener("resize", onResize);
    return () => { window.removeEventListener("resize", onResize); socket.close(); };
  }, [state.drawerOpen, state.drawerTab]);

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
        {state.openFile ? (
          <pre className="file-view">{state.openFileContent}</pre>
        ) : null}
      </div>
      <div id="drawer-changes" className="drawer-body" hidden={state.drawerTab !== "changes"}>
        <ChangesPanel />
      </div>
      <div id="drawer-terminal" className="drawer-body" hidden={state.drawerTab !== "terminal"}>
        <div id="terminal" ref={terminalRef} className="terminal" />
        <div id="terminal-note" className="where">{terminalNote}</div>
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

type TreeNode = { path: string; name: string; kind: string; children?: TreeNode[] };

/// The flat list of files, as a tree: a folder for every part of their paths. The
/// project's own folder is the root, as it is in the Mac's panel.
function buildTree(files: { path: string; name: string; kind: string }[], project = ""): TreeNode[] {
  const root: TreeNode[] = [];
  const folders = new Map<string, TreeNode>();
  const prefix = project ? project.replace(/[/\\]+$/, "") + "/" : "";
  for (const file of files) {
    const relative = file.path.startsWith(prefix) ? file.path.slice(prefix.length) : file.path;
    const parts = relative.replace(/^[/\\]+/, "").split(/[/\\]+/).filter(Boolean);
    let folder = "";
    let level = root;
    for (const part of parts.slice(0, -1)) {
      folder = folder ? `${folder}/${part}` : part;
      let node = folders.get(folder);
      if (!node) {
        node = { path: folder, name: part, kind: "dir", children: [] };
        folders.set(folder, node);
        level.push(node);
      }
      level = node.children ?? [];
    }
    level.push({ path: file.path, name: parts.at(-1) ?? file.name, kind: file.kind === "dir" ? "dir" : "file" });
  }
  return root;
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
