// The conversation view, in React: sessions on the left, the transcript and the composer
// on the right. The engine's events keep the transcript current, as they always did.

import { useEffect, useRef, useState } from "react";
import { api } from "./api";
import type { Attachment, FormRequest, PermissionRequest, SessionSummary, Transcript, TranscriptEntry } from "./api";
import { fromHistory } from "../../harness/transcript.mjs";
import { brief, compactTokens, errorText, renderMarkdown } from "./lib";
import { isRecording, keysOf, matchesEvent, shortcutFor } from "./shortcuts";
import { draftKey, readDraft, saveDraft } from "./drafts.mjs";
import {
  answerPermission,
  applyLook,
  boot,
  closeSessionTab,
  complain,
  deleteSession,
  dismissForm,
  exportConversation,
  loadAgents,
  loadCommands,
  loadForms,
  loadInbox,
  loadLook,
  loadModels,
  loadProjects,
  loadSessionDiff,
  loadSessions,
  loadVcs,
  look,
  newSession,
  notify,
  openProjectFile,
  openSession,
  redoNow,
  render,
  replyForm,
  saveConfig,
  sendPrompt,
  state,
  stopRun,
  undoFromHere,
  useStore,
} from "./store";
import { Settings, settingsPageTitle } from "./Settings";
import { DiffModal, Drawer, Palette, Picker, Toast } from "./Overlays";
import { Shimmer } from "./components/ai-elements/shimmer";
import { motion } from "motion/react";
import { macSpringOrStill } from "./motion";

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
        <span className="tool-chevron">{hasDetails ? (open ? "▾" : "▸") : ""}</span>
        <span className="tool-name">{part.name ?? "tool"}</span>
        <span className="tool-status">{status === "completed" ? "done" : status === "error" ? "failed" : status}</span>
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
  if (!long || open) return <div className="text markdown" dangerouslySetInnerHTML={{ __html: renderMarkdown(text, files) }} />;
  const cut = text.slice(0, 700);
  const line = cut.lastIndexOf("\n", 700);
  return (
    <div className="text markdown">
      <div dangerouslySetInnerHTML={{ __html: renderMarkdown(cut.slice(0, line > 200 ? line : 700), files) }} />
      <button className="small long-more" onClick={() => setOpen(true)}>Show more</button>
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

const duration = (seconds: number) => {
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min`;
  return `${Math.round(minutes / 60)} h`;
};

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

/// The row itself: the summary, and each step when it is opened.
function StepsRow({ entry }: { entry: TranscriptEntry }) {
  const [open, setOpen] = useState(false);
  const summary = stepsSummary(entry);
  if (!summary) return null;
  const calls = (entry.parts ?? []).filter(part => part.type === "tool");
  return (
    <div className="steps-row">
      <button className="steps-summary" onClick={() => setOpen(value => !value)} title={open ? "Hide the steps" : "Show each step"}>
        <span className="where">{open ? "▾" : "▸"}</span>
        <span>{summary}</span>
      </button>
      {open ? (
        <ul className="steps-list">
          {calls.map((call, index) => (
            <li key={call.id ?? index}>
              <span className={call.status === "error" ? "entry-error" : ""}>{call.name ?? "tool"}</span>
              {call.status === "error" ? <span className="where"> · failed</span> : null}
            </li>
          ))}
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
        onClick={async () => {
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
        }}
      >
        Fork here
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

function EntryNodes({ transcript }: { transcript: Transcript }) {
  // The message that started the turn: what "Try Again" sends again.
  const lastMessage = [...transcript.entries].reverse().find(entry => entry.kind === "user")?.text ?? "";
  return (
    <>
      {transcript.entries.map((entry, index) => {
        const key = entry.id ?? `${entry.kind}-${index}`;
        if (entry.kind === "user") {
          return (
            <article key={key} className="entry user">
              <div className="text">{entry.text}</div>
              {(entry.files ?? []).map((file, i) => <AttachmentNode key={i} file={file} />)}
              {entry.id ? (
                <button className="small entry-action" title="Take the session back to before this message" onClick={() => void undoFromHere(entry)}>
                  Undo from here
                </button>
              ) : null}
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
                  ↺ Try Again
                </button>
              ) : null}
            </div>
          );
        }
        if (entry.kind === "idle" && entry.outcome === "interrupted") return <div key={key} className="notice">Stopped.</div>;
        return null;
      })}
      {transcript.pending.map(item => (
        <article key={item.id} className="entry user pending">
          <div className="text">{item.text}</div>
          {item.delivery === "queue" ? <div className="entry-meta">queued</div> : null}
        </article>
      ))}
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
        <button className="primary" onClick={() => void answerPermission(request, "once")}>Allow once</button>
        <button onClick={() => void answerPermission(request, "always")}>Always allow</button>
        <button className="danger" onClick={() => void answerPermission(request, "reject")}>Reject</button>
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

/// The Mac's context ring, in the conversation card's header (the same figures as before).
function ContextGauge() {
  const [gaugeOpen, setGaugeOpen] = useState(false);
  const total = state.session?.tokens?.total ?? 0;
  const model = state.models.find(item => state.session?.model && `${item.providerID}/${item.id}` === `${state.session.model.providerID}/${state.session.model.id}`);
  const limit = model?.limit?.context ?? 0;
  const fraction = limit > 0 ? Math.min(total / limit, 1) : null;
  return (
    <>
      <div
        id="context-gauge"
        className="context-gauge"
        hidden={!total}
        title="Context window used"
        onClick={event => { event.stopPropagation(); setGaugeOpen(open => !open); }}
      >
        {fraction !== null ? `${Math.round(fraction * 100)}%` : compactTokens(total)}
      </div>
      <div id="gauge-pop" className="gauge-pop" hidden={!gaugeOpen}>
        <div className="gauge-line big">
          {fraction !== null ? `${Math.round(fraction * 100)}% of the context window` : `${compactTokens(total)} tokens in the context window`}
        </div>
        {limit ? <div className="gauge-line">{`${compactTokens(total)} of ${compactTokens(limit)} tokens`}</div> : null}
        {typeof state.session?.cost === "number" ? <div className="gauge-line">{`Session cost so far: $${state.session.cost.toFixed(4)}`}</div> : null}
        {state.session?.model ? <div className="gauge-line faint">{`${state.session.model.providerID}/${state.session.model.id}`}</div> : null}
        <button
          className="small"
          title="Squeeze the conversation into a summary, like the Mac app's compact"
          onClick={async () => {
            if (!state.session) return;
            try {
              await api(`/api/sessions/${encodeURIComponent(state.session.id)}/compact`, { method: "POST", body: {} });
              setGaugeOpen(false);
              await openSession(state.session.id);
            } catch (error) { complain(error); }
          }}
        >
          Compact context
        </button>
      </div>
    </>
  );
}

/// The conversation card's 38 pt header: the session, its project, and the card's own
/// actions (Card.swift:91-124). The title bar above keeps the window's own controls.
function CardHeader() {
  const title = state.session?.title || "New Session";
  const folder = state.project ? state.project.replace(/[\\/]+$/, "").split(/[\\/]/).pop() ?? "" : "";
  return (
    <div className="card-header">
      <span className="card-icon" aria-hidden="true">
        <svg viewBox="0 0 16 16" width="16" height="16" fill="none">
          <path d="M2.75 3.25h10.5v6.9H8.1l-3.1 2.6v-2.6H2.75z" stroke="currentColor" strokeWidth="1.2" strokeLinejoin="round" />
        </svg>
      </span>
      <div className="card-title" title={state.project ?? undefined}>
        <span>{title}</span>
        {folder ? <span className="card-detail">{"\u00A0| "}{folder}</span> : null}
      </div>
      <div className="spacer" />
      <div className="card-actions">
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
      </div>
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
    <header className={`titlebar ${sidebarOpen ? "" : "sidebar-hidden"} ${showingSettings ? "showing-settings" : ""}`}>
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
            <div className="identity" title={state.project ?? "Choose a folder"}>
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
        <input
          id="find"
          className="file-search header-find"
          placeholder="Find in conversation…"
          spellCheck={false}
          value={state.findQuery}
          onChange={event => { state.findQuery = event.target.value; render(); }}
        />
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
            onClick={() => { state.settingsOpen = false; void openSession(id); }}
          >
            {active ? <motion.span className="tab-pill" layoutId="session-tab-pill" transition={macSpringOrStill(motionIsReduced())} /> : null}
            <span className="tab-icon" aria-hidden="true">
              <svg viewBox="0 0 16 16" width="10" height="10" fill="none">
                <path d="M2.7 3.4h10.6v6.7H8.2l-3.2 2.5v-2.5H2.7z" stroke="currentColor" strokeWidth="1.2" strokeLinejoin="round" />
              </svg>
              {status ? <span className={`tab-status ${status}`} /> : null}
            </span>
            <span className="tab-title">{title}</span>
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
    </div>
  );
}

/// The session the split pane shows, read as the main pane reads its own.
async function openSplit(id: string) {
  if (!id) return;
  if (state.transcripts.has(id)) return;
  try {
    const detail = await api<{ session: SessionSummary; messages: unknown[]; permissions: unknown[]; running: boolean }>(`/api/sessions/${encodeURIComponent(id)}`);
    state.transcripts.set(id, fromHistory(id, detail.messages as never[], detail.permissions as never[], detail.running));
  } catch (error) {
    complain(error);
  }
}

async function toggleSplit() {
  const other = state.openSessions.find(id => id !== state.session?.id) ?? state.sessions.find(s => s.id !== state.session?.id)?.id;
  if (state.split) { state.split = null; render(); return; }
  if (!other) return;
  state.split = other;
  await openSplit(other);
  render();
}

// ---- The sidebar ----

function Sidebar() {
  const archived = (session: SessionSummary) => Boolean(session.time?.archived) || session.metadata?.["kuvo.archived"] === true;
  const query = state.sessionQuery.trim().toLowerCase();
  const visible = state.sessions
    .filter(session => !archived(session))
    .filter(s => (query ? (s.title || "").toLowerCase().includes(query) : true));
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
      </label>
      <div className="sidebar-scroll">
      <ul id="sessions">
        {visible.map(session => {
          const running = state.session?.id === session.id && state.transcript?.running;
          const unread = Boolean(session.time?.idle && session.time?.viewed && session.time.idle > session.time.viewed && session.id !== state.session?.id);
          return (
            <li key={session.id} className={`${session.id === state.session?.id ? "current" : ""} ${unread ? "unread" : ""}`}>
              <button className="session" data-id={session.id} onClick={() => void openSession(session.id)}>
                <span className="session-title">{session.title || "New Session"}</span>
                {running || unread ? <span className={`session-state ${running ? "running" : "unread"}`} aria-hidden="true" /> : null}
              </button>
              <button
                className="session-delete"
                title="Put this session away (Settings › Archived sessions brings it back)"
                onClick={async () => {
                  try {
                    await api(`/api/sessions/${encodeURIComponent(session.id)}/archive`, { method: "POST", body: { archived: true } });
                    if (state.session?.id === session.id) { state.session = null; state.transcript = null; }
                    await loadSessions();
                  } catch (error) { complain(error); }
                }}
              >
                ⇩
              </button>
              <button className="session-delete" title="Delete this session" onClick={() => void deleteSession(session)}>✕</button>
            </li>
          );
        })}
      </ul>
      <MessageSearch query={state.sessionQuery} />
      </div>
      <div id="sessions-empty" className="aside-empty" hidden={state.sessions.length > 0 || query.length > 0}>No sessions yet.</div>
    </aside>
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
      {matches.length === 0 ? <div className="search-empty">No conversations match.</div> : null}
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
  const [files, setFiles] = useState<Attachment[]>([]);
  const [mentions, setMentions] = useState<Mention[]>([]);
  const [queueOpen, setQueueOpen] = useState(false);
  const [mentionIndex, setMentionIndex] = useState(0);
  const promptRef = useRef<HTMLTextAreaElement>(null);
  const allFiles = useRef<{ path: string; name: string; relative: string }[]>([]);

  // The draft: what is typed but not sent, kept per session, across launches — the Mac's
  // drafts. A message that could not be sent is back in the box, the same way.
  const sessionKey = draftKey(state.session?.id ?? null, state.project);
  const [draftFor, setDraftFor] = useState<string | null>(null);
  useEffect(() => {
    const draft = readDraft(localStorage, sessionKey);
    setText(draft?.text ?? "");
    setFiles((draft?.files ?? []) as Attachment[]);
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

  // A passage quoted from the answer comes to the composer, the Mac app's way.
  useEffect(() => {
    if (!state.quote) return;
    setText(current => (current ? `${current}\n\n> ${state.quote}\n` : `> ${state.quote}\n`));
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
    const sent = notes.length
      ? `${text}\n\n${notes.map(note => `On ${note.file} (line ${note.line + 1}): ${note.text}`).join("\n")}`
      : text;
    setText("");
    setFiles([]);
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
        if (picked.length) setFiles(current => [...current, ...picked]);
      }}
    >
      <button id="redo" className="small" type="button" hidden={!state.revert} title="Bring back what an undo took away" onClick={() => void redoNow()}>Redo</button>
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
              ✕
            </button>
          </div>
        ))}
        <button className="small" title={queueOpen ? "Fold the queue away" : "Show what is waiting"} onClick={() => { setQueueOpen(open => !open); render(); }}>
          {queueOpen ? "↑" : `↓ ${queueItems.length} waiting`}
        </button>
      </div>
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
            <button className="small" type="button" onClick={() => setFiles(current => current.filter((_, i) => i !== index))}>✕</button>
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
          setMentionIndex(0);
          void complete(box.value, box.selectionStart ?? box.value.length);
        }}
        onClick={event => {
          const box = event.currentTarget;
          void complete(box.value, box.selectionStart ?? box.value.length);
        }}
        onKeyDown={event => {
          if (mentions.length && ["ArrowDown", "ArrowUp", "Enter", "Escape"].includes(event.key)) {
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
        <button id="attach" type="button" className="small icon" title="Attach files (also by dropping them here)" aria-label="Attach files">
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
            state.agent = value;
            render();
            if (!state.session || value === "") return;
            try {
              await api(`/api/sessions/${encodeURIComponent(state.session.id)}/agent`, { method: "POST", body: { agent: value } });
            } catch (error) { complain(error); }
          }}
          groups={[{ name: "", items: state.agents.map(agent => ({ value: agent.id, label: agent.name ?? agent.id, detail: agent.mode })) }]}
        />
        <Choice
          id="model"
          title="Model"
          empty="The engine's choice"
          value={state.session?.model ? `${state.session.model.providerID}/${state.session.model.id}` : ""}
          onPick={async value => {
            if (!state.session) return;
            try {
              await api(`/api/sessions/${encodeURIComponent(state.session.id)}/model`, { method: "POST", body: { model: value } });
            } catch (error) { complain(error); }
          }}
          groups={[
            { name: "", items: [{ value: "", label: "The engine's choice" }] },
            ...[...new Set(state.models.map(model => model.providerID))].map(provider => ({
              name: provider,
              items: state.models.filter(model => model.providerID === provider).map(model => ({
                value: `${model.providerID}/${model.id}`,
                label: model.name ?? model.id,
                detail: model.limit?.context ? `${Math.round(model.limit.context / 1000)}k` : undefined,
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
  if (!viewing) return null;
  return (
    <div className="image-viewer" onClick={() => { state.viewing = null; render(); }}>
      <img
        className={zoomed ? "zoomed" : ""}
        src={viewing.source}
        alt={viewing.name}
        onClick={event => { event.stopPropagation(); setZoomed(value => !value); }}
        title={zoomed ? "Click to bring it back" : "Click to zoom in"}
      />
      <div className="image-viewer-foot">{viewing.name}</div>
    </div>
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
  groups: { name: string; items: { value: string; label: string; detail?: string }[] }[];
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
                    className={`choice-item ${item.value === value ? "selected" : ""}`}
                    onClick={() => { onPick(item.value); setOpen(false); setQuery(""); }}
                  >
                    <span>{item.label}</span>
                    {item.detail ? <span className="where">{item.detail}</span> : null}
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
      (document.getElementById("find") as HTMLInputElement | null)?.focus();
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
        state.paletteOpen = false;
        state.settingsOpen = false;
        state.diffOpen = false;
        render();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const hasSession = state.session !== null;
  const needsFolder = state.project === null;
  const inShell = new URLSearchParams(window.location.search).get("shell") === "1";

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

  return (
    <>
      <Header />
      <main className={state.sidebarOpen === false ? "sidebar-hidden" : ""}>
        <Sidebar />
        <section id="conversation" className="card conversation-card">
          <div className="card-fade" aria-hidden="true" />
          <CardHeader />
          <div id="empty" className="empty" hidden={hasSession}>
            <h1>{needsFolder ? "Start with a folder" : "A session to work in"}</h1>
            <p>
              {needsFolder
                ? "Pick the project to work in, then say what you want done. The agent reads, edits and runs things in that folder, asking first."
                : "Sessions live in the folder you picked. Start one, then say what you want done in it."}
            </p>
            <button id="choose" className="primary" hidden={!needsFolder} onClick={() => { state.pickerOpen = true; render(); }}>Choose a folder</button>
            <button id="start" className="primary" hidden={needsFolder} onClick={() => void newSession()}>Start a session</button>
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
            {state.transcript ? <EntryNodes transcript={state.transcript} /> : null}
          </div>
          <button
            id="jump-latest"
            className="small"
            hidden={!showLatest}
            title="Go to the latest words"
            onClick={() => { scrollToLatest(true); }}
          >
            ↓ Latest
          </button>
          <div id="asks" className="asks">
            {(state.transcript?.permissions ?? []).map(request => <PermissionCard key={request.id} request={request} />)}
          </div>
          <div id="forms" className="forms" hidden={state.forms.length === 0}>
            {state.forms.map(form => <FormCard key={form.id} form={form} />)}
          </div>
          <Composer />
        </section>
        <section id="split-pane" className="split-pane" hidden={!state.split}>
          <div className="split-head">
            <select
              id="split-session"
              title="The session shown here"
              value={state.split ?? ""}
              onChange={event => { state.split = event.target.value; void openSplit(event.target.value); render(); }}
            >
              {state.openSessions.map(id => {
                const session = state.sessions.find(s => s.id === id);
                return <option key={id} value={id}>{session?.title || id.slice(0, 8)}</option>;
              })}
            </select>
            <button id="split-close" className="small" onClick={() => { state.split = null; render(); }}>✕</button>
          </div>
          <div id="split-entries" className="entries">
            {state.split ? <EntryNodes transcript={state.transcripts.get(state.split) ?? { entries: [], pending: [], permissions: [], running: false }} /> : null}
          </div>
        </section>
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
