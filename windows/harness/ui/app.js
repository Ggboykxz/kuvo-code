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
    const item = el("li", { class: session.id === state.session?.id ? "current" : "" },
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
    if (part.type === "text") block.append(el("div", { class: "text", text: part.text }));
    else if (part.type === "reasoning") {
      const summary = el("summary", { text: "Thinking" });
      if (entry.running) summary.classList.add("shimmer");
      block.append(el("details", { class: "reasoning" },
        summary,
        el("div", { class: "text", text: part.text }),
      ));
    } else if (part.type === "tool") block.append(toolCard(part));
  }
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

  const entries = state.transcript.entries;
  const rendered = [];
  for (const entry of entries) {
    if (entry.kind === "user") rendered.push(el("article", { class: "entry user" }, el("div", { class: "text", text: entry.text })));
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
  for (const item of state.transcript.pending) {
    rendered.push(el("article", { class: "entry user pending" },
      el("div", { class: "text", text: item.text }),
      item.delivery === "queue" ? el("div", { class: "entry-meta", text: "queued" }) : null,
    ));
  }
  $("entries").replaceChildren(...rendered);

  const asks = $("asks");
  asks.replaceChildren();
  for (const request of state.transcript.permissions) {
    asks.append(permissionCard(request));
  }

  $("stop").hidden = !state.transcript.running;
  $("prompt").placeholder = state.transcript.running ? "Send while it works — delivered at its next step…" : "Ask for something…  (Enter sends, Shift+Enter for a new line)";
}

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

function compactTokens(n) {
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)}K`;
  return String(n);
}

function updateContextGauge(session) {
  const gauge = $("context-gauge");
  const total = session?.tokens?.total ?? 0;
  if (!total) { gauge.hidden = true; return; }
  gauge.hidden = false;
  const label = compactTokens(total);
  gauge.textContent = label;
  gauge.title = `Context window: ${compactTokens(total)} tokens used`;
}

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
    render();
    $("prompt").focus();
  } catch (error) {
    complain(null, error);
  }
}

// ---- Composer ----

$("composer").addEventListener("submit", async event => {
  event.preventDefault();
  const box = $("prompt");
  const text = box.value.trim();
  if (text === "" || !state.session) return;
  box.value = "";
  try {
    const { id } = await api(`/api/sessions/${encodeURIComponent(state.session.id)}/prompt`, { method: "POST", body: { text } });
    state.transcript.pending.push({ id, text, delivery: "steer" });
    render();
  } catch (error) {
    box.value = text;
    alert(error.message);
  }
});

$("prompt").addEventListener("keydown", event => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    $("composer").requestSubmit();
  }
});

$("stop").addEventListener("click", async () => {
  if (!state.session) return;
  try {
    await api(`/api/sessions/${encodeURIComponent(state.session.id)}/interrupt`, { method: "POST", body: {} });
  } catch (error) {
    complain(null, error);
  }
});

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
    const { session } = await api("/api/sessions", { method: "POST", body: {} });
    await loadSessions();
    await openSession(session.id);
  } catch (error) {
    complain(null, error);
  }
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
  for (const model of state.models) {
    const value = `${model.providerID}/${model.id}`;
    select.append(el("option", { text: model.name ? `${model.name} — ${value}` : value, value }));
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

// ---- Keyboard shortcuts ----

document.addEventListener("keydown", (event) => {
  if (!(event.ctrlKey || event.metaKey)) return;
  const key = event.key.toLowerCase();
  if (key === "s" && state.openFile) {
    event.preventDefault();
    saveFile();
  } else if (key === "o") {
    event.preventDefault();
    if (state.project) { $("toggle-files").click(); }
    else openPicker();
  } else if (key === "`") {
    event.preventDefault();
    if ($("drawer").hidden) $("toggle-files").click();
    setDrawerTab("terminal");
  } else if (key === "f" && event.shiftKey) {
    event.preventDefault();
    if ($("drawer").hidden) $("toggle-files").click();
    setDrawerTab("files");
    setTimeout(() => $("files-search").focus(), 50);
  } else if (key === "n" && event.shiftKey && state.project) {
    event.preventDefault();
    $("new-session").click();
  }
});

// ---- Export conversation ----

function exportConversation() {
  if (!state.transcript || !state.session) return;
  const lines = [];
  lines.push(`# ${state.session.title || "Conversation"}`);
  lines.push("");
  lines.push(`Project: ${state.project || ""}`);
  lines.push(`Session: ${state.session.id}`);
  lines.push("");
  // A steps row: how much the agent did between its replies, like the Mac app's StepsRow.
  const steps = state.transcript.entries.filter(entry => entry.kind === "assistant");
  const stepCount = steps.length;
  const toolCount = steps.reduce((sum, entry) => sum + entry.parts.filter(part => part.type === "tool").length, 0);
  const totalMs = steps.reduce((sum, entry) => sum + ((entry.time?.completed ?? 0) - (entry.time?.started ?? 0)), 0);
  const stepsRow = $("steps-row");
  if (stepCount > 1 && !query) {
    stepsRow.hidden = false;
    const seconds = Math.round(totalMs / 1000);
    stepsRow.textContent = `${stepCount} steps · ${seconds}s · ${toolCount} tools`;
  } else {
    stepsRow.hidden = true;
  }

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
  // The engine may still be starting: keep the header honest.
  setInterval(async () => {
    try {
      const info = await api("/api/state");
      state.engine = info.engine;
      render();
    } catch {}
  }, 4000);
}

boot().catch(error => {
  document.body.append(el("div", { class: "fatal", text: `The harness isn't answering: ${error.message}` }));
});
