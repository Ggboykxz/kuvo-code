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
  for (const session of state.sessions) {
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
  return card;
}

function assistantEntry(entry) {
  const block = el("article", { class: "entry assistant" });
  for (const part of entry.parts) {
    if (part.type === "text") block.append(el("div", { class: "text", text: part.text }));
    else if (part.type === "reasoning") {
      block.append(el("details", { class: "reasoning" },
        el("summary", { text: "Thinking" }),
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

async function openSession(id) {
  const detail = await api(`/api/sessions/${encodeURIComponent(id)}`);
  state.session = detail.session;
  state.transcript = fromHistory(id, detail.messages, detail.permissions, detail.running);
  selectModelInPicker();
  render();
  $("prompt").focus();
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
    setTimeout(async () => {
      try {
        await openSession(state.session.id);
        await loadSessions();
      } catch {}
    }, 250);
  }
  if (event.type === "permission.asked" || event.type === "permission.replied") render();
}

function connectEvents() {
  const events = new EventSource("/api/events");
  events.onmessage = message => {
    try {
      handleEvent(JSON.parse(message.data));
    } catch {}
  };
  events.onopen = () => {
    // Anything that happened while the stream was away is fixed by a read.
    if (state.session) openSession(state.session.id).catch(() => {});
  };
  events.onerror = () => {};
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
