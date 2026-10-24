// Transcript components and helpers.

import { useEffect, useRef, useState } from "react";
import { api } from "./api";
import type { Attachment, FormRequest, PermissionRequest, SessionSummary, Transcript, TranscriptEntry } from "./api";
import { brief, errorText, renderMarkdown } from "./lib";
import { commentLocation, splitComments } from "./review-comments.mjs";
import {
  answerPermission,
  complain,
  dismissForm,
  loadSessions,
  openSession,
  replyForm,
  render,
  sendPrompt,
  state,
  undoFromHere,
  useStore,
  look,
} from "./store";
import { ContextMenu } from "./components/context-menu";
import { Spinner } from "./components/spinner";
import { Symbol } from "./components/symbols";
import { toolDiffStat, toolSummary, toolSymbol } from "./components/tool-call";
import { Shimmer } from "./components/ai-elements/shimmer";
import { motionIsReduced, duration, stepKind, stepPhrase, entryText, countOf } from "./app-shared";


export function ToolCard({ part }: { part: TranscriptEntry["parts"] extends (infer P)[] | undefined ? P : never }) {
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
export function LongText({ text }: { text: string }) {
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



export function stepsSummary(entry: TranscriptEntry): string {
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
export function WorkingLine({ transcript }: { transcript: Transcript }) {
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
export function FindBar() {
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


/// A message you sent: the words, and the comments on the changes that went with them
/// (AgentReferences.swift:170-179, YourMessage.swift:22, 829-831).
export function UserWords({ text }: { text: string }) {
  const { text: words, comments } = splitComments(text);
  return (
    <>
      {comments.map((one, index) => (
        <div className="comment-reference" key={index}>
          <div className="comment-reference-place">
            <Symbol name="text.bubble" size={11} />
            <span>{commentLocation(one)}</span>
          </div>
          {one.snippet ? (
            <div className={`comment-reference-snippet ${one.side === "old" ? "removed" : "added"}`}>
              {one.snippet}
            </div>
          ) : null}
          <div className="comment-reference-text">{one.text}</div>
        </div>
      ))}
      <div className="text">{words}</div>
    </>
  );
}


/// The row itself: the summary, and each step when it is opened.
export function StepsRow({ entry }: { entry: TranscriptEntry }) {
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

export function AssistantEntry({ entry }: { entry: TranscriptEntry }) {
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

export function AttachmentNode({ file, pictures }: { file: Attachment; pictures?: Attachment[] }) {
  const fromData = file.data ? `data:${file.mime};base64,${file.data}` : null;
  const fromUri = file.uri ? `/api/raw?path=${encodeURIComponent(decodeURIComponent(String(file.uri).replace(/^file:\/\//, "")))}` : null;
  const source = fromData ?? fromUri;
  if (!source) return <span className="attachment-chip">{file.name ?? "file"}</span>;
  if ((file.mime ?? "").startsWith("image/")) {
    // The viewer opens on the picture, with the others of the same message beside it: the
    // Mac's viewer steps through them (ImageViewer.swift:22-26, 128-131).
    const items = (pictures ?? [file])
      .filter(other => (other.mime ?? "").startsWith("image/"))
      .map(other => ({
        source: other.data ? `data:${other.mime};base64,${other.data}` : (other.uri ? `/api/raw?path=${encodeURIComponent(decodeURIComponent(String(other.uri).replace(/^file:\/\//, "")))}` : ""),
        name: other.name ?? "image",
      }))
      .filter(other => other.source);
    const index = Math.max(0, items.findIndex(other => other.source === source));
    return (
      <img
        className="attachment-image"
        src={source}
        alt={file.name ?? "image"}
        onClick={() => { state.viewing = { items, index }; render(); }}
      />
    );
  }
  return <a className="attachment-chip" href={source} target="_blank" rel="noreferrer">{`${file.name ?? "file"} (${file.mime})`}</a>;
}

/// A conversation with nothing in it yet: the Mac's own mark over its own question about
/// the folder (TranscriptView.swift:69-75 overlays it while the rows are empty;
/// EmptyConversationView's `plain` form is drawn at TranscriptView.swift:1757-1767).
export function EmptyConversation({ directory }: { directory: string }) {
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

export function EntryNodes({ transcript }: { transcript: Transcript }) {
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
              <UserWords text={entry.text ?? ""} />
              {(entry.files ?? []).map((file, i) => <AttachmentNode key={i} file={file} pictures={entry.files} />)}
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
                      await navigator.clipboard?.writeText(entryText(entry)).catch(() => {});
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
          <UserWords text={item.text ?? ""} />
          {/* The picture you just sent is shown at once, as the Mac shows it. */}
          {(item.files ?? []).map((file, i) => <AttachmentNode key={i} file={file} pictures={item.files} />)}
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

export function PermissionCard({ request }: { request: PermissionRequest }) {
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

export function FormCard({ form }: { form: FormRequest }) {
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

