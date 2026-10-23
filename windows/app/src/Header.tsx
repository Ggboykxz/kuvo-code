// Header components: context gauge, card header, title bar, tabs, split.

import { useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { api } from "./api";
import type { SessionSummary } from "./api";
import { compactTokens } from "./lib";
import {
  closeSessionTab,
  closeTabs,
  complain,
  openSession,
  openSplit,
  projectRun,
  render,
  renameSession,
  state,
} from "./store";
import { settingsPageTitle } from "./Settings";
import { runInTerminal } from "./Overlays";
import { Symbol } from "./components/symbols";
import { ContextMenu } from "./components/context-menu";
import { Spinner } from "./components/spinner";
import { motion } from "motion/react";
import { macSpringOrStill } from "./motion";
import { EntryNodes, EmptyConversation, WorkingLine } from "./Transcript";
import { motionIsReduced, folderName } from "./app-shared";

/// The Mac's context ring, in a card's header (the same figures as before) — the
/// conversation's own card and the split's each take one, over their own session.
export function ContextGauge({ session = state.session }: { session?: SessionSummary | null }) {
  const [gaugeOpen, setGaugeOpen] = useState(false);
  const total = session?.tokens?.total ?? 0;
  const model = state.models.find(item => session?.model && `${item.providerID}/${item.id}` === `${session.model.providerID}/${session.model.id}`);
  const limit = model?.limit?.context ?? 0;
  const fraction = limit > 0 ? Math.min(total / limit, 1) : null;
  // The popover sits by the gauge, and flips to the other side when it would not fit
  // (ScreenRoom.swift:4-33).
  const gauge = useRef<HTMLDivElement>(null);
  const pop = useRef<HTMLDivElement>(null);
  const [place, setPlace] = useState<{ left: number; top: number } | null>(null);
  useLayoutEffect(() => {
    if (!gaugeOpen) return;
    const button = gauge.current?.getBoundingClientRect();
    const box = pop.current?.getBoundingClientRect();
    if (!button || !box) return;
    const wanted = button.left + button.width - box.width;
    const left = Math.min(Math.max(8, wanted), Math.max(8, window.innerWidth - box.width - 8));
    setPlace({ left, top: button.bottom + 4 });
  }, [gaugeOpen]);
  return (
    <>
      {/* No id: the split card carries the same gauge, and both know each other (and are
          known) by class — two cards, one ring each, never a claim on the window. */}
      <div
        ref={gauge}
        className={`context-gauge ${fraction !== null && fraction > 0.8 ? "warn" : ""}`}
        hidden={!total}
        title={limit ? `Context window: ${compactTokens(total)} of ${compactTokens(limit)} tokens` : "Context window"}
        onClick={event => { event.stopPropagation(); setGaugeOpen(open => !open); }}
      >
        {fraction !== null ? `${Math.round(fraction * 100)}%` : compactTokens(total)}
      </div>
      <div
        ref={pop}
        className="gauge-pop"
        hidden={!gaugeOpen}
        style={place ? { left: place.left, top: place.top } : undefined}
      >
        <div className="gauge-line big">
          {fraction !== null ? `${Math.round(fraction * 100)}% of the context window` : `${compactTokens(total)} tokens in the context window`}
        </div>
        {limit ? <div className="gauge-line">{`${compactTokens(total)} of ${compactTokens(limit)} tokens`}</div> : null}
        {typeof session?.cost === "number" ? <div className="gauge-line">{`Session cost so far: $${session.cost.toFixed(4)}`}</div> : null}
        {session?.model ? <div className="gauge-line faint">{`${session.model.providerID}/${session.model.id}`}</div> : null}
        <button
          className="small"
          title="Squeeze the conversation into a summary, like the Mac app's compact"
          onClick={async () => {
            if (!session) return;
            try {
              await api(`/api/sessions/${encodeURIComponent(session.id)}/compact`, { method: "POST", body: {} });
              setGaugeOpen(false);
              await openSession(session.id);
            } catch (error) { complain(error); }
          }}
        >
          Compact context
        </button>
      </div>
    </>
  );
}

/// The Mac's card header (Card.swift:91-124): the card's mark, the session's name over
/// its project, and the card's own actions. The conversation card and the split beside it
/// take the same one — it is a card's head, never the window's title bar, which keeps the
/// window's controls above it (TitleBar.swift).
export function CardHeader({ session, folder, tooltip, children }: {
  session?: SessionSummary | null;
  folder?: string;
  tooltip?: string;
  children: ReactNode;
}) {
  return (
    <div className="card-header">
      <span className="card-icon" aria-hidden="true">
        <svg viewBox="0 0 16 16" width="16" height="16" fill="none">
          <path d="M2.75 3.25h10.5v6.9H8.1l-3.1 2.6v-2.6H2.75z" stroke="currentColor" strokeWidth="1.2" strokeLinejoin="round" />
        </svg>
      </span>
      <div className="card-title" title={tooltip}>
        <span>{session?.title || "New Session"}</span>
        {folder ? <span className="card-detail">{"\u00A0| "}{folder}</span> : null}
      </div>
      <div className="spacer" />
      <div className="card-actions">{children}</div>
    </div>
  );
}

export function Header() {
  const showingSettings = state.settingsOpen;
  const running = state.engine?.status === "running";
  const branch = state.vcs?.branch?.current;
  const sidebarOpen = state.sidebarOpen !== false;
  const folder = state.project ? state.project.replace(/[\\/]+$/, "").split(/[\\/]/).pop() ?? "" : "";
  const engineText = running ? `engine ${state.engine?.version ?? ""}`.trim() : state.engine?.status ?? "…";
  // The project's own run command, and the button that runs it (MainView.swift:562-566,
  // 601-610).
  const runFolder = state.project ?? "";
  const runCommand = runFolder ? projectRun(runFolder) : "";
  return (
    <header
      className={`titlebar ${sidebarOpen ? "" : "sidebar-hidden"} ${showingSettings ? "showing-settings" : ""} ${state.showsTabBar || showingSettings ? "" : "no-tab-bar"}`}
      onDoubleClick={event => {
        // The Mac's double-click on the title bar zooms the window (Card.swift:186-198);
        // on Windows, that is the window maximised.
        if ((event.target as HTMLElement | null)?.closest("button, input, a, .tab")) return;
        (window as unknown as { kuvo?: { maximize?: () => void } }).kuvo?.maximize?.();
      }}
    >
      <div className="titlebar-identity">
        {showingSettings ? (
          <button
            id="settings-back"
            className="titlebar-icon"
            title="Back to Sessions (Esc)"
            aria-label="Back to Sessions"
            onClick={() => { state.settingsOpen = false; render(); }}
          >
            <svg viewBox="0 0 16 16" width="14" height="14" fill="none" aria-hidden="true">
              <path d="M9.8 3.4L5.2 8l4.6 4.6" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </button>
        ) : (
          <>
            <button
              id="toggle-sidebar"
              className="titlebar-icon"
              title={sidebarOpen ? "Hide Sessions" : "Show Sessions"}
              aria-label={sidebarOpen ? "Hide Sessions" : "Show Sessions"}
              aria-pressed={!sidebarOpen}
              onClick={() => {
                state.sidebarOpen = !sidebarOpen;
                const main = document.querySelector("main");
                if (main) main.classList.toggle("sidebar-open", state.sidebarOpen);
                render();
              }}
            >
              <svg viewBox="0 0 16 16" width="14" height="14" fill="none" aria-hidden="true">
                <rect x="2.2" y="3" width="11.6" height="10" rx="2" stroke="currentColor" strokeWidth="1.2" />
                <path d="M6.3 3v10" stroke="currentColor" strokeWidth="1.2" />
              </svg>
            </button>
            {runCommand ? (
              <button
                id="run"
                className="titlebar-icon"
                title={`Run ${runCommand}`}
                aria-label="Run"
                onClick={() => runInTerminal(runCommand, runFolder)}
              >
                <Symbol name="play" size={13} />
              </button>
            ) : null}
            <div className="identity" title={state.project ?? "Open Folder…"}>
              <button
                id="project"
                className="identity-hit"
                title="Change the project folder"
                aria-label="Change the project folder"
                onClick={() => { state.pickerOpen = true; render(); }}
              ><span className="sr-only">{state.project ?? "choose a folder…"}</span></button>
              <span className="identity-name">{folder || "choose a folder…"}</span>
              {branch ? (
                <span className="identity-branch">
                  <svg viewBox="0 0 12 12" width="10" height="10" fill="none" aria-hidden="true">
                    <circle cx="3" cy="2.6" r="1.2" stroke="currentColor" strokeWidth="1" />
                    <circle cx="3" cy="9.4" r="1.2" stroke="currentColor" strokeWidth="1" />
                    <circle cx="9" cy="8.1" r="1.2" stroke="currentColor" strokeWidth="1" />
                    <path d="M3 3.8v4.4M4.2 7.6c2.3 0 3.3-.7 3.8-2.1" stroke="currentColor" strokeWidth="1" strokeLinecap="round" />
                  </svg>
                  <span>{branch}</span>
                </span>
              ) : null}
            </div>
          </>
        )}
      </div>
      <div className="titlebar-tabs">
        {showingSettings ? (
          <div className="tab-track" role="tablist" aria-label="Settings">
            <button className="tab active settings-tab" role="tab" aria-selected="true" tabIndex={-1}>
              <motion.span className="tab-pill" layoutId="settings-tab-pill" transition={macSpringOrStill(motionIsReduced())} />
              <span className="tab-icon" aria-hidden="true">
                <svg viewBox="0 0 16 16" width="10" height="10" fill="none">
                  <circle cx="8" cy="8" r="2.3" stroke="currentColor" strokeWidth="1.2" />
                  <path d="M8 1.9v1.7M8 12.4v1.7M1.9 8h1.7M12.4 8h1.7M3.7 3.7l1.2 1.2M11.1 11.1l1.2 1.2M12.3 3.7l-1.2 1.2M4.9 11.1l-1.2 1.2" stroke="currentColor" strokeWidth="1.1" strokeLinecap="round" />
                </svg>
              </span>
              <span className="tab-title">{settingsPageTitle(state.settingsSection)}</span>
            </button>
          </div>
        ) : (
          <SessionTabs />
        )}
      </div>
      <div className="titlebar-actions">
        <button
          id="palette-open"
          className="titlebar-icon"
          title="Commands, sessions and files (Ctrl+K)"
          aria-label="Commands, sessions and files"
          onClick={() => { state.paletteOpen = true; render(); }}
        >
          <svg viewBox="0 0 16 16" width="14" height="14" fill="none" aria-hidden="true">
            <circle cx="6.8" cy="6.8" r="4.1" stroke="currentColor" strokeWidth="1.3" />
            <path d="M9.9 9.9L13.4 13.4" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
          </svg>
        </button>
        {showingSettings ? null : (
          <>
            <button
              id="settings-open"
              className="titlebar-icon"
              title="Settings"
              aria-label="Settings"
              onClick={() => { state.settingsOpen = true; state.settingsSection = "appearance"; render(); }}
            >
              <svg viewBox="0 0 16 16" width="14" height="14" fill="none" aria-hidden="true">
                <path d="M2.5 4.5h11M2.5 8h11M2.5 11.5h11" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
                <circle cx="5.5" cy="4.5" r="1.5" fill="var(--panel)" stroke="currentColor" strokeWidth="1.2" />
                <circle cx="10.2" cy="8" r="1.5" fill="var(--panel)" stroke="currentColor" strokeWidth="1.2" />
                <circle cx="6.8" cy="11.5" r="1.5" fill="var(--panel)" stroke="currentColor" strokeWidth="1.2" />
              </svg>
            </button>
            <button
              id="toggle-files"
              className="titlebar-icon"
              title={state.drawerOpen ? "Hide Panel" : "Show Panel"}
              aria-label={state.drawerOpen ? "Hide Panel" : "Show Panel"}
              aria-pressed={state.drawerOpen}
              onClick={() => { state.drawerOpen = !state.drawerOpen; render(); }}
            >
              <svg viewBox="0 0 16 16" width="14" height="14" fill="none" aria-hidden="true">
                <rect x="2.2" y="3" width="11.6" height="10" rx="2" stroke="currentColor" strokeWidth="1.2" />
                <path d="M9.7 3v10" stroke="currentColor" strokeWidth="1.2" />
              </svg>
            </button>
          </>
        )}
        <span id="engine" className={`engine sr-only ${running ? "up" : state.engine?.status === "starting" ? "starting" : "down"}`} title="The engine on this machine">
          {engineText}
        </span>
      </div>
    </header>
  );
}

/// The Mac's TabStrip (TitleBar.swift:78-330): open sessions as tabs in one glass track,
/// with the active one a raised white pill, a hairline between the inactive neighbours,
/// and the close button under the pointer. The strip starts where the conversation card
/// does, so the project identity takes the sidebar's width.
export function SessionTabs() {
  // The Mac's own menu for a tab (TitleBar.swift:214-231), and the name written in the
  // tab itself, where the title was (TitleBar.swift:170-200).
  const [menu, setMenu] = useState<{ id: string; x: number; y: number } | null>(null);
  const [renaming, setRenaming] = useState<string | null>(null);
  if (!state.openSessions.length) return null;
  return (
    <div className="tab-track" role="tablist" aria-label="Open sessions">
      {state.openSessions.map(id => {
        const session = state.sessions.find(item => item.id === id) ?? (state.session?.id === id ? state.session : null);
        const active = id === state.session?.id;
        const running = active && state.transcript?.running;
        const unread = Boolean(session?.time?.idle && session?.time?.viewed && session.time.idle > session.time.viewed && !active);
        const status = running ? "running" : unread ? "unread" : "";
        const title = session?.title || "New Session";
        const help = running ? `${title} — Working` : unread ? `${title} — Finished` : title;
        return (
          <button
            key={id}
            className={`tab ${active ? "active" : ""}`}
            role="tab"
            data-id={id}
            aria-selected={active}
            tabIndex={active ? 0 : -1}
            title={help}
            onContextMenu={event => {
              event.preventDefault();
              setMenu({ id, x: event.clientX, y: event.clientY });
            }}
            onClick={() => { state.settingsOpen = false; void openSession(id); }}
          >
            {active ? <motion.span className="tab-pill" layoutId="session-tab-pill" transition={macSpringOrStill(motionIsReduced())} /> : null}
            <span className="tab-icon" aria-hidden="true">
              <svg viewBox="0 0 16 16" width="10" height="10" fill="none">
                <path d="M2.7 3.4h10.6v6.7H8.2l-3.2 2.5v-2.5H2.7z" stroke="currentColor" strokeWidth="1.2" strokeLinejoin="round" />
              </svg>
              {status ? (
                <span className={`tab-status ${status}`}>
                  {running ? <Spinner size={8} /> : null}
                </span>
              ) : null}
            </span>
            {renaming === id ? (
              <input
                className="tab-rename"
                defaultValue={title}
                autoFocus
                aria-label="Rename this session"
                onFocus={event => event.currentTarget.select()}
                onClick={event => event.stopPropagation()}
                onKeyDown={event => {
                  if (event.key === "Enter") { event.preventDefault(); const name = event.currentTarget.value; setRenaming(null); void renameSession(id, name); }
                  if (event.key === "Escape") { event.preventDefault(); setRenaming(null); }
                }}
                onBlur={event => { const name = event.currentTarget.value; setRenaming(null); void renameSession(id, name); }}
              />
            ) : (
              <span className="tab-title">{title}</span>
            )}
            <span
              className="tab-close"
              role="button"
              aria-label={`Close ${title}`}
              title="Close Tab"
              onClick={event => { event.stopPropagation(); closeSessionTab(id); }}
            >
              <svg viewBox="0 0 12 12" width="8" height="8" fill="none" aria-hidden="true">
                <path d="M3 3l6 6M9 3l-6 6" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
              </svg>
            </span>
          </button>
        );
      })}
      {menu ? (
        <ContextMenu
          x={menu.x}
          y={menu.y}
          onClose={() => setMenu(null)}
          items={[
            // The Mac's menu for a tab (TitleBar.swift:214-231), in its order and with its
            // words: beside the one in view, its name, and the tabs to close.
            ...(menu.id !== state.session?.id ? [{ label: "Open Beside", run: () => void openBeside(menu.id) }] : []),
            { label: "Rename…", run: () => { setRenaming(menu.id); void openSession(menu.id); } },
            { label: "", separator: true },
            { label: "Close Tab", run: () => closeSessionTab(menu.id) },
            { label: "Close Other Tabs", disabled: state.openSessions.length <= 1, run: () => closeTabs(menu.id) },
            { label: "", separator: true },
            { label: "Close All Tabs", run: () => closeTabs(null) },
          ]}
        />
      ) : null}
    </div>
  );
}

/// The session the split pane shows, read as the main pane reads its own.
/// The Mac's Open Beside (SidebarView.swift:609, MainView.swift:757-775): the session
/// opens beside the one in view, as the pair the split keeps — how a session is chosen for
/// the split, with no picker of its own inside the pane.
export async function openBeside(id: string) {
  if (!id || id === state.session?.id) return;
  state.split = id;
  await openSplit(id);
  render();
}

export async function toggleSplit() {
  const other = state.openSessions.find(id => id !== state.session?.id) ?? state.sessions.find(s => s.id !== state.session?.id)?.id;
  if (state.split) { state.split = null; render(); return; }
  if (!other) return;
  await openBeside(other);
}

/// The Mac's Swap (MainView.swift:743-747): the session in view and the one beside it
/// exchange places.
export function swapSplit() {
  const other = state.split;
  const main = state.session?.id;
  if (!other || !main || other === main) return;
  state.split = main;
  void openSplit(main);
  void openSession(other);
}

/// The session beside the one in view: the list's own row for it, or its id alone — the
/// Mac's split card titles itself from its session (MainView.swift:735), not from a picker.
export function splitSession(): SessionSummary | null {
  if (!state.split) return null;
  const found = [...state.sessions, ...Object.values(state.sessionsByProject).flat()].find(s => s.id === state.split);
  return found ?? { id: state.split, title: null };
}

/// The split card's own head: the Mac draws the split as a card with the very header the
/// conversation's card has (MainView.swift:733-754) — its session's name over the
/// project, its ring, and Swap and Close. No strip of controls, nothing that could pass
/// for the window's title bar above.
export function SplitHeader() {
  const split = splitSession();
  if (!state.split || !split) return null;
  const directory = split.location?.directory ?? "";
  return (
    <CardHeader session={split} folder={folderName(directory)} tooltip={directory || undefined}>
      <ContextGauge session={split} />
      <button id="split-swap" className="card-action icon" title="Swap the two sessions" aria-label="Swap the two sessions" onClick={swapSplit}>
        <svg viewBox="0 0 16 16" width="13" height="13" fill="none" aria-hidden="true">
          <path
            d="M4 6.5h8M12 6.5 9.5 4M12 6.5 9.5 9M12 9.5H4M4 9.5 6.5 7M4 9.5 6.5 12"
            stroke="currentColor"
            strokeWidth="1.2"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      </button>
      <button id="split-close" className="card-action icon" title="Close Split View" aria-label="Close Split View" onClick={() => { state.split = null; render(); }}>
        <Symbol name="xmark" size={11} />
      </button>
    </CardHeader>
  );
}

/// The split card's conversation: the same rows the conversation shows, with the Mac's
/// question over them while there is nothing in them yet — the same TranscriptView draws
/// it there too (TranscriptView.swift:69-75) — and the working line while its run goes.
export function SplitEntries() {
  const transcript = state.split
    ? state.transcripts.get(state.split) ?? { entries: [], pending: [], permissions: [], running: false }
    : null;
  if (!transcript) return null;
  return (
    <>
      {transcript.entries.length === 0 && transcript.pending.length === 0
        ? <EmptyConversation directory={splitSession()?.location?.directory ?? ""} />
        : null}
      <EntryNodes transcript={transcript} />
      {transcript.running ? <WorkingLine transcript={transcript} /> : null}
    </>
  );
}

