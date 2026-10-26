// The app shell.

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { api } from "./api";
import { isRecording, shortcutFor } from "./shortcuts";
import {
  applyLook,
  boot,
  closeSessionTab,
  complain,
  cycleTab,
  exportConversation,
  loadAgents,
  loadCommands,
  loadForms,
  loadLook,
  loadModels,
  loadProjects,
  loadSessionDiff,
  loadVcs,
  look,
  newSession,
  notify,
  openProjectFile,
  reopenClosedTab,
  render,
  rememberTabBar,
  saveConfig,
  showTab,
  state,
  stopRun,
  useStore,
} from "./store";
import { Settings } from "./Settings";
import { DiffModal, Drawer, OpenQuickly, Palette, Picker, ProjectEditor, openTerminal, runTheProject, Toasts } from "./Overlays";
import { Symbol } from "./components/symbols";
import { EmptyConversation, EntryNodes, WorkingLine, FindBar, PermissionCard, FormCard } from "./Transcript";
import { Header, CardHeader, ContextGauge, SplitHeader, SplitEntries, toggleSplit } from "./Header";
import { Sidebar, PaneResizer, paneLayoutNow } from "./Sidebar";
import { Composer, ImageViewer, AnalyticsNotice } from "./Composer";

// ---- The app ----

/// What a shortcut does. The keys are the ones the user recorded, or the ones the app
/// ships with; the Mac's own list is the same, in the Mac's key names.
function runShortcut(id: string) {
  const tab = /^show-tab-([1-9])$/.exec(id);
  if (tab) { showTab(Number(tab[1])); return; }
  switch (id) {
    case "palette":
      state.openQuickly = false;
      state.paletteOpen = !state.paletteOpen;
      render();
      return;
    case "open-quickly":
      if (!state.project) return;
      state.paletteOpen = false;
      state.openQuickly = true;
      render();
      return;
    case "new-session":
      if (state.project) void newSession();
      return;
    case "new-chat":
      void newSession();
      return;
    case "new-project":
      state.pickerOpen = true;
      render();
      return;
    case "open-folder":
      state.pickerOpen = true;
      render();
      return;
    case "save":
      void exportConversation();
      return;
    case "run":
      runTheProject();
      return;
    case "find":
      // The Mac's find is invoked, not always there (App menu › Find in Conversation…).
      state.findOpen = true;
      render();
      return;
    case "settings":
      state.settingsOpen = true;
      state.settingsSection = "appearance";
      render();
      return;
    case "stop":
      void stopRun();
      return;
    case "close-tab":
      // The Mac closes the settings' tab while settings are showing (MainView.swift:1295-1307);
      // one page is what this client has.
      if (state.settingsOpen) { state.settingsOpen = false; render(); return; }
      if (state.session) closeSessionTab(state.session.id);
      return;
    case "close-window":
      (window as unknown as { kuvo?: { closeWindow?: () => void } }).kuvo?.closeWindow?.();
      return;
    case "reopen-tab":
      reopenClosedTab();
      return;
    case "next-tab":
      cycleTab(1);
      return;
    case "previous-tab":
      cycleTab(-1);
      return;
    case "tab-bar":
      rememberTabBar(!state.showsTabBar);
      render();
      return;
    case "appearance-system":
    case "appearance-light":
    case "appearance-dark":
      look.theme = id.slice("appearance-".length);
      applyLook();
      render();
      return;
    case "build-mode":
      selectAgent("build");
      return;
    case "plan-mode":
      selectAgent("plan");
      return;
    case "sidebar":
      state.sidebarOpen = state.sidebarOpen === false;
      render();
      return;
    case "panel":
      state.drawerOpen = !state.drawerOpen;
      render();
      return;
    case "files":
      state.drawerOpen = true;
      state.drawerTab = "files";
      render();
      return;
    case "changes":
      state.drawerOpen = true;
      state.drawerTab = "changes";
      render();
      return;
    case "terminal":
      openTerminal();
      return;
    default:
      return;
  }
}

/// The Mac's Build and Plan command-menu items (KuvoCodeApp.swift:178-193): the session's
/// agent, changed where the composer changes it.
function selectAgent(id: string) {
  if (!state.session) return;
  state.agent = id;
  render();
  void api(`/api/sessions/${encodeURIComponent(state.session.id)}/agent`, { method: "POST", body: { agent: id } })
    .catch(complain);
}

export function App() {
  useStore();
  const [ready, setReady] = useState(false);
  const entriesRef = useRef<HTMLDivElement>(null);
  const [showLatest, setShowLatest] = useState(false);
  const pinned = useRef(true);

  // The conversation follows the newest words — unless you have scrolled up to read.
  const scrollToLatest = (force = false) => {
    const box = entriesRef.current;
    if (!box) return;
    if (!force && !pinned.current) return;
    // scrollTop everywhere; the smooth scroll where the browser has it.
    if (typeof box.scrollTo === "function") box.scrollTo({ top: box.scrollHeight, behavior: force ? "auto" : "smooth" });
    else box.scrollTop = box.scrollHeight;
    setShowLatest(false);
  };
  useEffect(() => {
    const box = entriesRef.current;
    if (!box) return;
    const onScroll = () => {
      const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 80;
      pinned.current = atBottom;
      setShowLatest(!atBottom);
    };
    box.addEventListener("scroll", onScroll, { passive: true });
    return () => box.removeEventListener("scroll", onScroll);
  }, []);
  useEffect(() => { scrollToLatest(); });

  useEffect(() => {
    // The shell's menu bar: the items that act on the conversation come here, by the
    // shortcut the Mac uses (NativeMenu.swift).
    const kuvo = (window as unknown as { kuvo?: { onMenu?: (callback: (id: string) => void) => void } }).kuvo;
    kuvo?.onMenu?.(id => runShortcut(id));
  }, []);

  useEffect(() => {
    // The menu bar's words and checks are the page's state's (KuvoCodeApp.swift:130-229).
    const bridge = (window as unknown as { kuvo?: { setMenuState?: (state: { tabBar: boolean; appearance: string }) => void } }).kuvo;
    bridge?.setMenuState?.({ tabBar: state.showsTabBar, appearance: look.theme });
  }, [state.showsTabBar, look.theme]);

  useEffect(() => {
    loadLook();
    boot()
      .then(() => setReady(true))
      .catch(error => {
        setReady(true);
        complain(error);
      });
    const onKey = (event: KeyboardEvent) => {
      // While a shortcut is being recorded, the keys belong to the recorder.
      if (isRecording()) return;
      // The shortcuts the user recorded, or the ones the app ships with.
      const shortcut = shortcutFor(event);
      if (shortcut) {
        event.preventDefault();
        runShortcut(shortcut.id);
        return;
      }
      // ⌘1 to ⌘8 show that tab, ⌘9 the last one, as in browsers (KuvoCodeApp.swift:223-228).
      if (event.ctrlKey && !event.altKey && !event.shiftKey && /^[1-9]$/.test(event.key)) {
        event.preventDefault();
        runShortcut(`show-tab-${event.key}`);
        return;
      }
      if (event.key === "Escape") {
        if ((document.activeElement as HTMLElement | null)?.id === "find") (document.activeElement as HTMLElement).blur();
        // Escape goes back one step, as it does on the Mac: the palette first, then the
        // settings, then the sheet that is open.
        if (state.openQuickly) { state.openQuickly = false; render(); return; }
        if (state.paletteOpen) { state.paletteOpen = false; render(); return; }
        if (state.settingsOpen) { state.settingsOpen = false; render(); return; }
        state.diffOpen = false;
        render();
      }
    };
    window.addEventListener("keydown", onKey);
    // A window resized has another measure to give the panes (MainView.swift:983-985).
    const onResize = () => render();
    window.addEventListener("resize", onResize);
    return () => {
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("resize", onResize);
    };
  }, []);

  const hasSession = state.session !== null;
  const needsFolder = state.project === null;
  const inShell = (window as unknown as { kuvo?: { isShell?: boolean } }).kuvo?.isShell === true
    || new URLSearchParams(window.location.search).get("shell") === "1";

  useEffect(() => {
    document.body.classList.toggle("in-shell", inShell);
    return () => document.body.classList.remove("in-shell");
  }, [inShell]);

  useEffect(() => {
    if (!state.project) return;
    void loadVcs();
    void loadSessionDiff();
    void loadForms();
  }, [state.session?.id, state.project]);

  // The layout the window can hold, measured the Mac's way (MainView.swift:983-1010): a
  // pane the window has no room for is put aside, and comes back when it has.
  const layout = paneLayoutNow();
  useLayoutEffect(() => {
    const root = document.documentElement;
    root.style.setProperty("--sessions-width", `${layout.sessions ?? state.sessionsWidth}px`);
    root.style.setProperty("--split-width", `${layout.split ?? state.splitWidth}px`);
    root.style.setProperty("--changes-width", `${layout.changes ?? state.changesWidth}px`);
  });

  return (
    <>
      <Header />
      <main className={[
        state.sidebarOpen === false || layout.sessions === null ? "sidebar-hidden" : "",
        state.drawerOpen && layout.changes === null ? "changes-hidden" : "",
      ].filter(Boolean).join(" ")}>
        <Sidebar />
        {state.sidebarOpen !== false && layout.sessions !== null ? <PaneResizer pane="sessions" /> : null}
        <section id="conversation" className="card conversation-card">
          <div className="card-fade" aria-hidden="true" />
          <CardHeader
            session={state.session}
            folder={state.project ? state.project.replace(/[\\/]+$/, "").split(/[\\/]/).pop() ?? "" : ""}
            tooltip={state.project ?? undefined}
          >
            <button
              id="split"
              className={`card-action icon ${state.split ? "active" : ""}`}
              title="Show a second session beside this one"
              aria-label="Split view"
              onClick={() => void toggleSplit()}
            >
              <svg viewBox="0 0 16 16" width="13" height="13" fill="none" aria-hidden="true">
                <rect x="2.2" y="3" width="11.6" height="10" rx="2" stroke="currentColor" strokeWidth="1.2" />
                <path d="M8 3v10" stroke="currentColor" strokeWidth="1.2" />
              </svg>
            </button>
            {state.sessionDiff.length ? (
              <button
                id="changes"
                className="card-action"
                title="The files this session changed"
                onClick={() => { state.diffOpen = true; render(); }}
              >
                {`Changes (${state.sessionDiff.length})`}
              </button>
            ) : null}
            <ContextGauge />
          </CardHeader>
          {state.findOpen ? <FindBar /> : null}
          <div id="empty" className="empty" hidden={hasSession}>
            <h1>{needsFolder ? "Open a folder" : "A session to work in"}</h1>
            <p>
              {needsFolder
                ? "Pick the project to work in, then say what you want done. The agent reads, edits and runs things in that folder, asking first."
                : "Sessions live in the folder you picked. Start one, then say what you want done in it."}
            </p>
            <button id="choose" className="primary" hidden={!needsFolder} onClick={() => { state.pickerOpen = true; render(); }}>Open Folder…</button>
            <button id="start" className="primary" hidden={needsFolder} onClick={() => void newSession()}>New Session</button>
          </div>
          <div
            id="entries"
            className="entries"
            ref={entriesRef}
            onClick={event => {
              // The Mac app's file links: a code span that names a file of the project opens
              // it, in the side panel.
              const link = (event.target as HTMLElement | null)?.closest?.("a.file-link") as HTMLAnchorElement | null;
              if (!link) return;
              event.preventDefault();
              void openProjectFile(link.dataset.path ?? "");
            }}
          >
            {/* The conversation at rest: the Mac overlays its question while there are no
                rows and nothing waiting (TranscriptView.swift:69-75). */}
            {state.transcript && state.transcript.entries.length === 0 && state.transcript.pending.length === 0
              ? <EmptyConversation directory={state.session?.location?.directory ?? ""} />
              : null}
            {state.transcript ? <EntryNodes transcript={state.transcript} /> : null}
            {state.transcript?.running ? <WorkingLine transcript={state.transcript} /> : null}
          </div>
          <button
            id="jump-latest"
            className="small"
            hidden={!showLatest}
            title="Go to the latest words"
            onClick={() => { scrollToLatest(true); }}
          >
            <Symbol name="arrow.down" size={12} /> Latest
          </button>
          <div id="asks" className="asks">
            {(state.transcript?.permissions ?? []).map(request => <PermissionCard key={request.id} request={request} />)}
          </div>
          <div id="forms" className="forms" hidden={state.forms.length === 0}>
            {state.forms.map(form => <FormCard key={form.id} form={form} />)}
          </div>
          <Composer />
        </section>
        {state.split && layout.split !== null ? <PaneResizer pane="split" /> : null}
        <section id="split-pane" className="card split-pane" hidden={!state.split || layout.split === null}>
          <div className="card-fade" aria-hidden="true" />
          <SplitHeader />
          <div id="split-entries" className="entries">
            <SplitEntries />
          </div>
        </section>
        {state.drawerOpen && layout.changes !== null ? <PaneResizer pane="changes" /> : null}
        <Drawer />
      </main>
      <Palette />
      <OpenQuickly />
      <Picker />
      <Settings />
      <DiffModal />
      <ProjectEditor />
      <Toasts />
      <ImageViewer />
      <AnalyticsNotice />
      {!ready ? <div className="fatal">Starting…</div> : null}
    </>
  );
}

export { motionIsReduced } from "./app-shared";
export { swapSplit, splitSession } from "./Header";
export { api, loadAgents, loadCommands, loadModels, loadProjects, saveConfig, notify, applyLook };

