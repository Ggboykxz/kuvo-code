// What floats over the conversation: the command palette, the files and terminal drawer,
// the changes of a session, and the little note that says what happened.

import { useEffect, useRef, useState } from "react";
import { api } from "./api";
import { errorText } from "./lib";
import { ChangesPanel } from "./Changes";
import { complain, loadSessions, notify, openSession, render, state, useStore } from "./store";

// ---- The command palette ----

export function Palette() {
  useStore();
  const [query, setQuery] = useState("");
  const [index, setIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (state.paletteOpen) {
      setQuery("");
      setTimeout(() => inputRef.current?.focus(), 0);
    }
  }, [state.paletteOpen]);

  const needle = query.trim().toLowerCase();
  const sessions = state.sessions.filter(s => !needle || (s.title || "").toLowerCase().includes(needle)).slice(0, 6);
  const commands = state.commands.filter(c => !needle || c.name.toLowerCase().includes(needle)).slice(0, 6);
  const [files, setFiles] = useState<{ path: string; name: string; relative: string }[]>([]);
  useEffect(() => {
    if (!state.paletteOpen || !state.project) return;
    void api<{ files: { path: string; name: string; relative: string }[] }>(`/api/search?q=${encodeURIComponent(needle)}`)
      .then(answer => setFiles((answer.files ?? []).slice(0, 6)))
      .catch(() => setFiles([]));
  }, [state.paletteOpen, needle, state.project]);
  const actions: [string, () => void | Promise<void>][] = [
    ["Appearance", async () => { state.settingsOpen = true; state.settingsSection = "appearance"; render(); }],
    ["Rename this session", async () => {
      const title = prompt("Name this session", state.session?.title ?? "");
      if (!title) return;
      await api(`/api/sessions/${encodeURIComponent(state.session!.id)}/rename`, { method: "POST", body: { title } });
      await loadSessions();
    }],
    ["Refresh sessions", async () => { await loadSessions(); notify("Kuvo Code", "Sessions refreshed."); }],
  ];
  const total = sessions.length + commands.length + files.length + actions.length;

  const run = async (action: () => void | Promise<void>) => {
    state.paletteOpen = false;
    render();
    await action();
  };

  return (
    <div id="palette" className={`palette ${state.paletteOpen ? "shown" : ""}`} hidden={!state.paletteOpen} onClick={event => { if (event.target === event.currentTarget) { state.paletteOpen = false; render(); } }}>
      <input
        id="palette-input"
        placeholder="Search sessions, files and actions…"
        spellCheck={false}
        autoComplete="off"
        value={query}
        ref={inputRef}
        onChange={event => { setQuery(event.target.value); setIndex(0); }}
        onKeyDown={event => {
          if (event.key === "ArrowDown") { event.preventDefault(); setIndex(current => (current + 1) % Math.max(total, 1)); return; }
          if (event.key === "ArrowUp") { event.preventDefault(); setIndex(current => (current - 1 + total) % Math.max(total, 1)); return; }
          if (event.key === "Enter") {
            event.preventDefault();
            const rows = [
              ...sessions.map(session => () => openSession(session.id)),
              ...commands.map(command => () => {
                const prompt = document.getElementById("prompt") as HTMLTextAreaElement | null;
                if (prompt) { prompt.value = `/${command.name} `; prompt.dispatchEvent(new Event("input", { bubbles: true })); prompt.focus(); }
              }),
              ...actions.map(([, action]) => action),
            ];
            void run(rows[index] ?? (() => {}));
          }
        }}
      />
      <div id="palette-list" className="palette-list">
        {sessions.map(session => (
          <div
            key={session.id}
            className={`palette-item ${sessions.indexOf(session) === index ? "selected" : ""}`}
            onClick={() => void run(async () => { await openSession(session.id); })}
          >
            <span className="palette-kind">session</span>
            <span>{session.title || "Untitled"}</span>
          </div>
        ))}
        {commands.map(command => (
          <div
            key={command.name}
            className={`palette-item ${sessions.length + commands.indexOf(command) === index ? "selected" : ""}`}
            onClick={() => void run(async () => {
              const prompt = document.getElementById("prompt") as HTMLTextAreaElement | null;
              if (prompt) {
                prompt.value = `/${command.name} `;
                prompt.dispatchEvent(new Event("input", { bubbles: true }));
                prompt.focus();
              }
            })}
          >
            <span className="palette-kind">command</span>
            <span>/{command.name}</span>
          </div>
        ))}
        {files.map(file => (
          <div
            key={file.path}
            className={`palette-item ${sessions.length + commands.length + files.indexOf(file) === index ? "selected" : ""}`}
            onClick={() => void run(async () => {
              state.drawerOpen = true;
              state.drawerTab = "files";
              render();
            })}
          >
            <span className="palette-kind">file</span>
            <span>{file.relative}</span>
          </div>
        ))}
        {actions.map(([title, action], position) => (
          <div
            key={title}
            className={`palette-item ${sessions.length + commands.length + files.length + position === index ? "selected" : ""}`}
            onClick={() => void run(action)}
          >
            <span className="palette-kind">action</span>
            <span>{title}</span>
          </div>
        ))}
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
          <button id="picker-up" className="small" disabled={parent === null} onClick={() => parent && void browse(parent)}>↑</button>
          <button id="picker-go" className="small" onClick={() => void browse(typed)}>Go</button>
          <button id="picker-use" className="primary" onClick={async () => {
            try {
              await api("/api/project", { method: "POST", body: { directory: shown } });
              state.project = shown;
              state.session = null;
              state.transcript = null;
              state.pickerOpen = false;
              await loadSessions();
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
    const port = new URLSearchParams(window.location.search).get("terminalPort");
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
    socket.onclose = () => setTerminalNote("Terminal closed.");
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
    <div id="drawer" className={`drawer ${state.drawerOpen ? "shown" : ""}`} hidden={!state.drawerOpen}>
      <div className="drawer-head">
        <div className="drawer-tabs">
          <button className={`drawer-tab ${state.drawerTab === "files" ? "active" : ""}`} onClick={() => { state.drawerTab = "files"; render(); }}>Files</button>
          <button className={`drawer-tab ${state.drawerTab === "changes" ? "active" : ""}`} onClick={() => { state.drawerTab = "changes"; render(); }}>Changes</button>
          <button className={`drawer-tab ${state.drawerTab === "terminal" ? "active" : ""}`} onClick={() => { state.drawerTab = "terminal"; render(); }}>Terminal</button>
        </div>
        <button id="drawer-close" className="small" onClick={() => { state.drawerOpen = false; render(); }}>✕</button>
      </div>
      <div id="drawer-files" className="drawer-body" hidden={state.drawerTab !== "files"}>
        <input
          id="files-search"
          className="file-search"
          placeholder="Search in files…"
          spellCheck={false}
          value={fileQuery}
          onChange={event => setFileQuery(event.target.value)}
        />
        <div id="files-search-results" className="search-results" hidden={!fileMatches.length}>
          {fileMatches.map(match => (
            <div className="hit" key={match.path}>
              <div>{match.path.replace(state.project ?? "", "").replace(/^[/\\]/, "")}</div>
              {match.hits.map((hit, index) => <div className="where" key={index}>{hit.snippet}</div>)}
            </div>
          ))}
        </div>
        {state.files.map(file => (
          <div key={file.path} className="file-row">
            <button className="small" onClick={async () => {
              try {
                const { content } = await api<{ content: string }>(`/api/file?path=${encodeURIComponent(file.path)}`);
                state.openFile = file.path;
                state.openFileContent = content;
                render();
              } catch (error) { complain(error); }
            }}>{file.name}</button>
          </div>
        ))}
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
    </div>
  );
}

// ---- The changes of a session ----

export function DiffModal() {
  useStore();
  return (
    <div id="diff-modal" className={`diff-modal ${state.diffOpen ? "shown" : ""}`} hidden={!state.diffOpen} onClick={event => { if (event.target === event.currentTarget) { state.diffOpen = false; render(); } }}>
      <div className="diff-card">
        <div className="diff-head">
          <strong id="diff-title">{state.diffTitle ?? "Changes in this session"}</strong>
          <button className="small" onClick={() => { state.diffOpen = false; render(); }}>✕</button>
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
