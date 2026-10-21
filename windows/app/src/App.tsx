// The conversation view, in React: sessions on the left, the transcript and the composer
// on the right. The engine's events keep the transcript current, as they always did.

import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { api } from "./api";
import type { Attachment, FormRequest, PermissionRequest, SessionSummary, Transcript, TranscriptEntry } from "./api";
import { brief, compactTokens, errorText, renderMarkdown } from "./lib";
import { isRecording, keysOf, matchesEvent, shortcutFor } from "./shortcuts";
import { paneLayout, paneRanges } from "../../harness/layout.mjs";
import { draftKey, readDraft, saveDraft } from "./drafts.mjs";
import {
  answerPermission,
  applyLook,
  approval,
  boot,
  favoriteModels,
  rememberFavorite,
  archiveSession,
  closeSessionTab,
  closeTabs,
  complain,
  copyMarkdown,
  deleteSession,
  dismissForm,
  exportConversation,
  exportMarkdownOf,
  loadAgents,
  loadCommands,
  loadForms,
  loadInbox,
  loadLook,
  loadModels,
  loadProjectSessions,
  loadProjects,
  loadSessionDiff,
  loadSessions,
  loadVcs,
  look,
  newSession,
  notify,
  openProject,
  openProjectFile,
  openSession,
  openSplit,
  pinSession,
  redoNow,
  render,
  rememberFolded,
  rememberModel,
  removeProject,
  renameSession,
  replyForm,
  saveConfig,
  savePaneWidth,
  sendPrompt,
  setApproval,
  setPaneWidth,
  showInFolder,
  state,
  stopRun,
  type Approval,
  undoFromHere,
  useStore,
} from "./store";
import { Settings, settingsPageTitle } from "./Settings";
import { DiffModal, Drawer, Palette, Picker, Toast } from "./Overlays";
import { Shimmer } from "./components/ai-elements/shimmer";
import { FolderIcon, Symbol } from "./components/symbols";
import { Spinner } from "./components/spinner";
import { toolDiffStat, toolSummary, toolSymbol } from "./components/tool-call";
import { ProviderLogo } from "./components/provider-logo";
import { AnimatePresence, motion } from "motion/react";
import { macSpringOrStill, viewerClose, viewerFade } from "./motion";

/// The app's own motion setting, and the system's: when either asks for less, the
/// shimmer stops (the Mac's ShimmerText reads the system's, Theme.swift:46-60).
function motionIsReduced() {
  if (look.motion === "reduced") return true;
  return typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

// ---- The pieces of the transcript ----

function ToolCard({ part }: { part: TranscriptEntry["parts"] extends (infer P)[] | undefined ? P : never }) {
  const status = part.status ?? "running";
  const [open, setOpen] = useState(false);
  const input = brief(part.input ?? part.inputText);
  const output = Array.isArray(part.output)
    ? part.output.map(item => (item as { text?: string })?.text ?? brief(item)).filter(Boolean).join("\n")
    : part.output === undefined ? "" : brief(part.output);
  const lower = (part.name ?? "").toLowerCase();
  const hasDiff = lower.includes("edit") || lower.includes("write") || lower.includes("patch")
    || Boolean(part.input && ((part.input as Record<string, unknown>).oldString || (part.input as Record<string, unknown>).old || (part.input as Record<string, unknown>).content));
  // A step with details opens like a button; the rest are lines. The Mac app's rule.
  const hasDetails = Boolean(input || output || part.error);
  const going = status !== "completed" && status !== "error";
  // A subagent at work shows what it is doing; opened later, its steps stay folded.
  useEffect(() => { if (lower === "subagent" && going) setOpen(true); }, [lower, going]);
  return (
    <div className={`tool ${status}`}>
      <button
        className="tool-head"
        disabled={!hasDetails}
        onClick={() => hasDetails && setOpen(value => !value)}
        title={hasDetails ? "Show what it did" : undefined}
      >
        {/* The Mac's row (ToolCallView.swift:99-128): the mark of the tool, what it did
            in words, and the chevron that opens what it did. */}
        <span className="tool-icon">
          {going ? <Spinner size={11} /> : <Symbol name={toolSymbol(part.name ?? "tool")} size={12} />}
        </span>
        <span className="tool-name">{toolSummary(part.name ?? "tool", part.input as Record<string, unknown> | undefined, going, state.project)}</span>
        {/* The lines it added and removed, the Mac's way (ToolCallView.swift:106-107,
            the stat read off the call's own metadata and printed in the row). */}
        {(() => {
          const stat = toolDiffStat(part.metadata);
          if (!stat) return null;
          return (
            <span className="diff-stat">
              {stat.additions > 0 ? <span className="added">+{stat.additions}</span> : null}
              {stat.deletions > 0 ? <span className="removed">−{stat.deletions}</span> : null}
            </span>
          );
        })()}
        <span className="tool-chevron">{hasDetails ? <Symbol name="chevron.right" size={12} className={open ? "turned" : ""} /> : null}</span>
      </button>
      {open && hasDetails ? (
        <div className="tool-details">
          {input ? <pre className="tool-input">{input}</pre> : null}
          {output ? <pre className="tool-output">{output.length > 4000 ? `${output.slice(0, 4000)}…` : output}</pre> : null}
          {part.error ? <div className="tool-error">{errorText(part.error)}</div> : null}
          {hasDiff ? (
            <button
              className="small"
              onClick={() => {
                const input_ = (part.input ?? {}) as Record<string, unknown>;
                const oldText = (input_.oldString ?? input_.old ?? "") as string;
                const newText = (input_.newString ?? input_.new ?? input_.content ?? part.output ?? "") as string;
                showDiff(`${part.name ?? "tool"} · ${(input_.filePath ?? input_.path ?? input_.file ?? "") as string}`, oldText, newText);
              }}
            >
              diff
            </button>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

export function showDiff(title: string, oldText: string, newText: string) {
  state.diffOpen = true;
  state.diffTitle = title;
  state.diffOld = oldText;
  state.diffNew = newText;
}

/// A long message folds, the way the Mac app's does: the first lines, and a way to see
/// the rest.
function LongText({ text }: { text: string }) {
  useStore();
  const [open, setOpen] = useState(false);
  const long = text.length > 900;
  const files = state.projectFiles;
  if (!long) return <div className="text markdown" dangerouslySetInnerHTML={{ __html: renderMarkdown(text, files) }} />;
  const cut = text.slice(0, 700);
  const line = cut.lastIndexOf("\n", 700);
  return (
    <div className="text markdown">
      <div
        dangerouslySetInnerHTML={{
          __html: renderMarkdown(open ? text : cut.slice(0, line > 200 ? line : 700), files),
        }}
      />
      {/* The Mac's own words, and the same way round: it folds and unfolds. */}
      <button className="small long-more" onClick={() => setOpen(value => !value)}>
        {open ? "Show Less" : "Show More"}
      </button>
    </div>
  );
}

/// How the agent's work shows between its replies: "Thought for 40s, ran 6 commands, read
/// 3 files (1 failed)" — the Mac app's words, word for word.
const stepKind = (name: string) => {
  const lower = (name ?? "").toLowerCase();
  if (lower.startsWith("kuvo-browser_browser_") || lower.startsWith("browser_")) return "browser";
  switch (lower) {
    case "grep": case "glob": case "list": return "search";
    case "bash": case "shell": return "shell";
    case "edit": case "write": case "patch": return "edit";
    case "kuvo-browser_show_in_panel": return "show";
    case "kuvo-browser_send_message": return "message";
    case "kuvo-browser_list_agents": return "agents";
    default: return lower;
  }
};

const stepPhrase = (kind: string, count: number) => {
  const many = count > 1;
  switch (kind) {
    case "websearch": return many ? `searched the web ${count} times` : "searched the web";
    case "webfetch": return many ? `fetched ${count} pages` : "fetched a page";
    case "read": return many ? `read ${count} files` : "read a file";
    case "search": return many ? `searched the files ${count} times` : "searched the files";
    case "shell": return many ? `ran ${count} commands` : "ran a command";
    case "edit": return many ? `edited files ${count} times` : "edited a file";
    case "browser": return many ? `used the browser (${count} steps)` : "used the browser";
    case "subagent": return many ? `handed off ${count} tasks` : "handed off a task";
    case "question": return many ? `asked you ${count} questions` : "asked you a question";
    case "show": return many ? `showed you ${count} things` : "showed you something";
    case "message": return many ? `wrote to other agents ${count} times` : "wrote to another agent";
    case "agents": return "looked up the other agents";
    case "todowrite": case "todoread": return "kept its to-do list";
    default: return many ? `used ${kind} ${count} times` : `used ${kind}`;
  }
};

/// The Mac's own way of saying how long (MessageTime.duration, TranscriptView.swift:1119).
const duration = (seconds: number) => {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
};;

function stepsSummary(entry: TranscriptEntry): string {
  const parts = entry.parts ?? [];
  const calls = parts.filter(part => part.type === "tool");
  const thought = parts
    .filter(part => part.type === "reasoning")
    .reduce((total, part) => {
      const times = part as unknown as { created?: number; completed?: number };
      if (!times.created || !times.completed) return total;
      return total + (times.completed - times.created) / 1000;
    }, 0);
  const pieces: string[] = [];
  if (parts.some(part => part.type === "reasoning")) pieces.push(`thought for ${duration(Math.max(1, Math.round(thought)))}`);
  if (calls.length) {
    const order: string[] = [];
    const counts = new Map<string, number>();
    for (const call of calls) {
      const kind = stepKind(call.name ?? "");
      if (!counts.has(kind)) order.push(kind);
      counts.set(kind, (counts.get(kind) ?? 0) + 1);
    }
    pieces.push(order.map(kind => stepPhrase(kind, counts.get(kind) ?? 1)).join(", "));
  }
  const failed = calls.filter(call => call.status === "error").length;
  const text = pieces.join(", ") + (failed > 0 ? ` (${failed} failed)` : "");
  return text ? text[0].toUpperCase() + text.slice(1) : "";
}

/// The Mac's line while the agent is working (TranscriptView.swift:598-610): "Working…",
/// the time it has been at it, and the way to stop it. The words shimmer, as the Mac's do.
function WorkingLine({ transcript }: { transcript: Transcript }) {
  const [now, setNow] = useState(0);
  useEffect(() => {
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);
  const last = [...transcript.entries].reverse().find(entry => entry.kind === "assistant");
  const seconds = last?.created && now ? Math.floor((now - last.created) / 1000) : 0;
  const elapsed = seconds >= 2 ? ` ${duration(seconds)} · Esc to stop` : "";
  return (
    <div className="working-line">
      <Shimmer as="span" className="thinking-shimmer" duration={1.6}>{`Working…${elapsed}`}</Shimmer>
    </div>
  );
}

/// The find bar, the Mac's (FindBar.swift:251-291): the magnifier and the field in a
/// 38 pt row, the count of what was found, the two arrows that step through it, and Done.
function FindBar() {
  useStore();
  const query = state.findQuery.trim();
  const [at, setAt] = useState(0);
  const input = useRef<HTMLInputElement>(null);
  // What the find reads: the messages that have come, and the ones still on their way.
  const messages = [
    ...(state.transcript?.entries ?? []).filter(entry => entry.kind === "user" || entry.kind === "assistant"),
    ...(state.transcript?.pending ?? []),
  ];
  const matches = messages
    .map(entry => ({ entry, count: countOf(entryText(entry), query) }))
    .filter(item => item.count > 0);
  const places = matches.reduce((sum, item) => sum + item.count, 0);
  const current = Math.min(at, Math.max(places - 1, 0));
  useEffect(() => {
    if (!state.findOpen) return;
    input.current?.focus();
    input.current?.select();
  }, [state.findOpen]);
  const step = (delta: number) => {
    if (!places) return;
    const next = (current + delta + places) % places;
    setAt(next);
    // The message the match is in is brought into view.
    let seen = 0;
    for (const item of matches) {
      seen += item.count;
      if (next < seen) {
        const node = document.querySelector(`[data-entry="${item.entry.id ?? ""}"]`);
        node?.scrollIntoView({ block: "center" });
        break;
      }
    }
  };
  return (
    <div id="find-bar" className="find-bar">
      <div className="find-row">
        <Symbol name="magnifyingglass" size={13} />
        <input
          ref={input}
          id="find"
          className="find-field"
          placeholder="Find in Conversation"
          spellCheck={false}
          value={state.findQuery}
          onChange={event => { state.findQuery = event.target.value; setAt(0); render(); }}
          onKeyDown={event => {
            if (event.key === "Enter") { event.preventDefault(); step(event.shiftKey ? -1 : 1); }
            if (event.key === "Escape") { event.preventDefault(); state.findOpen = false; render(); }
          }}
        />
        <span className="find-count">
          {query.length < 2 ? "" : places ? `${current + 1} / ${places} ${places === 1 ? "result" : "results"}` : "No results"}
        </span>
        <button id="find-previous" className="find-action" title="Previous Result (Shift+Return)" aria-label="Previous Result" disabled={!places} onClick={() => step(-1)}>
          <Symbol name="arrow.up" size={12} />
        </button>
        <button id="find-next" className="find-action" title="Next Result (Return)" aria-label="Next Result" disabled={!places} onClick={() => step(1)}>
          <Symbol name="arrow.down" size={12} />
        </button>
        <button id="find-done" className="find-action" title="Done (Esc)" aria-label="Done" onClick={() => { state.findOpen = false; render(); }}>
          <Symbol name="xmark" size={12} />
        </button>
      </div>
    </div>
  );
}

/// A new session, from a message and the ones before it (the Mac's "New Session From
/// Here"): the session is forked at that message, and the fork is opened.
async function forkSessionFrom(entry: TranscriptEntry) {
  if (!state.session) return;
  try {
    const { session: branched } = await api<{ session: SessionSummary }>(`/api/sessions/${encodeURIComponent(state.session.id)}/fork`, {
      method: "POST",
      body: { before: entry.id },
    });
    state.transcripts.delete(branched.id);
    await loadSessions();
    await openSession(branched.id);
  } catch (error) {
    complain(error);
  }
}

/// When a message was sent, the Mac's way (MessageTime.sentAt): the time today, "Yesterday"
/// for the day before, and the date and the time further back.
export function sentAt(created?: number) {
  if (!created) return "";
  const then = new Date(created);
  const now = new Date();
  const time = then.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
  const yesterday = new Date(now.getTime() - 86_400_000);
  if (then.toDateString() === now.toDateString()) return time;
  if (then.toDateString() === yesterday.toDateString()) return `Yesterday ${time}`;
  return `${then.toLocaleDateString(undefined, { day: "numeric", month: "short" })} ${time}`;
}

/// The words of a message, as the find reads them.
function entryText(entry: { text?: string; parts?: { type: string; text?: string }[] }) {
  if (entry.text) return entry.text;
  return (entry.parts ?? []).map(part => (part.type === "text" || part.type === "reasoning" ? part.text ?? "" : "")).join("\n");
}

/// How many times a phrase is in a text.
function countOf(text: string, query: string) {
  if (query.length < 2) return 0;
  const haystack = text.toLowerCase();
  const needle = query.toLowerCase();
  let count = 0;
  let at = haystack.indexOf(needle);
  while (at >= 0) {
    count += 1;
    at = haystack.indexOf(needle, at + needle.length);
  }
  return count;
}

/// The row itself: the summary, and each step when it is opened.
function StepsRow({ entry }: { entry: TranscriptEntry }) {
  const [open, setOpen] = useState(false);
  // The Mac's three levels (StepsDetail, StepsRow.swift:6-19, 89-91): the steps each on
  // their own, the summary in a line, or the count alone.
  const steps = (entry.parts ?? []).length;
  const summary = look.steps === "minimal" ? `${steps} ${steps === 1 ? "step" : "steps"}` : stepsSummary(entry);
  if (!summary) return null;
  const calls = (entry.parts ?? []).filter(part => part.type === "tool");
  return (
    <div className="steps-row">
      <button className="steps-summary" onClick={() => setOpen(value => !value)} title={open ? "Hide the steps" : "Show each step"}>
        <Symbol name="list.bullet" size={13} />
        <span>{summary}</span>
        <Symbol name="chevron.right" size={11} className={open ? "turned" : ""} />
      </button>
      {/* Each step, as the Mac shows it (StepsRow.swift:69-77): the step itself, in its
          own row — the tool's mark and what it did. */}
      {open ? (
        <ul className="steps-list">
          {calls.map((call, index) => {
            const name = call.name ?? "tool";
            const going = call.status !== "completed" && call.status !== "error";
            return (
              <li key={call.id ?? index}>
                <span className="tool-icon">
                  {going ? <Spinner size={11} /> : <Symbol name={toolSymbol(name)} size={12} />}
                </span>
                <span className="tool-name">{toolSummary(name, call.input as Record<string, unknown> | undefined, going, state.project)}</span>
                {call.status === "error" ? <span className="entry-error">Stopped</span> : null}
              </li>
            );
          })}
        </ul>
      ) : null}
    </div>
  );
}

function AssistantEntry({ entry }: { entry: TranscriptEntry }) {
  const [quote, setQuote] = useState<{ text: string; top: number; left: number } | null>(null);
  const blockRef = useRef<HTMLElement>(null);

  // The Mac app's selection menu: select a passage, and ask for it in your own message.
  const onSelect = () => {
    const selection = window.getSelection();
    const text = selection?.toString().trim() ?? "";
    if (!text || !blockRef.current?.contains(selection?.anchorNode ?? null)) { setQuote(null); return; }
    const range = selection?.getRangeAt(0);
    const box = range?.getBoundingClientRect();
    const host = blockRef.current?.getBoundingClientRect();
    if (!box || !host) { setQuote(null); return; }
    setQuote({ text, top: box.top - host.top - 22, left: box.left - host.left });
  };

  return (
    <article className="entry assistant" ref={blockRef} onMouseUp={onSelect}>
      <StepsRow entry={entry} />
      {(entry.parts ?? []).map((part, index) => {
        if (part.type === "text") return <LongText key={index} text={part.text ?? ""} />;
        if (part.type === "reasoning") {
          return (
            <details key={index} className="reasoning">
              <summary>
                {entry.running && !motionIsReduced()
                  ? <Shimmer as="span" className="thinking-shimmer" duration={1.6}>Thinking…</Shimmer>
                  : "Thinking…"}
              </summary>
              <div className="text markdown" dangerouslySetInnerHTML={{ __html: renderMarkdown(part.text ?? "", state.projectFiles) }} />
            </details>
          );
        }
        if (part.type === "tool") return <ToolCard key={index} part={part} />;
        return null;
      })}
      {quote ? (
        <button
          className="small quote-button"
          style={{ top: quote.top, left: quote.left }}
          onMouseDown={event => event.preventDefault()}
          onClick={() => {
            state.quote = quote.text;
            window.getSelection()?.removeAllRanges();
            setQuote(null);
            render();
          }}
        >
          Quote
        </button>
      ) : null}
      <button
        className="small entry-action"
        title="New Session From Here"
        onClick={() => void forkSessionFrom(entry)}
      >
        New Session From Here
      </button>
      {entry.retry ? <div className="entry-meta retry">retrying{entry.retry.attempt ? ` (attempt ${entry.retry.attempt})` : ""}…</div> : null}
      {entry.error ? <div className="entry-error">{errorText(entry.error)}</div> : null}
      {entry.cost ? <div className="entry-meta">{entry.model ?? ""} · ${entry.cost.toFixed(4)}</div> : null}
    </article>
  );
}

function AttachmentNode({ file }: { file: Attachment }) {
  const fromData = file.data ? `data:${file.mime};base64,${file.data}` : null;
  const fromUri = file.uri ? `/api/raw?path=${encodeURIComponent(decodeURIComponent(String(file.uri).replace(/^file:\/\//, "")))}` : null;
  const source = fromData ?? fromUri;
  if (!source) return <span className="attachment-chip">{file.name ?? "file"}</span>;
  if ((file.mime ?? "").startsWith("image/")) {
    return (
      <img
        className="attachment-image"
        src={source}
        alt={file.name ?? "image"}
        onClick={() => { state.viewing = { source, name: file.name ?? "image" }; render(); }}
      />
    );
  }
  return <a className="attachment-chip" href={source} target="_blank" rel="noreferrer">{`${file.name ?? "file"} (${file.mime})`}</a>;
}

/// A conversation with nothing in it yet: the Mac's own mark over its own question about
/// the folder (TranscriptView.swift:69-75 overlays it while the rows are empty;
/// EmptyConversationView's `plain` form is drawn at TranscriptView.swift:1757-1767).
function EmptyConversation({ directory }: { directory: string }) {
  // The folder goes by its last path component, the Mac's way — however the engine names it.
  const folder = directory.split(/[\\/]/).filter(Boolean).at(-1) ?? "";
  // Without a folder there is no question to ask; the Mac always has one.
  if (!folder) return null;
  return (
    <div className="empty-conversation">
      <Symbol name="bubble.left.and.text.bubble.right" size={34} stroke={2.4} />
      <p>{`What should we work on in ${folder}?`}</p>
    </div>
  );
}

function EntryNodes({ transcript }: { transcript: Transcript }) {
  // The message that started the turn: what "Try Again" sends again.
  const lastMessage = [...transcript.entries].reverse().find(entry => entry.kind === "user")?.text ?? "";
  // The menu of a message, where the Mac has one (YourMessage.swift:81-89).
  const [menu, setMenu] = useState<{ id: string; x: number; y: number } | null>(null);
  return (
    <>
      {transcript.entries.map((entry, index) => {
        const key = entry.id ?? `${entry.kind}-${index}`;
        if (entry.kind === "user") {
          return (
            <article
              key={key}
              className="entry user"
              onContextMenu={event => {
                event.preventDefault();
                setMenu({ id: entry.id ?? key, x: event.clientX, y: event.clientY });
              }}
            >
              <div className="text">{entry.text}</div>
              {(entry.files ?? []).map((file, i) => <AttachmentNode key={i} file={file} />)}
              {/* The Mac's actions under your words (YourMessage.swift:41-64): the time it
                  was sent, Copy, a new session from here, and undo — always laid out, and
                  shown under the pointer, so nothing moves when they appear. */}
              <div className="entry-actions">
                <span className="entry-time">{sentAt(entry.created)}</span>
                {entry.text ? (
                  <button
                    className="entry-action"
                    title="Copy"
                    aria-label="Copy"
                    onClick={async () => {
                      await navigator.clipboard?.writeText(entry.text ?? "").catch(() => {});
                    }}
                  >
                    <Symbol name="doc" size={12} />
                    <span className="entry-action-text">Copy</span>
                  </button>
                ) : null}
                {entry.id ? (
                  <button
                    className="entry-action"
                    title="New Session From Here"
                    aria-label="New Session From Here"
                    onClick={() => void forkSessionFrom(entry)}
                  >
                    <Symbol name="arrow.triangle.branch" size={12} />
                    <span className="entry-action-text">New Session From Here</span>
                  </button>
                ) : null}
                {entry.id ? (
                  <button
                    className="entry-action"
                    title="Undo From Here…"
                    aria-label="Undo From Here"
                    onClick={() => void undoFromHere(entry)}
                  >
                    <Symbol name="arrow.uturn.backward" size={12} />
                    <span className="entry-action-text">Undo From Here…</span>
                  </button>
                ) : null}
              </div>
            </article>
          );
        }
        if (entry.kind === "assistant") return <AssistantEntry key={key} entry={entry} />;
        if (entry.kind === "notice") return <div key={key} className="notice">{entry.text}</div>;
        if (entry.kind === "shell") {
          return (
            <div key={key} className="shell">
              <pre>{`$ ${entry.command ?? ""}${entry.exit ? `  — exit ${entry.exit}` : ""}`}</pre>
              {entry.output ? <pre className="tool-output">{entry.output}</pre> : null}
            </div>
          );
        }
        if (entry.kind === "idle" && entry.outcome === "failed") {
          return (
            <div key={key} className="entry-failed">
              <div className="entry-error">{errorText(entry.error) || "The run failed."}</div>
              {lastMessage ? (
                <button
                  className="small"
                  title="Send your last message again"
                  onClick={() => void sendPrompt(lastMessage)}
                >
                  <Symbol name="arrow.clockwise" size={12} /> Try Again
                </button>
              ) : null}
            </div>
          );
        }
        if (entry.kind === "idle" && entry.outcome === "interrupted") return <div key={key} className="notice">Stopped</div>;
        return null;
      })}
      {transcript.pending.map(item => (
        <article key={item.id} className="entry user pending">
          <div className="text">{item.text}</div>
          {/* The picture you just sent is shown at once, as the Mac shows it. */}
          {(item.files ?? []).map((file, i) => <AttachmentNode key={i} file={file} />)}
          {item.delivery === "queue" ? <div className="entry-meta">queued</div> : null}
        </article>
      ))}
      {menu ? (
        <ContextMenu
          x={menu.x}
          y={menu.y}
          onClose={() => setMenu(null)}
          items={[
            { label: "Copy", run: () => { const found = transcript.entries.find(item => item.id === menu.id); void navigator.clipboard?.writeText(found ? entryText(found) : "").catch(() => {}); } },
            { label: "New Session From Here", run: () => { const found = transcript.entries.find(item => item.id === menu.id); if (found) void forkSessionFrom(found); } },
            { label: "Undo From Here…", run: () => { const found = transcript.entries.find(item => item.id === menu.id); if (found) void undoFromHere(found); } },
          ]}
        />
      ) : null}
    </>
  );
}

// ---- The questions ----

function PermissionCard({ request }: { request: PermissionRequest }) {
  return (
    <div className="ask">
      <div className="ask-head">
        <strong>{request.action ?? "permission"}</strong>
        <span>{(request.resources ?? []).join(", ")}</span>
      </div>
      {request.message ? <div className="ask-message">{request.message}</div> : null}
      <div className="ask-buttons">
        <button className="primary" onClick={() => void answerPermission(request, "once")}>Allow</button>
        <button onClick={() => void answerPermission(request, "always")}>Always Allow</button>
        <button className="danger" onClick={() => void answerPermission(request, "reject")}>Deny</button>
      </div>
    </div>
  );
}

function FormCard({ form }: { form: FormRequest }) {
  const [values, setValues] = useState<Record<string, unknown>>(() => {
    const initial: Record<string, unknown> = {};
    for (const field of form.fields ?? []) {
      if (field.default !== undefined) initial[field.key] = field.default;
    }
    return initial;
  });
  const set = (key: string, value: unknown) => setValues(current => ({ ...current, [key]: value }));
  return (
    <div className="ask form">
      <div className="ask-head">
        <strong>{form.title ?? "A question"}</strong>
        {form.metadata?.kind === "mcp-elicitation" ? <span className="where">{form.metadata?.server ?? "an MCP server"}</span> : null}
      </div>
      {form.metadata?.message ? <div className="ask-message">{form.metadata.message}</div> : null}
      {(form.fields ?? []).filter(field => !field.hidden).map(field => (
        <div className="form-field" key={field.key}>
          <label>
            <span>{field.title ?? field.key}</span>
            {field.required ? <span className="warn"> · needed</span> : null}
          </label>
          {field.type === "boolean" ? (
            <input type="checkbox" checked={values[field.key] === true} onChange={event => set(field.key, event.target.checked)} />
          ) : field.type === "number" || field.type === "integer" ? (
            <input
              type="number"
              value={String(values[field.key] ?? "")}
              min={field.minimum}
              max={field.maximum}
              step={field.type === "integer" ? 1 : undefined}
              onChange={event => set(field.key, event.target.value === "" ? undefined : Number(event.target.value))}
            />
          ) : field.type === "multiselect" ? (
            <div className="form-choices">
              {(field.options ?? []).map(option => (
                <label className="form-choice" key={option.value}>
                  <input
                    type="checkbox"
                    checked={Array.isArray(values[field.key]) && (values[field.key] as string[]).includes(option.value)}
                    onChange={event => {
                      const picked = new Set(Array.isArray(values[field.key]) ? (values[field.key] as string[]) : []);
                      if (event.target.checked) picked.add(option.value); else picked.delete(option.value);
                      set(field.key, [...picked]);
                    }}
                  />
                  <span>{option.label ?? option.value}</span>
                </label>
              ))}
            </div>
          ) : field.type === "external" ? (
            <a className="small" href={field.url} target="_blank" rel="noreferrer">Open the page</a>
          ) : (field.options ?? []).length ? (
            <select value={String(values[field.key] ?? "")} onChange={event => set(field.key, event.target.value)}>
              {!field.required ? <option value="">—</option> : null}
              {(field.options ?? []).map(option => <option key={option.value} value={option.value}>{option.label ?? option.value}</option>)}
            </select>
          ) : (
            <input type="text" placeholder={field.placeholder ?? ""} value={String(values[field.key] ?? "")} onChange={event => set(field.key, event.target.value)} />
          )}
          {field.description ? <div className="where">{field.description}</div> : null}
        </div>
      ))}
      <div className="ask-buttons">
        <button className="primary" onClick={() => void replyForm(form, values)}>Answer</button>
        <button className="danger" onClick={() => void dismissForm(form)}>Skip</button>
      </div>
    </div>
  );
}

// ---- The header ----

/// The Mac's context ring, in a card's header (the same figures as before) — the
/// conversation's own card and the split's each take one, over their own session.
function ContextGauge({ session = state.session }: { session?: SessionSummary | null }) {
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
function CardHeader({ session, folder, tooltip, children }: {
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

function Header() {
  const showingSettings = state.settingsOpen;
  const running = state.engine?.status === "running";
  const branch = state.vcs?.branch?.current;
  const sidebarOpen = state.sidebarOpen !== false;
  const folder = state.project ? state.project.replace(/[\\/]+$/, "").split(/[\\/]/).pop() ?? "" : "";
  const engineText = running ? `engine ${state.engine?.version ?? ""}`.trim() : state.engine?.status ?? "…";
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
              onClick={() => { state.sidebarOpen = !sidebarOpen; render(); }}
            >
              <svg viewBox="0 0 16 16" width="14" height="14" fill="none" aria-hidden="true">
                <rect x="2.2" y="3" width="11.6" height="10" rx="2" stroke="currentColor" strokeWidth="1.2" />
                <path d="M6.3 3v10" stroke="currentColor" strokeWidth="1.2" />
              </svg>
            </button>
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
function SessionTabs() {
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
async function openBeside(id: string) {
  if (!id || id === state.session?.id) return;
  state.split = id;
  await openSplit(id);
  render();
}

async function toggleSplit() {
  const other = state.openSessions.find(id => id !== state.session?.id) ?? state.sessions.find(s => s.id !== state.session?.id)?.id;
  if (state.split) { state.split = null; render(); return; }
  if (!other) return;
  await openBeside(other);
}

/// The Mac's Swap (MainView.swift:743-747): the session in view and the one beside it
/// exchange places.
function swapSplit() {
  const other = state.split;
  const main = state.session?.id;
  if (!other || !main || other === main) return;
  state.split = main;
  void openSplit(main);
  void openSession(other);
}

/// The session beside the one in view: the list's own row for it, or its id alone — the
/// Mac's split card titles itself from its session (MainView.swift:735), not from a picker.
function splitSession(): SessionSummary | null {
  if (!state.split) return null;
  const found = [...state.sessions, ...Object.values(state.sessionsByProject).flat()].find(s => s.id === state.split);
  return found ?? { id: state.split, title: null };
}

/// The split card's own head: the Mac draws the split as a card with the very header the
/// conversation's card has (MainView.swift:733-754) — its session's name over the
/// project, its ring, and Swap and Close. No strip of controls, nothing that could pass
/// for the window's title bar above.
function SplitHeader() {
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
function SplitEntries() {
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

// ---- The sidebar ----

/// The name of a folder, as the Mac's project row shows it.
function folderName(path: string) {
  const name = path.replace(/[/\\]+$/, "").split(/[/\\]+/).pop() ?? path;
  return name || path;
}

/// A menu, where the Mac has one (RightClickMenu.swift:4-65): the items, and the place
/// it was asked for. The Mac's menus are the system's own, and they carry what a menu
/// carries: a line between groups, an item that cannot be chosen, and the one that undoes.
function ContextMenu({ x, y, items, onClose }: {
  x: number;
  y: number;
  items: { label: string; run?: () => void; disabled?: boolean; danger?: boolean; separator?: boolean }[];
  onClose: () => void;
}) {
  return (
    <div className="context-menu" style={{ left: x, top: y }} role="menu" onMouseLeave={onClose}>
      {items.map((item, index) => item.separator ? (
        <hr key={`separator_${index}`} className="menu-separator" role="separator" />
      ) : (
        <button
          key={item.label}
          role="menuitem"
          disabled={item.disabled}
          className={item.danger ? "danger" : undefined}
          onClick={() => { onClose(); item.run?.(); }}
        >{item.label}</button>
      ))}
    </div>
  );
}

/// The Mac's section heading (SidebarView.swift:1039-1088): the title, a chevron that
/// folds the section away, and what the section has on the right.
function SectionHeader({ title, folded, onToggle, action }: { title: string; folded: boolean; onToggle: () => void; action?: React.ReactNode }) {
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

function Sidebar() {
  const archived = (session: SessionSummary) => Boolean(session.time?.archived) || session.metadata?.["kuvo.archived"] === true;
  const query = state.sessionQuery.trim().toLowerCase();
  // A session being renamed, in its row where Rename was chosen (SidebarView.swift:41-52),
  // and the rows' own menus, which are where the Mac offers it (SidebarView.swift:586).
  const [renaming, setRenaming] = useState<string | null>(null);
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
          <button className="session" data-id={session.id} onClick={() => { state.settingsOpen = false; void openSession(session.id); }}>
            <span className="session-title">{session.title || "New Session"}</span>
            {running || unread ? <span className={`session-state ${running ? "running" : "unread"}`} aria-hidden="true" /> : null}
          </button>
        )}
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
        <button className="session-delete" title="Delete this session" aria-label="Delete this session" onClick={() => void deleteSession(session)}>
          <Symbol name="xmark" size={10} />
        </button>
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
                <span className="project-name">{folderName(folder)}</span>
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
              { label: "Delete…", danger: true, run: () => { if (found) void deleteSession(found); } },
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
function paneLayoutNow() {
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
function PaneResizer({ pane }: { pane: "sessions" | "split" | "changes" }) {
  const [dragging, setDragging] = useState(false);
  const start = useRef({ x: 0, width: 0 });
  const range = paneRanges[pane];
  const asked = () => (pane === "sessions" ? state.sessionsWidth : pane === "split" ? state.splitWidth : state.changesWidth);
  return (
    <div
      className={`pane-resizer ${pane} ${dragging ? "dragging" : ""}`}
      title="Drag to resize"
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

/// What was said, in every session: the one sidebar search looks in the titles and in the
/// conversations, the way the Mac app's does (SidebarView.swift:84-112).
function MessageSearch({ query }: { query: string }) {
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
            <div className="where" key={index} onClick={() => void openSession(match.session.id)}>{hit.snippet}</div>
          ))}
        </div>
      ))}
    </div>
  );
}

// ---- The composer ----

type Mention = { kind: "files" | "commands"; name: string; path?: string; relative?: string; description?: string };

function Composer() {
  const [text, setText] = useState("");
  // The models the user keeps: the Mac's starred models (ModelPicker.swift:40).
  const [favorites, setFavorites] = useState(favoriteModels);
  // The approval as it stands: the tools run without asking, or they wait for an OK
  // (the Mac's ToolApproval, ComposerMenus.swift:6-26).
  const [approvalShown, setApprovalShown] = useState<Approval>(approval);
  const [files, setFiles] = useState<Attachment[]>([]);
  const [mentions, setMentions] = useState<Mention[]>([]);
  const [queueOpen, setQueueOpen] = useState(false);
  // Where you are in the messages you have already sent (null: writing a new one).
  const [historyAt, setHistoryAt] = useState<number | null>(null);
  const [mentionIndex, setMentionIndex] = useState(0);
  const promptRef = useRef<HTMLTextAreaElement>(null);
  const allFiles = useRef<{ path: string; name: string; relative: string }[]>([]);

  // The draft: what is typed but not sent, kept per session, across launches — the Mac's
  // drafts. A message that could not be sent is back in the box, the same way.
  const sessionKey = draftKey(state.session?.id ?? null, state.project);
  const [draftFor, setDraftFor] = useState<string | null>(null);
  // The session the files in the box were picked for: a file picked before the session
  // was in view is the user's, and the draft of another session does not take it away.
  const pickedFor = useRef<string | null>(null);
  useEffect(() => {
    const draft = readDraft(localStorage, sessionKey);
    setText(draft?.text ?? "");
    setFiles(current => {
      if (pickedFor.current !== null && pickedFor.current !== sessionKey) return (draft?.files ?? []) as Attachment[];
      pickedFor.current = sessionKey;
      return current;
    });
    setMentions([]);
    setDraftFor(sessionKey);
  }, [sessionKey]);
  useEffect(() => {
    if (draftFor !== sessionKey) return;
    const timer = setTimeout(() => saveDraft(localStorage, sessionKey, { text, files }), 500);
    return () => clearTimeout(timer);
  }, [text, files, sessionKey, draftFor]);

  // What the typing is asking for: a file (@) or a command (/).
  const complete = async (value: string, caret: number) => {
    const upTo = value.slice(0, caret);
    const at = upTo.match(/(?:^|\s)@([^\s@]*)$/);
    const slash = !at ? upTo.match(/^\/(\w*)$/) : null;
    if (!at && !slash) { setMentions([]); return; }
    if (at) {
      const query = at[1].toLowerCase();
      if (!query) {
        const answer = await api<{ files: { path: string; name: string; relative: string }[] }>("/api/files").catch(() => null);
        const list = answer?.files ?? [];
        allFiles.current = list;
        setMentions(list.slice(0, 12).map(file => ({ kind: "files", name: file.name, path: file.path, relative: file.relative })));
        return;
      }
      const answer = await api<{ files: { path: string; name: string; relative: string }[] }>(`/api/files?q=${encodeURIComponent(query)}`).catch(() => null);
      const found = answer?.files ?? [];
      const local = allFiles.current.filter(file => file.relative.toLowerCase().includes(query)).slice(0, 12);
      const merged = [...found, ...local.filter(file => !found.some(f => f.path === file.path))].slice(0, 12);
      setMentions(merged.map(file => ({ kind: "files", name: file.name, path: file.path, relative: file.relative })));
      return;
    }
    const query = slash![1].toLowerCase();
    const items = state.commands.filter(command => query === "" || command.name.toLowerCase().startsWith(query)).slice(0, 12);
    setMentions(items.map(command => ({ kind: "commands", name: command.name, description: command.description })));
  };

  const chooseMention = (item: Mention) => {
    const box = promptRef.current;
    if (!box) return;
    const caret = box.selectionStart ?? box.value.length;
    if (item.kind === "files") {
      const before = box.value.slice(0, caret).replace(/@[^\s@]*$/, `@${item.relative} `);
      const next = before + box.value.slice(caret);
      setText(next);
      setMentions([]);
      requestAnimationFrame(() => {
        const at = caret;
        box.focus();
        box.setSelectionRange(at + (item.relative?.length ?? 0) + 2, at + (item.relative?.length ?? 0) + 2);
      });
      return;
    }
    setText(`/${item.name} `);
    setMentions([]);
    requestAnimationFrame(() => box.focus());
  };

  useEffect(() => {
    const draft = localStorage.getItem("kuvo-undo-draft");
    if (draft) { setText(draft); localStorage.removeItem("kuvo-undo-draft"); }
  }, []);

  // A passage quoted from the answer comes to the composer, the Mac app's way: it sits
  // in a card over the composer until it is sent or dropped (Quoting.swift, QuoteViews).
  const [quote, setQuote] = useState<string | null>(null);
  useEffect(() => {
    if (!state.quote) return;
    setQuote(state.quote);
    state.quote = undefined;
    promptRef.current?.focus();
  }, [state.quote]);

  const queueItems = [
    ...state.inbox.map(item => ({ id: item.id, text: item.payload?.text ?? "", delivery: item.delivery })),
    ...(state.transcript?.pending ?? []).filter(item => !state.inbox.some(inboxItem => inboxItem.id === item.id)),
  ];

  const submit = async (event: React.FormEvent, delivery: "steer" | "queue" = "steer") => {
    event.preventDefault();
    if (!text.trim() && !files.length) return;
    // The notes on the changes go with the message, the way the Mac app sends them.
    const notes = state.lineComments ?? [];
    const withNotes = notes.length
      ? `${text}\n\n${notes.map(note => `On ${note.file} (line ${note.line + 1}): ${note.text}`).join("\n")}`
      : text;
    // The quote you are answering goes first, as a block, and your words after it
    // (Quoting.message).
    const sent = quote
      ? `${quote.trim().split("\n").map(line => (line ? `> ${line}` : ">")).join("\n")}\n\n${withNotes}`
      : withNotes;
    setText("");
    setFiles([]);
    setQuote(null);
    state.lineComments = [];
    const sent_ = await sendPrompt(sent, files, delivery);
    // A message that did not go is back in the box, the Mac's way.
    if (!sent_) {
      setText(sent);
      setFiles(files);
    }
    render();
  };

  return (
    <form
      id="composer"
      className="composer"
      hidden={!state.session}
      onSubmit={submit}
      onDragOver={event => { event.preventDefault(); event.currentTarget.classList.add("dropping"); }}
      onDragLeave={event => event.currentTarget.classList.remove("dropping")}
      onDrop={async event => {
        event.preventDefault();
        event.currentTarget.classList.remove("dropping");
        const picked: Attachment[] = [];
        for (const file of Array.from(event.dataTransfer?.files ?? [])) {
          const data = await new Promise<string>(resolve => {
            const reader = new FileReader();
            reader.onload = () => resolve(String(reader.result).split(",")[1] ?? "");
            reader.readAsDataURL(file);
          });
          picked.push({ name: file.name, mime: file.type, data });
        }
        if (picked.length) {
          pickedFor.current = sessionKey;
          setFiles(current => [...current, ...picked]);
        }
      }}
    >
      <button id="redo" className="small" type="button" hidden={!state.revert} title="Redo" onClick={() => void redoNow()}>Redo</button>
      <div id="queue-dock" className={`queue-dock ${queueOpen ? "open" : ""}`} hidden={queueItems.length === 0}>
        {!queueOpen ? null : queueItems.map(item => (
          <div className="queue-item" key={item.id}>
            <span className="queue-text">{item.text || "(attachment only)"}</span>
            <button
              className="small"
              title={`Turn into ${item.delivery === "queue" ? "steering" : "queued"}`}
              onClick={async () => {
                const next = item.delivery === "queue" ? "steer" : "queue";
                try {
                  await api(`/api/sessions/${encodeURIComponent(state.session!.id)}/inbox/${encodeURIComponent(item.id)}`, { method: "PATCH", body: { delivery: next } });
                  await loadInbox();
                } catch (error) { complain(error); }
              }}
            >
              {item.delivery === "queue" ? "queued" : "steer"}
            </button>
            <button
              className="small"
              title="Take it back"
              onClick={async () => {
                try {
                  await api(`/api/sessions/${encodeURIComponent(state.session!.id)}/inbox/${encodeURIComponent(item.id)}`, { method: "DELETE" });
                  await loadInbox();
                } catch (error) { complain(error); }
              }}
            >
              <Symbol name="xmark" size={10} />
            </button>
          </div>
        ))}
        <button className="small" title={queueOpen ? "Fold the queue away" : "Queue for After This Run"} onClick={() => { setQueueOpen(open => !open); render(); }}>
          <Symbol name={queueOpen ? "arrow.up" : "arrow.down"} size={12} /> {queueItems.length} waiting
        </button>
      </div>
      {quote ? (
        <div className="quote-card">
          <span className="quote-bar" aria-hidden="true" />
          <div className="quote-body">
            <span className="quote-label">Replying to</span>
            <span className="quote-text">{quote}</span>
          </div>
          <button
            className="titlebar-icon"
            title="Drop the quote"
            aria-label="Don’t Reply to This"
            onClick={() => setQuote(null)}
          >
            <Symbol name="xmark" size={11} />
          </button>
        </div>
      ) : null}
      <div id="autocomplete" className="autocomplete" hidden={mentions.length === 0}>
        {mentions.map((item, index) => (
          <div
            key={`${item.kind}-${item.path ?? item.name}`}
            className={`mention-item ${index === mentionIndex ? "selected" : ""}`}
            onMouseDown={event => { event.preventDefault(); chooseMention(item); }}
          >
            <span className="mention-name">{item.kind === "files" ? item.name : `/${item.name}`}</span>
            <span className="where">{item.kind === "files" ? item.relative : item.description ?? ""}</span>
          </div>
        ))}
      </div>
      <div id="attachments" className="attachments" hidden={files.length === 0}>
        {files.map((file, index) => (
          <span className="attachment-chip" key={index}>
            {file.name}
            <button className="remove-button" type="button" title="Remove this file" aria-label="Remove this file" onClick={() => setFiles(current => current.filter((_, i) => i !== index))}>
              <Symbol name="xmark" size={10} />
            </button>
          </span>
        ))}
      </div>
      <textarea
        id="prompt"
        rows={3}
        ref={promptRef}
        placeholder={state.transcript?.running ? "Send while it works — delivered at its next step…" : "Ask for something…  (@ mentions a file, / runs a command)"}
        value={text}
        onChange={event => {
          const box = event.currentTarget;
          setText(box.value);
          setHistoryAt(null);
          setMentionIndex(0);
          void complete(box.value, box.selectionStart ?? box.value.length);
        }}
        onClick={event => {
          const box = event.currentTarget;
          void complete(box.value, box.selectionStart ?? box.value.length);
        }}
        onKeyDown={event => {
          // The composer's history: up and down walk what you have already sent, as in a
          // shell (Composer.swift:22-24) — with the composer empty, and with no mention
          // list open.
          if (!mentions.length && !text && (event.key === "ArrowUp" || event.key === "ArrowDown")) {
            const sent = (state.transcript?.entries ?? [])
              .filter(entry => entry.kind === "user")
              .map(entry => entry.text ?? "")
              .filter(Boolean);
            if (!sent.length) return;
            event.preventDefault();
            const at = historyAt;
            const next = event.key === "ArrowUp"
              ? (at === null ? sent.length - 1 : Math.max(0, at - 1))
              : (at === null ? null : at + 1 >= sent.length ? null : at + 1);
            setHistoryAt(next);
            const value = next === null ? "" : sent[next];
            setText(value);
            requestAnimationFrame(() => {
              const box = promptRef.current;
              if (!box) return;
              box.setSelectionRange(value.length, value.length);
            });
            return;
          }
          if (mentions.length && ["ArrowDown", "ArrowUp", "Enter", "Escape"].includes(event.key)) {
            // A key the page has already handled (the palette's own Escape) stops here.
      if (event.defaultPrevented) return;
      if (event.key === "Escape") { setMentions([]); return; }
            if (event.key === "ArrowDown") { event.preventDefault(); setMentionIndex(index => (index + 1) % mentions.length); return; }
            if (event.key === "ArrowUp") { event.preventDefault(); setMentionIndex(index => (index - 1 + mentions.length) % mentions.length); return; }
            // A chord belongs to the composer itself (⌘Return queues), so the mention is
            // only taken when the key is pressed plain.
            if (event.key === "Enter" && !event.ctrlKey && !event.metaKey && !event.altKey) {
              event.preventDefault();
              chooseMention(mentions[mentionIndex]);
              return;
            }
          }
          if (event.key !== "Enter") return;
          // Return sends; Shift-Return starts a new line; Ctrl-Return queues.
          if (matchesEvent(keysOf("queue"), event)) {
            event.preventDefault();
            void submit(event as unknown as React.FormEvent, "queue");
            return;
          }
          if (matchesEvent(keysOf("newline"), event)) return;
          if (matchesEvent(keysOf("send"), event)) {
            event.preventDefault();
            void submit(event as unknown as React.FormEvent);
          }
        }}
      />
      <div className="composer-foot">
        <button id="attach" type="button" className="small icon" title="Attach Files… You can also drop files here, or paste them." aria-label="Attach Files">
          {/* A paperclip, drawn — one stroke, the same weight as the app's other marks. */}
          <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <path d="M10.6 4.3 5.2 9.7a1.6 1.6 0 0 0 2.3 2.3l5.5-5.5a3 3 0 0 0-4.2-4.2L3 8.3a4.4 4.4 0 0 0 6.2 6.2l4.3-4.3" />
          </svg>
        </button>
        <Choice
          id="agent"
          title="Agent"
          empty="Build"
          value={state.agent}
          onPick={async value => {
            // The Mac's mode menu holds the modes and the tool permissions
            // (ComposerMenus.swift:120-135: the modes, a line, then the permissions).
            if (value === "approveAll" || value === "askFirst") {
              setApprovalShown(value);
              await setApproval(value);
              return;
            }
            state.agent = value;
            render();
            if (!state.session || value === "") return;
            try {
              await api(`/api/sessions/${encodeURIComponent(state.session.id)}/agent`, { method: "POST", body: { agent: value } });
            } catch (error) { complain(error); }
          }}
          groups={[
            { name: "", items: state.agents.map(agent => ({ value: agent.id, label: agent.name ?? agent.id, detail: agent.mode })) },
            {
              name: "Tool Permissions",
              items: [
                { value: "approveAll", label: "Approve All", detail: "Runs tools without asking", checked: approvalShown === "approveAll" },
                { value: "askFirst", label: "Ask First", detail: "Asks before editing files or running commands", checked: approvalShown === "askFirst" },
              ],
            },
          ]}
        />
        <Choice
          id="model"
          title="Model"
          empty="The engine's choice"
          value={state.session?.model ? `${state.session.model.providerID}/${state.session.model.id}` : ""}
          onPick={async value => {
            if (!state.session) return;
            // The engine takes a Model.ref, not the picker's shorthand (OpenCodeKit's
            // OpenCodeAPI.swift:473-476): the provider, and the id exactly as the catalog
            // writes it — an id may hold slashes of its own.
            const slash = value.indexOf("/");
            if (slash < 1) return;
            const ref = { providerID: value.slice(0, slash), id: value.slice(slash + 1) };
            // The model picked last, so the next session starts with it (SessionView.swift:459-490).
            rememberModel(ref);
            const current = state.session;
            const previous = current.model ?? null;
            // The picker shows the model it now has, as the Mac's does (SessionModel.swift:
            // 1333-1341); a refusal puts the old one back and says why.
            current.model = ref;
            render();
            try {
              await api(`/api/sessions/${encodeURIComponent(current.id)}/model`, { method: "POST", body: { model: ref } });
            } catch (error) {
              current.model = previous;
              render();
              complain(error);
            }
          }}
          groups={[
            // The Mac's starred models first, in their own group (ModelPicker.swift:500,
            // 732-755): the models the user keeps, and the mark that keeps them.
            ...(favorites.length ? [{
              name: "Starred",
              items: favorites.map(model => ({
                value: `${model.providerID}/${model.id}`,
                label: state.models.find(known => known.providerID === model.providerID && known.id === model.id)?.name ?? model.id,
                logo: model.providerID,
                star: { on: true, toggle: () => { rememberFavorite(model, false); setFavorites(favoriteModels()); render(); } },
              })),
            }] : []),
            ...[...new Set(state.models.map(model => model.providerID))].map(provider => ({
              name: provider,
              items: state.models.filter(model => model.providerID === provider).map(model => ({
                value: `${model.providerID}/${model.id}`,
                label: model.name ?? model.id,
                detail: model.limit?.context ? `${Math.round(model.limit.context / 1000)}k` : undefined,
                logo: model.providerID,
                star: {
                  on: favorites.some(one => one.providerID === model.providerID && one.id === model.id),
                  toggle: () => {
                    rememberFavorite({ providerID: model.providerID, id: model.id }, !favorites.some(one => one.providerID === model.providerID && one.id === model.id));
                    setFavorites(favoriteModels());
                    render();
                  },
                },
              })),
            })),
          ]}
        />
        <div className="spacer" />
        <button id="stop" type="button" className="small" hidden={!state.transcript?.running} onClick={() => void stopRun()}>Stop</button>
        <button id="send" className="primary" type="submit">Send</button>
      </div>
      <input
        id="attach-input"
        type="file"
        multiple
        hidden
        onChange={async event => {
          const picked: Attachment[] = [];
          for (const file of Array.from(event.target.files ?? [])) {
            const data = await new Promise<string>(resolve => {
              const reader = new FileReader();
              reader.onload = () => resolve(String(reader.result).split(",")[1] ?? "");
              reader.readAsDataURL(file);
            });
            picked.push({ name: file.name, mime: file.type, data });
          }
          pickedFor.current = sessionKey;
          setFiles(current => [...current, ...picked]);
        }}
      />
    </form>
  );
}

/// An image, looked at: the Mac app's viewer, over the page. A click zooms it in,
/// a click again brings it back, Escape closes it.
function ImageViewer() {
  const viewing = state.viewing;
  const [zoomed, setZoomed] = useState(false);
  useEffect(() => { if (!viewing) setZoomed(false); }, [viewing]);
  useEffect(() => {
    if (!viewing) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") { state.viewing = null; render(); }
      if (event.key === "+" || event.key === "=") setZoomed(true);
      if (event.key === "-") setZoomed(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [viewing]);
  // The window under the viewer dims with it, and cannot be reached while it is open
  // (ImageViewer.swift:33-41).
  useEffect(() => {
    document.body.classList.toggle("viewing-image", Boolean(viewing));
    return () => document.body.classList.remove("viewing-image");
  }, [viewing]);
  return (
    <AnimatePresence>
      {viewing ? (
        <motion.div
          className="image-viewer"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0, transition: viewerClose }}
          transition={viewerFade}
          onClick={() => { state.viewing = null; render(); }}
        >
          <motion.img
            className={zoomed ? "zoomed" : ""}
            src={viewing.source}
            alt={viewing.name}
            // The picture comes in from 0.94 of its size (ImageViewer.swift:88).
            initial={{ scale: 0.94 }}
            animate={{ scale: 1 }}
            transition={viewerFade}
            onClick={event => event.stopPropagation()}
            onDoubleClick={event => { event.stopPropagation(); setZoomed(value => !value); }}
            title={zoomed ? "Double-click to bring it back" : "Double-click to zoom in"}
          />
          <div className="image-viewer-foot">{viewing.name}</div>
        </motion.div>
      ) : null}
    </AnimatePresence>
  );
}

/// What the app does with what it is told, said once.
function AnalyticsNotice() {
  const [open, setOpen] = useState(() => !localStorage.getItem("kuvo-analytics-ack"));
  if (!open) return null;
  return (
    <div id="analytics-notice" className="AnalyticsNotice">
      <div className="analytics-card">
        <div className="settings-title">Before you start</div>
        <p className="settings-note">Kuvo Code works entirely on this machine: the engine runs locally, its words go to the model provider you configured, and this app collects nothing and reports nothing anywhere. Close it and everything stops with it.</p>
        <button id="analytics-ok" className="primary" onClick={() => { localStorage.setItem("kuvo-analytics-ack", "1"); setOpen(false); }}>Understood</button>
      </div>
    </div>
  );
}

/// A choice, the Mac app's way: a button that opens a list you can search in.
function Choice({ id, title, groups, value, onPick, empty }: {
  id: string;
  title: string;
  groups: { name: string; items: { value: string; label: string; detail?: string; logo?: string; checked?: boolean; star?: { on: boolean; toggle: () => void } }[] }[];
  value: string;
  onPick: (value: string) => void;
  empty: string;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const needle = query.trim().toLowerCase();
  const shown = groups
    .map(group => ({
      name: group.name,
      items: group.items.filter(item => !needle || `${item.label} ${item.detail ?? ""} ${group.name}`.toLowerCase().includes(needle)),
    }))
    .filter(group => group.items.length > 0);
  const current = groups.flatMap(group => group.items).find(item => item.value === value);

  useEffect(() => {
    if (!open) return;
    const away = (event: MouseEvent) => {
      if (!(event.target as HTMLElement)?.closest(".choice")) { setOpen(false); setQuery(""); }
    };
    document.addEventListener("mousedown", away);
    return () => document.removeEventListener("mousedown", away);
  }, [open]);

  return (
    <span className="choice">
      <button id={id} className="choice-button" title={title} onClick={() => { setOpen(value => !value); setQuery(""); }}>
        {current?.label ?? empty}
        {/* The Mac's menu chevron: 8 pt, bold, in the secondary ink, after the label
            (Pressable.swift:192-198). */}
        <Symbol name="chevron.down" size={8} className="choice-chevron" />
      </button>
      {open ? (
        <span className="choice-panel">
          <input
            className="choice-search"
            placeholder={`Search ${title.toLowerCase()}…`}
            value={query}
            autoFocus
            onChange={event => setQuery(event.target.value)}
            onKeyDown={event => { if (event.key === "Escape") { setOpen(false); setQuery(""); } }}
          />
          <span className="choice-list">
            {shown.length === 0 ? <span className="where">Nothing matches.</span> : shown.map(group => (
              <span key={group.name}>
                {group.name ? <span className="choice-group">{group.name}</span> : null}
                {group.items.map(item => (
                  <button
                    key={item.value}
                    className={`choice-item ${item.checked || item.value === value ? "selected" : ""}`}
                    onClick={() => { onPick(item.value); setOpen(false); setQuery(""); }}
                  >
                    {item.logo ? <ProviderLogo id={item.logo} size={15} /> : null}
                    <span>{item.label}</span>
                    {item.detail ? <span className="where">{item.detail}</span> : null}
                    {item.star ? (
                      <span
                        className={`choice-star ${item.star.on ? "on" : ""}`}
                        role="button"
                        aria-label={item.star.on ? "Unstar this model" : "Star this model"}
                        title={item.star.on ? "Unstar" : "Star"}
                        onClick={event => { event.stopPropagation(); item.star?.toggle(); }}
                      >
                        <Symbol name="star" size={12} />
                      </span>
                    ) : null}
                  </button>
                ))}
              </span>
            ))}
          </span>
        </span>
      ) : null}
    </span>
  );
}

// ---- The app ----

/// What a shortcut does. The keys are the ones the user recorded, or the ones the app
/// ships with; the Mac's own list is the same, in the Mac's key names.
function runShortcut(id: string) {
  switch (id) {
    case "palette":
      state.paletteOpen = !state.paletteOpen;
      render();
      return;
    case "new-session":
      if (state.project) void newSession();
      return;
    case "save":
      void exportConversation();
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
      state.drawerOpen = true;
      state.drawerTab = "terminal";
      render();
      return;
    default:
      return;
  }
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
    kuvo?.onMenu?.(id => {
      if (id === "open-folder") { state.pickerOpen = true; render(); return; }
      runShortcut(id);
    });
  }, []);

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
      if (event.key === "Escape") {
        if ((document.activeElement as HTMLElement | null)?.id === "find") (document.activeElement as HTMLElement).blur();
        // Escape goes back one step, as it does on the Mac: the palette first, then the
        // settings, then the sheet that is open.
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
      <Picker />
      <Settings />
      <DiffModal />
      <Toast />
      <ImageViewer />
      <AnalyticsNotice />
      {!ready ? <div className="fatal">Starting…</div> : null}
    </>
  );
}

export { api, loadAgents, loadCommands, loadModels, loadProjects, saveConfig, notify, applyLook };
