// The conversation view: sessions on the left, the transcript and the composer on the
// right. Plain DOM, no framework; the engine's events keep the transcript current.

import { apply, emptyTranscript, fromHistory } from "/transcript.mjs";

const $ = id => document.getElementById(id);
const el = (tag, attrs = {}, ...children) => {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(attrs)) {
    if (value === undefined || value === null) continue;
    if (name === "class") node.className = value;
    else if (name === "text") node.textContent = value;
    else if (name === "html") node.innerHTML = value;
    else if (name.startsWith("on")) node.addEventListener(name.slice(2), value);
    else node.setAttribute(name, value);
  }
  for (const child of children) node.append(child);
  return node;
};

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: { "content-type": "application/json", ...options.headers },
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
  });
  const text = await response.text();
  const data = text === "" ? {} : JSON.parse(text);
  if (!response.ok) throw new Error(data.error ?? `HTTP ${response.status}`);
  return data;
}

/// Says what went wrong, in the page: a click that ends in a dead promise helps nobody.
// ---- Markdown (the Mac app renders markdown; so does this) ----

function sanitizeHtml(html) {
  // The engine's words can carry anything: keep the structure, drop the dangerous parts.
  const doc = new DOMParser().parseFromString(html, "text/html");
  doc.querySelectorAll("script, iframe, object, embed, link, meta, base, style").forEach(node => node.remove());
  doc.querySelectorAll("*").forEach(node => {
    [...node.attributes].forEach(attr => {
      if (attr.name.startsWith("on") || /^\s*javascript:/i.test(attr.value)) node.removeAttribute(attr.name);
    });
  });
  return doc.body.innerHTML;
}

function renderMarkdown(text) {
  if (typeof marked === "undefined") return escapeHtml(String(text));
  marked.setOptions({ breaks: true, gfm: true, highlight: (code, lang) => {
    if (lang && typeof hljs !== "undefined" && hljs.getLanguage(lang)) {
      try { return hljs.highlight(code, { language: lang }).value; } catch {}
    }
    if (typeof hljs !== "undefined") { try { return hljs.highlightAuto(code).value; } catch {} }
    return escapeHtml(code);
  } });
  const html = sanitizeHtml(marked.parse(String(text)));
  // A copy button on each code block, like the Mac app's CodeTextView.
  const doc = new DOMParser().parseFromString(html, "text/html");
  doc.querySelectorAll("pre").forEach(pre => {
    const button = document.createElement("button");
    button.className = "small code-copy";
    button.textContent = "Copy";
    button.addEventListener("click", () => {
      navigator.clipboard?.writeText(pre.querySelector("code")?.textContent ?? "").catch(() => {});
      button.textContent = "Copied";
      setTimeout(() => { button.textContent = "Copy"; }, 1200);
    });
    pre.style.position = "relative";
    pre.append(button);
  });
  return doc.body.innerHTML;
}

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char]));
}

function complain(where, error) {
  const message = error?.message ?? String(error);
  if (where) where.textContent = message;
  else alert(message);
}

function notify(title, body) {
  try {
    if (typeof Notification === "undefined") return;
    if (Notification.permission === "default") Notification.requestPermission().catch(() => {});
    if (Notification.permission === "granted") new Notification({ title, body }).show();
  } catch {}
}

const when = stamp => {
  if (!stamp) return "";
  const seconds = Math.round((Date.now() - stamp) / 1000);
  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.round(seconds / 60)} min ago`;
  if (seconds < 86_400) return `${Math.round(seconds / 3600)} h ago`;
  return new Date(stamp).toLocaleDateString();
};

const brief = (value, limit = 1600) => {
  let text;
  try {
    text = typeof value === "string" ? value : JSON.stringify(value, null, 2);
  } catch {
    text = String(value);
  }
  if (text === undefined) return "";
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
};

const errorText = error => {
  if (!error) return "";
  if (typeof error === "string") return error;
  return error.message ?? error.type ?? brief(error, 400);
};

const state = {
  project: null,
  engine: null,
  sessions: [],
  session: null,
  transcript: null,
  models: [],
  openFile: null,
  drawerTab: "files",
  eventSource: null,
  sessionQuery: "",
  openSessions: [],
  transcripts: new Map(),
  findQuery: "",
  agents: [],
  agent: "",
  split: null,
  commands: [],
  projects: [],
  shortcuts: null,
  contextGauge: null,
  inbox: [],
  vcs: null,
  sessionDiff: [],
  config: null,
  configPath: null,
  configProblem: null,
  configLive: null,
  opencode: null,
  mcpLive: [],
  skillsEngine: [],
  cfgEditor: null,
  forms: [],
  revert: null,
};

let renderQueued = false;
const render = () => {
  if (renderQueued) return;
  renderQueued = true;
  requestAnimationFrame(() => {
    renderQueued = false;
    renderHeader();
    renderSessions();
    renderConversation();
  });
};

// ---- Header ----

function renderHeader() {
  $("project").textContent = state.project ?? "choose a folder…";
  const engine = $("engine");
  const running = state.engine?.status === "running";
  engine.textContent = running ? `engine ${state.engine.version ?? ""}`.trim() : state.engine?.status ?? "…";
  engine.className = `engine ${running ? "up" : state.engine?.status === "starting" ? "starting" : "down"}`;
}

// ---- Sessions ----

function renderSessions() {
  const list = $("sessions");
  list.replaceChildren();
  $("sessions-empty").hidden = state.sessions.length > 0;
  const visibleSessions = state.sessionQuery ? state.sessions.filter(s => (s.title || "").toLowerCase().includes(state.sessionQuery)) : state.sessions;
  for (const session of visibleSessions) {
    const running = state.session?.id === session.id && state.transcript?.running;
    const unread = session.time?.idle && session.time?.viewed && session.time.idle > session.time.viewed && session.id !== state.session?.id;
    const item = el("li", { class: `${session.id === state.session?.id ? "current" : ""} ${unread ? "unread" : ""}` },
      el("button", { class: "session", "data-id": session.id, onclick: () => openSession(session.id) },
        el("span", { class: "session-title", text: session.title || "Untitled" }),
        el("span", { class: "session-sub", text: `${running ? "running · " : ""}${when(session.time?.updated)}` }),
      ),
      el("button", {
        class: "session-delete", title: "Delete this session", text: "✕",
        onclick: async () => {
          try {
            if (!confirm(`Delete “${session.title || "Untitled"}”?`)) return;
            await api(`/api/sessions/${encodeURIComponent(session.id)}`, { method: "DELETE" });
            if (state.session?.id === session.id) {
              state.session = null;
              state.transcript = null;
            }
            await loadSessions();
          } catch (error) {
            complain(null, error);
          }
        },
      }),
    );
    list.append(item);
  }
}

async function loadSessions() {
  if (!state.project) {
    state.sessions = [];
    return render();
  }
  const { sessions } = await api(`/api/sessions?directory=${encodeURIComponent(state.project)}`);
  state.sessions = sessions;
  render();
}

// ---- Conversation ----

function toolCard(part) {
  const status = part.status ?? "running";
  const card = el("div", { class: `tool ${status}` });
  card.append(el("div", { class: "tool-head" },
    el("span", { class: "tool-name", text: part.name ?? "tool" }),
    el("span", { class: "tool-status", text: status === "completed" ? "done" : status === "error" ? "failed" : status }),
  ));
  const input = brief(part.input ?? part.inputText);
  if (input) card.append(el("pre", { class: "tool-input", text: input }));
  const output = Array.isArray(part.output)
    ? part.output.map(item => item?.text ?? brief(item)).filter(Boolean).join("\n")
    : part.output === undefined ? "" : brief(part.output);
  if (output) card.append(el("pre", { class: "tool-output", text: output.length > 4000 ? `${output.slice(0, 4000)}…` : output }));
  if (part.error) card.append(el("div", { class: "tool-error", text: errorText(part.error) }));
  const lower = (part.name || "").toLowerCase();
  const hasDiff = lower.includes("edit") || lower.includes("write") || lower.includes("patch")
    || (part.input && (part.input.oldString || part.input.old || part.input.content));
  if (hasDiff) {
    const button = el("button", { class: "small", text: "diff" });
    button.addEventListener("click", () => {
      const input = part.input || {};
      const oldText = input.oldString ?? input.old ?? "";
      const newText = input.newString ?? input.new ?? input.content ?? part.output ?? "";
      showDiff(`${part.name || "tool"} · ${input.filePath || input.path || input.file || ""}`, oldText, newText);
    });
    card.append(button);
  }
  return card;
}

function assistantEntry(entry) {
  const block = el("article", { class: "entry assistant" });
  for (const part of entry.parts) {
    if (part.type === "text") { const div = el("div", { class: "text markdown" }); div.innerHTML = renderMarkdown(part.text); block.append(div); }
    else if (part.type === "reasoning") {
      const summary = el("summary", { text: "Thinking" });
      if (entry.running) summary.classList.add("shimmer");
      block.append(el("details", { class: "reasoning" },
        summary,
        el("div", { class: "text markdown", html: renderMarkdown(part.text) }),
      ));
    } else if (part.type === "tool") block.append(toolCard(part));
  }
  // Fork: a new session from the conversation up to here, like the Mac app's fork.
  const forkButton = el("button", { class: "small entry-action", text: "Fork here", onclick: async () => {
    if (!state.session) return;
    try {
      const { session: branched } = await api(`/api/sessions/${encodeURIComponent(state.session.id)}/fork`, { method: "POST", body: { before: entry.id } });
      state.transcripts.delete(branched.id);
      await loadSessions();
      await openSession(branched.id);
    } catch (error) { complain(null, error); }
  } });
  block.append(forkButton);
  if (entry.retry) block.append(el("div", { class: "entry-meta retry", text: `retrying${entry.retry.attempt ? ` (attempt ${entry.retry.attempt})` : ""}…` }));
  if (entry.error) block.append(el("div", { class: "entry-error", text: errorText(entry.error) }));
  if (entry.cost) block.append(el("div", { class: "entry-meta", text: `${entry.model ?? ""} · $${entry.cost.toFixed(4)}` }));
  return block;
}

function renderConversation() {
  const hasSession = state.session !== null;
  const tabs = $("session-tabs");
  tabs.hidden = state.openSessions.length < 2;
  tabs.innerHTML = "";
  for (const id of state.openSessions) {
    const session = state.sessions.find(s => s.id === id) || (state.session && state.session.id === id ? state.session : null);
    const title = session?.title || id.slice(0, 8);
    const tab = el("div", { class: `session-tab ${id === state.session?.id ? "active" : ""}` });
    const label = el("span", { text: title, onclick: () => openSession(id) });
    const close = el("span", { class: "close", text: "✕", onclick: (e) => { e.stopPropagation(); closeSessionTab(id); } });
    tab.append(label, close);
    tabs.append(tab);
  }
  $("composer").hidden = !hasSession;
  const empty = $("empty");
  empty.hidden = hasSession;
  if (!hasSession) {
    // Before a folder, ask for one; after, offer a session in it.
    const needsFolder = state.project === null;
    empty.querySelector("h1").textContent = needsFolder ? "Start with a folder" : "A session to work in";
    empty.querySelector("p").textContent = needsFolder
      ? "Pick the project to work in, then say what you want done. The agent reads, edits and runs things in that folder, asking first."
      : "Sessions live in the folder you picked. Start one, then say what you want done in it.";
    $("choose").hidden = !needsFolder;
    $("start").hidden = needsFolder;
  }
  if (!hasSession) {
    $("entries").replaceChildren();
    $("asks").replaceChildren();
    return;
  }

  $("entries").replaceChildren(...entryNodes(state.transcript));

  const asks = $("asks");
  asks.replaceChildren();
  for (const request of state.transcript.permissions) {
    asks.append(permissionCard(request));
  }

  $("stop").hidden = !state.transcript.running;
  $("prompt").placeholder = state.transcript.running ? "Send while it works — delivered at its next step…" : "Ask for something…  (@ mentions a file, / runs a command)";
  renderQueueDock();
  renderSplit();
}

// The conversation, as nodes — shared by the main pane and the split pane, like the
// Mac app renders each half of a split from the same entry views.
function entryNodes(transcript) {
  const rendered = [];
  for (const entry of transcript.entries) {
    if (entry.kind === "user") {
      const node = el("article", { class: "entry user" }, el("div", { class: "text", text: entry.text }));
      for (const file of entry.files ?? []) node.append(attachmentNode(file));
      if (entry.id) node.append(el("button", { class: "small entry-action", text: "Undo from here", title: "Take the session back to before this message", onclick: () => undoFromHere(entry) }));
      rendered.push(node);
    }
    else if (entry.kind === "assistant") rendered.push(assistantEntry(entry));
    else if (entry.kind === "notice") rendered.push(el("div", { class: "notice", text: entry.text }));
    else if (entry.kind === "shell") {
      rendered.push(el("div", { class: "shell" },
        el("pre", { text: `$ ${entry.command ?? ""}${entry.exit ? `  — exit ${entry.exit}` : ""}` }),
        entry.output ? el("pre", { class: "tool-output", text: entry.output }) : null,
      ));
    } else if (entry.kind === "idle" && entry.outcome === "failed") {
      rendered.push(el("div", { class: "entry-error", text: errorText(entry.error) || "The run failed." }));
    } else if (entry.kind === "idle" && entry.outcome === "interrupted") {
      rendered.push(el("div", { class: "notice", text: "Stopped." }));
    }
  }
  for (const item of transcript.pending) {
    rendered.push(el("article", { class: "entry user pending" },
      el("div", { class: "text", text: item.text }),
      item.delivery === "queue" ? el("div", { class: "entry-meta", text: "queued" }) : null,
    ));
  }
  return rendered;
}

// An attachment as the message history stores it: base64 data of its own, or a file
// reference the harness serves.
function attachmentNode(file) {
  const fromData = file.data ? `data:${file.mime};base64,${file.data}` : null;
  const fromUri = file.uri ? `/api/raw?path=${encodeURIComponent(decodeURIComponent(String(file.uri).replace(/^file:\/\//, "")))}` : null;
  const source = fromData ?? fromUri;
  if (!source) return el("span", { class: "attachment-chip", text: file.name ?? "file" });
  if ((file.mime ?? "").startsWith("image/")) {
    const img = el("img", { class: "attachment-image", src: source, alt: file.name ?? "image" });
    img.addEventListener("click", () => { window.open(source, "_blank"); });
    return img;
  }
  return el("a", { class: "attachment-chip", href: source, target: "_blank", text: `${file.name ?? "file"} (${file.mime})` });
}

// ---- The session's own changes (the files it edited, patches from the engine) ----

async function loadSessionDiff() {
  if (!state.session) { state.sessionDiff = []; $("changes").hidden = true; return; }
  try {
    const { diff } = await api(`/api/sessions/${encodeURIComponent(state.session.id)}/diff`);
    state.sessionDiff = Array.isArray(diff) ? diff : [];
  } catch {
    state.sessionDiff = [];
  }
  $("changes").hidden = state.sessionDiff.length === 0;
  $("changes").textContent = state.sessionDiff.length > 0 ? `Changes (${state.sessionDiff.length})` : "Changes";
  render();
}

function showSessionDiff() {
  const body = $("diff-body");
  body.innerHTML = "";
  if (!state.sessionDiff.length) return;
  for (const file of state.sessionDiff) {
    const head = el("div", { class: "diff-file" },
      el("strong", { text: file.file }),
      el("span", { class: "where", text: `+${file.additions ?? 0} −${file.deletions ?? 0}${file.status ? ` · ${file.status}` : ""}` }),
    );
    body.append(head);
    for (const line of String(file.patch ?? "").split("\n")) {
      if (line === "") continue;
      body.append(el("div", { class: line.startsWith("+") ? "add" : line.startsWith("-") ? "del" : "ctx", text: line }));
    }
  }
  $("diff-title").textContent = "Changes in this session";
  $("diff-modal").hidden = false;
}

$("changes").addEventListener("click", showSessionDiff);

// ---- Queue dock (the Mac app's QueueDock, backed by the engine's inbox) ----

async function loadInbox() {
  if (!state.session || !state.transcript) { state.inbox = []; return; }
  try {
    const { inbox } = await api(`/api/sessions/${encodeURIComponent(state.session.id)}/inbox`);
    state.inbox = Array.isArray(inbox) ? inbox : [];
  } catch {
    state.inbox = [];
  }
  // What the transcript knows that the engine's list doesn't (optimistic sends) stays.
  render();
}

async function toggleDelivery(item) {
  const next = item.delivery === "queue" ? "steer" : "queue";
  try {
    await api(`/api/sessions/${encodeURIComponent(state.session.id)}/inbox/${encodeURIComponent(item.id)}`, { method: "PATCH", body: { delivery: next } });
    await loadInbox();
  } catch (error) {
    complain(null, error);
  }
}

async function cancelInboxItem(item) {
  try {
    await api(`/api/sessions/${encodeURIComponent(state.session.id)}/inbox/${encodeURIComponent(item.id)}`, { method: "DELETE" });
    state.transcript.pending = state.transcript.pending.filter(what => what.id !== item.id);
    await loadInbox();
  } catch (error) {
    complain(null, error);
  }
}

function renderQueueDock() {
  const dock = $("queue-dock");
  const engineItems = state.inbox.map(item => ({ id: item.id, text: item.payload?.text ?? "", delivery: item.delivery, engine: true }));
  const localOnly = (state.transcript?.pending ?? []).filter(item => !state.inbox.some(inboxItem => inboxItem.id === item.id));
  const items = engineItems.concat(localOnly);
  dock.hidden = items.length === 0;
  if (items.length === 0) { dock.innerHTML = ""; return; }
  dock.innerHTML = "";
  const open = dock.classList.contains("open");
  for (const item of items) {
    if (!open && dock.querySelector(".queue-item")) continue;
    const row = el("div", { class: "queue-item" },
      el("span", { class: "queue-text", text: item.text || "(attachment only)" }),
    );
    const toggle = el("button", { class: "small", text: item.delivery === "queue" ? "queued" : "steer", title: `Turn into ${item.delivery === "queue" ? "steering" : "queued"}` });
    toggle.addEventListener("click", () => toggleDelivery(item));
    row.append(toggle,
      el("button", { class: "small", text: "✕", title: "Take it back", onclick: () => cancelInboxItem(item).catch(() => {}) }),
    );
    dock.append(row);
  }
  dock.append(el("button", { class: "small", text: open ? "↑" : `↓ ${items.length} waiting`, onclick: () => { dock.classList.toggle("open"); renderQueueDock(); } }));
}

// The agent switch is live: like the Mac app's selectAgent, the session turns right away.
$("agent").addEventListener("change", async event => {
  state.agent = event.target.value;
  if (!state.session || state.agent === "") return;
  try {
    await api(`/api/sessions/${encodeURIComponent(state.session.id)}/agent`, { method: "POST", body: { agent: state.agent } });
  } catch (error) {
    complain(null, error);
  }
});

// ---- Forms: the agent's question tool and MCP servers' questions, answered here ----

async function loadForms() {
  if (!state.session) { state.forms = []; renderForms(); return; }
  try {
    const { forms } = await api(`/api/sessions/${encodeURIComponent(state.session.id)}/forms`);
    state.forms = Array.isArray(forms) ? forms : [];
  } catch {
    state.forms = [];
  }
  renderForms();
}

function formInput(field) {
  const kind = field.type ?? "string";
  if (kind === "boolean") {
    const input = el("input", { type: "checkbox" });
    input.checked = field.default === true;
    return ["check", input];
  }
  if (kind === "number" || kind === "integer") {
    const input = el("input", { type: "number" });
    if (field.default != null) input.value = String(field.default);
    if (field.minimum != null) input.min = String(field.minimum);
    if (field.maximum != null) input.max = String(field.maximum);
    if (kind === "integer") input.step = "1";
    return ["number", input];
  }
  if (kind === "multiselect") {
    const box = el("div", { class: "form-choices" });
    for (const option of field.options ?? []) {
      const input = el("input", { type: "checkbox" });
      input.dataset.value = option.value;
      if ((field.default ?? []).includes(option.value)) input.checked = true;
      box.append(el("label", { class: "form-choice" }, input, el("span", { text: option.label ?? option.value })));
    }
    return ["list", box];
  }
  if (kind === "external") {
    const open = el("a", { href: field.url, target: "_blank", class: "small", text: "Open the page" });
    return ["external", open];
  }
  const options = field.options ?? [];
  if (options.length) {
    const select = el("select");
    if (!field.required) select.append(el("option", { value: "", text: "—" }));
    for (const option of options) select.append(el("option", { value: option.value, text: option.label ?? option.value }));
    if (field.default != null) select.value = field.default;
    return ["select", select];
  }
  const input = el("input", { type: "text", placeholder: field.placeholder ?? "" });
  if (field.default != null) input.value = field.default;
  return ["text", input];
}

function formCard(form) {
  const card = el("div", { class: "ask form" });
  card.append(el("div", { class: "ask-head" },
    el("strong", { text: form.title ?? "A question" }),
    form.metadata?.kind === "mcp-elicitation" ? el("span", { class: "where", text: form.metadata?.server ?? "an MCP server" }) : null,
  ));
  if (form.metadata?.message) card.append(el("div", { class: "ask-message", text: form.metadata.message }));
  const values = {};
  const inputs = [];
  for (const field of form.fields ?? []) {
    if (field.hidden) continue;
    const [kind, input] = formInput(field);
    inputs.push([field.key, kind, input, field]);
    const row = el("div", { class: "form-field" },
      el("label", {},
        el("span", { text: field.title ?? field.key }),
        field.required ? el("span", { class: "warn", text: " · needed" }) : null,
      ),
      input,
    );
    if (field.description) row.append(el("div", { class: "where", text: field.description }));
    card.append(row);
  }
  const submit = async () => {
    const answer = {};
    for (const [key, kind, input] of inputs) {
      if (kind === "check") { if (input.checked) answer[key] = true; }
      else if (kind === "number") { if (input.value !== "") answer[key] = Number(input.value); }
      else if (kind === "list") { const picked = [...input.querySelectorAll("input:checked")].map(one => one.dataset.value); if (picked.length) answer[key] = picked; }
      else if (kind === "select") { if (input.value !== "") answer[key] = input.value; }
      else if (kind === "text") { if (input.value !== "") answer[key] = input.value; }
    }
    try {
      await api(`/api/sessions/${encodeURIComponent(state.session.id)}/forms/${encodeURIComponent(form.id)}/reply`, { method: "POST", body: { answer } });
      state.forms = state.forms.filter(item => item.id !== form.id);
      renderForms();
    } catch (error) {
      complain(null, error);
    }
  };
  card.append(el("div", { class: "ask-buttons" },
    el("button", { class: "primary", text: "Answer", onclick: submit }),
    el("button", { class: "danger", text: "Skip", onclick: async () => {
      try {
        await api(`/api/sessions/${encodeURIComponent(state.session.id)}/forms/${encodeURIComponent(form.id)}?message=`, { method: "DELETE" });
        state.forms = state.forms.filter(item => item.id !== form.id);
        renderForms();
      } catch (error) {
        complain(null, error);
      }
    } }),
  ));
  return card;
}

function renderForms() {
  const box = $("forms");
  box.hidden = state.forms.length === 0;
  box.innerHTML = "";
  for (const form of state.forms) box.append(formCard(form));
}

// ---- Undo and redo: take the session back before a message, bring it back ----

async function undoFromHere(entry) {
  if (!state.session) return;
  try {
    if (state.transcript?.running) {
      await api(`/api/sessions/${encodeURIComponent(state.session.id)}/interrupt`, { method: "POST", body: {} }).catch(() => {});
    }
    const { revert } = await api(`/api/sessions/${encodeURIComponent(state.session.id)}/revert`, { method: "POST", body: { messageID: entry.id } });
    state.revert = revert ?? { messageID: entry.id };
    $("prompt").value = entry.text ?? "";
    await openSession(state.session.id);
  } catch (error) {
    complain(null, error);
  }
}

async function redoNow() {
  if (!state.session) return;
  try {
    await api(`/api/sessions/${encodeURIComponent(state.session.id)}/revert`, { method: "DELETE" });
    state.revert = null;
    renderRedo();
    await openSession(state.session.id);
  } catch (error) {
    complain(null, error);
  }
}

function renderRedo() {
  const redo = $("redo");
  redo.hidden = !state.revert;
}
$("redo").addEventListener("click", redoNow);

function permissionCard(request) {
  const answer = decision => async () => {
    try {
      await api(`/api/sessions/${encodeURIComponent(request.sessionID)}/permission/${encodeURIComponent(request.id)}`, { method: "POST", body: { decision } });
      state.transcript.permissions = state.transcript.permissions.filter(item => item.id !== request.id);
      render();
    } catch (error) {
      complain(null, error);
    }
  };
  const card = el("div", { class: "ask" });
  card.append(el("div", { class: "ask-head" },
    el("strong", { text: request.action ?? "permission" }),
    el("span", { text: (request.resources ?? []).join(", ") }),
  ));
  if (request.message) card.append(el("div", { class: "ask-message", text: request.message }));
  const buttons = el("div", { class: "ask-buttons" },
    el("button", { class: "primary", text: "Allow once", onclick: answer("once") }),
    el("button", { text: "Always allow", onclick: answer("always") }),
    el("button", { class: "danger", text: "Reject", onclick: answer("reject") }),
  );
  card.append(buttons);
  return card;
}

function closeSessionTab(id) {
  state.openSessions = state.openSessions.filter(s => s !== id);
  state.transcripts.delete(id);
  if (state.session && state.session.id === id) {
    const next = state.openSessions[state.openSessions.length - 1];
    if (next) openSession(next);
    else { state.session = null; state.transcript = null; render(); }
  } else {
    render();
  }
}

// ---- Split view (the Mac app's split: two sessions beside each other) ----

async function toggleSplit() {
  const other = state.openSessions.find(id => id !== state.session?.id) ?? state.sessions.find(s => s.id !== state.session?.id)?.id;
  if (state.split) {
    state.split = null;
    renderSplit();
    return;
  }
  if (!other) return;
  await loadSplit(other);
  renderSplit();
}

async function loadSplit(id) {
  let transcript = state.transcripts.get(id);
  if (!transcript) {
    try {
      const detail = await api(`/api/sessions/${encodeURIComponent(id)}`);
      transcript = fromHistory(id, detail.messages, detail.permissions, detail.running);
      state.transcripts.set(id, transcript);
    } catch (error) {
      complain(null, error);
      return;
    }
  }
  state.split = id;
}

function renderSplit() {
  const pane = $("split-pane");
  pane.hidden = !state.split;
  $("split").classList.toggle("active", Boolean(state.split));
  if (!state.split) return;
  const select = $("split-session");
  select.innerHTML = "";
  for (const id of state.openSessions.concat(state.split)) {
    if (select.querySelector(`option[value="${id}"]`)) continue;
    const session = state.sessions.find(s => s.id === id) || (id === state.session?.id ? state.session : null);
    select.append(el("option", { value: id, text: session?.title || id.slice(0, 8) }));
  }
  for (const id of [...select.options].map(o => o.value)) {
    if (!state.openSessions.includes(id) && id !== state.split) select.querySelector(`option[value="${id}"]`).remove();
  }
  for (const option of select.options) option.selected = option.value === state.split;
  $("split-entries").replaceChildren(...entryNodes(state.transcripts.get(state.split) ?? { entries: [], pending: [] }));
}

$("split").addEventListener("click", () => toggleSplit().catch(error => complain(null, error)));
$("split-close").addEventListener("click", () => {
  state.split = null;
  renderSplit();
});
$("split-session").addEventListener("change", async event => {
  await loadSplit(event.target.value);
  renderSplit();
});

function compactTokens(n) {
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)}K`;
  return String(n);
}

function updateContextGauge(session) {
  const gauge = $("context-gauge");
  const total = session?.tokens?.total ?? 0;
  if (!total) { gauge.hidden = true; $("gauge-pop").hidden = true; return; }
  gauge.hidden = false;
  // The gauge knows what the number is: the model's limit and the session's cost,
  // like the Mac app's ContextGauge.
  const ref = session?.model;
  const model = state.models.find(item => ref && `${item.providerID}/${item.id}` === `${ref.providerID}/${ref.id}`);
  const limit = model?.limit?.context ?? 0;
  const fraction = limit > 0 ? Math.min(total / limit, 1) : null;
  const label = compactTokens(total);
  gauge.textContent = fraction !== null ? `${Math.round(fraction * 100)}%` : compactTokens(total);
  gauge.title = `Context window: ${compactTokens(total)} tokens used${fraction !== null ? ` of ${compactTokens(limit)}` : ""}`;
  state.contextGauge = { total, limit, fraction, cost: session?.cost ?? 0, model: ref ? `${ref.providerID}/${ref.id}` : "default model" };
  $("gauge-pop").hidden = true;
}

function renderGaugeDetails() {
  const info = state.contextGauge;
  if (!info) return;
  const pop = $("gauge-pop");
  pop.hidden = false;
  pop.innerHTML = "";
  pop.append(
    el("div", { class: "gauge-line big", text: info.fraction !== null ? `${Math.round(info.fraction * 100)}% of the context window` : `${compactTokens(info.total)} tokens in the context window` }),
    info.limit ? el("div", { class: "gauge-line", text: `${compactTokens(info.total)} of ${compactTokens(info.limit)} tokens` }) : null,
    el("div", { class: "gauge-line", text: `Session cost so far: $${info.cost.toFixed(4)}` }),
    el("div", { class: "gauge-line faint", text: info.model }),
    el("button", { class: "small", text: "Compact context", title: "Squeeze the conversation into a summary, like the Mac app's compact",
      onclick: async () => {
        if (!state.session) return;
        try {
          await api(`/api/sessions/${encodeURIComponent(state.session.id)}/compact`, { method: "POST", body: {} });
          pop.hidden = true;
          await openSession(state.session.id);
        } catch (error) { complain(null, error); }
      } }),
  );
}

$("context-gauge").addEventListener("click", event => {
  event.stopPropagation();
  const pop = $("gauge-pop");
  if (pop.hidden) renderGaugeDetails();
  else pop.hidden = true;
});
document.addEventListener("click", event => {
  const pop = $("gauge-pop");
  if (!pop.hidden && !pop.contains(event.target)) pop.hidden = true;
});

async function openSession(id) {
  if (!id) return;
  if (state.session && state.transcript) state.transcripts.set(state.session.id, state.transcript);
  if (!state.openSessions.includes(id)) state.openSessions.push(id);
  try {
    const detail = await api(`/api/sessions/${encodeURIComponent(id)}`);
    state.session = detail.session;
    updateContextGauge(detail);
    const cached = state.transcripts.get(id);
    state.transcript = cached || fromHistory(id, detail.messages, detail.permissions, detail.running);
    if (!cached) state.transcripts.set(id, state.transcript);
    selectModelInPicker();
    state.revert = detail.revert ?? null;
    renderRedo();
    api(`/api/sessions/${encodeURIComponent(id)}/view`, { method: "POST", body: { idle: Date.now() } }).catch(() => {});
    loadInbox().catch(() => {});
    loadVcs().catch(() => {});
    loadSessionDiff().catch(() => {});
    loadForms().catch(() => {});
    render();
    $("prompt").focus();
  } catch (error) {
    complain(null, error);
  }
}

// ---- Composer ----

// The files staged with the prompt, until it sends.
let stagedAttachments = [];

async function stageFiles(list) {
  for (const file of list) {
    try {
      const data = await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(String(reader.result ?? "").split(",")[1] ?? "");
        reader.onerror = reject;
        reader.readAsDataURL(file);
      });
      const { path: stored } = await api("/api/upload", { method: "POST", body: { name: file.name, data } });
      stagedAttachments.push({ path: stored, name: file.name });
      renderAttachments();
    } catch (error) {
      complain(null, error);
    }
  }
}

function renderAttachments() {
  const strip = $("attachments");
  strip.innerHTML = "";
  strip.hidden = stagedAttachments.length === 0;
  for (const item of stagedAttachments) {
    const pill = el("span", { class: "attachment-pill" },
      el("span", { text: item.name }),
      el("span", { class: "close", text: "✕", onclick: () => { stagedAttachments = stagedAttachments.filter(a => a !== item); renderAttachments(); } }),
    );
    strip.append(pill);
  }
}

$("attach").addEventListener("click", () => $("attach-input").click());
$("attach-input").addEventListener("change", async event => {
  await stageFiles(event.target.files ?? []);
  event.target.value = "";
});

// Drop a file anywhere on the page and it attaches.
document.addEventListener("dragover", event => { event.preventDefault(); document.body.classList.add("dropping"); });
document.addEventListener("dragleave", event => { if (!event.relatedTarget) document.body.classList.remove("dropping"); });
document.addEventListener("drop", async event => {
  event.preventDefault();
  document.body.classList.remove("dropping");
  if (!state.session) return;
  await stageFiles(event.dataTransfer?.files ?? []);
});

// ---- File mentions (@) and slash commands (/), like the Mac app's GroupMentions ----

let mentionItems = [];
let mentionQueryFiles = [];

function completeBox() {
  const box = $("prompt");
  const upTo = box.value.slice(0, box.selectionStart ?? box.value.length);
  const at = upTo.match(/(?:^|\s)@([^\s@]*)$/);
  const slash = !at && upTo.match(/^\/(\w*)$/) ? upTo.match(/^\/(\w*)$/) : null;
  const popup = $("autocomplete");
  if (!at && !slash) { popup.hidden = true; return; }
  if (at) {
    const query = at[1].toLowerCase();
    if (!query) api("/api/files").then(({ files }) => { mentionQueryFiles = files; showMentions(files.slice(0, 12), "files"); }).catch(() => { popup.hidden = true; });
    else {
      const all = mentionQueryFiles.length ? mentionQueryFiles : [];
      const local = all.filter(file => file.relative.toLowerCase().includes(query)).slice(0, 12);
      api(`/api/files?q=${encodeURIComponent(query)}`).then(({ files }) => showMentions(files.slice(0, 12).concat(local.filter(l => !files.some(f => f.path === l.path))).slice(0, 12), "files")).catch(() => { popup.hidden = true; });
    }
  } else if (slash) {
    const query = slash[1].toLowerCase();
    const items = state.commands.filter(command => query === "" || command.name.toLowerCase().startsWith(query)).slice(0, 12);
    if (items.length === 0) { popup.hidden = true; return; }
    showMentions(items, "commands");
  }
}

function showMentions(items, kind) {
  mentionItems = items.map(item => ({ ...item, kind }));
  const popup = $("autocomplete");
  popup.innerHTML = "";
  for (const item of mentionItems) {
    const row = el("div", { class: "mention-item" });
    row.append(el("span", { class: "mention-name", text: item.kind === "files" ? item.name : `/${item.name}` }));
    row.append(el("span", { class: "where", text: item.kind === "files" ? item.relative : item.description ?? "" }));
    row.addEventListener("mousedown", event => { event.preventDefault();chooseMention(item); });
    popup.append(row);
  }
  popup.hidden = false;
}

function chooseMention(item) {
  const box = $("prompt");
  const caret = box.selectionStart ?? box.value.length;
  if (item.kind === "files") {
    const before = box.value.slice(0, caret).replace(/@[^\s@]*$/, `@${item.relative} `);
    box.value = before + box.value.slice(caret);
    const at = caret;
    box.focus();
    box.selectionStart = box.selectionEnd = at + item.relative.length + 2;
    $("autocomplete").hidden = true;
    return;
  }
  // A command: replace the prompt with the command name and its arguments input expected after.
  box.value = `/${item.name} `;
  box.focus();
  box.selectionStart = box.selectionEnd = box.value.length;
  $("autocomplete").hidden = true;
}

$("prompt").addEventListener("input", () => completeBox());
$("prompt").addEventListener("click", () => completeBox());

async function loadCommands() {
  try {
    const { commands } = await api("/api/commands");
    state.commands = Array.isArray(commands) ? commands : [];
  } catch {
    state.commands = [];
  }
}

// A session's first word after "/" names a command; everything after is its arguments.
function parseCommand(text) {
  const match = text.match(/^\/(\w+)\b\s*([\s\S]*)$/);
  if (!match) return null;
  const command = state.commands.find(item => item.name.toLowerCase() === match[1].toLowerCase());
  return command ? { name: command.name, command, args: match[2].trim() } : null;
}

$("prompt").addEventListener("keydown", event => {
  if (!$("autocomplete").hidden && ["ArrowDown", "ArrowUp", "Enter", "Escape"].includes(event.key) && mentionItems.length > 0) {
    event.preventDefault();
    const rows = [...$("autocomplete").querySelectorAll(".mention-item")];
    const index = Math.max(0, rows.findIndex(row => row.classList.contains("selected")));
    if (event.key === "Escape") { $("autocomplete").hidden = true; return; }
    if (event.key === "ArrowDown") { const next = Math.min(index + 1, mentionItems.length - 1); rows[index]?.classList.remove("selected"); rows[next]?.classList.add("selected"); }
    else if (event.key === "ArrowUp") { const prev = Math.max(index - 1, 0); rows[index]?.classList.remove("selected"); rows[prev]?.classList.add("selected"); }
    else if (event.key === "Enter") { const selected = Math.min(index, mentionItems.length - 1); chooseMention(mentionItems[selected]); }
    return;
  }
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    $("composer").requestSubmit();
  }
});

$("composer").addEventListener("submit", async event => {
  event.preventDefault();
  const box = $("prompt");
  const text = box.value.trim();
  const attachments = stagedAttachments;
  if ((text === "" && attachments.length === 0) || !state.session) return;
  box.value = "";
  stagedAttachments = [];
  renderAttachments();
  $("autocomplete").hidden = true;
  try {
    const command = parseCommand(text);
    if (command) {
      await api(`/api/sessions/${encodeURIComponent(state.session.id)}/command`, { method: "POST", body: { name: command.name, text: command.args } });
    } else {
      const { id } = await api(`/api/sessions/${encodeURIComponent(state.session.id)}/prompt`, { method: "POST", body: { text, files: attachments } });
      state.transcript.pending.push({ id, text, delivery: "steer", files: attachments.map(a => ({ name: a.name })) });
    }
    render();
  } catch (error) {
    box.value = text;
    stagedAttachments = attachments;
    renderAttachments();
    alert(error.message);
  }
});

async function interruptRun() {
  if (!state.session) return;
  try {
    await api(`/api/sessions/${encodeURIComponent(state.session.id)}/interrupt`, { method: "POST", body: {} });
  } catch (error) {
    complain(null, error);
  }
}

$("stop").addEventListener("click", () => interruptRun().catch(() => {}));

$("session-search").addEventListener("input", (event) => {
  state.sessionQuery = event.target.value.trim().toLowerCase();
  renderSessions();
});

$("find").addEventListener("input", (event) => {
  state.findQuery = event.target.value.trim().toLowerCase();
  render();
});

$("message-search").addEventListener("input", async (event) => {
  const query = event.target.value.trim();
  const results = $("message-search-results");
  if (query.length < 3) { results.hidden = true; results.innerHTML = ""; return; }
  try {
    const { matches } = await api(`/api/search/sessions?q=${encodeURIComponent(query)}`);
    results.innerHTML = "";
    results.hidden = false;
    for (const match of matches.slice(0, 20)) {
      const item = el("div", { class: "hit" });
      item.append(el("div", { text: match.session.title || match.session.id }));
      for (const hit of match.hits) {
        const where = el("div", { class: "where", text: hit.snippet });
        where.addEventListener("click", () => openSession(match.session.id));
        item.append(where);
      }
      results.append(item);
    }
    if (matches.length === 0) results.append(el("div", { class: "where", text: "No matches." }));
  } catch (error) { complain(null, error); }
});

$("new-session").addEventListener("click", async () => {
  if (!state.project) return openPicker();
  try {
    const { session } = await api("/api/sessions", { method: "POST", body: state.agent ? { agent: state.agent } : {} });
    await loadSessions();
    await openSession(session.id);
  } catch (error) {
    complain(null, error);
  }
});

// ---- The folder's git, from the engine (branch in the header, like the Mac app) ----

async function loadVcs() {
  try {
    const { vcs } = await api("/api/vcs");
    state.vcs = vcs?.branch?.current ? vcs : null;
  } catch {
    state.vcs = null;
  }
  renderVcs();
}

function renderVcs() {
  const chip = $("vcs");
  const branch = state.vcs?.branch?.current;
  chip.hidden = !branch;
  chip.textContent = branch ? `⎇ ${branch}` : "";
  chip.title = state.vcs?.provider ? `${state.vcs.provider} · ${branch}` : branch;
}

// ---- Projects (the Mac app keeps a list; so does the harness) ----

async function loadProjects() {
  try {
    const { projects, current } = await api("/api/projects");
    state.projects = Array.isArray(projects) ? projects : [];
    if (current) state.project = current;
  } catch {
    state.projects = [];
  }
  renderProjects();
}

async function switchProject(folder) {
  try {
    await api("/api/project", { method: "POST", body: { directory: folder } });
    $("picker").hidden = true;
    state.project = folder;
    state.session = null;
    state.transcript = null;
    state.openSessions = [];
    state.transcripts.clear();
    state.split = null;
    renderSplit();
    await loadSessions();
    await loadProjects();
    render();
  } catch (error) {
    complain($("picker-note"), error);
  }
}

function projectRow(folder, onSwitch) {
  const row = el("div", { class: "project-row" });
  const open = el("button", { class: "project-open" },
    el("span", { class: "project-name", text: folder.split(/[\\/]/).pop() }),
    el("span", { class: "where", text: folder }),
  );
  open.addEventListener("click", onSwitch);
  const remove = el("button", { class: "small close-project", text: "✕", title: "Forget this project" });
  remove.addEventListener("click", async event => {
    event.stopPropagation();
    try { await api("/api/projects", { method: "DELETE", body: { path: folder } }); await loadProjects(); }
    catch (error) { complain(null, error); }
  });
  row.append(open, remove);
  return row;
}

function renderProjects() {
  for (const [selector, emptyNote] of [["picker-recent", false], ["projects-settings-list", true]]) {
    const list = $(selector);
    if (!list) continue;
    list.innerHTML = "";
    if (state.projects.length === 0) {
      list.hidden = true;
      if (emptyNote) list.append(el("div", { class: "where", text: "No projects yet." }));
      continue;
    }
    list.hidden = false;
    for (const folder of state.projects) list.append(projectRow(folder, () => switchProject(folder)));
  }
}

// ---- Agents (the ones a person picks between, like the Mac app's agents) ----

async function loadAgents() {
  try {
    const { agents } = await api("/api/agents");
    const primary = agents.filter(agent => agent.mode !== "subagent" && !agent.hidden);
    state.agents = primary;
  } catch {
    state.agents = [];
  }
  renderAgentPicker();
}

function renderAgentPicker() {
  const select = $("agent");
  select.replaceChildren();
  if (state.agents.length === 0) { select.hidden = true; return; }
  select.disabled = false;
  select.append(el("option", { text: "Default agent", value: "" }));
  for (const agent of state.agents) {
    const title = agent.name ? `${agent.name}${agent.description ? ` — ${agent.description}` : ""}`.slice(0, 60) : agent.id;
    select.append(el("option", { text: title, value: agent.id }));
  }
  select.value = state.agent;
  if (state.session?.agent) {
    if (state.agents.some(item => item.id === state.session.agent)) select.value = state.session.agent;
  }
  select.hidden = false;
}

$("agent").addEventListener("change", event => {
  state.agent = event.target.value;
});

// ---- Models ----

async function loadModels() {
  try {
    const { models } = await api("/api/models");
    state.models = Array.isArray(models) ? models : [];
  } catch {
    state.models = [];
  }
  selectModelInPicker();
}

function selectModelInPicker() {
  const select = $("model");
  select.replaceChildren();
  if (state.models.length === 0) {
    select.append(el("option", { text: "default model", value: "" }));
    select.disabled = true;
    return;
  }
  select.disabled = state.session === null;
  select.append(el("option", { text: "default model", value: "" }));
  // Grouped by provider, like the Mac app's ModelPicker.
  const byProvider = new Map();
  for (const model of state.models) {
    const group = byProvider.get(model.providerID) ?? [];
    group.push(model);
    byProvider.set(model.providerID, group);
  }
  for (const [providerID, models] of byProvider) {
    const group = el("optgroup", { label: providerID });
    for (const model of models) {
      const value = `${model.providerID}/${model.id}`;
      group.append(el("option", { text: model.name || model.id, value }));
    }
    select.append(group);
  }
  const current = state.session?.model;
  select.value = current ? `${current.providerID}/${current.id}` : "";
  select.onchange = async () => {
    if (!state.session || select.value === "") return;
    try {
      const [providerID, ...rest] = select.value.split("/");
      await api(`/api/sessions/${encodeURIComponent(state.session.id)}/model`, { method: "POST", body: { model: { providerID, id: rest.join("/") } } });
    } catch (error) {
      complain(null, error);
    }
  };
}

// ---- Events ----

function handleEvent(event) {
  if (event.type === "harness.error") {
    state.engine = { status: "down" };
    return render();
  }
  // The split pane holds its own session: its events go there too.
  if (state.split && event.data?.sessionID === state.split) {
    const splitTranscript = state.transcripts.get(state.split);
    if (splitTranscript) { apply(splitTranscript, event); renderSplit(); }
  }
  if (!state.transcript || !state.session) return;
  if (event.data?.sessionID !== state.session.id && event.data?.sessionID !== undefined) return;
  const before = state.transcript.running;
  apply(state.transcript, event);
  render();
  // A turn just ended: what the engine stored is the truth, and the list changed.
  if (before && !state.transcript.running) {
    notify("Kuvo Code", "The turn is done.");
    setTimeout(async () => {
      try {
        await openSession(state.session.id);
        await loadSessions();
        loadSessionDiff().catch(() => {});
        loadForms().catch(() => {});
      } catch {}
    }, 250);
  }
  if (event.type === "permission.asked") {
    notify("Kuvo Code", event.data?.message || "The agent is asking for permission.");
    render();
  } else if (event.type === "permission.replied") {
    render();
  }
}

function connectEvents() {
  let reconnectTimer = null;
  const connect = () => {
    const events = new EventSource("/api/events");
    state.eventSource = events;
    events.onmessage = message => {
      try {
        handleEvent(JSON.parse(message.data));
      } catch {}
    };
    events.onopen = () => {
      if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
      state.engine = state.engine || { status: "running" };
      render();
      // Anything that happened while the stream was away is fixed by a read.
      if (state.session) openSession(state.session.id).catch(() => {});
    };
    events.onerror = () => {
      // The browser closes the stream on error; reopen it shortly.
      try { events.close(); } catch {}
      if (!reconnectTimer) {
        reconnectTimer = setTimeout(() => { reconnectTimer = null; connect(); }, 2000);
      }
    };
  };
  connect();
}

// ---- Folder picker ----

let pickerPath = null;

async function browse(folder) {
  const { path: shown, parent, folders } = await api(`/api/browse?path=${encodeURIComponent(folder ?? "")}`);
  pickerPath = shown;
  $("picker-path").value = shown;
  $("picker-note").textContent = folders.length === 0 ? "No folders inside." : "";
  const list = $("picker-folders");
  list.replaceChildren(...folders.map(child => el("li", {},
    el("button", { text: `${child.name}/`, onclick: () => browse(child.path).catch(error => { $("picker-note").textContent = error.message; }) }),
  )));
  $("picker-up").disabled = parent === null;
  $("picker-up").onclick = () => parent && browse(parent).catch(() => {});
}

function openPicker() {
  $("picker").hidden = false;
  browse(state.project ?? null).catch(error => {
    $("picker-note").textContent = error.message;
  });
}

$("choose").addEventListener("click", openPicker);
$("start").addEventListener("click", () => $("new-session").click());
$("project").addEventListener("click", openPicker);
$("picker-close").addEventListener("click", () => { $("picker").hidden = true; });
$("picker-go").addEventListener("click", () => browse($("picker-path").value).catch(error => { $("picker-note").textContent = error.message; }));
$("picker-path").addEventListener("keydown", event => {
  if (event.key === "Enter") $("picker-go").click();
});
$("picker-use").addEventListener("click", async () => {
  try {
    await api("/api/project", { method: "POST", body: { directory: pickerPath } });
    state.project = pickerPath;
    state.session = null;
    state.transcript = null;
    $("picker").hidden = true;
    await loadSessions();
  } catch (error) {
    complain($("picker-note"), error);
  }
});


// ---- Files, terminal, diff ----

function toggleDrawer() {
  const drawer = $("drawer");
  drawer.hidden = !drawer.hidden;
  if (!drawer.hidden) {
    if (state.drawerTab === "files") { loadFileTree(state.project); refreshGit(); }
    else initTerminal();
  }
}

function setDrawerTab(tab) {
  state.drawerTab = tab;
  document.querySelectorAll(".drawer-tab").forEach(button => {
    button.classList.toggle("active", button.dataset.tab === tab);
  });
  $("drawer-files").hidden = tab !== "files";
  $("drawer-terminal").hidden = tab !== "terminal";
  if (tab === "files") loadFileTree(state.project);
  else initTerminal();
}

async function loadFileTree(folder) {
  if (!folder) return;
  try {
    const { path: p, parent, folders, files } = await api(`/api/browse?path=${encodeURIComponent(folder)}`);
    $("files-root").textContent = p;
    $("files-refresh").dataset.path = p;
    const list = $("file-tree");
    list.innerHTML = "";
    if (parent) list.append(el("li", { class: "dir", text: "..", onclick: () => loadFileTree(parent) }));
    for (const folder of folders || []) {
      list.append(el("li", { class: "dir", text: `${folder.name}/`, onclick: () => loadFileTree(folder.path) }));
    }
    for (const file of files || []) {
      list.append(el("li", { text: file.name, onclick: () => openFile(file.path) }));
    }
  } catch (error) {
    complain(null, error);
  }
}

async function openFile(filePath) {
  try {
    const { content } = await api(`/api/file?path=${encodeURIComponent(filePath)}`);
    state.openFile = filePath;
    $("file-name").textContent = filePath.split(/[\\/]/).pop();
    $("file-content").value = content;
    $("file-editor").hidden = false;
  } catch (error) {
    complain(null, error);
  }
}

async function saveFile() {
  if (!state.openFile) return;
  const button = $("file-save");
  const previous = button.textContent;
  try {
    await api("/api/file", { method: "POST", body: { path: state.openFile, content: $("file-content").value } });
    button.textContent = "Saved";
    setTimeout(() => { button.textContent = previous; }, 1200);
  } catch (error) {
    complain(null, error);
  }
}

function initTerminal() {
  const container = $("terminal");
  if (container.dataset.ready === "1") return;
  container.dataset.ready = "1";
  const note = $("terminal-note");
  const port = new URLSearchParams(location.search).get("terminalPort");
  if (!port) { note.textContent = "Terminal is available when running inside the Kuvo Code shell."; return; }
  if (typeof Terminal === "undefined") { note.textContent = "Terminal library failed to load."; return; }
  const term = new Terminal({ convertEol: true, fontSize: 13, theme: { background: "#1e1e1e", foreground: "#d4d4d4" } });
  let fitAddon = null;
  if (typeof FitAddon === "function") {
    fitAddon = new FitAddon();
    term.loadAddon(fitAddon);
  }
  term.open(container);
  if (fitAddon) fitAddon.fit();
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  ws.onopen = () => { note.textContent = ""; term.focus(); };
  ws.onmessage = (event) => term.write(typeof event.data === "string" ? event.data : "");
  ws.onclose = () => { note.textContent = "Terminal closed."; };
  term.onData((data) => { if (ws.readyState === WebSocket.OPEN) ws.send(data); });
  window.addEventListener("resize", () => { if (fitAddon) { fitAddon.fit(); if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: "resize", cols: term.cols, rows: term.rows })); } });
}

function diffLines(oldText, newText) {
  const a = String(oldText).split("\n");
  const b = String(newText).split("\n");
  const m = a.length, n = b.length;
  const dp = Array.from({ length: m + 1 }, () => new Array(n + 1).fill(0));
  for (let i = m - 1; i >= 0; i--)
    for (let j = n - 1; j >= 0; j--)
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  const ops = [];
  let i = 0, j = 0;
  while (i < m && j < n) {
    if (a[i] === b[j]) { ops.push({ t: " ", line: a[i] }); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) { ops.push({ t: "-", line: a[i] }); i++; }
    else { ops.push({ t: "+", line: b[j] }); j++; }
  }
  while (i < m) { ops.push({ t: "-", line: a[i] }); i++; }
  while (j < n) { ops.push({ t: "+", line: b[j] }); j++; }
  return ops;
}

function showDiff(title, oldText, newText) {
  const body = $("diff-body");
  body.innerHTML = "";
  for (const op of diffLines(oldText, newText)) {
    body.append(el("div", { class: op.t === "+" ? "add" : op.t === "-" ? "del" : "ctx", text: `${op.t} ${op.line}` }));
  }
  $("diff-title").textContent = title;
  $("diff-modal").hidden = false;
}

$("toggle-files").addEventListener("click", toggleDrawer);
$("export").addEventListener("click", exportConversation);
$("drawer-close").addEventListener("click", () => { $("drawer").hidden = true; });
document.querySelectorAll(".drawer-tab").forEach(button => {
  button.addEventListener("click", () => setDrawerTab(button.dataset.tab));
});
$("files-refresh").addEventListener("click", () => loadFileTree($("files-refresh").dataset.path || state.project));
$("file-save").addEventListener("click", saveFile);
$("diff-close").addEventListener("click", () => { $("diff-modal").hidden = true; });


$("files-new-file").addEventListener("click", async () => {
  if (!state.project) return;
  const name = prompt("New file name:");
  if (!name) return;
  const target = `${$("files-refresh").dataset.path || state.project}/${name}`;
  try {
    await api("/api/file", { method: "POST", body: { path: target, content: "" } });
    await loadFileTree($("files-refresh").dataset.path || state.project);
    await openFile(target);
  } catch (error) { complain(null, error); }
});
$("files-new-folder").addEventListener("click", async () => {
  if (!state.project) return;
  const name = prompt("New folder name:");
  if (!name) return;
  const target = `${$("files-refresh").dataset.path || state.project}/${name}`;
  try {
    await api("/api/mkdir", { method: "POST", body: { path: target } });
    await loadFileTree($("files-refresh").dataset.path || state.project);
  } catch (error) { complain(null, error); }
});
$("files-delete").addEventListener("click", async () => {
  if (!state.openFile) return;
  if (!confirm(`Delete ${state.openFile}?`)) return;
  try {
    await api(`/api/file?path=${encodeURIComponent(state.openFile)}`, { method: "DELETE" });
    state.openFile = null;
    $("file-editor").hidden = true;
    await loadFileTree($("files-refresh").dataset.path || state.project);
  } catch (error) { complain(null, error); }
});
$("files-search").addEventListener("input", async (event) => {
  const query = event.target.value.trim();
  const results = $("files-search-results");
  if (query.length < 2) { results.hidden = true; results.innerHTML = ""; return; }
  try {
    const { matches } = await api(`/api/search?q=${encodeURIComponent(query)}`);
    results.innerHTML = "";
    results.hidden = false;
    for (const match of matches.slice(0, 30)) {
      const item = el("div", { class: "hit" });
      item.append(el("div", { text: match.path.replace(state.project, "").replace(/^[/\\]/, "") }));
      for (const hit of match.hits) {
        const where = el("div", { class: "where", text: `${hit.line}: ${hit.text}` });
        where.addEventListener("click", () => openFile(match.path));
        item.append(where);
      }
      results.append(item);
    }
    if (matches.length === 0) results.append(el("div", { class: "where", text: "No matches." }));
  } catch (error) { complain(null, error); }
});
async function refreshGit() {
  try {
    const { repository, entries } = await api("/api/git/status");
    const box = $("git-status");
    const button = $("git-diff");
    const amend = $("git-amend");
    const branchRow = $("git-branch-row");
    if (!repository) { box.hidden = true; button.hidden = true; amend.hidden = true; branchRow.hidden = true; return; }
    box.hidden = false; button.hidden = false; amend.hidden = false; branchRow.hidden = false;
    // Load branches.
    try {
      const { branches, current } = await api("/api/git/branches");
      const select = $("git-branch");
      select.innerHTML = "";
      for (const branch of branches) {
        const option = el("option", { value: branch, text: branch });
        if (branch === current) option.selected = true;
        select.append(option);
      }
    } catch {}
    box.innerHTML = "";
    if (entries.length === 0) { box.append(el("div", { class: "entry", text: "Working tree clean." })); return; }
    for (const entry of entries) {
      const row = el("div", { class: "entry" });
      row.append(el("span", { class: "code", text: entry.code }));
      const name = el("span", { text: entry.path });
      row.append(name);
      const staged = entry.code.trim() !== "" && !entry.code.startsWith(" ");
      // Actually: staged if first char is not space and not ?
      const isStaged = entry.code[0] && entry.code[0] !== " " && entry.code[0] !== "?";
      const button = el("button", { class: "small", text: isStaged ? "unstage" : "stage" });
      button.addEventListener("click", async () => {
        try {
          await api("/api/git/" + (isStaged ? "unstage" : "stage"), { method: "POST", body: { paths: [entry.path] } });
          await refreshGit();
        } catch (error) { complain(null, error); }
      });
      row.append(button);
      box.append(row);
    }
    // Commit controls
    if (entries.length > 0) {
      const commitRow = el("div", { class: "entry" });
      const input = el("input", { class: "file-search", placeholder: "Commit message…" });
      const button = el("button", { class: "small primary", text: "Commit" });
      button.addEventListener("click", async () => {
        try {
          await api("/api/git/commit", { method: "POST", body: { message: input.value } });
          input.value = "";
          await refreshGit();
        } catch (error) { complain(null, error); }
      });
      commitRow.append(input, button);
      box.append(commitRow);
    }
  } catch (error) { complain(null, error); }
}
$("git-diff").addEventListener("click", async () => {
  try {
    const { diff } = await api("/api/git/diff");
    showDiff("Working tree", "", diff || "(no changes)");
  } catch (error) { complain(null, error); }
});
$("git-branch").addEventListener("change", async (event) => {
  try {
    await api("/api/git/checkout", { method: "POST", body: { name: event.target.value } });
    await refreshGit();
  } catch (error) { complain(null, error); }
});
$("git-new-branch").addEventListener("click", async () => {
  const name = prompt("New branch name:");
  if (!name) return;
  try {
    await api("/api/git/branch", { method: "POST", body: { name } });
    await refreshGit();
  } catch (error) { complain(null, error); }
});
$("git-checkout").addEventListener("click", async () => {
  const name = prompt("Branch to check out:");
  if (!name) return;
  try {
    await api("/api/git/checkout", { method: "POST", body: { name } });
    await refreshGit();
  } catch (error) { complain(null, error); }
});
$("git-amend").addEventListener("click", async () => {
  const message = prompt("New commit message (leave empty to keep):");
  if (message === null) return;
  try {
    await api("/api/git/amend", { method: "POST", body: { message } });
    await refreshGit();
  } catch (error) { complain(null, error); }
});
const originalToggleDrawer = toggleDrawer;
// wrap toggleDrawer to also refresh git

// ---- Command palette (Ctrl+K, like the Mac app's ⌘K) ----

const paletteActions = () => [
  { id: "new", title: "New session", detail: "Ctrl+Shift+N", run: () => $("new-session").click() },
  { id: "files", title: "Toggle files panel", detail: "Ctrl+O", run: () => $("toggle-files").click() },
  { id: "terminal", title: "Toggle terminal", detail: "Ctrl+`", run: () => $("toggle-files").click(), after: () => setDrawerTab("terminal") },
  { id: "find", title: "Find in this conversation", detail: "", run: () => $("find").focus() },
  { id: "export", title: "Export conversation as Markdown", detail: "", run: () => exportConversation() },
  { id: "split", title: state.split ? "Close the split view" : "Split: show a second session", detail: "", run: () => toggleSplit().catch(() => {}) },
  { id: "rename", title: "Rename this session", detail: "", run: async () => {
    if (!state.session) return;
    const title = prompt("Session name:", state.session.title ?? "");
    if (!title) return;
    try { await api(`/api/sessions/${encodeURIComponent(state.session.id)}/rename`, { method: "POST", body: { title } }); await loadSessions(); if (state.session) state.session.title = title; render(); }
    catch (error) { complain(null, error); }
  } },
  { id: "fork", title: "Fork this session (new session, same history)", detail: "", run: async () => {
    if (!state.session || state.transcript) { /* fallthrough */ }
    const last = state.transcript?.entries.filter(item => item.kind === "assistant" || item.kind === "user").at(-1);
    if (!state.session || !last) return;
    try {
      const { session: branched } = await api(`/api/sessions/${encodeURIComponent(state.session.id)}/fork`, { method: "POST", body: { before: last.id } });
      await loadSessions();
      await openSession(branched.id);
    } catch (error) { complain(null, error); }
  } },
  { id: "appearance", title: "Appearance settings", detail: "", run: () => openSettings() },
  { id: "folder", title: "Choose a project folder", detail: "", run: () => openPicker() },
  { id: "stop", title: state.transcript?.running ? "Stop the run" : "Stop", detail: "", run: () => { if (state.session) interruptRun(); } },
  { id: "project", title: state.project ? `Switch project away from ${state.project.split(/[\\/]/).pop()}` : "Choose project", detail: "", run: () => openPicker() },
];

let paletteIndex = 0;
let paletteSectionsCache = [];

function paletteSections() {
  const raw = $("palette-input").value.trim().toLowerCase();
  if (!raw) {
    const sections = [
      { title: "Recent sessions", items: state.sessions.slice(0, 5).map(s => ({ id: `session:${s.id}`, title: s.title || s.id.slice(0, 8), run: () => openSession(s.id) })) },
      { title: "Actions", items: paletteActions().slice(0, 7).map(a => ({ ...a, id: `action:${a.id}` })) },
    ];
    return sections.filter(section => section.items.length > 0);
  }
  const matches = needle => needle.includes(raw) || needle.split(/\s+/).some(word => word.startsWith(raw));
  const sections = [];
  const actions = paletteActions().filter(a => matches(a.title.toLowerCase())).slice(0, 5).map(a => ({ ...a, id: `action:${a.id}` }));
  if (actions.length) sections.push({ title: "Actions", items: actions });
  const sessions = state.sessions.filter(s => matches((s.title || "").toLowerCase() + " " + s.id)).slice(0, 5).map(s => ({ id: `session:${s.id}`, title: s.title || s.id.slice(0, 8), run: () => openSession(s.id) }));
  if (sessions.length) sections.push({ title: "Sessions", items: sessions });
  const commands = state.commands.filter(c => matches(("/" + c.name.toLowerCase()) + " " + (c.description ?? "").toLowerCase())).slice(0, 5).map(c => ({
    id: `command:${c.name}`,
    title: `/${c.name}`,
    detail: c.description ?? "",
    run: () => { if (!state.session) return; $("prompt").value = `/${c.name} `; $("prompt").focus(); },
  }));
  if (commands.length) sections.push({ title: "Commands", items: commands });
  return sections;
}

function renderPalette() {
  paletteSectionsCache = paletteSections();
  const list = $("palette-list");
  list.innerHTML = "";
  if (paletteSectionsCache.length === 0) {
    list.append(el("div", { class: "palette-empty", text: "Nothing matches." }));
    return;
  }
  const flat = [];
  for (const section of paletteSectionsCache) {
    list.append(el("div", { class: "palette-title", text: section.title }));
    for (const item of section.items) {
      const row = el("div", { class: `palette-item ${flat.length === paletteIndex ? "selected" : ""}` });
      row.append(el("div", { class: "palette-name", text: item.title }));
      if (item.detail) row.append(el("span", { class: "palette-detail", text: item.detail }));
      row.addEventListener("click", () => choosePalette(item));
      list.append(row);
      flat.push(item);
    }
  }
  paletteIndex = Math.min(paletteIndex, Math.max(flat.length - 1, 0));
  list.querySelectorAll(".palette-item")[paletteIndex]?.classList.add("selected");
}

function choosePalette(item) {
  closePalette();
  item.run?.();
  item.after?.();
}

function openPalette() {
  $("palette").hidden = false;
  $("palette-input").value = "";
  paletteIndex = 0;
  renderPalette();
  $("palette-input").focus();
}

function closePalette() {
  $("palette").hidden = true;
}

$("palette-open").addEventListener("click", openPalette);
$("palette-input").addEventListener("input", () => { paletteIndex = 0; renderPalette(); });
$("palette").addEventListener("click", event => { if (event.target === $("palette")) closePalette(); });

// ---- Appearance settings (the Mac app's AppearanceSettings) ----

const LOOK_KEY = "kuvo-look";
const lookAccents = {
  system: { color: "", title: "Default" },
  blue: { color: "#0a84ff", title: "Blue" },
  purple: { color: "#bf5af2", title: "Purple" },
  pink: { color: "#ff375f", title: "Pink" },
  red: { color: "#ff453a", title: "Red" },
  orange: { color: "#ff9f0a", title: "Orange" },
  yellow: { color: "#ffd60a", title: "Yellow" },
  green: { color: "#32d74b", title: "Green" },
  graphite: { color: "#8e8e93", title: "Graphite" },
};

const look = { accent: "system", textSize: "14", motion: "full", theme: "system" };

function saveLook() {
  localStorage.setItem(LOOK_KEY, JSON.stringify(look));
}

function applyLook() {
  const root = document.documentElement;
  const accent = lookAccents[look.accent] ?? lookAccents.system;
  if (accent.color) {
    root.style.setProperty("--accent", accent.color);
    root.style.setProperty("--accent-hover", `color-mix(in oklab, ${accent.color}, black 12%)`);
  } else {
    root.style.removeProperty("--accent");
    root.style.removeProperty("--accent-hover");
  }
  root.style.setProperty("--text-base", `${look.textSize}px`);
  root.classList.toggle("reduced-motion", look.motion === "reduced");
  if (look.theme === "system") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.dataset.theme = look.theme;
  $("setting-text-size").value = look.textSize;
  $("setting-motion").value = look.motion;
  $("setting-theme").value = look.theme;
  for (const swatch of document.querySelectorAll("#accent-swatches .swatch")) {
    swatch.classList.toggle("selected", swatch.dataset.accent === look.accent);
  }
  try { saveLook(); } catch {}
}

function renderAccentSwatches() {
  const swatches = $("accent-swatches");
  swatches.innerHTML = "";
  for (const [key, value] of Object.entries(lookAccents)) {
    const swatch = el("button", { class: "swatch", title: value.title, type: "button" });
    swatch.dataset.accent = key;
    swatch.style.background = value.color || "var(--accent)";
    swatch.addEventListener("click", () => { look.accent = key; applyLook(); });
    swatches.append(swatch);
  }
}

// The other half of the Mac app's settings: the engine, the storage, the projects.
async function renderSystemSettings() {
  try {
    const info = await api("/api/storage");
    $("engine-line").textContent = `Engine: ${info.engine?.status ?? "unknown"}${info.engine?.version ? ` · v${info.engine.version}` : ""}`;
    $("storage-log").textContent = `Log: ${info.logPath} (${(info.logSize / (1024 * 1024)).toFixed(1)} MB)`;
    $("storage-attachments").textContent = info.attachments
      ? `Attachments: ${info.attachments.files} files in ${info.attachments.path} (${(info.attachments.bytes / (1024 * 1024)).toFixed(2)} MB)`
      : "Attachments: none (open a project first)";
  } catch (error) {
    $("engine-line").textContent = "Engine: the harness isn't answering.";
    $("storage-log").textContent = "";
    $("storage-attachments").textContent = "";
  }
}

async function renderSavedPermissions() {
  const list = $("saved-permissions");
  list.innerHTML = "";
  let saved = [];
  try { ({ saved } = await api("/api/permission/saved")); } catch { saved = []; }
  if (!saved.length) { list.append(el("div", { class: "where", text: "Nothing saved — the agent's always-allowed list is empty." })); return; }
  for (const item of saved) {
    const row = el("div", { class: "shortcut-row" },
      el("span", { text: item.action }),
      el("span", { class: "where", text: item.resource ?? "" }),
      el("button", { class: "small", text: "Forget", onclick: async () => {
        try { await api("/api/permission/saved", { method: "DELETE", body: { id: item.id } }); await renderSavedPermissions(); }
        catch (error) { complain(null, error); }
      } }),
    );
    list.append(row);
  }
}

async function renderConfigLists() {
  const box = $("config-lists");
  try {
    const { skills, mcp, providers } = await api("/api/config-lists");
    const name = list => Array.isArray(list) && list.length ? list.slice(0, 6).map(item => item.name ?? item.id).join(", ") + (list.length > 6 ? ` … +${list.length - 6}` : "") : "none";
    box.innerHTML = "";
    box.append(
      el("div", { class: "gauge-line", text: `Providers: ${name(providers)}` }),
      el("div", { class: "gauge-line", text: `MCP servers: ${name(mcp)}` }),
      el("div", { class: "gauge-line", text: `Skills: ${name(skills)}` }),
    );
  } catch {
    box.textContent = "";
  }
}

// ---- Config pages: the engine's settings file, read once, edited page by page ----
// What the Mac app's EngineConfig does for its Settings pages, from this side: values in,
// changes into one object, and saved whole as they're made — Done just goes back.

const MCP_CATALOG = [
  { id: "linear", title: "Linear", summary: "Issues, projects and cycles", access: "needs an account", settings: { type: "remote", url: "https://mcp.linear.app/mcp" } },
  { id: "sentry", title: "Sentry", summary: "Errors and performance problems in your apps", access: "needs an account", settings: { type: "remote", url: "https://mcp.sentry.dev/mcp" } },
  { id: "notion", title: "Notion", summary: "Pages and databases in your workspace", access: "needs an account", settings: { type: "remote", url: "https://mcp.notion.com/mcp" } },
  { id: "atlassian", title: "Atlassian", summary: "Jira issues and Confluence pages", access: "needs an account", settings: { type: "remote", url: "https://mcp.atlassian.com/v2/mcp" } },
  { id: "stripe", title: "Stripe", summary: "Payments, customers and Stripe's docs", access: "needs an account", settings: { type: "remote", url: "https://mcp.stripe.com" } },
  { id: "supabase", title: "Supabase", summary: "Databases, auth and storage in your projects", access: "needs an account", settings: { type: "remote", url: "https://mcp.supabase.com/mcp" } },
  { id: "neon", title: "Neon", summary: "Postgres databases and branches", access: "needs an account", settings: { type: "remote", url: "https://mcp.neon.tech/mcp" } },
  { id: "context7", title: "Context7", summary: "Current docs and examples for libraries", access: "no account needed", settings: { type: "remote", url: "https://mcp.context7.com/mcp" } },
  { id: "cloudflare-docs", title: "Cloudflare Docs", summary: "Cloudflare's documentation", access: "no account needed", settings: { type: "remote", url: "https://docs.mcp.cloudflare.com/mcp" } },
  { id: "huggingface", title: "Hugging Face", summary: "Models, datasets, Spaces and papers", access: "no account needed", settings: { type: "remote", url: "https://huggingface.co/mcp" } },
  { id: "chrome-devtools", title: "Chrome DevTools", summary: "Inspect and debug pages in Google Chrome", access: "runs on this machine", settings: { type: "local", command: ["npx", "chrome-devtools-mcp@latest"] } },
];

const CFG_ACTIONS = [
  ["edit", "Edit files"], ["shell", "Run commands"], ["read", "Read files"],
  ["external_directory", "Work outside the project"], ["webfetch", "Open web pages"],
  ["websearch", "Search the web"], ["subagent", "Hand work to subagents"], ["skill", "Use skills"],
];

const cfgGet = path => path.reduce((node, key) => (node && typeof node === "object" ? node[key] : undefined), state.config);

const cfgSet = (path, value) => {
  if (!state.config) return;
  let node = state.config;
  for (const key of path.slice(0, -1)) {
    if (typeof node[key] !== "object" || node[key] === null) node[key] = {};
    node = node[key];
  }
  const key = path[path.length - 1];
  if (value === null) delete node[key];
  else node[key] = value;
};

async function saveConfig() {
  try {
    await api("/api/config", { method: "PUT", body: { settings: state.config } });
    notify("Kuvo Code", "Saved to the engine's settings.");
    await bootConfig();
    return true;
  } catch (error) {
    complain(null, error);
    return false;
  }
}

/// Re-opens an existing editor so its fields line up with the file again, without bouncing.
function reEditor(kind, id) {
  if (state.cfgEditor?.kind !== kind || state.cfgEditor?.id !== id) return;
  openCfgEditor(kind, id);
}

async function bootConfig() {
  const [cfg, mcp, skills] = await Promise.all([
    api("/api/config").catch(() => null),
    api("/api/mcp").catch(() => null),
    api("/api/skills").catch(() => null),
  ]);
  if (cfg) {
    state.config = cfg.settings && typeof cfg.settings === "object" ? cfg.settings : {};
    state.configPath = cfg.path;
    state.configProblem = cfg.problem ?? null;
    state.configLive = cfg.live ?? null;
    state.opencode = cfg.opencode ?? null;
  }
  state.mcpLive = mcp?.servers ?? [];
  state.skillsEngine = skills?.skills ?? [];
  $("skills-folder").textContent = skills?.folder ? `Skills folder: ${skills.folder}/<name>/SKILL.md` : "";
  if (!state.cfgEditor) renderCfgPages();
  else refreshMcp();
  // What the composer and palette read reaches them again, as the engine sees it.
  loadCommands().catch(() => {});
  loadAgents().catch(() => {});
}

function renderCfgPages() {
  for (const id of ["cfg-problem", "mcp-problem", "agents-problem", "skills-problem", "commands-problem"]) {
    const box = $(id);
    if (!box) continue;
    box.hidden = !state.configProblem;
    box.textContent = state.configProblem ? `The settings file (${state.configPath}) has a problem: ${state.configProblem}` : "";
  }
  renderMcp();
  renderMcpCatalog();
  renderMcpTimeouts();
  renderOpencodeMcp();
  renderAgentsPage();
  renderSkillsPage();
  renderCommandsPage();
}

async function refreshMcp() {
  try { state.mcpLive = (await api("/api/mcp")).servers ?? []; } catch { state.mcpLive = []; }
  if (!state.cfgEditor) renderMcp();
}

// ---- MCP page ----

const mcpStatusOf = name => state.mcpLive.find(server => server.name === name)?.status;

function mcpStatusText(name, isOn) {
  if (!isOn) return ["Off", ""];
  const status = mcpStatusOf(name);
  switch (status?.status) {
    case "connected": return ["Connected", "ok"];
    case "pending": return ["Connecting…", "faint"];
    case "needs_auth": return ["Needs sign-in", "warn"];
    case "failed": return [`Couldn't connect${status?.error ? ` — ${status.error}` : ""}`, "danger"];
    case "disabled": return ["Off", ""];
    default: return ["Not started", "faint"];
  }
}

function mcpDetail(settings) {
  if (typeof settings?.url === "string") return settings.url;
  if (Array.isArray(settings?.command)) return settings.command.filter(word => typeof word === "string").join(" ");
  if (typeof settings?.command === "string") return settings.command;
  return "";
}

function renderMcp() {
  const list = $("mcp-list");
  if (!list) return;
  list.innerHTML = "";
  if (!state.config) return;
  const configured = Object.keys(state.config?.mcp?.servers ?? {}).filter(name => name !== "kuvo-browser");
  const live = state.mcpLive.map(server => server.name).filter(name => name !== "kuvo-browser" && !configured.includes(name));
  const names = [...new Set([...configured, ...live])].sort();
  if (!names.length) list.append(el("div", { class: "where", text: "None yet." }));
  for (const name of names) {
    const settings = state.config?.mcp?.servers?.[name];
    const isOn = settings ? settings.disabled !== true : true;
    const [title, tone] = mcpStatusText(name, isOn);
    const row = el("div", { class: "cfg-row" },
      el("div", { class: "cfg-row-main" },
        el("div", { class: "cfg-row-title" },
          el("strong", { text: name }),
          el("span", { class: `where ${tone}`, text: title }),
        ),
        settings ? el("div", { class: "where", text: mcpDetail(settings) }) : null,
      ),
    );
    if (isOn && mcpStatusOf(name)?.status === "failed") {
      row.append(el("button", { class: "small", text: "Try Again", onclick: async () => {
        try { await api(`/api/mcp/${encodeURIComponent(name)}/connect`, { method: "POST", body: {} }); }
        catch (error) { complain(null, error); }
        await refreshMcp();
      } }));
    }
    if (settings) {
      row.append(el("button", { class: "small", text: "Edit…", onclick: () => openCfgEditor("mcp", name) }));
      const toggle = el("input", { type: "checkbox", title: `Turn on or off ${name}` });
      toggle.checked = isOn;
      toggle.addEventListener("change", () => {
        cfgSet(["mcp", "servers", name, "disabled"], toggle.checked ? null : true);
        saveConfig();
      });
      row.append(toggle);
    }
    list.append(row);
  }
}

function renderMcpCatalog() {
  const list = $("mcp-catalog");
  if (!list) return;
  list.innerHTML = "";
  for (const server of MCP_CATALOG) {
    const added = state.config?.mcp?.servers?.[server.id] != null;
    list.append(el("div", { class: "cfg-row" },
      el("div", { class: "cfg-row-main" },
        el("div", { class: "cfg-row-title" }, el("strong", { text: server.title }), el("span", { class: "where", text: server.access })),
        el("div", { class: "where", text: server.summary }),
      ),
      added ? el("span", { class: "where", text: "Added" }) :
        el("button", { class: "small", text: "Add", onclick: () => {
          cfgSet(["mcp", "servers", server.id], { ...server.settings, codemode: false });
          saveConfig();
        } }),
    ));
  }
}

function renderMcpTimeouts() {
  const put = (id, key) => { const box = $(id); if (box) box.value = cfgGet(["mcp", "timeout", key]) ?? ""; };
  put("mcp-timeout-startup", "startup");
  put("mcp-timeout-catalog", "catalog");
  put("mcp-timeout-execution", "execution");
}

/// The MCP servers in opencode's own settings — what the CLI, another agent, or a tool like
/// OpenDesign wrote there. The engine here reads its own folder only, so these have to be
/// brought over to be of any use.
function opencodeServers() {
  const theirs = state.opencode?.settings;
  const mcp = theirs && typeof theirs.mcp === "object" && theirs.mcp ? theirs.mcp : {};
  const servers = {};
  for (const [name, entry] of Object.entries(mcp.servers ?? {})) {
    if (entry && typeof entry === "object") servers[name] = entry;
  }
  for (const [name, entry] of Object.entries(mcp)) {
    if (name === "servers" || !entry || typeof entry !== "object" || Array.isArray(entry)) continue;
    if (!servers[name]) servers[name] = entry;
  }
  return servers;
}

function renderOpencodeMcp() {
  const box = $("opencode-mcp");
  if (!box) return;
  box.innerHTML = "";
  const note = $("opencode-path");
  if (note) note.textContent = state.opencode?.path ? `opencode's own settings: ${state.opencode.path}` : "";
  const theirs = opencodeServers();
  const ours = state.config?.mcp?.servers ?? {};
  const names = Object.keys(theirs);
  if (!names.length) {
    box.append(el("div", { class: "where", text: "Nothing there yet." }));
    return;
  }
  const bring = async name => {
    try {
      const answer = await api("/api/config/import", { method: "POST", body: name ? { name } : {} });
      if (answer.added?.length) {
        notify("Kuvo Code", `${answer.added.join(", ")} ${answer.added.length === 1 ? "is" : "are"} here now. The engine reads them in a moment.`);
        // The engine reads its settings when it starts: start it over, so the new servers
        // are picked up without the user having to think about it.
        await restartEngineNow();
      } else {
        notify("Kuvo Code", "It was already here.");
      }
      await bootConfig();
      await refreshMcp();
    } catch (error) {
      complain(null, error);
    }
  };
  for (const name of names) {
    const here = ours[name] != null;
    box.append(el("div", { class: "cfg-row" },
      el("div", { class: "cfg-row-main" },
        el("div", { class: "cfg-row-title" },
          el("strong", { text: name }),
          here ? el("span", { class: "where ok", text: "Already here" }) : null,
        ),
        el("div", { class: "where", text: mcpDetail(theirs[name]) }),
      ),
      here ? null : el("button", { class: "small", text: "Add here", onclick: () => bring(name) }),
    ));
  }
  const all = $("opencode-import-all");
  if (all) {
    all.hidden = !names.some(name => ours[name] == null);
    all.onclick = () => bring(null);
  }
}

function timeoutSaved(key) {
  return event => { cfgSet(["mcp", "timeout", key], event.target.value === "" ? null : Number(event.target.value)); saveConfig(); };
}

// ---- Agents page ----

const AGENTS_BUILTIN = ["build", "plan", "general", "explore"];

function agentRows() {
  const configured = Object.keys(state.config?.agents ?? {});
  const ids = [...AGENTS_BUILTIN, ...configured].filter((id, index, all) => all.indexOf(id) === index && !["compaction", "title", "summary"].includes(id));
  return ids.map(id => {
    const settings = state.config?.agents?.[id] ?? {};
    const live = state.agents.find(agent => agent.id === id);
    return {
      id,
      name: live?.name ?? id,
      mode: settings.mode ?? live?.mode ?? "primary",
      description: settings.description ?? live?.description ?? "",
      isOff: settings.disabled === true,
    };
  });
}

function modelSelect(select, path, emptyTitle) {
  select.innerHTML = "";
  select.append(el("option", { value: "", text: emptyTitle }));
  const current = typeof cfgGet(path) === "string" ? cfgGet(path) : "";
  const offered = new Set();
  const providers = new Map();
  for (const model of state.models) {
    if (!providers.has(model.providerID)) providers.set(model.providerID, []);
    providers.get(model.providerID).push(model);
  }
  for (const [provider, models] of providers) {
    const group = el("optgroup", { label: provider });
    for (const model of models) {
      const value = `${model.providerID}/${model.id}`;
      offered.add(value);
      group.append(el("option", { value, text: model.name }));
    }
    select.append(group);
  }
  if (current && !offered.has(current)) select.append(el("option", { value: current, text: current }));
  select.value = current;
  select.onchange = () => { cfgSet(path, select.value === "" ? null : select.value); saveConfig(); };
}

function renderAgentsPage() {
  const defaultAgent = $("agent-default");
  if (!defaultAgent || !state.config) return;
  defaultAgent.innerHTML = "";
  defaultAgent.append(el("option", { value: "", text: "Build" }));
  const primary = state.agents.filter(agent => agent.mode === "primary" && !["build", "compaction", "title", "summary"].includes(agent.id));
  for (const agent of primary) defaultAgent.append(el("option", { value: agent.id, text: agent.name }));
  defaultAgent.value = cfgGet(["default_agent"]) ?? "";
  defaultAgent.onchange = () => { cfgSet(["default_agent"], defaultAgent.value === "" ? null : defaultAgent.value); saveConfig(); };

  modelSelect($("agent-default-model"), ["model"], "The engine's choice");
  modelSelect($("agent-title-model"), ["agents", "title", "model"], "The session's model");

  const list = $("agents-list");
  list.innerHTML = "";
  for (const agent of agentRows()) {
    list.append(el("div", { class: "cfg-row" },
      el("div", { class: "cfg-row-main" },
        el("div", { class: "cfg-row-title" },
          el("strong", { text: agent.name }),
          el("span", { class: "where", text: agent.mode === "subagent" ? "Subagent" : agent.mode === "all" ? "Mode and subagent" : "Mode" }),
          agent.isOff ? el("span", { class: "where warn", text: "Off" }) : null,
        ),
        agent.description ? el("div", { class: "where", text: agent.description }) : null,
      ),
      el("button", { class: "small", text: "Edit…", onclick: () => openCfgEditor("agent", agent.id) }),
    ));
  }
}

// ---- Skills page ----

function skillOn(id) {
  const items = state.config?.permissions ?? [];
  return !items.some(item => item?.action === "skill" && item?.resource === id && item?.effect === "deny");
}

function renderSkillsPage() {
  const list = $("skills-list");
  if (!list) return;
  list.innerHTML = "";
  if (!state.skillsEngine.length) list.append(el("div", { class: "where", text: "None yet." }));
  for (const skill of state.skillsEngine) {
    const own = typeof skill.path === "string" && !skill.path.startsWith("/builtin");
    const row = el("div", { class: "cfg-row" },
      el("div", { class: "cfg-row-main" },
        el("div", { class: "cfg-row-title" },
          el("strong", { text: skill.name }),
          el("span", { class: "where", text: own ? "the skills folder" : "the engine's own" })),
        skill.description ? el("div", { class: "where", text: skill.description }) : null,
      ),
    );
    if (own) row.append(el("button", { class: "small", text: "Edit…", onclick: () => openCfgEditor("skill", skill.id) }));
    const toggle = el("input", { type: "checkbox", title: `Use ${skill.name}` });
    toggle.checked = skillOn(skill.id);
    toggle.addEventListener("change", () => {
      const items = (state.config?.permissions ?? []).filter(item => !(item?.action === "skill" && item?.resource === skill.id && item?.effect === "deny"));
      if (!toggle.checked) items.push({ action: "skill", resource: skill.id, effect: "deny" });
      cfgSet(["permissions"], items.length ? items : null);
      saveConfig();
    });
    row.append(toggle);
    list.append(row);
  }
}

// ---- Commands page ----

function renderCommandsPage() {
  const list = $("commands-list");
  if (!list) return;
  list.innerHTML = "";
  const names = Object.keys(state.config?.commands ?? {}).sort();
  if (!names.length) list.append(el("div", { class: "where", text: "None yet." }));
  for (const name of names) {
    const settings = state.config.commands[name] ?? {};
    list.append(el("div", { class: "cfg-row" },
      el("div", { class: "cfg-row-main" },
        el("div", { class: "cfg-row-title" }, el("strong", { text: "/" + name })),
        settings.description ? el("div", { class: "where", text: settings.description }) : null,
      ),
      el("button", { class: "small", text: "Edit…", onclick: () => openCfgEditor("command", name) }),
    ));
  }
  const others = $("commands-others");
  if (!others) return;
  others.innerHTML = "";
  const own = state.commands.filter(command => !names.includes(command.name));
  if (!own.length) others.append(el("div", { class: "where", text: "None." }));
  for (const command of own) {
    others.append(el("div", { class: "cfg-row" },
      el("div", { class: "cfg-row-main" },
        el("div", { class: "cfg-row-title" }, el("strong", { text: "/" + command.name })),
        command.description ? el("div", { class: "where", text: command.description }) : null,
      ),
    ));
  }
}

// ---- The config editors: a settings sub-page, fields per kind, saved as they're made ----

/// The command as words (quotes hold spaces together); a word typed back quoted where needed.
function commandWords(line) {
  const words = [];
  let word = "";
  let quote = null, escaped = false, hasWord = false;
  for (const character of line) {
    if (escaped) { word += character; escaped = false; }
    else if (character === "\\" && quote !== "'") { escaped = true; hasWord = true; }
    else if (quote) { if (character === quote) quote = null; else word += character; }
    else if (character === '"' || character === "'") { quote = character; hasWord = true; }
    else if (character === " " || character === "\t") { if (hasWord) { words.push(word); word = ""; hasWord = false; } }
    else { word += character; hasWord = true; }
  }
  if (hasWord) words.push(word);
  return words;
}

function commandQuoted(word) {
  if (word.includes(" ") || word.includes('"') || word.includes("'") || word.includes("\\")) {
    return '"' + word.replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + '"';
  }
  return word;
}

const commandLine = command => (Array.isArray(command) ? command.filter(word => typeof word === "string") : [])
  .map(commandQuoted).join(" ");

function idForName(text) {
  return text.trim().replace(/ /g, "-").replace(/[^a-zA-Z0-9_-]/g, "");
}

function lowerIDForName(text) {
  return text.toLowerCase().trim().replace(/ /g, "-").replace(/[^a-z0-9_-]/g, "");
}

function openCfgEditor(kind, id) {
  if (!$("settings-modal") || !$("editor-fields")) return;
  if (!state.config) { bootConfig().then(() => { if (state.config) openCfgEditor(kind, id); }); return; }
  state.cfgEditor = { kind, id };
  state.settingsSection = "editor";
  $("editor-title").textContent = { mcp: id ?? "Add Server", agent: id ?? "New Agent", skill: id ?? "New Skill", command: id ? "/" + id : "New Command" }[kind];
  const fields = $("editor-fields");
  fields.innerHTML = "";
  $("editor-buttons").innerHTML = "";
  if (kind === "mcp") editorMcp(fields, id);
  else if (kind === "agent") editorAgent(fields, id);
  else if (kind === "skill") editorSkill(fields, id);
  else if (kind === "command") editorCommand(fields, id);
  document.querySelectorAll(".settings-page").forEach(page => { page.hidden = page.dataset.section !== "editor"; });
  document.querySelectorAll(".settings-nav button").forEach(button => { button.classList.toggle("active", button.dataset.section === "editor"); });
  $("settings-modal").hidden = false;
  $("settings-close").textContent = "Done";
}

function closeCfgEditor(kind) {
  state.cfgEditor = null;
  state.settingsSection = kind === "mcp" ? "mcp" : kind === "agent" ? "agents" : kind === "skill" ? "skills" : "commands";
  openSettings();
}

function editorButtons(kind, id, { onRemove } = {}) {
  const done = $("editor-buttons");
  done.innerHTML = "";
  if (id !== null && onRemove) {
    done.append(el("button", { class: "danger small", text: { mcp: "Remove Server…", agent: "Remove Agent…", skill: "Delete Skill…", command: "Delete Command…" }[kind], onclick: () => {
      if (!confirm("Remove it?")) return;
      onRemove();
    } }));
  }
  done.append(el("button", { class: "primary", text: "Done", onclick: () => closeCfgEditor(kind) }));
}

function fieldLine(fields, label, value, onchange, { placeholder, mono } = {}) {
  const input = el("input", { type: "text", placeholder: placeholder ?? "" });
  input.value = value ?? "";
  input.addEventListener("change", () => { onchange(input.value); });
  if (mono) input.classList.add("mono");
  fields.append(el("div", { class: "settings-row" }, el("span", { text: label }), input));
  return input;
}

function fieldToggle(fields, label, note, checked, onchange) {
  const input = el("input", { type: "checkbox" });
  input.checked = checked;
  input.addEventListener("change", () => onchange(input.checked));
  const labelBox = el("span", { class: "setting-label" });
  labelBox.append(el("span", { text: label }));
  if (note) labelBox.append(el("span", { class: "where", text: note }));
  const row = el("div", { class: "settings-row" }, labelBox, input);
  fields.append(row);
  return input;
}

function fieldArea(fields, label, value, onchange, { placeholder, rows = 6, mono } = {}) {
  const area = el("textarea", { placeholder: placeholder ?? "", rows: String(rows) });
  area.value = value ?? "";
  area.addEventListener("change", () => onchange(area.value));
  if (mono) area.classList.add("mono");
  const column = el("div", { class: "settings-row column" }, el("span", { text: label }), area);
  fields.append(column);
  return area;
}

function fieldPairs(fields, label, object, onChange) {
  const values = object && typeof object === "object" && !Array.isArray(object) ? Object.entries(object).map(([key, value]) => (typeof value === "string" ? value : JSON.stringify(value))).map((value, index) => [Object.keys(object)[index], value]) : [];
  const box = el("div", { class: "kvs" });
  const commit = () => {
    const next = {};
    for (const [key, value] of values) if (key) next[key] = value;
    onChange(next);
  };
  const draw = () => {
    box.innerHTML = "";
    for (const pair of values.values()) {
      const holder = pair;
      const keyInput = el("input", { type: "text", value: holder[0] ?? "", placeholder: "Name" });
      const valueInput = el("input", { type: "text", value: holder[1] ?? "", placeholder: "Value" });
      keyInput.addEventListener("change", () => { holder[0] = keyInput.value.trim(); draw(); commit(); });
      valueInput.addEventListener("change", () => { holder[1] = valueInput.value; commit(); });
      const del = el("button", { class: "small", text: "✕", title: "Remove this pair", onclick: () => { values.splice(values.indexOf(holder), 1); draw(); commit(); } });
      box.append(el("div", { class: "kvs-row" }, keyInput, valueInput, del));
    }
    if (!values.length) box.append(el("div", { class: "where", text: "None." }));
  };
  draw();
  const column = el("div", { class: "settings-row column" }, el("span", { text: label }), box,
    el("button", { class: "small", text: "Add a pair", onclick: () => { values.push(["", ""]); draw(); } }));
  fields.append(column);
}

function fieldPick(fields, label, value, options, onChange) {
  const select = el("select");
  for (const option of options) select.append(el("option", { value: option[0], text: option[1] }));
  if (value && !options.some(option => option[0] === value)) select.append(el("option", { value, text: value }));
  if (value == null) select.value = options[0]?.[0];
  else select.value = value;
  select.onchange = () => onChange(select.value);
  fields.append(el("div", { class: "settings-row" }, el("span", { text: label }), select));
  return select;
}

// ---- MCP server editor ----

const MCP_KIND_FIELDS = ["command", "cwd", "environment", "url", "headers", "oauth"];

function editorMcp(fields, id) {
  if (!id) {
    const nameInput = fieldLine(fields, "Name", "", () => {}, { placeholder: "github" });
    const note = el("div", { class: "where", text: "Names use lowercase letters, digits, hyphens and underscores. The server's tools are named after it." });
    fields.append(note);
    nameInput.addEventListener("change", () => {
      const fresh = idForName(nameInput.value);
      if (!fresh) note.textContent = "A name needs a letter or a number.";
      else if (cfgGet(["mcp", "servers", fresh]) != null || state.mcpLive.some(server => server.name === fresh)) note.textContent = `There's a server called ${fresh} already.`;
      else if (fresh !== nameInput.value.trim()) note.textContent = `It'll be called ${fresh}.`;
      else note.textContent = "Looks good. Done creates it, off until it has a command or URL.";
    });
    editorButtons("mcp", null, { onRemove: null });
    $("editor-buttons").innerHTML = "";
    $("editor-buttons").append(el("button", { class: "primary", text: "Create Server", onclick: () => {
      const fresh = idForName(nameInput.value);
      if (!fresh) { complain(null, "A name needs a letter or a number."); return; }
      if (cfgGet(["mcp", "servers", fresh]) != null) { complain(null, `There's a server called ${fresh} already.`); return; }
      // Off until it has a command or URL, so the engine doesn't try to run an empty one.
      cfgSet(["mcp", "servers", fresh], { type: "local", command: [], disabled: true, codemode: false });
      openCfgEditor("mcp", fresh);
    } }));
    return;
  }

  const base = ["mcp", "servers", id];
  const settings = cfgGet(base) ?? {};
  const isRemote = settings.type === "remote";

  fieldPick(fields, "Runs", isRemote ? "remote" : "local", [["local", "On this machine"], ["remote", "On the web"]], value => {
    if (value === (isRemote ? "remote" : "local")) return;
    // What the kind you leave has is put aside; what the other had comes back — then it starts in the file again.
    const leaving = {};
    for (const key of MCP_KIND_FIELDS) { const had = settings[key]; if (had !== undefined) leaving[key] = had; }
    for (const key of Object.keys(leaving)) cfgSet([...base, key], null);
    for (const [key, had] of Object.entries(MCP_PUT_ASIDE.get(id) ?? {})) cfgSet([...base, key], had);
    MCP_PUT_ASIDE.set(id, leaving);
    cfgSet([...base, "disabled"], Object.keys(leaving).length ? settings.disabled : true);
    cfgSet([...base, "type"], value);
    saveConfig().then(() => reEditor("mcp", id));
  });

  if (isRemote) {
    fieldLine(fields, "URL", settings.url ?? "", value => {
      cfgSet([...base, "url"], value === "" ? null : value);
      if (value === "") cfgSet([...base, "disabled"], true); else cfgSet([...base, "disabled"], null);
      saveConfig();
    }, { placeholder: "https://example.com/mcp" });
    const oauth = settings.oauth;
    fieldToggle(fields, "Sign in when the server asks", typeof oauth === "object" ? "With the sign-in set up in the settings file." : "Turn off for a server that takes an API key in a header instead.",
      typeof oauth === "object" ? true : oauth !== false,
      on => { if (typeof oauth !== "object") cfgSet([...base, "oauth"], on ? null : false); });
    fieldPairs(fields, "Headers", settings.headers, next => { cfgSet([...base, "headers"], Object.keys(next).length ? next : null); saveConfig(); });
  } else {
    const commandArea = fieldArea(fields, "Command", commandLine(settings.command), value => {
      const words = commandWords(value);
      cfgSet([...base, "command"], words);
      if (words.length) cfgSet([...base, "disabled"], null); else cfgSet([...base, "disabled"], true);
      saveConfig().then(() => reEditor("mcp", id));
    }, { placeholder: "npx -y @modelcontextprotocol/server-github", rows: 2, mono: true });
    commandArea.addEventListener("change", () => reEditor("mcp", id));
    fieldLine(fields, "Working folder", settings.cwd ?? "", value => { cfgSet([...base, "cwd"], value === "" ? null : value); saveConfig(); }, { placeholder: "The project's folder" });
    fieldPairs(fields, "Environment Variables", settings.environment, next => { cfgSet([...base, "environment"], Object.keys(next).length ? next : null); saveConfig(); });
  }
  fieldToggle(fields, "Let the agent call its tools from code", "Code Mode: the agent looks up this server's tools and combines several in one step. Smaller models may not find its tools this way.", settings.codemode !== false, on => cfgSet([...base, "codemode"], on ? null : false));

  editorButtons("mcp", id, {
    onRemove: () => {
      cfgSet(base, null);
      saveConfig();
      closeCfgEditor("mcp");
    },
  });
}

// A kind's put-aside fields, per server being edited (in memory, as the Mac app's editor does).
const MCP_PUT_ASIDE = new Map();

// ---- Agent editor ----

function editorAgent(fields, id) {
  if (!id) {
    const nameInput = fieldLine(fields, "Name", "", () => {}, { placeholder: "reviewer" });
    const note = el("div", { class: "where", text: "A short name without spaces. It's how the agent is chosen." });
    fields.append(note);
    nameInput.addEventListener("change", () => {
      const fresh = lowerIDForName(nameInput.value);
      if (!fresh) note.textContent = "A name needs a letter or a number.";
      else if (cfgGet(["agents", fresh]) != null) note.textContent = `There's an agent called ${fresh} already.`;
      else if (fresh !== nameInput.value.trim()) note.textContent = `It'll be called ${fresh}.`;
      else note.textContent = "Looks good. Done creates it.";
    });
    const buttons = $("editor-buttons");
    buttons.append(el("button", { class: "primary", text: "Create Agent", onclick: () => {
      const fresh = lowerIDForName(nameInput.value);
      if (!fresh) { complain(null, "A name needs a letter or a number."); return; }
      if (cfgGet(["agents", fresh]) != null) { complain(null, `There's an agent called ${fresh} already.`); return; }
      cfgSet(["agents", fresh], { mode: "primary", description: "" });
      saveConfig();
      openCfgEditor("agent", fresh);
    } }));
    return;
  }

  const base = ["agents", id];
  const settings = cfgGet(base) ?? {};
  const live = state.agents.find(agent => agent.id === id);
  const builtIn = AGENTS_BUILTIN.includes(id) || live?.hidden === true;
  fields.append(el("div", { class: "where", text: `Agent: ${live?.name ?? id}${builtIn ? " (built into the engine)" : ""}` }));
  fieldArea(fields, "Description", settings.description ?? "", value => { cfgSet([...base, "description"], value === "" ? null : value); saveConfig(); }, { placeholder: builtIn ? (live?.description ?? "What it's for, so the agent knows when to use it") : "What it's for, so the agent knows when to use it", rows: 3 });
  fieldPick(fields, "Use as", settings.mode ?? live?.mode ?? "primary",
    [["primary", "Mode"], ["subagent", "Subagent"], ["all", "Mode and subagent"]],
    value => { cfgSet([...base, "mode"], value); saveConfig(); });
  const modelRow = el("div", { class: "settings-row" }, el("span", { text: "Model" }));
  const modelInput = el("select");
  modelRow.append(modelInput);
  fields.append(modelRow);
  modelSelect(modelInput, [...base, "model"], "The session's model");
  fieldLine(fields, "Most steps per message", settings.steps ?? "", value => { cfgSet([...base, "steps"], value === "" ? null : Number(value)); saveConfig(); }, { placeholder: "No limit" });
  fieldToggle(fields, "Use this agent", null, settings.disabled !== true, on => { cfgSet([...base, "disabled"], on ? null : true); saveConfig(); });
  fieldArea(fields, "Instructions", settings.system ?? "", value => { cfgSet([...base, "system"], value === "" ? null : value); saveConfig(); }, { placeholder: builtIn ? "Leave empty to keep the engine's own. Anything here replaces them." : "How it should work. The project's AGENTS.md, skills and MCP servers still apply.", rows: 8 });

  const rulesBox = el("div", { class: "rules" });
  const items = () => Array.isArray(cfgGet([...base, "permissions"])) ? cfgGet([...base, "permissions"]).map(item => (item && typeof item === "object" ? { ...item } : item)) : [];
  const redraw = () => {
    rulesBox.innerHTML = "";
    const all = items();
    const shown = all.filter(item => item && typeof item === "object" && item.action !== "skill");
    for (const rule of shown) {
      const index = all.indexOf(rule);
      const action = el("select");
      for (const [value, label] of CFG_ACTIONS) action.append(el("option", { value, text: label }));
      const resource = el("input", { type: "text", value: rule.resource ?? "*", placeholder: "Pattern, like git push *" });
      const effect = el("select");
      for (const value of ["allow", "ask", "deny"]) effect.append(el("option", { value, text: value }));
      action.value = rule.action ?? "edit";
      effect.value = rule.effect ?? "ask";
      const commit = () => {
        all[index] = { action: action.value, resource: resource.value === "" ? "*" : resource.value, effect: effect.value };
        cfgSet([...base, "permissions"], all);
        saveConfig();
      };
      action.onchange = commit;
      effect.onchange = commit;
      resource.onchange = commit;
      rulesBox.append(el("div", { class: "kvs-row" }, action, resource, effect, el("button", { class: "small", text: "✕", onclick: () => {
        all.splice(index, 1);
        cfgSet([...base, "permissions"], all.length ? all : null);
        saveConfig();
        redraw();
      } })));
    }
    if (!shown.length) rulesBox.append(el("div", { class: "where", text: "None yet." }));
  };
  redraw();
  fields.append(el("div", { class: "settings-row column" },
    el("span", { text: "Permissions" }),
    rulesBox,
    el("button", { class: "small", text: "Add a rule", onclick: () => {
      const all = items();
      all.push({ action: "edit", resource: "*", effect: "ask" });
      cfgSet([...base, "permissions"], all);
      saveConfig();
      redraw();
    } }),
  ));
  fields.append(el("div", { class: "where", text: "Added after the ones in Settings › Permissions, so these win for this agent." }));

  editorButtons("agent", id, {
    onRemove: () => {
      cfgSet(base, null);
      saveConfig();
      closeCfgEditor("agent");
    },
  });
}

// ---- Skill editor: a SKILL.md in the skills folder, one file per skill, as the Mac app writes ----

function skillNameFrom(text) {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 64).replace(/[^a-z0-9-]/g, "");
}

function skillText(name, summary, body, existing = "") {
  let others = [];
  if (existing.startsWith("---")) {
    const end = existing.indexOf("\n---", 3);
    if (end >= 0) {
      others = existing.slice(3, end).split("\n").filter(line => line.trim() && !line.startsWith("name:") && !line.startsWith("description:"));
    }
  }
  const summaryLine = String(summary).replace(/[\r\n]+/g, " ").trim();
  const quote = text => '"' + text.replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + '"';
  const header = [`name: ${name}`, `description: ${quote(summaryLine)}`, ...others].join("\n");
  return `---\n${header}\n---\n\n${String(body).trim()}\n`;
}

async function editorSkill(fields, id) {
  let file = "";
  if (id) {
    try { file = (await api(`/api/skill-file/${id}`)).text ?? ""; } catch {}
  }
  const header = file.startsWith("---") ? file.indexOf("\n---", 3) : -1;
  const summaryMatch = header >= 0 ? file.slice(3, header).match(/^description:\s*["']?(.*?)["']?\s*$/m) : null;
  const summary = summaryMatch ? summaryMatch[1].replace(/\\(["\\])/g, "$1") : "";
  const body = header >= 0 ? file.slice(file.indexOf("\n", header + 4) + 1) : file;

  const nameLine = fieldLine(fields, "Name", id ?? "", () => {}, { placeholder: "writing well" });
  const note = el("div", { class: "where", text: "Names use lowercase letters a to z, digits and hyphens." });
  fields.append(note);
  nameLine.disabled = id != null;
  const summaryArea = fieldArea(fields, "Description", summary, () => {}, { rows: 2, placeholder: "What it's for: the agent reaches for the skill by this." });
  const bodyArea = fieldArea(fields, "Instructions", body, () => {}, { rows: 10, placeholder: id ? "When a task calls for this, the agent loads it: how to do it, step by step." : "How to do the task, step by step. Scripts can sit in the same folder." });
  if (!id) {
    nameLine.addEventListener("change", () => {
      const fresh = skillNameFrom(nameLine.value);
      if (nameLine.value.trim() && !fresh) note.textContent = "Names use the letters a to z and digits, and this one has none.";
      else if (state.skillsEngine.some(skill => skill.id === fresh)) note.textContent = `There's a skill called ${fresh} already.`;
      else note.textContent = `It lives in the skills folder as ${fresh || "<name>"}/SKILL.md.`;
    });
  }

  const write = async () => {
    const fresh = id ?? skillNameFrom(nameLine.value);
    if (!fresh) { complain(null, "Names use the letters a to z and digits, and this one has none."); return null; }
    if (id == null && state.skillsEngine.some(skill => skill.id === fresh)) { complain(null, `There's a skill called ${fresh} already.`); return null; }
    try {
      await api(`/api/skill-file/${fresh}`, { method: "PUT", body: { text: skillText(fresh, summaryArea.value.trim(), bodyArea.value, file) } });
    } catch (error) { complain(null, error); return null; }
    await bootConfig();
    return fresh;
  };

  const buttons = $("editor-buttons");
  buttons.append(el("button", { class: "primary", text: "Save Skill", onclick: async () => {
    const fresh = await write();
    if (!fresh) return;
    closeCfgEditor("skill");
  } }));
  buttons.append(el("button", { class: "primary", text: "Done", onclick: () => closeCfgEditor("skill") }));
  buttons.append(el("button", { class: "danger small", text: "Delete Skill…", onclick: () => {
    if (!confirm("Delete this skill?")) return;
    api(`/api/skill-file/${id}`, { method: "DELETE" }).catch(error => complain(null, error));
    bootConfig();
    closeCfgEditor("skill");
  } }));
}

// ---- Command editor ----

function editorCommand(fields, id) {
  const base = id ? ["commands", id] : null;
  const settings = id ? cfgGet(base) ?? {} : {};
  if (!id) {
    const nameLine = fieldLine(fields, "Name", "", () => {}, { placeholder: "test" });
    nameLine.dataset.forNew = "command-name";
  } else {
    nameLineEditing(fields, id);
  }
  fieldArea(fields, "Description", settings.description ?? "", value => { if (base) { cfgSet([...base, "description"], value === "" ? null : value); saveConfig(); } }, { placeholder: "Shown in the list when you type /", rows: 3 });
  const agentSelect = el("select");
  agentSelect.append(el("option", { value: "", text: "The session's agent" }));
  for (const agent of state.agents.filter(agent => !agent.hidden)) agentSelect.append(el("option", { value: agent.id, text: agent.name }));
  if (settings.agent && !state.agents.some(agent => agent.id === settings.agent)) agentSelect.append(el("option", { value: settings.agent, text: settings.agent }));
  agentSelect.value = settings.agent ?? "";
  agentSelect.onchange = () => { if (base) { cfgSet([...base, "agent"], agentSelect.value === "" ? null : agentSelect.value); saveConfig(); } };
  fields.append(el("div", { class: "settings-row" }, el("span", { text: "Agent" }), agentSelect));

  const modelRow = el("div", { class: "settings-row" }, el("span", { text: "Model" }));
  const modelInput = el("select");
  modelRow.append(modelInput);
  fields.append(modelRow);
  if (base) modelSelect(modelInput, [...base, "model"], "The agent's or session's model");

  if (base) {
    fieldToggle(fields, "Run as a subagent", "In the background, without filling up the conversation.", settings.subagent === true, on => { cfgSet([...base, "subagent"], on ? true : null); saveConfig(); });
    fieldArea(fields, "Prompt", settings.template ?? "", value => { cfgSet([...base, "template"], value); saveConfig(); }, { rows: 9, placeholder: "What the agent gets. $ARGUMENTS is what you type after the command; $1, $2 and so on are its words." });
  } else {
    const template = fieldArea(fields, "Prompt", "", () => {}, { rows: 9, placeholder: "What the agent gets. $ARGUMENTS is what you type after the command; $1, $2 and so on are its words." });
    template.dataset.forNew = "command-template";
  }

  if (!id) {
    const note = el("div", { class: "where", text: "A short name without spaces: you'll type / and this name. A name that's taken can't be used." });
    fields.append(note);
    const buttons = $("editor-buttons");
    const nameInput = fields.querySelector("[data-for-new='command-name']");
    const templateArea = fields.querySelector("[data-for-new='command-template']");
    nameInput.addEventListener("change", () => {
      const fresh = idForName(nameInput.value);
      note.textContent = !nameInput.value.trim() ? "A short name without spaces: you'll type / and this name." :
        cfgGet(["commands", fresh]) != null || state.commands?.some(command => command.name === fresh) ? `There's a command called /${fresh} already.` : `You'll type /${fresh}.`;
    });
    buttons.querySelectorAll(".primary").forEach(button => button.remove());
    buttons.append(el("button", { class: "primary", text: "Create Command", onclick: () => {
      const fresh = idForName(nameInput.value);
      if (!fresh) { complain(null, "A name needs a letter or a number."); return; }
      if (cfgGet(["commands", fresh]) != null) { complain(null, `There's a command called /${fresh} already.`); return; }
      cfgSet(["commands", fresh], { template: templateArea?.value ?? "" });
      saveConfig();
      openCfgEditor("command", fresh);
    } }));
    return;
  }

  editorButtons("command", id, {
    onRemove: () => {
      cfgSet(base, null);
      saveConfig();
      closeCfgEditor("command");
    },
  });
}

function nameLineEditing(fields, id) {
  fields.append(el("div", { class: "where", text: `Run by typing /${id}.` }));
}

// The engine-side of settings changes: the engine reads them again when it starts over.
async function restartEngineNow() {
  const { version } = await api("/api/engine/restart", { method: "POST", body: {} });
  notify("Kuvo Code", `The engine is back (${version}).`);
  await loadSessions();
  if (state.session) await openSession(state.session.id).catch(() => {});
}
$("engine-restart").addEventListener("click", async () => {
  const button = $("engine-restart");
  button.disabled = true;
  try {
    await restartEngineNow();
    await bootConfig();
  } catch (error) {
    complain(null, error);
  }
  button.disabled = false;
});
$("mcp-timeout-startup").addEventListener("change", timeoutSaved("startup"));
$("mcp-timeout-catalog").addEventListener("change", timeoutSaved("catalog"));
$("mcp-timeout-execution").addEventListener("change", timeoutSaved("execution"));
$("mcp-add").addEventListener("click", () => openCfgEditor("mcp", null));
$("agent-new").addEventListener("click", () => openCfgEditor("agent", null));
$("skill-new").addEventListener("click", () => openCfgEditor("skill", null));
$("command-new").addEventListener("click", () => openCfgEditor("command", null));

function openSettings() {
  applyLook();
  $("settings-modal").hidden = false;
  const section = state.settingsSection ?? "appearance";
  document.querySelectorAll(".settings-nav button").forEach(button => {
    button.classList.toggle("active", button.dataset.section === section);
  });
  document.querySelectorAll(".settings-page").forEach(page => {
    page.hidden = page.dataset.section !== section;
  });
  renderShortcutEditor();
  renderProjects();
  renderSystemSettings();
  renderSavedPermissions();
  renderConfigLists();
  bootConfig();
  for (const button of document.querySelectorAll(".settings-nav button")) button.onclick = () => {
    if (button.dataset.section === "editor") return;
    state.cfgEditor = null;
    state.settingsSection = button.dataset.section;
    openSettings();
  };
}

function closeSettings() {
  $("settings-modal").hidden = true;
}

$("settings-open").addEventListener("click", openSettings);
$("settings-close").addEventListener("click", closeSettings);
$("settings-modal").addEventListener("click", event => { if (event.target === $("settings-modal")) closeSettings(); });
$("setting-text-size").addEventListener("change", event => { look.textSize = event.target.value; applyLook(); });
$("setting-motion").addEventListener("change", event => { look.motion = event.target.value; applyLook(); });
$("setting-theme").addEventListener("change", event => { look.theme = event.target.value; applyLook(); });

try {
  const stored = JSON.parse(localStorage.getItem(LOOK_KEY) || "{}");
  if (stored.accent in lookAccents) look.accent = stored.accent;
  if (["13", "14", "16"].includes(stored.textSize)) look.textSize = stored.textSize;
  if (["full", "reduced"].includes(stored.motion)) look.motion = stored.motion;
  if (["system", "light", "dark"].includes(stored.theme)) look.theme = stored.theme;
} catch {}

// ---- Keyboard shortcuts, editable like the Mac app's ShortcutsSettings ----

const defaultShortcuts = {
  palette: "Ctrl+K",
  files: "Ctrl+O",
  terminal: "Ctrl+`",
  find: "Ctrl+Shift+F",
  "new-session": "Ctrl+Shift+N",
  split: "Ctrl+Shift+B",
  export: "Ctrl+Shift+E",
};
const shortcutActions = {
  palette: () => ($("palette").hidden ? openPalette() : closePalette()),
  files: () => { if (state.project) $("toggle-files").click(); else openPicker(); },
  terminal: () => { if ($("drawer").hidden) $("toggle-files").click(); setDrawerTab("terminal"); },
  find: () => $("find").focus(),
  "new-session": () => { if (state.project) $("new-session").click(); },
  split: () => toggleSplit().catch(() => {}),
  export: () => exportConversation(),
};
const SHORTCUTS_KEY = "kuvo-shortcuts";

function loadShortcuts() {
  try { state.shortcuts = { ...defaultShortcuts, ...(JSON.parse(localStorage.getItem(SHORTCUTS_KEY)) ?? {}) }; }
  catch { state.shortcuts = { ...defaultShortcuts }; }
}

function comboOf(event) {
  const parts = [];
  if (event.ctrlKey || event.metaKey) parts.push("Ctrl");
  if (event.shiftKey) parts.push("Shift");
  if (event.altKey) parts.push("Alt");
  if (["Control", "Shift", "Alt", "Meta"].includes(event.key)) return null;
  const key = event.key.length === 1 ? event.key.toUpperCase() : event.key;
  return parts.length ? `${parts.join("+")}+${key}` : key;
}

function matchShortcut(event) {
  const combo = comboOf(event);
  if (!combo) return null;
  for (const [id, shortcut] of Object.entries(state.shortcuts)) {
    if (shortcut && shortcut.toLowerCase() === combo.toLowerCase()) return id;
  }
  return null;
}

let capturingShortcut = null;

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    if (capturingShortcut) { capturingShortcut = null; renderShortcutEditor(); return; }
    if (!$("palette").hidden) { closePalette(); return; }
    if (!$("settings-modal").hidden) { closeSettings(); return; }
  }
  if (capturingShortcut) {
    event.preventDefault();
    event.stopPropagation();
    const combo = comboOf(event);
    if (combo) {
      state.shortcuts[capturingShortcut] = combo;
      try { localStorage.setItem(SHORTCUTS_KEY, JSON.stringify(state.shortcuts)); } catch {}
      capturingShortcut = null;
      renderShortcutEditor();
    }
    return;
  }
  // Saving the open file keeps working whatever the map says.
  if (state.openFile && event.ctrlKey && event.key.toLowerCase() === "s") {
    event.preventDefault();
    saveFile();
    return;
  }
  const id = matchShortcut(event);
  if (!id || !(event.ctrlKey || event.metaKey)) return;
  event.preventDefault();
  shortcutActions[id]?.();
});

function renderShortcutEditor() {
  const list = $("shortcut-list");
  if (!list) return;
  list.innerHTML = "";
  for (const [id, shortcut] of Object.entries(state.shortcuts)) {
    const row = el("div", { class: "shortcut-row" });
    row.append(el("span", { text: shortcut }),
      el("button", { class: "small", text: capturingShortcut === id ? "Press keys…" : "Change", onclick: () => { capturingShortcut = id; renderShortcutEditor(); } }),
    );
    list.append(row);
  }
}

loadShortcuts();

// ---- Export conversation ----

function exportConversation() {
  if (!state.transcript || !state.session) return;
  const lines = [];
  lines.push(`# ${state.session.title || "Conversation"}`);
  lines.push("");
  lines.push(`Project: ${state.project || ""}`);
  lines.push(`Session: ${state.session.id}`);
  lines.push("");

  const query = state.findQuery;
  const visibleEntries = query
    ? state.transcript.entries.filter(entry => {
        const text = (entry.parts ?? []).map(p => p.text ?? "").join(" ").toLowerCase();
        return text.includes(query);
      })
    : state.transcript.entries;
  for (const entry of visibleEntries) {
    if (entry.kind === "user") {
      lines.push(`## You`);
      lines.push("");
      lines.push(entry.text);
      lines.push("");
    } else if (entry.kind === "assistant") {
      lines.push(`## Assistant`);
      lines.push("");
      for (const part of entry.parts) {
        if (part.type === "text") lines.push(part.text);
        else if (part.type === "reasoning") lines.push(`> ${part.text}`);
        else if (part.type === "tool") lines.push(`- tool: ${part.name} (${part.status})`);
      }
      if (entry.error) lines.push(`
_error: ${entry.error.message || entry.error}_`);
      lines.push("");
    }
  }
  const blob = new Blob([lines.join("\n")], { type: "text/markdown" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = `${(state.session.title || "conversation").replace(/[^a-z0-9]+/gi, "-")}.md`;
  document.body.append(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

// ---- Boot ----

async function boot() {
  const info = await api("/api/state");
  state.project = info.project;
  state.engine = info.engine;
  render();
  connectEvents();
  if (state.project) {
    await loadSessions();
    const newest = state.sessions[0];
    if (newest) await openSession(newest.id);
  } else {
    renderConversation();
  }
  loadModels();
  loadAgents();
  loadCommands();
  loadProjects();
  renderAccentSwatches();
  applyLook();
  // The engine may still be starting: keep the header honest.
  setInterval(async () => {
    try {
      const info = await api("/api/state");
      state.engine = info.engine;
      render();
    } catch {}
  }, 4000);
}

// The analytics notice, told once: this harness sends nothing anywhere.
if (!localStorage.getItem("kuvo-analytics-ack") && !$("analytics-notice").hidden) {
  $("analytics-notice").hidden = false;
}
$("analytics-ok").addEventListener("click", () => {
  localStorage.setItem("kuvo-analytics-ack", "1");
  $("analytics-notice").hidden = true;
});

// Inside the shell the window has no native title bar: this page is it.
if (new URLSearchParams(location.search).get("shell") === "1") {
  document.body.classList.add("in-shell");
  const overlay = document.createElement("div");
  overlay.className = "titlebar-drag";
  document.body.prepend(overlay);
}

boot().catch(error => {
  document.body.append(el("div", { class: "fatal", text: `The harness isn't answering: ${error.message}` }));
});
