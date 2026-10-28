// Sidebar components.

import { useEffect, useRef, useState } from "react";
import { api } from "./api";
import type { SessionSummary } from "./api";
import { paneLayout, paneRanges } from "../../harness/layout.mjs";
import {
  archiveSession,
  complain,
  copyMarkdown,
  deleteSession,
  exportMarkdownOf,
  loadProjectSessions,
  loadSessions,
  newSession,
  openProject,
  openSession,
  pinSession,
  projectName,
  rememberFolded,
  removeProject,
  render,
  renameSession,
  savePaneWidth,
  setPaneWidth,
  showInFolder,
  state,
} from "./store";
import { Symbol, FolderIcon } from "./components/symbols";
import { ContextMenu } from "./components/context-menu";
import { openBeside } from "./Header";
import { folderName } from "./app-shared";
import { findRanges } from "./find.mjs";
/// The Mac's section heading (SidebarView.swift:1039-1088): the title, a chevron that
/// folds the section away, and what the section has on the right.
export function SectionHeader({ title, folded, onToggle, action }: { title: string; folded: boolean; onToggle: () => void; action?: React.ReactNode }) {
  const [hover, setHover] = useState(false);
  return (
    <div className="section-header">
      <button
        className="section-title"
        onClick={onToggle}
        title={folded ? `Show ${title}` : `Hide ${title}`}
        aria-expanded={!folded}
        onMouseEnter={() => setHover(true)}
        onMouseLeave={() => setHover(false)}
      >
        <span>{title}</span>
        <Symbol name="chevron.down" size={9} className={`section-chevron ${folded ? "folded" : ""} ${hover ? "hover" : ""}`} />
      </button>
      {action ? <span className="section-action">{action}</span> : null}
    </div>
  );
}

export function Sidebar() {
  const archived = (session: SessionSummary) => Boolean(session.time?.archived) || session.metadata?.["kuvo.archived"] === true;
  const query = state.sessionQuery.trim().toLowerCase();
  // A session being renamed, in its row where Rename was chosen (SidebarView.swift:41-52),
  // and the rows' own menus, which are where the Mac offers it (SidebarView.swift:586).
  const [renaming, setRenaming] = useState<string | null>(null);
  const [confirmingDelete, setConfirmingDelete] = useState<string | null>(null);
  const [menu, setMenu] = useState<{ id: string; x: number; y: number } | null>(null);
  const [projectMenu, setProjectMenu] = useState<{ id: string; x: number; y: number } | null>(null);
  // Which project shows all its sessions, and which only the first few
  // (SidebarView.swift:62-63, 386-398).
  const [showsAll, setShowsAll] = useState<Record<string, boolean>>({});
  const commitRename = async (id: string, title: string) => {
    setRenaming(null);
    await renameSession(id, title);
  };

  // The Mac's projects, each with its own sessions (SidebarView.swift:178-196), and the
  // Recents: the most recent sessions across them (SidebarView.swift:490-493).
  const sessionsOf = (folder: string) => {
    const list = folder === state.project ? state.sessions : state.sessionsByProject[folder] ?? [];
    return list
      .filter(session => !archived(session))
      .filter(session => (query ? (session.title || "").toLowerCase().includes(query) : true))
      .sort((a, b) => (b.time?.updated ?? 0) - (a.time?.updated ?? 0));
  };
  // The Mac's pinned sessions, at the top of the sidebar (SidebarView.swift:115-121,
  // 513-515): a session kept there, out of the recents.
  const pinned = state.projects
    .flatMap(folder => sessionsOf(folder))
    .filter((session, index, all) => all.findIndex(other => other.id === session.id) === index)
    .filter(session => session.metadata?.["kuvo.pinned"] === true)
    .sort((a, b) => (b.time?.updated ?? 0) - (a.time?.updated ?? 0));
  // Pinned ones are already at the top (SidebarView.swift:511).
  const recents = state.projects
    .flatMap(folder => sessionsOf(folder))
    .filter((session, index, all) => all.findIndex(other => other.id === session.id) === index)
    .filter(session => session.metadata?.["kuvo.pinned"] !== true)
    .sort((a, b) => (b.time?.updated ?? 0) - (a.time?.updated ?? 0))
    .slice(0, 8);
  const folded = (key: string) => Boolean(state.collapsed[key]);
  const toggle = (key: string) => { rememberFolded(key, !folded(key)); render(); };

  const sessionRow = (session: SessionSummary) => {
    const running = state.session?.id === session.id && state.transcript?.running;
    const unread = Boolean(session.time?.idle && session.time?.viewed && session.time.idle > session.time.viewed && session.id !== state.session?.id);
    return (
      <li
        key={session.id}
        className={`${session.id === state.session?.id ? "current" : ""} ${unread ? "unread" : ""}`}
        onContextMenu={event => {
          event.preventDefault();
          setMenu({ id: session.id, x: event.clientX, y: event.clientY });
        }}
      >
        {renaming === session.id ? (
          <input
            className="session-rename"
            defaultValue={session.title || ""}
            autoFocus
            aria-label="Rename this session"
            onFocus={event => event.currentTarget.select()}
            onKeyDown={event => {
              if (event.key === "Enter") { event.preventDefault(); void commitRename(session.id, event.currentTarget.value); }
              if (event.key === "Escape") { event.preventDefault(); setRenaming(null); }
            }}
            onBlur={event => { void commitRename(session.id, event.currentTarget.value); }}
          />
        ) : (
          <button className="session" data-id={session.id} onClick={() => { state.settingsOpen = false; void openSession(session.id); const main = document.querySelector("main"); if (main) main.classList.remove("sidebar-open"); }}>
            <span className="session-title">{session.title || "New Session"}</span>
            {running || unread ? <span className={`session-state ${running ? "running" : "unread"}`} aria-hidden="true" /> : null}
          </button>
        )}
        {confirmingDelete === session.id ? (
          <span
            className="session-confirm"
            role="group"
            aria-label={`Delete “${session.title || "New Session"}”?`}
            onBlur={event => {
              if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setConfirmingDelete(null);
            }}
          >
            <button
              className="session-confirm-no"
              autoFocus
              onClick={() => setConfirmingDelete(null)}
              onKeyDown={event => { if (event.key === "Escape") { event.preventDefault(); setConfirmingDelete(null); } }}
            >
              Keep
            </button>
            <button
              className="session-confirm-yes"
              onClick={() => { setConfirmingDelete(null); void deleteSession(session); }}
              onKeyDown={event => { if (event.key === "Escape") { event.preventDefault(); setConfirmingDelete(null); } }}
            >
              Delete
            </button>
          </span>
        ) : (
          <>
            <button
              className="session-delete"
              title="Put this session away (Settings › Archived sessions brings it back)"
              onClick={async () => {
                try {
                  await api(`/api/sessions/${encodeURIComponent(session.id)}/archive`, { method: "POST", body: { archived: true } });
                  if (state.session?.id === session.id) { state.session = null; state.transcript = null; }
                  await loadSessions();
                  await loadProjectSessions();
                } catch (error) { complain(error); }
              }}
            >
              <Symbol name="tray.and.arrow.down" size={12} />
            </button>
            <button className="session-delete" title="Delete this session" aria-label="Delete this session" onClick={() => setConfirmingDelete(session.id)}>
              <Symbol name="xmark" size={10} />
            </button>
          </>
        )}
      </li>
    );
  };

  return (
    <aside>
      <button id="new-session" className="sidebar-new" onClick={() => void newSession()}>
        <svg viewBox="0 0 16 16" width="14" height="14" fill="none" aria-hidden="true">
          <path d="M3 12.5L3.7 9.6 9.9 3.4l2.7 2.7-6.2 6.2z" stroke="currentColor" strokeWidth="1.2" strokeLinejoin="round" />
          <path d="M8.8 4.5l2.7 2.7" stroke="currentColor" strokeWidth="1.2" />
        </svg>
        <span>New Session</span>
      </button>
      <label className="search-well sidebar-search">
        <svg viewBox="0 0 16 16" width="12" height="12" fill="none" aria-hidden="true">
          <circle cx="6.9" cy="6.9" r="4" stroke="currentColor" strokeWidth="1.2" />
          <path d="M9.9 9.9l3.2 3.2" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
        </svg>
        <input
          id="session-search"
          className="file-search"
          placeholder="Search"
          spellCheck={false}
          value={state.sessionQuery}
          onChange={event => { state.sessionQuery = event.target.value; render(); }}
        />
        {/* The Mac's clear (Pressable.swift:73-91): quiet at rest, and brighter under the
            pointer. */}
        {state.sessionQuery ? (
          <button
            id="session-search-clear"
            className="search-clear"
            title="Clear Search"
            aria-label="Clear Search"
            onClick={() => { state.sessionQuery = ""; render(); }}
          >
            <Symbol name="xmark" size={10} />
          </button>
        ) : null}
      </label>
      <div className="sidebar-scroll">
      {/* The Mac's projects (SidebarView.swift:178-196): every project, each with its own
          sessions, and the Recents: the most recent sessions across them. */}
      <SectionHeader
        title="Projects"
        folded={folded("projects")}
        onToggle={() => toggle("projects")}
        action={
          <button
            className="section-action-button"
            title="New Project…"
            aria-label="New Project"
            onClick={() => { state.pickerOpen = true; render(); }}
          >
            <Symbol name="plus" size={12} />
          </button>
        }
      />
      {!folded("projects") ? (
        state.projects.length === 0 ? (
          <p className="aside-empty project-empty">Open a folder for the agent to work in.</p>
        ) : state.projects.map(folder => {
          const sessions = sessionsOf(folder);
          const open = !folded(folder);
          const all = Boolean(showsAll[folder]);
          const shown = all ? sessions : sessions.slice(0, 5);
          return (
            <div className="project-group" key={folder}>
              <button
                className="project-row"
                onClick={() => toggle(folder)}
                onContextMenu={event => {
                  event.preventDefault();
                  setProjectMenu({ id: folder, x: event.clientX, y: event.clientY });
                }}
                aria-expanded={open}
              >
                <FolderIcon open={open} size={16} className="project-icon" />
                <span className="project-name">{projectName(folder)}</span>
                <span
                  className="project-compose"
                  title={`New Session in ${folderName(folder)}`}
                  role="button"
                  tabIndex={0}
                  onClick={event => { event.stopPropagation(); void newSession(folder); }}
                  onKeyDown={event => { if (event.key === "Enter") { event.stopPropagation(); void newSession(folder); } }}
                >
                  <Symbol name="square.and.pencil" size={13} />
                </span>
              </button>
              {open ? (
                <>
                  <ul className="sessions" id={folder === state.project ? "sessions" : undefined}>
                    {shown.map(sessionRow)}
                  </ul>
                  {sessions.length > 5 ? (
                    <button
                      className="show-more"
                      onClick={() => setShowsAll(current => ({ ...current, [folder]: !current[folder] }))}
                    >
                      {all ? "Show Less" : `Show ${sessions.length - 5} More`}
                    </button>
                  ) : null}
                </>
              ) : null}
            </div>
          );
        })
      ) : null}
      {pinned.length ? (
        <>
          <SectionHeader title="Pinned" folded={folded("pinned")} onToggle={() => toggle("pinned")} />
          {!folded("pinned") ? <ul className="sessions pinned">{pinned.map(sessionRow)}</ul> : null}
        </>
      ) : null}
      {recents.length ? (
        <>
          <SectionHeader title="Recents" folded={folded("recents")} onToggle={() => toggle("recents")} />
          {!folded("recents") ? <ul className="sessions recents">{recents.map(sessionRow)}</ul> : null}
        </>
      ) : null}
      <MessageSearch query={state.sessionQuery} />
      </div>
      {menu ? (() => {
        // The Mac's own menu for a session (SidebarView.swift:600-643), in its order and
        // with its words: pinned or not, beside the one in view, its name, the folder it
        // works in, the conversation as Markdown, put away or brought back, and the one
        // that undoes.
        const found = [...state.sessions, ...Object.values(state.sessionsByProject).flat()].find(session => session.id === menu.id);
        const isArchived = found ? archived(found) : false;
        const isPinned = found?.metadata?.["kuvo.pinned"] === true;
        return (
          <ContextMenu
            x={menu.x}
            y={menu.y}
            onClose={() => setMenu(null)}
            items={[
              ...(isArchived || !found ? [] : [{
                label: isPinned ? "Unpin" : "Pin",
                run: () => void pinSession(found, !isPinned),
              }]),
              // The Mac's Open Beside: how a session is chosen for the split (SidebarView.swift:609).
              ...(menu.id !== state.session?.id ? [{ label: "Open Beside", run: () => void openBeside(menu.id) }] : []),
              { label: "Rename…", run: () => setRenaming(menu.id) },
              { label: "Show in Folder", run: () => showInFolder(found?.location?.directory ?? "") },
              { label: "", separator: true },
              { label: "Copy as Markdown", run: () => { if (found) void copyMarkdown(found); } },
              { label: "Export as Markdown…", run: () => { if (found) void exportMarkdownOf(found); } },
              { label: "", separator: true },
              { label: isArchived ? "Unarchive" : "Archive", run: () => { if (found) void archiveSession(found, !isArchived); } },
              { label: "Delete…", danger: true, run: () => { if (found) setConfirmingDelete(found.id); } },
            ]}
          />
        );
      })() : null}
      {projectMenu ? (
        <ContextMenu
          x={projectMenu.x}
          y={projectMenu.y}
          onClose={() => setProjectMenu(null)}
          items={[
            { label: "New Session", run: () => void newSession(projectMenu.id) },
            // The Mac's own menu for a project (SidebarView.swift:379-396).
            { label: "Edit Project…", run: () => { state.editingProject = projectMenu.id; render(); } },
            { label: "Open Project", run: () => void openProject(projectMenu.id) },
            { label: "Remove from Sidebar", run: () => void removeProject(projectMenu.id) },
          ]}
        />
      ) : null}
    </aside>
  );
}

/// The handle in the gap between the sessions and the conversation, the Mac's
/// (WindowGlass.swift:43-81): the gap is the handle, a faint capsule shows while it is
/// held, and the cursor says what it does.
/// The window's own measure, as the Mac takes it (MainView.swift:983-985): the width the
/// cards share, and what each asks for — the sessions and the panel only while they are
/// shown, the split only while a session is beside the one in view.
export function paneLayoutNow() {
  const main = document.querySelector("main");
  const available = (main ? main.clientWidth : window.innerWidth) - 2 * 8;
  return paneLayout({
    available,
    sessions: state.sidebarOpen === false ? null : state.sessionsWidth,
    changes: state.drawerOpen ? state.changesWidth : null,
    split: state.split ? state.splitWidth : null,
    gap: 8,
  });
}

/// The handle in the gap between two cards (WindowGlass.swift:43-81): the gap is the
/// handle, a faint capsule shows while it is held, and the cursor says what it does. It
/// drags one of the Mac's three panes (MainView.swift:228, 256, 280), within that pane's
/// range and the room the window leaves it (`PaneLayout`, MainView.swift:2112-2179).
export function PaneResizer({ pane }: { pane: "sessions" | "split" | "changes" }) {
  const [dragging, setDragging] = useState(false);
  const start = useRef({ x: 0, width: 0 });
  const range = paneRanges[pane];
  const asked = () => (pane === "sessions" ? state.sessionsWidth : pane === "split" ? state.splitWidth : state.changesWidth);
  return (
    <div
      className={`pane-resizer ${pane} ${dragging ? "dragging" : ""}`}
      title="Drag to resize"
      style={{ touchAction: "none" }}
      onPointerDown={event => {
        event.preventDefault();
        setDragging(true);
        // The sessions sit at the window's left, so pulling right widens them; the split
        // and the panel sit at its right, and widen as the handle is pulled left.
        const sideways = pane === "sessions" ? 1 : -1;
        start.current = { x: event.clientX, width: asked() };
        const move = (moveEvent: PointerEvent) => {
          const layout = paneLayoutNow();
          const room = pane === "sessions" ? layout.sessionsMax : pane === "split" ? layout.splitMax : layout.changesMax;
          const next = Math.min(
            Math.max(start.current.width + sideways * (moveEvent.clientX - start.current.x), range.lower),
            Math.min(range.upper, Math.max(range.lower, room)),
          );
          setPaneWidth(pane, next);
          render();
        };
        const up = () => {
          setDragging(false);
          // The width is kept for the next time the window opens (MainView.swift:38-40).
          savePaneWidth(pane);
          window.removeEventListener("pointermove", move);
          window.removeEventListener("pointerup", up);
        };
        window.addEventListener("pointermove", move);
        window.addEventListener("pointerup", up);
      }}
    />
  );
}

/// The words of a search result with what was looked for marked, so the eye finds it in
/// the snippet without reading the whole line.
function markedSnippet(text: string, query: string): React.ReactNode {
  const ranges = findRanges(text, query);
  if (!ranges.length) return text;
  const parts: React.ReactNode[] = [];
  let at = 0;
  ranges.forEach((range, index) => {
    if (range.start > at) parts.push(text.slice(at, range.start));
    parts.push(<mark className="find-mark" key={index}>{text.slice(range.start, range.end)}</mark>);
    at = range.end;
  });
  if (at < text.length) parts.push(text.slice(at));
  return parts;
}

/// What was said, in every session: the one sidebar search looks in the titles and in the
/// conversations, the way the Mac app's does (SidebarView.swift:84-112).
export function MessageSearch({ query }: { query: string }) {
  const [matches, setMatches] = useState<{ session: { id: string; title?: string | null }; hits: { snippet: string }[] }[]>([]);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    const text = query.trim();
    if (text.length < 3) { setMatches([]); setOpen(false); return; }
    const timer = setTimeout(() => {
      void api<{ matches: { session: { id: string; title?: string | null }; hits: { snippet: string }[] }[] }>(`/api/search/sessions?q=${encodeURIComponent(text)}`)
        .then(answer => { setMatches(answer.matches ?? []); setOpen(true); })
        .catch(() => { setMatches([]); setOpen(false); });
    }, 250);
    return () => clearTimeout(timer);
  }, [query]);

  return (
    <div id="message-search-results" className="search-results" hidden={!open}>
      <div className="search-heading">In Conversations</div>
      {matches.length === 0 ? <div className="search-empty">No sessions match.</div> : null}
      {matches.slice(0, 20).map(match => (
        <div className="hit" key={match.session.id}>
          <div>{match.session.title || match.session.id}</div>
          {match.hits.map((hit, index) => (
            <div className="where" key={index} onClick={() => { void openSession(match.session.id); const main = document.querySelector("main"); if (main) main.classList.remove("sidebar-open"); }}>{markedSnippet(hit.snippet, query)}</div>
          ))}
        </div>
      ))}
    </div>
  );
}


export { folderName } from "./app-shared";

