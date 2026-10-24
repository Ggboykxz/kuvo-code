// Composer and related components.

import { useEffect, useRef, useState } from "react";
import { keysOf, matchesEvent } from "./shortcuts";
import { api } from "./api";
import type { Attachment } from "./api";
import {
  approval,
  complain,
  favoriteModels,
  loadInbox,
  modelInView,
  rememberFavorite,
  rememberModel,
  render,
  redoNow,
  sendPrompt,
  setApproval,
  state,
  stopRun,
  type Approval,
} from "./store";
import { draftKey, readDraft, saveDraft } from "./drafts.mjs";
import { effortTitle } from "../../harness/models.mjs";
import { commentsText } from "./review-comments.mjs";
import { Symbol } from "./components/symbols";
import { ProviderLogo } from "./components/provider-logo";
import { AnimatePresence, motion } from "motion/react";
import { viewerClose, viewerFade } from "./motion";

export type Mention = { kind: "files" | "commands"; name: string; path?: string; relative?: string; description?: string };

export function Composer() {
  const [text, setText] = useState("");
  // The models the user keeps: the Mac's starred models (ModelPicker.swift:40).
  const [favorites, setFavorites] = useState(favoriteModels);
  // The model the conversation would use, and the levels it can be asked for: the
  // engine's own list of them (the Mac's startingModel, Catalog.swift:219-226).
  const model = modelInView();
  const effortLevels = model
    ? (state.models.find(known => known.providerID === model.providerID && known.id === model.id)?.variants ?? [])
    : [];
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

  // Something from the panel is added to what you are writing, as the Mac adds it
  // (MainView.swift:1239-1253): a space before it, and one after.
  useEffect(() => {
    if (!state.addition) return;
    const addition = state.addition;
    state.addition = undefined;
    setText(current => {
      const isBlock = addition.startsWith("```");
      let text = current;
      if (text !== "") {
        if (isBlock) { if (!text.endsWith("\n")) text += "\n"; }
        else if (!/\s$/.test(text)) text += " ";
      }
      return text + addition + (isBlock ? "\n" : " ");
    });
    promptRef.current?.focus();
  }, [state.addition]);

  const queueItems = [
    ...state.inbox.map(item => ({ id: item.id, text: item.payload?.text ?? "", delivery: item.delivery })),
    ...(state.transcript?.pending ?? []).filter(item => !state.inbox.some(inboxItem => inboxItem.id === item.id)),
  ];

  const submit = async (event: React.FormEvent, delivery: "steer" | "queue" = "steer") => {
    event.preventDefault();
    if (!text.trim() && !files.length) return;
    // The notes on the changes go with the message, in the block the Mac sends them in
    // (ReviewComments.swift:27-39).
    const notes = state.lineComments ?? [];
    const withNotes = notes.length ? commentsText(text, notes) : text;
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
          value={model ? `${model.providerID}/${model.id}` : ""}
          suffix={model?.variant ? effortTitle(model.variant) : undefined}
          onPick={async value => {
            if (!state.session) return;
            // The effort of the model in view: the same model, asked for at another level
            // (the Mac's card, ModelPicker.swift:567-614).
            if (value.startsWith("effort:")) {
              const current = state.session;
              if (!current.model) return;
              const level = value.slice("effort:".length);
              const ref = { ...current.model, variant: level === "default" ? undefined : level };
              const previous = current.model;
              current.model = ref;
              render();
              try {
                await api(`/api/sessions/${encodeURIComponent(current.id)}/model`, { method: "POST", body: { model: ref } });
              } catch (error) {
                current.model = previous;
                render();
                complain(error);
              }
              return;
            }
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
            // The effort of the model in view, the Mac's own levels (ModelPicker.swift:5-14,
            // 567-614): the model asked for at another level, and the level it has now.
            ...(effortLevels.length ? [{
              name: "Effort",
              items: effortLevels.map(level => ({
                value: `effort:${level.id}`,
                label: effortTitle(level.id),
                checked: state.session?.model?.variant === level.id,
              })),
            }] : []),
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
export function ImageViewer() {
  const viewing = state.viewing;
  const [zoomed, setZoomed] = useState(false);
  const items = viewing?.items ?? [];
  const index = viewing?.index ?? 0;
  const picture = items[index];
  const step = (by: number) => {
    if (!viewing) return;
    const next = index + by;
    if (next < 0 || next >= items.length) return;
    state.viewing = { items, index: next };
    setZoomed(false);
    render();
  };
  useEffect(() => { if (!viewing) setZoomed(false); }, [viewing]);
  useEffect(() => {
    if (!viewing) return;
    const onKey = (event: KeyboardEvent) => {
      // The Mac's own keys (ImageViewer.swift:146-158): Escape and space put it away, the
      // arrows step through the pictures, and ⌘C copies the one in view.
      if (event.key === "Escape" || event.key === " ") { state.viewing = null; render(); return; }
      if (event.key === "ArrowLeft") { step(-1); return; }
      if (event.key === "ArrowRight") { step(1); return; }
      if (event.key === "+" || event.key === "=") setZoomed(true);
      if (event.key === "-") setZoomed(false);
      if ((event.key === "c" || event.key === "C") && (event.ctrlKey || event.metaKey)) {
        void navigator.clipboard?.writeText(picture?.source ?? "").catch(() => {});
      }
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
            src={picture?.source}
            alt={picture?.name}
            // The picture comes in from 0.94 of its size (ImageViewer.swift:88).
            initial={{ scale: 0.94 }}
            animate={{ scale: 1 }}
            transition={viewerFade}
            onClick={event => event.stopPropagation()}
            onDoubleClick={event => { event.stopPropagation(); setZoomed(value => !value); }}
            title={zoomed ? "Double-click to bring it back" : "Double-click to zoom in"}
          />
          {/* The Mac's own header (ImageViewer.swift:164-197): the picture's name, how many
              there are, and what else can be done with it. */}
          <div className="image-viewer-head">
            <span className="image-viewer-title">{picture?.name}</span>
            {items.length > 1 ? <span className="where">{`${index + 1} of ${items.length}`}</span> : null}
            <span className="spacer" />
            <button
              className="card-action icon"
              title="Copy the picture (Ctrl+C)"
              aria-label="Copy the picture"
              onClick={event => { event.stopPropagation(); void navigator.clipboard?.writeText(picture?.source ?? "").catch(() => {}); }}
            >
              <Symbol name="doc.on.doc" size={13} />
            </button>
            <button
              className="card-action icon"
              title="Close (Esc)"
              aria-label="Close"
              onClick={event => { event.stopPropagation(); state.viewing = null; render(); }}
            >
              <Symbol name="xmark" size={13} />
            </button>
          </div>
          {/* And the arrows between the pictures of the same message (ImageViewer.swift:128-131,
              209-221). */}
          {items.length > 1 ? (
            <>
              <button
                className="image-viewer-step left"
                title="Previous (←)"
                aria-label="Previous picture"
                disabled={index <= 0}
                onClick={event => { event.stopPropagation(); step(-1); }}
              >
                <Symbol name="chevron.left" size={15} />
              </button>
              <button
                className="image-viewer-step right"
                title="Next (→)"
                aria-label="Next picture"
                disabled={index >= items.length - 1}
                onClick={event => { event.stopPropagation(); step(1); }}
              >
                <Symbol name="chevron.right" size={15} />
              </button>
            </>
          ) : null}
        </motion.div>
      ) : null}
    </AnimatePresence>
  );
}

/// What the app does with what it is told, said once.
export function AnalyticsNotice() {
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
export function Choice({ id, title, groups, value, onPick, empty, suffix }: {
  id: string;
  title: string;
  groups: { name: string; items: { value: string; label: string; detail?: string; logo?: string; checked?: boolean; star?: { on: boolean; toggle: () => void } }[] }[];
  value: string;
  onPick: (value: string) => void;
  empty: string;
  suffix?: string;
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
        {suffix ? <span className="choice-suffix">{suffix}</span> : null}
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


