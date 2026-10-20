// @bun
// Agents/src/main.ts
import { mkdirSync as mkdirSync11, readdirSync as readdirSync4, rmSync as rmSync8 } from "fs";
import { join as join14 } from "path";

// Agents/src/accounts.ts
import { randomBytes } from "crypto";
import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
var kinds = ["claude", "codex", "cursor", "grok", "antigravity"];
var baseProvider = {
  claude: "claude-code",
  codex: "codex-cli",
  cursor: "cursor",
  grok: "grok-cli",
  antigravity: "antigravity"
};
function providerID(kind, id) {
  return id === "default" ? baseProvider[kind] : `${baseProvider[kind]}@${id}`;
}
function parseProvider(provider) {
  const [base, id] = provider.split("@", 2);
  const kind = kinds.find((kind2) => baseProvider[kind2] === base);
  if (!kind)
    return;
  return { kind, id: id ?? "default" };
}

class Accounts {
  root;
  records = [];
  constructor(root) {
    this.root = root;
    try {
      const saved = JSON.parse(readFileSync(this.file, "utf8"));
      this.records = saved.filter((record) => kinds.includes(record.kind) && record.id && record.id !== "default");
    } catch {}
  }
  get file() {
    return join(this.root, "accounts.json");
  }
  all() {
    return [...kinds.map((kind) => ({ kind, id: "default" })), ...this.records];
  }
  home(record) {
    return record.id === "default" ? undefined : join(this.root, record.kind, "accounts", record.id);
  }
  add(kind, label) {
    const record = { kind, id: randomBytes(4).toString("hex"), label: label?.trim() || undefined };
    mkdirSync(this.home(record), { recursive: true, mode: 448 });
    this.records.push(record);
    this.save();
    return record;
  }
  rename(provider, label) {
    const parsed = parseProvider(provider);
    const record = this.records.find((record2) => record2.kind === parsed?.kind && record2.id === parsed?.id);
    if (!record)
      return;
    record.label = label?.trim() || undefined;
    this.save();
  }
  remove(provider) {
    const parsed = parseProvider(provider);
    const index = this.records.findIndex((record2) => record2.kind === parsed?.kind && record2.id === parsed?.id);
    if (index < 0)
      return;
    const [record] = this.records.splice(index, 1);
    this.save();
    rmSync(this.home(record), { recursive: true, force: true });
    return record;
  }
  save() {
    mkdirSync(this.root, { recursive: true });
    writeFileSync(this.file + ".new", JSON.stringify(this.records, null, 2));
    renameSync(this.file + ".new", this.file);
  }
}

// Agents/src/auto.ts
import { mkdirSync as mkdirSync2, readFileSync as readFileSync2, renameSync as renameSync2, writeFileSync as writeFileSync2 } from "fs";
import { join as join2 } from "path";
var autoProvider = "auto";
var unknownReset = 30 * 60000;
var briefReset = 3 * 60000;

class Auto {
  root;
  entries = [];
  held = [];
  constructor(root) {
    this.root = root;
    try {
      const saved = JSON.parse(readFileSync2(this.file, "utf8"));
      this.entries = (saved.entries ?? []).filter((entry) => entry?.providerID && entry?.modelID);
      this.held = (saved.limits ?? []).filter((held) => held?.key && held.until > Date.now());
    } catch {}
  }
  get file() {
    return join2(this.root, "auto.json");
  }
  list() {
    return this.entries.map((entry) => ({ ...entry }));
  }
  set(entries) {
    this.entries = entries.filter((entry) => entry && typeof entry.providerID === "string" && typeof entry.modelID === "string" && entry.providerID !== autoProvider).map((entry) => ({ providerID: entry.providerID, modelID: entry.modelID, ...entry.variant ? { variant: entry.variant } : {} }));
    this.save();
  }
  limits() {
    this.prune();
    return this.held.map((held) => ({ ...held }));
  }
  clearLimits() {
    this.held = [];
    this.save();
  }
  prune() {
    const before = this.held.length;
    this.held = this.held.filter((held) => held.until > Date.now());
    if (this.held.length !== before)
      this.save();
  }
  static providerKey(providerID2) {
    return providerID2;
  }
  static modelKey(entry) {
    return `${entry.providerID}/${entry.modelID}`;
  }
  isHeld(entry) {
    this.prune();
    return this.held.find((held) => held.key === Auto.providerKey(entry.providerID) || held.key === Auto.modelKey(entry));
  }
  hold(entry, limit) {
    const key = limit.scope === "provider" ? Auto.providerKey(entry.providerID) : Auto.modelKey(entry);
    const known = Boolean(limit.resetsAt && limit.resetsAt > Date.now());
    const until = known ? limit.resetsAt : Date.now() + (limit.brief ? briefReset : unknownReset);
    this.held = this.held.filter((held) => held.key !== key);
    this.held.push({ key, until, scope: limit.scope, known });
    this.save();
  }
  save() {
    mkdirSync2(this.root, { recursive: true });
    writeFileSync2(this.file + ".new", JSON.stringify({ entries: this.entries, limits: this.held }, null, 2));
    renameSync2(this.file + ".new", this.file);
  }
}
function resetTime(at) {
  const date = new Date(at);
  const today = new Date;
  const time = date.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
  if (date.toDateString() === today.toDateString())
    return time;
  return `${date.toLocaleDateString("en-US", { month: "short", day: "numeric" })}, ${time}`;
}

// Agents/src/deps.ts
import { existsSync, mkdirSync as mkdirSync3, readFileSync as readFileSync3, writeFileSync as writeFileSync3 } from "fs";
import { join as join3 } from "path";
var installing = new Map;

class Deps {
  root;
  cache;
  constructor(root, cache) {
    this.root = root;
    this.cache = cache;
  }
  folder(agent) {
    return join3(this.root, agent);
  }
  has(agent, packages) {
    return packages.every((pkg) => installedVersion(this.folder(agent), pkg.name) === pkg.version);
  }
  async ensure(agent, packages, options = {}) {
    const folder = this.folder(agent);
    if (this.has(agent, packages))
      return folder;
    let pending = installing.get(agent);
    if (!pending) {
      pending = this.install(folder, packages, options.optional ?? true).finally(() => installing.delete(agent));
      installing.set(agent, pending);
    }
    await pending;
    return folder;
  }
  async install(folder, packages, optional) {
    mkdirSync3(folder, { recursive: true });
    const manifest = { name: "kuvo-agents-runtime", private: true, dependencies: Object.fromEntries(packages.map((pkg) => [pkg.name, pkg.version])) };
    writeFileSync3(join3(folder, "package.json"), JSON.stringify(manifest, null, 2));
    const args = [process.execPath, "install", "--no-save", "--no-progress", "--silent"];
    if (!optional)
      args.push("--omit", "optional");
    const child = Bun.spawn(args, {
      cwd: folder,
      env: {
        ...process.env,
        BUN_BE_BUN: "1",
        BUN_INSTALL: this.cache,
        BUN_INSTALL_CACHE_DIR: join3(this.cache, "install")
      },
      stdout: "pipe",
      stderr: "pipe"
    });
    const [code, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()]);
    if (code !== 0)
      throw new Error(`Couldn't download what the agent needs (${packages.map((pkg) => pkg.name).join(", ")}): ${stderr.trim().slice(-400)}`);
  }
  async load(agent, name) {
    const entry = Bun.resolveSync(name, this.folder(agent));
    return await import(entry);
  }
}
function installedVersion(folder, name) {
  const file = join3(folder, "node_modules", name, "package.json");
  if (!existsSync(file))
    return;
  try {
    return JSON.parse(readFileSync3(file, "utf8")).version;
  } catch {
    return;
  }
}

// Agents/src/agent.ts
function model(providerID2, id, name, options = {}) {
  return {
    id,
    providerID: providerID2,
    name,
    family: options.family,
    capabilities: { tools: true, input: options.images ? ["text", "image"] : ["text"], output: ["text"] },
    variants: (options.variants ?? []).map((id2) => ({ id: id2 })),
    time: { released: options.released ?? 0 },
    cost: [{ input: 0, output: 0 }],
    status: "active",
    enabled: true,
    limit: { context: options.context ?? 200000, output: 32000 }
  };
}
function accountName(name, account) {
  if (account.id === "default")
    return name;
  return `${name} \xB7 ${account.label ?? "Another account"}`;
}
function failure(error, type = "agent") {
  const message = error instanceof Error ? error.message : typeof error === "string" ? error : JSON.stringify(error);
  return { type, message: message || "The agent stopped with an error." };
}

// Agents/src/ids.ts
var alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
var last = { timestamp: 0, counter: 0 };
function ascending() {
  const timestamp = Date.now();
  if (last.timestamp !== timestamp)
    last = { timestamp, counter: 0 };
  last.counter += 1;
  const value = BigInt(timestamp) * 0x1000n + BigInt(last.counter) & 0xffffffffffffn;
  const time = value.toString(16).padStart(12, "0");
  let random = "";
  const bytes = crypto.getRandomValues(new Uint8Array(14));
  for (const byte of bytes)
    random += alphabet[byte % alphabet.length];
  return time + random;
}
var newID = (prefix) => `${prefix}_${ascending()}`;
var messageID = (eventID) => "msg_" + eventID.slice("evt_".length);

// Agents/src/engine.ts
class EngineLink {
  url;
  authorization;
  generation = 0;
  listeners = new Map;
  children = new Map;
  names = new Map;
  catalog;
  get ready() {
    return Boolean(this.url);
  }
  configure(url, password) {
    const authorization = password ? "Basic " + Buffer.from(`opencode:${password}`).toString("base64") : undefined;
    if (url === this.url && authorization === this.authorization)
      return;
    this.url = url?.replace(/\/$/, "");
    this.authorization = authorization;
    this.names.clear();
    this.catalog = undefined;
    const generation = ++this.generation;
    if (this.url)
      this.feed(generation);
    for (const set of this.listeners.values())
      for (const listener of set)
        listener.reconnected();
  }
  async request(method, path, body, timeout = 30000, directory) {
    if (!this.url)
      throw new Error("The engine isn't running.");
    const response = await fetch(this.url + path, {
      method,
      headers: {
        Authorization: this.authorization ?? "",
        ...body === undefined ? {} : { "Content-Type": "application/json" },
        ...directory ? { "x-opencode-directory": encodeURIComponent(directory) } : {}
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(timeout)
    });
    const text = await response.text();
    let value;
    try {
      value = text ? JSON.parse(text) : undefined;
    } catch {
      value = text;
    }
    if (!response.ok) {
      const error = new EngineError(value?.message ?? `The engine answered ${response.status}.`);
      error.status = response.status;
      throw error;
    }
    return value;
  }
  providerName(providerID2) {
    if (!this.names.size && this.url) {
      this.names.set("", "");
      this.request("GET", "/api/provider").then((answer) => {
        for (const provider of answer?.data ?? [])
          if (provider?.id && provider?.name)
            this.names.set(provider.id, provider.name);
        if (this.names.size === 1)
          this.names.clear();
      }).catch(() => this.names.clear());
    }
    return this.names.get(providerID2);
  }
  settings = new Map;
  async settingsFiles(directory) {
    const kept = this.settings.get(directory);
    if (!this.url || kept && Date.now() - kept.at < 30000)
      return kept?.sources ?? [];
    try {
      const answer = await this.request("GET", "/api/config", undefined, 1e4, directory);
      const sources = Array.isArray(answer) ? answer : Array.isArray(answer?.data) ? answer.data : [{ info: answer?.data ?? answer }];
      this.settings.set(directory, { at: Date.now(), sources });
      return sources;
    } catch {
      return kept?.sources ?? [];
    }
  }
  async policies(directory) {
    const policies = (await this.settingsFiles(directory)).flatMap((source) => Array.isArray(source?.info?.policies) ? source.info.policies : []);
    const rules = [];
    for (const policy of policies) {
      if (policy?.action !== "tool.use" || typeof policy.resource !== "string")
        continue;
      if (policy.effect !== "deny" && policy.effect !== "allow")
        continue;
      const at = policy.resource.indexOf(":");
      rules.push({ action: at < 0 ? policy.resource : policy.resource.slice(0, at), resource: at < 0 ? "*" : policy.resource.slice(at + 1) || "*", effect: policy.effect });
    }
    return rules;
  }
  async commandTemplate(name, directory) {
    let template;
    for (const source of await this.settingsFiles(directory)) {
      const own = source?.info?.commands?.[name]?.template ?? source?.info?.command?.[name]?.template;
      if (typeof own === "string" && own.trim())
        template = own;
    }
    return template;
  }
  async agentPrompt(name, directory) {
    let prompt;
    for (const source of await this.settingsFiles(directory)) {
      const own = source?.info?.agents?.[name]?.system ?? source?.info?.agent?.[name]?.prompt;
      if (typeof own === "string" && own.trim())
        prompt = own.trim();
    }
    return prompt;
  }
  async offered(providerID2) {
    if (!this.url)
      return;
    if (!this.catalog || Date.now() - this.catalog.at > 60000) {
      try {
        const [providers, models] = await Promise.all([this.request("GET", "/api/provider"), this.request("GET", "/api/model")]);
        const ready = new Set((providers?.data ?? []).map((provider) => provider.id));
        if (!ready.size)
          return { ready: false, models: [] };
        this.catalog = { at: Date.now(), ready, models: models?.data ?? [] };
      } catch {
        return;
      }
    }
    return { ready: this.catalog.ready.has(providerID2), models: this.catalog.models.filter((model2) => model2.providerID === providerID2) };
  }
  listen(sessionID, listener) {
    let set = this.listeners.get(sessionID);
    if (!set)
      this.listeners.set(sessionID, set = new Set);
    set.add(listener);
    return () => {
      set.delete(listener);
      if (!set.size)
        this.listeners.delete(sessionID);
      for (const [child, parent] of this.children)
        if (parent === sessionID)
          this.children.delete(child);
    };
  }
  dispatch(event) {
    const data = event.data ?? {};
    if (event.type === "session.created") {
      const session = data.session ?? data.info;
      const child = data.sessionID ?? session?.id;
      const parent = data.parentID ?? session?.parentID;
      if (child && parent && (this.listeners.has(parent) || this.children.has(parent)))
        this.children.set(child, this.children.get(parent) ?? parent);
      return;
    }
    let sessionID = data.sessionID ?? data.form?.sessionID;
    if (!sessionID)
      return;
    sessionID = this.children.get(sessionID) ?? sessionID;
    for (const listener of this.listeners.get(sessionID) ?? [])
      listener.event(event);
  }
  async feed(generation) {
    let first = true;
    while (generation === this.generation && this.url) {
      try {
        const response = await fetch(this.url + "/api/event", { headers: { Authorization: this.authorization ?? "", Accept: "text/event-stream" } });
        if (!response.ok || !response.body)
          throw new Error(`feed ${response.status}`);
        if (!first)
          for (const set of this.listeners.values())
            for (const listener of set)
              listener.reconnected();
        first = false;
        const reader = response.body.getReader();
        const decoder = new TextDecoder;
        let buffer = "";
        while (generation === this.generation) {
          const read = await Promise.race([reader.read(), new Promise((done) => setTimeout(() => done("quiet"), 45000))]);
          if (read === "quiet" || read.done)
            break;
          buffer += decoder.decode(read.value, { stream: true });
          let end;
          while ((end = buffer.indexOf(`

`)) >= 0) {
            const chunk = buffer.slice(0, end);
            buffer = buffer.slice(end + 2);
            const data = chunk.split(`
`).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trimStart()).join(`
`);
            if (!data)
              continue;
            try {
              this.dispatch(JSON.parse(data));
            } catch {}
          }
        }
        await reader.cancel().catch(() => {});
      } catch {}
      if (generation !== this.generation)
        return;
      first = false;
      await Bun.sleep(1000);
    }
  }
}

class EngineError extends Error {
  status;
}

class EngineAgent {
  link;
  providerID;
  id = "engine";
  instance = { id: "default" };
  constructor(link, providerID2) {
    this.link = link;
    this.providerID = providerID2;
  }
  get name() {
    return this.link.providerName(this.providerID) || this.providerID;
  }
  methods() {
    return [];
  }
  async account() {
    const offered = await this.link.offered(this.providerID);
    return { installed: true, signedIn: this.link.ready && (offered?.ready ?? true) };
  }
  async models() {
    return (await this.link.offered(this.providerID))?.models ?? [];
  }
  thread(session, state) {
    return new EngineThread(this.link, session, state);
  }
  async forgetConversation(state) {
    const id = state.engineSession;
    if (id)
      await this.link.request("DELETE", `/api/session/${encodeURIComponent(id)}`).catch(() => {});
  }
}
var outputLimit = 64000;

class EngineThread {
  link;
  session;
  state;
  stop;
  constructor(link, session, state) {
    this.link = link;
    this.session = session;
    this.state = state;
  }
  async engineSession(input, hooks) {
    const existing = this.state.engineSession;
    if (existing) {
      try {
        await this.link.request("GET", `/api/session/${encodeURIComponent(existing)}`);
        return existing;
      } catch (error) {
        if (error.status !== 404)
          throw error;
      }
    }
    const created = await this.link.request("POST", "/api/session", {
      title: this.session.title ? `Kuvo Code: ${this.session.title}` : "Kuvo Code",
      location: { directory: this.session.location.directory },
      model: input.model,
      agent: input.plan ? "plan" : "build",
      permissions: this.session.permissions ?? [],
      metadata: { kuvo: { engineFor: this.session.id } }
    });
    const id = created?.data?.id;
    if (!id)
      throw new Error("The engine didn't start a session.");
    if (existing)
      this.startedOver = true;
    this.state.engineSession = id;
    delete this.state.engineInstructions;
    hooks.saveState();
    return id;
  }
  startedOver = false;
  async prepare(input, hooks) {
    if (!this.link.ready)
      return;
    await this.engineSession(input, hooks);
    const fresh = this.startedOver;
    this.startedOver = false;
    return { fresh };
  }
  async run(input, turn, hooks) {
    if (!this.link.ready)
      return { outcome: "failed", error: { type: "engine", message: "The engine isn't running: wait for it to start, or restart Kuvo Code." } };
    const id = await this.engineSession(input, hooks);
    const path = `/api/session/${encodeURIComponent(id)}`;
    await this.link.request("PATCH", path, { permissions: this.session.permissions ?? [] });
    await this.link.request("POST", `${path}/model`, { model: input.model });
    await this.link.request("POST", `${path}/agent`, { agent: input.plan ? "plan" : "build" });
    const instructions = hooks.instructions();
    if (instructions !== (this.state.engineInstructions ?? "")) {
      if (instructions)
        await this.link.request("PUT", `/api/experimental/session/${encodeURIComponent(id)}/instructions/entries/kuvo`, { value: instructions });
      else
        await this.link.request("DELETE", `/api/experimental/session/${encodeURIComponent(id)}/instructions/entries/kuvo`).catch(() => {});
      this.state.engineInstructions = instructions;
      hooks.saveState();
    }
    const active = await this.link.request("GET", "/api/session/active").catch(() => {
      return;
    });
    if (active?.data?.[id])
      await this.link.request("POST", `${path}/interrupt`).catch(() => {});
    const inputID = newID("msg");
    const sentAt = Date.now();
    let step;
    let delivered = false;
    let limit;
    const shells = new Map;
    const stopShell = (tool) => {
      clearInterval(shells.get(tool));
      shells.delete(tool);
    };
    let settle;
    const settled = new Promise((resolve) => settle = resolve);
    let done = false;
    const finish = (result) => {
      if (done)
        return;
      done = true;
      settle(result);
    };
    const interrupt = async () => {
      await this.link.request("POST", `${path}/interrupt`).catch(() => {});
      setTimeout(() => finish({ outcome: "interrupted" }), 1e4);
    };
    this.stop = interrupt;
    const answerPermission = async (data) => {
      const ask = {
        toolCallID: data.source?.id,
        action: data.action,
        resources: data.resources ?? [],
        save: data.save,
        metadata: data.metadata,
        message: data.message,
        weighed: true
      };
      let decision = "reject";
      try {
        decision = await hooks.permission(ask);
      } catch {}
      await this.link.request("POST", `/api/session/${encodeURIComponent(data.sessionID)}/permission/${encodeURIComponent(data.id)}/reply`, { decision }).catch(() => {});
    };
    const answerForm = async (form) => {
      let answer = null;
      try {
        answer = await hooks.question({ title: form.title ?? "A question", fields: form.fields ?? [] });
      } catch {}
      const formPath = `/api/session/${encodeURIComponent(form.sessionID)}/form/${encodeURIComponent(form.id)}`;
      if (answer)
        await this.link.request("POST", `${formPath}/reply`, { answer }).catch(() => {});
      else
        await this.link.request("DELETE", formPath).catch(() => {});
    };
    const followShell = (tool, shellID) => {
      if (shells.has(tool))
        return;
      let cursor = 0;
      let output = "";
      let reading = false;
      const read = async () => {
        if (reading)
          return;
        reading = true;
        try {
          const answer = await this.link.request("GET", `/api/shell/${encodeURIComponent(shellID)}/output?cursor=${cursor}`, undefined, 1e4, this.session.location.directory).catch(() => {
            return;
          });
          const more = String(answer?.data?.output ?? "");
          if (typeof answer?.data?.cursor === "number")
            cursor = answer.data.cursor;
          if (!more)
            return;
          output = (output + more).slice(-outputLimit);
          turn.toolProgress(tool, { output });
        } finally {
          reading = false;
        }
      };
      shells.set(tool, setInterval(read, 1000));
    };
    const onEvent = (event) => {
      const data = event.data;
      const ownSession = data.sessionID === id;
      switch (event.type) {
        case "permission.asked":
          answerPermission(data);
          return;
        case "form.created":
          if (data.form)
            answerForm(data.form);
          return;
      }
      if (!ownSession)
        return;
      switch (event.type) {
        case "session.inbox.delivered":
          if (data.inboxID === inputID)
            delivered = true;
          return;
        case "session.step.started":
          if (data.assistantMessageID === step)
            return;
          step = data.assistantMessageID;
          turn.startStep(data.model ?? input.model);
          return;
        case "session.text.started":
        case "session.reasoning.started": {
          const kind = event.type === "session.text.started" ? "text" : "reasoning";
          turn.blockStart(`${kind}-${data.ordinal ?? 0}`, kind);
          return;
        }
        case "session.text.delta":
        case "session.reasoning.delta": {
          const kind = event.type === "session.text.delta" ? "text" : "reasoning";
          turn.blockDelta(`${kind}-${data.ordinal ?? 0}`, kind, String(data.delta ?? ""));
          return;
        }
        case "session.text.ended":
        case "session.reasoning.ended":
          turn.blockEnd(`${event.type === "session.text.ended" ? "text" : "reasoning"}-${data.ordinal ?? 0}`);
          return;
        case "session.tool.input.started":
          turn.toolStart(data.id, data.name);
          return;
        case "session.tool.input.delta":
          turn.toolInputDelta(data.id, String(data.delta ?? ""));
          return;
        case "session.tool.called":
          turn.toolCalled(data.id, data.input);
          return;
        case "session.tool.progress": {
          const { shellID, ...rest } = data.metadata ?? {};
          if (typeof shellID === "string")
            followShell(data.id, shellID);
          if (Object.keys(rest).length)
            turn.toolProgress(data.id, rest);
          return;
        }
        case "session.tool.success": {
          stopShell(data.id);
          const { shellID: _, ...metadata } = data.metadata ?? {};
          turn.toolSucceeded(data.id, data.content ?? [], metadata);
          return;
        }
        case "session.tool.failed": {
          stopShell(data.id);
          const { shellID: _, ...metadata } = data.metadata ?? {};
          const error = data.error ?? {};
          turn.toolFailed(data.id, error.message ?? "", metadata, error.type ?? "tool");
          return;
        }
        case "session.step.ended":
        case "session.step.failed":
          if (data.assistantMessageID !== step)
            return;
          step = undefined;
          turn.endStep({ tokens: data.tokens, cost: data.cost, finish: data.finish, error: data.error });
          return;
        case "session.retry.scheduled": {
          const reached = limitOf(data.error);
          if (input.auto && reached) {
            limit = reached;
            interrupt();
          }
          return;
        }
        case "session.execution.succeeded":
          if (delivered)
            finish({ outcome: "succeeded" });
          return;
        case "session.execution.interrupted":
          if (delivered || limit)
            finish(limit ? { outcome: "failed", error: { type: "limit", message: "A usage limit was reached." }, limit, taken: delivered } : { outcome: "interrupted" });
          return;
        case "session.execution.failed": {
          const error = data.error ?? { type: "engine", message: "The engine stopped with an error." };
          finish({ outcome: "failed", error, limit: limit ?? limitOf(error), taken: delivered });
          return;
        }
      }
    };
    const onReconnected = async () => {
      if (done)
        return;
      const active2 = await this.link.request("GET", "/api/session/active").catch(() => {
        return;
      });
      if (active2?.data?.[id])
        return;
      const session = await this.link.request("GET", path).catch(() => {
        return;
      });
      const outcome = session?.data?.outcome;
      const idle = Number(session?.data?.time?.idle ?? 0);
      finish(outcome === "succeeded" && idle >= sentAt ? { outcome } : { outcome: "failed", error: { type: "engine", message: "The engine restarted during this message." } });
    };
    const unlisten = this.link.listen(id, { event: onEvent, reconnected: () => void onReconnected() });
    const abort = () => void interrupt();
    hooks.signal.addEventListener("abort", abort);
    try {
      await this.link.request("POST", `${path}/prompt`, {
        id: inputID,
        text: input.text,
        files: input.files.length ? input.files.map((file) => ({ uri: file.uri, name: file.name })) : undefined,
        delivery: "steer"
      });
      if (hooks.signal.aborted)
        interrupt();
      return await settled;
    } catch (error) {
      return { outcome: "failed", error: failure(error, "engine") };
    } finally {
      hooks.signal.removeEventListener("abort", abort);
      unlisten();
      for (const tool of [...shells.keys()])
        stopShell(tool);
      this.stop = undefined;
    }
  }
  async interrupt() {
    await this.stop?.();
  }
  close() {}
}
function limitOf(error) {
  if (!error)
    return;
  if (error.type === "provider.quota")
    return { scope: "provider", message: error.message };
  if (error.type === "provider.rate-limit")
    return { scope: "model", message: error.message };
  return;
}

// Agents/src/snapshots.ts
import { createHash } from "crypto";
import { existsSync as existsSync2, mkdirSync as mkdirSync4, rmSync as rmSync2 } from "fs";
import { join as join5, resolve } from "path";

// Agents/src/diff.ts
var searchLimit = 2000;
function edits(a, b) {
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start])
    start++;
  let endA = a.length;
  let endB = b.length;
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) {
    endA--;
    endB--;
  }
  const ops = [];
  for (let i = 0;i < start; i++)
    ops.push({ kind: " ", line: a[i] });
  for (const op of middle(a.slice(start, endA), b.slice(start, endB)))
    ops.push(op);
  for (let i = endA;i < a.length; i++)
    ops.push({ kind: " ", line: a[i] });
  return ops;
}
function middle(a, b) {
  const n = a.length;
  const m = b.length;
  const removed = () => a.map((line) => ({ kind: "-", line }));
  const added = () => b.map((line) => ({ kind: "+", line }));
  if (!n)
    return added();
  if (!m)
    return removed();
  const max = n + m;
  const limit = Math.min(max, searchLimit);
  const v = new Int32Array(2 * max + 2);
  const trace = [];
  let found = false;
  outer:
    for (let d = 0;d <= limit; d++) {
      trace.push(v.slice(max - d, max + d + 1));
      for (let k = -d;k <= d; k += 2) {
        let x2 = k === -d || k !== d && v[max + k - 1] < v[max + k + 1] ? v[max + k + 1] : v[max + k - 1] + 1;
        let y2 = x2 - k;
        while (x2 < n && y2 < m && a[x2] === b[y2]) {
          x2++;
          y2++;
        }
        v[max + k] = x2;
        if (x2 >= n && y2 >= m) {
          found = true;
          break outer;
        }
      }
    }
  if (!found)
    return [...removed(), ...added()];
  const ops = [];
  let x = n;
  let y = m;
  for (let d = trace.length - 1;d >= 0; d--) {
    const t = trace[d];
    const at = (k2) => t[k2 + d];
    const k = x - y;
    const prevK = k === -d || k !== d && at(k - 1) < at(k + 1) ? k + 1 : k - 1;
    const prevX = d === 0 ? 0 : at(prevK);
    const prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      ops.push({ kind: " ", line: a[--x] });
      y--;
    }
    if (d > 0) {
      if (x === prevX)
        ops.push({ kind: "+", line: b[--y] });
      else
        ops.push({ kind: "-", line: a[--x] });
    }
  }
  return ops.reverse();
}
function lines(text) {
  if (text === "")
    return [];
  const split = text.split(`
`);
  if (split[split.length - 1] === "")
    split.pop();
  return split;
}
function unified(before, after, context = 3) {
  const ops = edits(lines(before), lines(after));
  let additions = 0;
  let deletions = 0;
  for (const op of ops) {
    if (op.kind === "+")
      additions++;
    else if (op.kind === "-")
      deletions++;
  }
  let patch = "";
  let i = 0;
  let oldLine = 1;
  let newLine = 1;
  const starts = ops.map((op) => {
    const at = { old: oldLine, new: newLine };
    if (op.kind !== "+")
      oldLine++;
    if (op.kind !== "-")
      newLine++;
    return at;
  });
  while (i < ops.length) {
    if (ops[i].kind === " ") {
      i++;
      continue;
    }
    let start = Math.max(0, i - context);
    let end = i;
    while (end < ops.length) {
      if (ops[end].kind !== " ") {
        end++;
        continue;
      }
      let next = end;
      while (next < ops.length && ops[next].kind === " ")
        next++;
      if (next < ops.length && next - end <= context * 2)
        end = next;
      else
        break;
    }
    end = Math.min(ops.length, end + context);
    const slice = ops.slice(start, end);
    const oldCount = slice.filter((op) => op.kind !== "+").length;
    const newCount = slice.filter((op) => op.kind !== "-").length;
    const oldStart = oldCount === 0 ? starts[start].old - 1 : starts[start].old;
    const newStart = newCount === 0 ? starts[start].new - 1 : starts[start].new;
    patch += `@@ -${oldStart},${oldCount} +${newStart},${newCount} @@
`;
    for (const op of slice)
      patch += op.kind + op.line + `
`;
    i = end;
  }
  return { patch, additions, deletions };
}
function header(path) {
  return path.startsWith("/") ? `--- ${path}
+++ ${path}
` : `--- a/${path}
+++ b/${path}
`;
}
function fileDiff(path, before, after) {
  const { patch, additions, deletions } = unified(before ?? "", after ?? "");
  const status = before === undefined ? "added" : after === undefined ? "deleted" : "modified";
  return { file: path, patch: header(path) + patch, additions, deletions, status };
}
function fromPatch(path, patch, status) {
  let additions = 0;
  let deletions = 0;
  let inHunk = false;
  for (const line of patch.split(`
`)) {
    if (line.startsWith("@@"))
      inHunk = true;
    else if (!inHunk)
      continue;
    else if (line.startsWith("+"))
      additions++;
    else if (line.startsWith("-"))
      deletions++;
  }
  const headed = patch.startsWith("---") || patch.startsWith("diff ") ? patch : header(path) + patch;
  return { file: path, patch: headed, additions, deletions, status: status ?? "modified" };
}

// Agents/src/proc.ts
import { accessSync, constants } from "fs";
import { delimiter, join as join4 } from "path";
function which(name, extra = []) {
  const folders = [...(process.env.PATH ?? "").split(delimiter), ...extra].filter(Boolean);
  for (const folder of folders) {
    const path = join4(folder, name);
    try {
      accessSync(path, constants.X_OK);
      return path;
    } catch {}
  }
  return;
}
async function run(command, args, options = {}) {
  const child = Bun.spawn([command, ...args], {
    cwd: options.cwd,
    env: { ...process.env, ...options.env },
    stdin: options.input !== undefined ? "pipe" : "ignore",
    stdout: "pipe",
    stderr: "pipe"
  });
  if (options.input !== undefined && child.stdin) {
    child.stdin.write(options.input);
    child.stdin.end();
  }
  const timer = options.timeout ? setTimeout(() => child.kill(), options.timeout) : undefined;
  let stdout = "";
  let stderr = "";
  const reads = Promise.all([new Response(child.stdout).text().then((text) => stdout = text), new Response(child.stderr).text().then((text) => stderr = text)]);
  const code = await child.exited;
  await Promise.race([reads, Bun.sleep(2000)]);
  if (timer)
    clearTimeout(timer);
  return { code, stdout, stderr };
}
var pathRead = 0;
async function refreshLoginPath() {
  if (Date.now() - pathRead < 5000)
    return;
  pathRead = Date.now();
  const shell = process.env.SHELL || "/bin/zsh";
  for (const flags of ["-ilc", "-lc"]) {
    try {
      const ran = await run(shell, [flags, 'printf "__KUVO_PATH__%s__KUVO_END__" "$PATH"'], { timeout: 8000, env: { DISABLE_AUTO_UPDATE: "true" } });
      const found = ran.stdout.match(/__KUVO_PATH__([\s\S]*?)__KUVO_END__/)?.[1];
      if (found?.trim()) {
        process.env.PATH = found.trim();
        return;
      }
    } catch {}
  }
}
function firstURL(text) {
  return text.match(/https?:\/\/[^\s"'<>]+/)?.[0];
}
function plain(text) {
  return text.replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, "").replace(/\x1b\][^\x07]*\x07/g, "");
}

// Agents/src/snapshots.ts
var quiet = { GIT_TERMINAL_PROMPT: "0", GIT_CONFIG_NOSYSTEM: "1", GIT_OPTIONAL_LOCKS: "0" };

class Snapshots {
  root;
  constructor(root) {
    this.root = root;
  }
  store(directory) {
    return join5(this.root, createHash("sha1").update(resolve(directory)).digest("hex").slice(0, 20));
  }
  git(directory, args, timeout = 120000) {
    return run("git", ["--git-dir", this.store(directory), "--work-tree", directory, ...args], { cwd: directory, timeout, env: quiet });
  }
  async take(directory) {
    const inside = await run("git", ["-C", directory, "rev-parse", "--is-inside-work-tree"], { timeout: 15000, env: quiet }).catch(() => {
      return;
    });
    if (inside?.stdout.trim() !== "true")
      return;
    const store = this.store(directory);
    if (!existsSync2(join5(store, "HEAD"))) {
      mkdirSync4(store, { recursive: true });
      const made = await run("git", ["init", "--bare", "-q", store], { timeout: 30000, env: quiet }).catch(() => {
        return;
      });
      if (made?.code !== 0)
        return;
    }
    const added = await this.git(directory, ["add", "-A", "."]).catch(() => {
      return;
    });
    if (added?.code !== 0)
      return;
    const tree = await this.git(directory, ["write-tree"]).catch(() => {
      return;
    });
    return tree?.code === 0 ? tree.stdout.trim() || undefined : undefined;
  }
  async changes(directory, from, to) {
    const ran = await this.git(directory, ["diff", "--no-color", "--no-renames", "--no-ext-diff", from, to]).catch(() => {
      return;
    });
    if (ran?.code !== 0)
      return [];
    const files = [];
    for (const section of ran.stdout.split(/^(?=diff --git )/m)) {
      const path = /^diff --git a\/(.+?) b\//.exec(section)?.[1];
      if (!path)
        continue;
      const status = /^new file mode/m.test(section) ? "added" : /^deleted file mode/m.test(section) ? "deleted" : "modified";
      files.push(fromPatch(join5(directory, path), section, status));
    }
    return files;
  }
  async restore(directory, tree, now) {
    const changed = await this.git(directory, ["diff", "--name-only", "--no-renames", "-z", now, tree]).catch(() => {
      return;
    });
    if (changed?.code !== 0)
      return false;
    const paths = changed.stdout.split("\x00").filter(Boolean);
    if (!paths.length)
      return true;
    const listed = await this.git(directory, ["ls-tree", "-r", "-z", "--name-only", tree, "--", ...paths]).catch(() => {
      return;
    });
    if (listed?.code !== 0)
      return false;
    const there = new Set(listed.stdout.split("\x00").filter(Boolean));
    const back = paths.filter((path) => there.has(path));
    if (back.length) {
      const checked = await this.git(directory, ["checkout", tree, "--", ...back]).catch(() => {
        return;
      });
      if (checked?.code !== 0)
        return false;
    }
    for (const path of paths.filter((path2) => !there.has(path2)))
      rmSync2(join5(directory, path), { force: true });
    return true;
  }
}

// Agents/src/agents/antigravity.ts
import { createHash as createHash2 } from "crypto";
import { chmodSync as chmodSync2, existsSync as existsSync5, mkdirSync as mkdirSync7, readdirSync, readFileSync as readFileSync6, renameSync as renameSync3, rmSync as rmSync4, writeFileSync as writeFileSync6 } from "fs";
import { join as join7 } from "path";

// Agents/src/acp.ts
import { existsSync as existsSync3, mkdirSync as mkdirSync5, readFileSync as readFileSync4, writeFileSync as writeFileSync4 } from "fs";
import { dirname } from "path";

// Agents/src/rpc.ts
class RPCError extends Error {
  code;
  data;
  constructor(code, message, data) {
    super(message);
    this.code = code;
    this.data = data;
  }
}

class RPC {
  next = 1;
  pending = new Map;
  child;
  closed = false;
  stderr = "";
  onNotification = () => {};
  onRequest = async (method) => {
    throw new RPCError(-32601, `Method not found: ${method}`);
  };
  onExit = () => {};
  exited;
  constructor(command, options = {}) {
    this.jsonrpc = options.jsonrpc ?? false;
    if (options.firstID)
      this.next = options.firstID;
    this.filter = options.filter;
    const env = options.cleanEnv ? options.env : { ...process.env, ...options.env };
    this.child = Bun.spawn(command, { cwd: options.cwd, env, stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    this.exited = this.child.exited.then((code) => {
      this.closed = true;
      for (const { reject } of this.pending.values())
        reject(new Error(this.stderr.trim().split(`
`).slice(-3).join(`
`) || `The agent stopped (exit code ${code}).`));
      this.pending.clear();
      this.onExit(code);
      return code;
    });
    this.read();
    this.readErrors();
  }
  jsonrpc;
  filter;
  get pid() {
    return this.child.pid;
  }
  get isClosed() {
    return this.closed;
  }
  async read() {
    const decoder = new TextDecoder;
    let buffer = "";
    for await (const chunk of this.child.stdout) {
      buffer += decoder.decode(chunk, { stream: true });
      let newline;
      while ((newline = buffer.indexOf(`
`)) >= 0) {
        const line = buffer.slice(0, newline).replace(/\r$/, "");
        buffer = buffer.slice(newline + 1);
        if (line.trim() && (!this.filter || this.filter(line)))
          this.receive(line);
      }
    }
  }
  async readErrors() {
    const decoder = new TextDecoder;
    for await (const chunk of this.child.stderr) {
      this.stderr = (this.stderr + decoder.decode(chunk, { stream: true })).slice(-8000);
    }
  }
  receive(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    if (message.method !== undefined && message.id !== undefined) {
      this.answer(message.id, message.method, message.params);
    } else if (message.method !== undefined) {
      this.onNotification(message.method, message.params);
    } else if (message.id !== undefined) {
      const pending = this.pending.get(message.id);
      if (!pending)
        return;
      this.pending.delete(message.id);
      if (message.error)
        pending.reject(new RPCError(message.error.code ?? -32000, message.error.message ?? "The agent refused.", message.error.data));
      else
        pending.resolve(message.result);
    }
  }
  async answer(id, method, params) {
    try {
      const result = await this.onRequest(method, params);
      this.write({ id, result: result ?? null });
    } catch (error) {
      const code = error instanceof RPCError ? error.code : -32603;
      this.write({ id, error: { code, message: error instanceof Error ? error.message : String(error) } });
    }
  }
  write(message) {
    if (this.closed)
      return;
    const body = this.jsonrpc ? { jsonrpc: "2.0", ...message } : message;
    try {
      this.child.stdin.write(JSON.stringify(body) + `
`);
      this.child.stdin.flush();
    } catch {}
  }
  request(method, params, timeout) {
    if (this.closed)
      return Promise.reject(new Error(this.stderr.trim().split(`
`).slice(-3).join(`
`) || "The agent isn't running."));
    const id = this.next++;
    return new Promise((resolve2, reject) => {
      this.pending.set(id, { resolve: resolve2, reject });
      this.write(params === undefined ? { id, method } : { id, method, params });
      if (timeout) {
        setTimeout(() => {
          if (!this.pending.has(id))
            return;
          this.pending.delete(id);
          reject(new Error(`${method} took too long.`));
        }, timeout);
      }
    });
  }
  notify(method, params) {
    this.write(params === undefined ? { method } : { method, params });
  }
  kill() {
    if (this.closed)
      return;
    try {
      this.child.stdin.end();
    } catch {}
    this.child.kill();
  }
}

// Agents/src/kuvotools.ts
var server;
function setToolServer(value) {
  server = value;
}
var toolServerName = "kuvo-browser";
function kuvoTools(sessionID) {
  if (!server)
    return;
  return { name: toolServerName, url: server.url, headers: { Authorization: `Bearer ${server.token}`, "X-Kuvo-Session": sessionID }, timeout: server.timeout };
}

// Agents/src/acp.ts
var outputLimit2 = 30000;
var limitWords = /RESOURCE_EXHAUSTED|usage limit (?:reached|exceeded)|quota exceeded|exceeded your (?:current )?quota|rate limit exceeded|too many requests/i;

class AcpThread {
  flavor;
  session;
  state;
  name;
  rpc;
  sessionID;
  setup;
  spawnedWith;
  active;
  loading = false;
  stale;
  startedOver = false;
  constructor(flavor, session, state, name) {
    this.flavor = flavor;
    this.session = session;
    this.state = state;
    this.name = name;
  }
  async open(input, hooks) {
    const mode = { approvesAll: hooks.approvesAll(), plan: input.plan };
    const key = JSON.stringify({ ...mode, program: this.flavor.program?.() ?? 0, tools: kuvoTools(this.session.id)?.url });
    if (this.rpc && !this.rpc.isClosed && this.spawnedWith === key && this.rpc !== this.stale)
      return this.rpc;
    this.close();
    const launch = await this.flavor.command(mode);
    const flavor = this.flavor;
    const rpc = new RPC(launch.argv, {
      cwd: launch.cwd ?? this.session.location.directory,
      env: launch.env,
      cleanEnv: launch.cleanEnv,
      jsonrpc: true,
      firstID: 2 ** 30,
      filter: (line) => {
        const fatal = flavor.fatalLine?.(line);
        if (fatal) {
          setTimeout(() => {
            rpc.stderr = fatal;
            rpc.kill();
          });
          return false;
        }
        return flavor.filter?.(line) ?? true;
      }
    });
    rpc.onNotification = (method, params) => this.notification(method, params);
    rpc.onRequest = (method, params) => this.request(method, params);
    rpc.onExit = () => {
      launch.onExit?.();
      if (this.rpc === rpc)
        this.rpc = undefined;
      const active = this.active;
      if (active && !active.ended && active.rpc === rpc)
        this.end(active, "failed", rpc.stderr.trim().split(`
`).slice(-3).join(`
`) || `${this.name} stopped.`);
    };
    this.rpc = rpc;
    this.spawnedWith = key;
    if (launch.signInFile) {
      const file = launch.signInFile;
      const watch = setInterval(() => {
        if (rpc.isClosed)
          return clearInterval(watch);
        if (!existsSync3(file))
          return;
        clearInterval(watch);
        rpc.stderr = `${this.name} needs you to sign in again: Settings \u203A Accounts.`;
        rpc.kill();
      }, 500);
    }
    try {
      const init = await rpc.request("initialize", {
        protocolVersion: 1,
        clientCapabilities: { fs: { readTextFile: this.flavor.fileSystem, writeTextFile: this.flavor.fileSystem }, terminal: false },
        clientInfo: { name: "kuvo-code", title: "Kuvo Code", version: "1" },
        ...this.flavor.initializeMeta ? { _meta: this.flavor.initializeMeta } : {}
      }, 120000);
      const advertised = init?.authMethods ?? [];
      const authenticate = async () => {
        const methodId = this.flavor.authMethod(advertised);
        if (!methodId)
          throw new Error(`${this.name} isn't signed in. Sign in again in Settings \u203A Accounts.`);
        await rpc.request("authenticate", { methodId }, 300000);
      };
      if (this.flavor.authenticatesFirst)
        await authenticate();
      const cwd = this.session.location.directory;
      const previous = this.state.acpSession;
      const openSession = async () => {
        if (previous && this.flavor.resumes && init?.agentCapabilities?.sessionCapabilities?.resume) {
          this.loading = true;
          try {
            this.setup = await rpc.request("session/resume", { sessionId: previous, cwd, mcpServers: this.mcpServers(init) }, 120000);
            this.sessionID = previous;
            return;
          } catch {} finally {
            this.loading = false;
          }
        }
        if (previous && init?.agentCapabilities?.loadSession) {
          this.loading = true;
          try {
            this.setup = await rpc.request("session/load", { sessionId: previous, cwd, mcpServers: this.mcpServers(init) }, 120000);
            this.sessionID = previous;
            return;
          } catch {} finally {
            this.loading = false;
          }
        }
        this.setup = await rpc.request("session/new", { cwd, mcpServers: this.mcpServers(init) }, 120000);
        this.sessionID = this.setup?.sessionId;
        if (previous && previous !== this.sessionID) {
          this.startedOver = true;
          delete this.state.acpInstructions;
          delete this.state.acpInstructed;
        }
        this.state.acpSession = this.sessionID;
        hooks.saveState();
      };
      try {
        await openSession();
      } catch (error) {
        if (!(error instanceof RPCError && error.code === -32000))
          throw error;
        await authenticate();
        await openSession();
      }
    } catch (error) {
      if (this.rpc === rpc)
        this.close();
      throw error;
    }
    return rpc;
  }
  mcpServers(init) {
    const tools = kuvoTools(this.session.id);
    if (!tools || !init?.agentCapabilities?.mcpCapabilities?.http)
      return [];
    return [{ type: "http", name: tools.name, url: tools.url, headers: Object.entries(tools.headers).map(([name, value]) => ({ name, value })) }];
  }
  async prepare(input, hooks) {
    await this.open(input, hooks);
    const fresh = this.startedOver;
    this.startedOver = false;
    return { fresh };
  }
  async run(input, turn, hooks) {
    const rpc = await this.open(input, hooks);
    if (hooks.signal.aborted)
      return { outcome: "interrupted" };
    const sessionId = this.sessionID;
    await this.flavor.selectModel(rpc, sessionId, input.model.id, this.setup).catch(() => {});
    await this.flavor.selectMode?.(rpc, sessionId, { approvesAll: hooks.approvesAll(), plan: input.plan }, this.setup).catch(() => {});
    if (hooks.signal.aborted)
      return { outcome: "interrupted" };
    const prompt = [];
    const others = [];
    for (const file of input.files) {
      const data = file.data ?? (file.mime.startsWith("image/") && file.path ? safeBase64(file.path) : undefined);
      if (file.mime.startsWith("image/") && data)
        prompt.push({ type: "image", data, mimeType: file.mime });
      else if (file.path)
        others.push(file.path);
    }
    let text = input.text;
    const instructions = hooks.instructions();
    const sent = typeof this.state.acpInstructions === "string" ? this.state.acpInstructions : this.state.acpInstructed ? undefined : "";
    let instructed;
    if (instructions !== sent && (instructions || sent)) {
      if (instructions)
        text = `${sent ? `Your instructions from Kuvo Code changed. They're now:

` : ""}${instructions}

${text}`;
      instructed = { value: instructions };
    }
    if (others.length)
      text += `

Attached files:
${others.map((path) => `- ${path}`).join(`
`)}`;
    prompt.unshift({ type: "text", text });
    return new Promise((resolve2) => {
      const active = { turn, hooks, resolve: resolve2, rpc, tools: new Map, toolsSinceText: false, ended: false, instructed };
      this.active = active;
      turn.startStep();
      const meta = this.flavor.promptMeta?.();
      rpc.request("session/prompt", { sessionId, prompt, ...meta ? { _meta: meta } : {} }).then((result) => {
        active.answered = true;
        if (result?.stopReason === "rate_limit")
          this.end(active, "failed", `You've reached your ${this.name} usage limit for now.`, this.limit());
        else
          this.end(active, result?.stopReason === "cancelled" ? "interrupted" : "succeeded");
      }, (error) => {
        const limited = error instanceof RPCError && error.code === -32003 || limitWords.test(errorText(error));
        this.end(active, "failed", limited ? `You've reached your ${this.name} usage limit for now.` : errorText(error), limited ? this.limit(errorText(error)) : undefined);
      });
    });
  }
  limit(message) {
    return { scope: this.flavor.limitScope ?? "provider", message };
  }
  end(active, outcome, message, limit) {
    if (active.ended)
      return;
    active.ended = true;
    if (active.instructed && (outcome !== "failed" || active.heard)) {
      this.state.acpInstructions = active.instructed.value;
      delete this.state.acpInstructed;
      active.hooks.saveState();
    }
    if (this.active === active)
      this.active = undefined;
    if (active.plan)
      active.turn.toolSucceeded(active.plan.id, "", { todos: active.plan.todos });
    active.turn.endStep();
    if (active.hooks.signal.aborted)
      active.resolve({ outcome: "interrupted" });
    else if (limit)
      active.resolve({ outcome: "failed", error: { type: "limit", message: message ?? `You've reached your ${this.name} usage limit for now.` }, limit, taken: active.heard || active.answered });
    else
      active.resolve(outcome === "failed" ? { outcome, error: failure(message ?? `${this.name} stopped with an error.`), taken: active.heard || active.answered } : { outcome });
  }
  context() {
    const active = this.active;
    return {
      turn: active?.turn,
      hooks: active?.hooks,
      endPrompt: (stopReason, error) => {
        if (active)
          this.end(active, error ? "failed" : stopReason === "cancelled" ? "interrupted" : "succeeded", error, stopReason === "rate_limit" ? this.limit(error) : undefined);
      }
    };
  }
  notification(method, params) {
    if (method !== "session/update") {
      this.flavor.notification?.(method, params, this.context());
      return;
    }
    const active = this.active;
    if (!active || this.loading || params?._meta?.isReplay)
      return;
    active.heard = true;
    const update = params?.update ?? {};
    const turn = active.turn;
    switch (update.sessionUpdate) {
      case "agent_message_chunk":
        this.words(active);
        turn.text(contentText(update.content));
        return;
      case "agent_thought_chunk":
        this.words(active);
        turn.reasoning(contentText(update.content));
        return;
      case "tool_call":
      case "tool_call_update":
        return this.tool(active, update);
      case "plan": {
        const todos = (update.entries ?? []).map((entry) => ({ content: entry.content, status: entry.status === "in_progress" ? "in_progress" : entry.status }));
        const id = active.plan?.id ?? newID("call");
        active.plan = { id, todos };
        if (!turn.hasTool(id))
          turn.toolStart(id, "todowrite", { todos });
        else
          turn.toolCalled(id, { todos });
        return;
      }
    }
  }
  words(active) {
    if (!active.toolsSinceText)
      return;
    active.toolsSinceText = false;
    active.turn.endStep();
    active.turn.startStep();
  }
  tool(active, update) {
    const turn = active.turn;
    const id = update.toolCallId;
    if (!id)
      return;
    const merged = { ...active.tools.get(id) ?? {}, ...Object.fromEntries(Object.entries(update).filter(([, value]) => value !== undefined && value !== null)) };
    active.tools.set(id, merged);
    const kuvo = kuvoTool(merged);
    if (!turn.hasTool(id)) {
      active.toolsSinceText = true;
      turn.toolStart(id, kuvo.name, kuvo.input);
    } else {
      turn.toolRename(id, kuvo.name);
      if (merged.status !== "completed" && merged.status !== "failed")
        turn.toolCalled(id, kuvo.input);
    }
    const output = toolOutput(merged);
    const files = (merged.content ?? []).filter((part) => part?.type === "diff" && part.path).map((part) => fileDiff(part.path, part.oldText ?? undefined, part.newText ?? ""));
    const metadata = {};
    if (files.length)
      metadata.files = files;
    const exit = merged.rawOutput?.exit_code ?? merged.rawOutput?.exitCode;
    if (typeof exit === "number")
      metadata.exit = exit;
    if (output)
      metadata.output = output;
    if (merged.status === "completed")
      turn.toolSucceeded(id, output, metadata);
    else if (merged.status === "failed")
      turn.toolFailed(id, output || "The tool failed.", metadata);
    else if (output)
      turn.toolProgress(id, metadata);
  }
  async request(method, params) {
    const own = this.flavor.request?.(method, params, this.context());
    if (own)
      return own;
    const active = this.active;
    switch (method) {
      case "session/request_permission": {
        const options = params?.options ?? [];
        if (!active)
          return { outcome: { outcome: "cancelled" } };
        const call = { ...active.tools.get(params.toolCall?.toolCallId) ?? {}, ...params.toolCall ?? {} };
        if (String(call.toolCallId ?? "").startsWith("interaction_")) {
          const answer = await active.hooks.question({
            title: "Question",
            fields: [{ key: "answer", title: "Question", description: call.title ?? "", required: true, type: "string", options: options.map((option2) => ({ value: option2.optionId, label: option2.name ?? option2.optionId })) }]
          });
          const chosen = answer?.answer;
          return chosen ? { outcome: { outcome: "selected", optionId: String(chosen) } } : { outcome: { outcome: "cancelled" } };
        }
        const kuvo = kuvoTool(call);
        const files = (call.content ?? []).filter((part) => part?.type === "diff" && part.path).map((part) => fileDiff(part.path, part.oldText ?? undefined, part.newText ?? ""));
        const decision = await active.hooks.permission({
          toolCallID: call.toolCallId,
          action: permissionAction(call.kind, kuvo.name),
          resources: resources(call),
          metadata: files.length ? { files } : undefined,
          message: call.title
        });
        const pick = (kinds2) => kinds2.map((kind) => options.find((option2) => option2.kind === kind)).find(Boolean);
        const option = decision === "reject" ? pick(["reject_once", "reject_always"]) : decision === "always" ? pick(["allow_always", "allow_once"]) : pick(["allow_once", "allow_always"]);
        return option ? { outcome: { outcome: "selected", optionId: option.optionId } } : { outcome: { outcome: "cancelled" } };
      }
      case "fs/read_text_file": {
        if (!this.flavor.fileSystem)
          break;
        let content = readFileSync4(params.path, "utf8");
        if (params.line || params.limit) {
          const lines2 = content.split(`
`);
          const start = Math.max(0, (params.line ?? 1) - 1);
          content = lines2.slice(start, params.limit ? start + params.limit : undefined).join(`
`);
        }
        return { content };
      }
      case "fs/write_text_file": {
        if (!this.flavor.fileSystem)
          break;
        mkdirSync5(dirname(params.path), { recursive: true });
        writeFileSync4(params.path, params.content ?? "");
        return {};
      }
    }
    throw new RPCError(-32601, `Method not found: ${method}`);
  }
  async interrupt() {
    const active = this.active;
    const rpc = active?.rpc;
    if (!active || !rpc || !this.sessionID)
      return;
    if (this.flavor.restartAfterInterrupt)
      this.stale = rpc;
    rpc.notify("session/cancel", { sessionId: this.sessionID });
    for (let waited = 0;waited < 15000 && !active.ended; waited += 100)
      await Bun.sleep(100);
    if (active.ended)
      return;
    this.end(active, "interrupted");
    if (this.rpc === rpc && (!this.active || this.active.rpc !== rpc))
      this.close();
  }
  close() {
    this.rpc?.kill();
    this.rpc = undefined;
  }
}
function kuvoTool(call) {
  const raw = call.rawInput ?? {};
  const path = call.locations?.[0]?.path ?? raw.path ?? raw.file_path ?? raw.filePath;
  const command = Array.isArray(raw.command) ? raw.command.join(" ") : raw.command ?? raw.CommandLine ?? raw.command_line ?? raw.commandLine;
  switch (call.kind) {
    case "execute":
      return { name: "shell", input: { command: command ?? backticked(call.title) ?? call.title, description: raw.description } };
    case "read":
      return { name: "read", input: { path } };
    case "edit":
    case "delete":
    case "move":
      return { name: "edit", input: { path } };
    case "search":
      return { name: "grep", input: { pattern: raw.pattern ?? raw.query ?? call.title, path } };
    case "fetch":
      return { name: raw.url ? "webfetch" : "websearch", input: { url: raw.url, query: raw.query ?? call.title } };
    case "think":
      return { name: "think", input: {} };
  }
  return { name: (call.title ?? "tool").toLowerCase().replace(/[^a-z0-9_]+/g, "_").replace(/^_|_$/g, "") || "tool", input: raw };
}
function permissionAction(kind, name) {
  switch (kind) {
    case "execute":
      return "shell";
    case "edit":
    case "delete":
    case "move":
      return "edit";
    case "fetch":
      return "webfetch";
    case "read":
    case "search":
      return "read";
  }
  return name;
}
function resources(call) {
  const raw = call.rawInput ?? {};
  if (call.kind === "execute") {
    const command = Array.isArray(raw.command) ? raw.command.join(" ") : raw.command ?? backticked(call.title);
    return [command ?? call.title ?? "*"];
  }
  const paths = (call.locations ?? []).map((location) => location.path).filter(Boolean);
  if (paths.length)
    return paths;
  return [raw.path ?? raw.url ?? raw.file_path ?? "*"];
}
function backticked(title) {
  return typeof title === "string" ? title.match(/`([^`]+)`/)?.[1] : undefined;
}
function contentText(content) {
  if (!content)
    return "";
  if (typeof content === "string")
    return content;
  if (content.type === "text")
    return content.text ?? "";
  if (content.type === "resource_link")
    return content.name ?? content.uri ?? "";
  if (content.type === "resource")
    return content.resource?.text ?? "";
  return "";
}
function toolOutput(call) {
  const parts = [];
  for (const part of call.content ?? []) {
    if (part?.type === "content")
      parts.push(contentText(part.content));
    else if (part?.type === "terminal")
      continue;
  }
  const raw = call.rawOutput;
  if (!parts.length && raw) {
    for (const key of ["output_for_prompt", "combinedOutput", "combined_output", "output", "stdout", "content"]) {
      const value = raw[key];
      if (typeof value === "string" && value) {
        parts.push(value);
        break;
      }
    }
  }
  const text = parts.filter(Boolean).join(`
`);
  return text.length > outputLimit2 ? text.slice(-outputLimit2) : text;
}
function errorText(error) {
  if (error instanceof RPCError) {
    const data = error.data;
    return data?.message ?? error.message;
  }
  return error instanceof Error ? error.message : String(error);
}
function safeBase64(path) {
  try {
    return readFileSync4(path).toString("base64");
  } catch {
    return;
  }
}
function questionFields(questions) {
  return questions.map((question, index) => ({
    key: question.id ?? `q${index}`,
    title: question.header ?? `Question ${index + 1}`,
    description: question.question,
    required: true,
    type: question.multiSelect ? "multiselect" : "string",
    options: (question.options ?? []).map((option) => ({ value: option.label, label: option.label, description: option.description })),
    custom: true
  }));
}

// Agents/src/signin.ts
import { chmodSync, existsSync as existsSync4, mkdirSync as mkdirSync6, readFileSync as readFileSync5, rmSync as rmSync3, writeFileSync as writeFileSync5 } from "fs";
import { join as join6 } from "path";
function catcher(temporary) {
  const path = join6(temporary, "bin", "kuvo-catch-url");
  if (!existsSync4(path)) {
    mkdirSync6(join6(temporary, "bin"), { recursive: true });
    writeFileSync5(path, `#!/bin/sh
printf '%s\\n' "$1" >> "$KUVO_URL_FILE"
`);
    chmodSync(path, 493);
  }
  return path;
}
async function commandSignIn(options) {
  const urlFile = join6(options.temporary, `${newID("att")}.url`);
  const child = Bun.spawn([options.command, ...options.args], {
    env: { ...process.env, ...options.env, BROWSER: catcher(options.temporary), KUVO_URL_FILE: urlFile },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe"
  });
  let output = "";
  let status = { status: "pending" };
  const read = async (stream) => {
    const decoder = new TextDecoder;
    for await (const chunk of stream)
      output += plain(decoder.decode(chunk));
  };
  read(child.stdout);
  read(child.stderr);
  let pasted = false;
  let signedInBefore;
  const succeed = () => {
    status = { status: "complete" };
    options.onComplete?.();
  };
  child.exited.then(async (code) => {
    rmSync3(urlFile, { force: true });
    if (status.status !== "pending")
      return;
    const signedIn = await options.signedIn().catch(() => false);
    if (status.status !== "pending")
      return;
    if (signedIn && (code === 0 || signedInBefore === false))
      succeed();
    else if (pasted)
      status = { status: "failed", message: "That code didn't work. Start again, and paste the code from the page this sign-in opens." };
    else
      status = { status: "failed", message: lastLines(options.codePrompt ? output.replace(options.codePrompt, "") : output) || `Signing in stopped (exit code ${code}).` };
  });
  (async () => {
    signedInBefore = await options.signedIn().catch(() => true);
    if (signedInBefore)
      return;
    while (status.status === "pending") {
      await Bun.sleep(3000);
      if (status.status !== "pending")
        return;
      if (!await options.signedIn().catch(() => false))
        continue;
      if (status.status === "pending")
        succeed();
      child.kill();
    }
  })();
  let url = "";
  let printedAt;
  for (let waited = 0;waited < 15000 && !url; waited += 200) {
    if (existsSync4(urlFile))
      url = readFileSync5(urlFile, "utf8").split(`
`)[0].trim();
    const printed = firstURL(output);
    if (printed)
      printedAt ??= waited;
    if (!url && printed && waited - printedAt >= 3000)
      url = printed;
    if (!url)
      await Bun.sleep(200);
    if (status.status !== "pending")
      break;
  }
  return {
    url,
    instructions: options.instructions,
    mode: "auto",
    acceptsCode: Boolean(options.codePrompt),
    complete: options.codePrompt ? async (code) => {
      if (status.status !== "pending")
        throw new Error("That sign-in is over. Start it again.");
      pasted = true;
      const from = output.length;
      child.stdin.write(code.trim() + `
`);
      await child.stdin.flush();
      for (let waited = 0;waited < 1500 && status.status === "pending"; waited += 100) {
        await Bun.sleep(100);
        if (/invalid code/i.test(output.slice(from))) {
          pasted = false;
          throw new Error("That code couldn't be read. Copy all of it from the page, and paste it again.");
        }
      }
    } : undefined,
    status: () => status,
    cancel() {
      if (status.status === "pending")
        status = { status: "failed", message: "Cancelled." };
      child.kill();
    }
  };
}
function lastLines(text) {
  return text.trim().split(`
`).slice(-4).join(`
`).trim();
}

// Agents/src/agents/antigravity.ts
var version = "1.3.0";
var releases = {
  "darwin-arm64": {
    url: "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-1.3.0-darwin-arm64.zip",
    sha256: "7cd97045f7b4fe81175a107cdf16f9c51484e3c78a5162cae415338bb6aa5b88",
    bytes: 111456962
  },
  "darwin-x64": {
    url: "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-1.3.0-darwin-x86_64.zip",
    sha256: "bb23956b89984bf5d354af2c3725e6c57f0cc1b7228e77a0e91c9c2bc1d47646",
    bytes: 117245544
  },
  "linux-x64": {
    url: "https://dl.google.com/agy-extensions/releases/linux/agy-acp-server-1.3.0-linux-x86_64.zip",
    sha256: "9fb60956af0a9d76220a4db91ca9ac88e2a2372ad68f985ab5fceace6b825b96",
    bytes: 333727150
  },
  "linux-arm64": {
    url: "https://dl.google.com/agy-extensions/releases/linux/agy-acp-server-1.3.0-linux-arm64.zip",
    sha256: "500b0bc0fb858e88f4df404d4cedf80bf9298c178291e39e383d6c50b111cbdf",
    bytes: 321690363
  }
};
var executableName = "agy_acp_server.par";
var harnessName = "localharness_external";
var signInLine = "Open the following link to authenticate the ACP server:";
var scrubbed = [
  "GEMINI_API_KEY",
  "GOOGLE_API_KEY",
  "GOOGLE_APPLICATION_CREDENTIALS",
  "GOOGLE_CLOUD_PROJECT",
  "GOOGLE_CLOUD_LOCATION",
  "GOOGLE_CLOUD_QUOTA_PROJECT",
  "GOOGLE_GENAI_USE_VERTEXAI",
  "GCLOUD_PROJECT",
  "CLOUDSDK_CORE_PROJECT",
  "AGY_ACP_CCPA_PROJECT",
  "AGY_ACP_ENABLE_OAUTH",
  "GEMINI_HOME",
  "AGY_ACP_FORCE_FILE_STORAGE",
  "ANTIGRAVITY_HARNESS_PATH",
  "BROWSER",
  "PYTHONUNBUFFERED",
  "ELECTRON_RUN_AS_NODE"
];

class AntigravityAgent {
  context;
  instance;
  id = "antigravity";
  providerID;
  get name() {
    return accountName("Antigravity", this.instance);
  }
  installing;
  downloaded;
  constructor(context, instance = { id: "default" }) {
    this.context = context;
    this.instance = instance;
    this.providerID = providerID("antigravity", instance.id);
  }
  get root() {
    return join7(this.context.home, "antigravity");
  }
  get folder() {
    return join7(this.root, version);
  }
  get profile() {
    return this.instance.home ? join7(this.instance.home, "profile") : join7(this.root, "profile");
  }
  get tokenFile() {
    return join7(this.profile, "antigravity-acp", "acp_token.json");
  }
  get modelsFile() {
    return join7(this.profile, "kuvo-models.json");
  }
  get isInstalled() {
    return existsSync5(join7(this.folder, ".complete"));
  }
  methods() {
    return [{ type: "oauth", id: "oauth-personal", label: "Sign in with Google" }];
  }
  async account() {
    const release = releases[`${process.platform}-${process.arch}`];
    if (!release)
      return { installed: false, signedIn: false, message: "Google doesn't make Antigravity's agent for this computer." };
    if (!existsSync5(this.tokenFile)) {
      return {
        installed: this.isInstalled,
        signedIn: false,
        message: this.isInstalled ? "Sign in with your Google account." : "Sign in with your Google account. Kuvo Code downloads Google's Antigravity agent (about 110 MB) first."
      };
    }
    return { installed: this.isInstalled, signedIn: true, label: "Google account" };
  }
  ensureInstalled() {
    if (this.isInstalled)
      return Promise.resolve();
    this.installing ??= this.download().finally(() => this.installing = undefined);
    return this.installing;
  }
  async download() {
    const release = releases[`${process.platform}-${process.arch}`];
    if (!release)
      throw new Error("Google doesn't make Antigravity's agent for this computer.");
    const staging = join7(this.root, `.install-${newID("att")}`);
    mkdirSync7(staging, { recursive: true });
    try {
      const archive = join7(staging, "download.zip");
      const response = await fetch(release.url);
      if (!response.ok || !response.body)
        throw new Error(`Couldn't download Antigravity's agent (HTTP ${response.status}).`);
      const hash = createHash2("sha256");
      const writer = Bun.file(archive).writer();
      let bytes = 0;
      this.downloaded = { bytes, total: release.bytes };
      for await (const chunk of response.body) {
        hash.update(chunk);
        writer.write(chunk);
        bytes += chunk.byteLength;
        this.downloaded = { bytes, total: release.bytes };
      }
      await writer.end();
      if (bytes !== release.bytes || hash.digest("hex") !== release.sha256)
        throw new Error("Antigravity's agent didn't download whole. Try again.");
      const listed = await run("/usr/bin/unzip", ["-Z1", archive]);
      const entries = listed.stdout.split(`
`).filter(Boolean).sort();
      if (entries.join(",") !== [executableName, harnessName].sort().join(","))
        throw new Error("Antigravity's agent wasn't what Kuvo Code expected.");
      const unzipped = await run("/usr/bin/unzip", ["-q", "-o", archive, "-d", staging]);
      if (unzipped.code !== 0)
        throw new Error(`Couldn't unpack Antigravity's agent: ${unzipped.stderr.trim()}`);
      rmSync4(archive, { force: true });
      for (const name of [executableName, harnessName])
        chmodSync2(join7(staging, name), 493);
      writeFileSync6(join7(staging, ".complete"), JSON.stringify({ version, sha256: release.sha256 }));
      rmSync4(this.folder, { recursive: true, force: true });
      renameSync3(staging, this.folder);
      for (const name of readdirSync(this.root)) {
        if (name !== version && name !== "profile" && /^\d/.test(name))
          rmSync4(join7(this.root, name), { recursive: true, force: true });
      }
    } finally {
      this.downloaded = undefined;
      rmSync4(staging, { recursive: true, force: true });
    }
  }
  launch() {
    mkdirSync7(join7(this.profile, "antigravity-acp", "tmp"), { recursive: true, mode: 448 });
    const settings = join7(this.profile, "antigravity-acp", "settings.json");
    if (!existsSync5(settings))
      writeFileSync6(settings, JSON.stringify({ auth: { type: "oauth-personal" } }));
    const temporary = join7(this.context.temporary, "antigravity", newID("att"));
    mkdirSync7(temporary, { recursive: true });
    const env = {};
    for (const [key, value] of Object.entries(process.env))
      if (!scrubbed.includes(key.toUpperCase()))
        env[key] = value;
    Object.assign(env, {
      GEMINI_HOME: this.profile,
      AGY_ACP_FORCE_FILE_STORAGE: "1",
      BROWSER: catcher(this.context.temporary),
      KUVO_URL_FILE: join7(temporary, "url"),
      PYTHONUNBUFFERED: "1",
      TMPDIR: temporary,
      ANTIGRAVITY_HARNESS_PATH: join7(this.folder, harnessName)
    });
    const argv = [join7(this.folder, executableName), ...process.platform === "linux" ? ["--uid="] : []];
    return { argv, env, cleanEnv: true, onExit: () => rmSync4(temporary, { recursive: true, force: true }), signInFile: join7(temporary, "url") };
  }
  async signIn() {
    let status = { status: "pending" };
    let link = "";
    let rpc;
    let cancelled = false;
    const found = (url) => {
      if (!link && url.startsWith("https://"))
        link = url;
    };
    const flow = async () => {
      await this.ensureInstalled();
      if (cancelled)
        return;
      const launch = this.launch();
      const cwd = join7(this.context.temporary, "antigravity", newID("att"));
      mkdirSync7(cwd, { recursive: true });
      rpc = new RPC(launch.argv, {
        cwd,
        env: launch.env,
        cleanEnv: true,
        jsonrpc: true,
        firstID: 2 ** 30,
        filter: (line) => {
          const at = line.indexOf(signInLine);
          if (at >= 0) {
            found(line.slice(at + signInLine.length).trim());
            return false;
          }
          return true;
        }
      });
      rpc.onExit = () => {
        launch.onExit();
        rmSync4(cwd, { recursive: true, force: true });
      };
      const watch = setInterval(() => {
        try {
          found(readFileSync6(launch.env.KUVO_URL_FILE, "utf8").split(`
`)[0].trim());
        } catch {}
      }, 300);
      try {
        await rpc.request("initialize", { protocolVersion: 1, clientCapabilities: { fs: { readTextFile: true, writeTextFile: true }, terminal: false }, clientInfo: { name: "kuvo-code", version: "1" } }, 120000);
        await rpc.request("authenticate", { methodId: "oauth-personal" }, 600000);
        const setup = await rpc.request("session/new", { cwd, mcpServers: [] }, 120000);
        this.saveModels(setup);
        if (setup?.sessionId)
          this.removeSessionFiles(setup.sessionId);
        if (!cancelled)
          status = { status: "complete" };
      } finally {
        clearInterval(watch);
        rpc.kill();
      }
    };
    flow().catch((error) => {
      if (status.status !== "pending")
        return;
      const message = String(error?.message ?? error);
      status = {
        status: "failed",
        message: cancelled ? "Cancelled." : /SUBSCRIPTION_REQUIRED/i.test(message) ? "Google says this account needs an Antigravity subscription." : /access_denied/i.test(message) ? "Google sign-in wasn't approved." : failure(error).message
      };
    });
    return {
      url: "",
      instructions: "Finish signing in with Google in your browser.",
      mode: "auto",
      status: () => {
        if (status.status !== "pending")
          return status;
        const downloading = this.downloaded;
        if (downloading) {
          const percent = Math.floor(downloading.bytes / downloading.total * 100);
          return { status: "pending", message: `Downloading Google's Antigravity agent\u2026 ${percent}%` };
        }
        if (!link)
          return { status: "pending", message: "Starting Google's Antigravity agent\u2026" };
        return { status: "pending", url: link, message: "Finish signing in with Google in your browser." };
      },
      cancel: () => {
        cancelled = true;
        if (status.status === "pending")
          status = { status: "failed", message: "Cancelled." };
        rpc?.kill();
      }
    };
  }
  async signOut() {
    rmSync4(this.tokenFile, { force: true });
    rmSync4(this.modelsFile, { force: true });
  }
  saveModels(setup) {
    const option = (setup?.configOptions ?? []).find((option2) => option2.id === "model" || option2.category === "model");
    const flat = [];
    for (const entry of option?.options ?? []) {
      if (Array.isArray(entry.options))
        for (const inner of entry.options)
          flat.push({ value: inner.value, name: inner.name ?? inner.value });
      else if (entry.value)
        flat.push({ value: entry.value, name: entry.name ?? entry.value });
    }
    if (!flat.length) {
      for (const info of setup?.models?.availableModels ?? [])
        flat.push({ value: info.modelId, name: info.name ?? info.modelId });
    }
    if (flat.length)
      writeFileSync6(this.modelsFile, JSON.stringify({ current: option?.currentValue, models: flat }));
  }
  removeSessionFiles(sessionID) {
    const folder = join7(this.profile, "antigravity-acp");
    for (const suffix of [".db", ".db-wal", ".db-shm", ".db-journal", ".meta"])
      rmSync4(join7(folder, "conversations", sessionID + suffix), { force: true });
    rmSync4(join7(folder, "brain", sessionID), { recursive: true, force: true });
  }
  async models() {
    try {
      const saved = JSON.parse(readFileSync6(this.modelsFile, "utf8"));
      return saved.models.map((info, index) => model(this.providerID, info.value, info.name, { images: true, released: info.value === saved.current ? 2000 : 1000 - index, context: 1e6 }));
    } catch {
      return [];
    }
  }
  thread(session, state) {
    const agent = this;
    return new AcpThread({
      fileSystem: true,
      authenticatesFirst: true,
      resumes: true,
      limitScope: "model",
      authMethod: () => "oauth-personal",
      async command() {
        if (!agent.isInstalled)
          throw new Error("Sign in to Antigravity in Settings \u203A Accounts first.");
        return agent.launch();
      },
      fatalLine(line) {
        return line.includes(signInLine) ? "Antigravity needs you to sign in again: Settings \u203A Accounts." : undefined;
      },
      async selectModel(rpc, sessionId, modelID, setup) {
        if (setup?.kuvoModel === modelID)
          return;
        await rpc.request("session/set_config_option", { sessionId, configId: "model", value: modelID }, 30000);
        setup.kuvoModel = modelID;
        agent.saveModels(setup);
      },
      async selectMode(rpc, sessionId, { approvesAll, plan }, setup) {
        const option = (setup?.configOptions ?? []).find((option2) => option2.id === "mode" || option2.category === "mode");
        const values = (option?.options ?? []).map((entry) => entry.value);
        const wanted = plan && values.includes("plan") ? "plan" : approvesAll ? "yolo" : "default";
        if (!option || setup.kuvoMode === wanted || values.length && !values.includes(wanted))
          return;
        await rpc.request("session/set_config_option", { sessionId, configId: option.id, value: wanted }, 30000);
        setup.kuvoMode = wanted;
      }
    }, session, state, this.name);
  }
}

// Agents/src/agents/claude.ts
import { randomUUID } from "crypto";
import { existsSync as existsSync7, readFileSync as readFileSync7, statSync } from "fs";
import { homedir } from "os";
import { join as join9 } from "path";

// Agents/src/maintenance.ts
import { existsSync as existsSync6, realpathSync } from "fs";
import { basename, join as join8 } from "path";
var checked = new Map;
var newest = new Map;
var updating = new Map;
async function maintenance(definition, fresh = false) {
  const kept = checked.get(definition.executable);
  if (!fresh && kept && Date.now() - kept.at < 10 * 60000)
    return kept.value;
  const [installed, updater] = await Promise.all([installedVersion2(definition.executable), resolveUpdater(definition)]);
  const latest = updater.homebrew ? updater.latest : updater.latest ?? await npmLatest(definition.npmPackage, fresh, updater.distTag);
  const value = { installed, latest, command: updater.command, shown: updater.shown, env: updater.env };
  checked.set(definition.executable, { at: Date.now(), value });
  return value;
}
function isOutdated(maintenance2) {
  return Boolean(maintenance2.installed && maintenance2.latest && compareVersions(maintenance2.installed, maintenance2.latest) < 0);
}
function update(definition, temporary) {
  const running = updating.get(definition.executable);
  if (running)
    return running;
  const task = (async () => {
    const before = await maintenance(definition, true);
    if (!before.command)
      return { updated: false, version: before.installed, message: `Update ${definition.name} the way you installed it.` };
    const ran = await run(before.command[0], before.command.slice(1), { cwd: temporary, env: before.env, timeout: 10 * 60000 });
    const after = await maintenance(definition, true);
    const changed = Boolean(after.installed && after.installed !== before.installed);
    if (changed || after.installed && !isOutdated(after))
      return { updated: changed, version: after.installed };
    const output = plain(ran.stderr + `
` + ran.stdout).trim().split(`
`).slice(-6).join(`
`).trim();
    return {
      updated: false,
      version: after.installed,
      message: `${definition.name} is still ${after.installed ?? "the same version"} after \`${before.shown}\`.${output ? `

${output}` : ""}`
    };
  })().finally(() => updating.delete(definition.executable));
  updating.set(definition.executable, task);
  return task;
}
async function installedVersion2(executable) {
  const ran = await run(executable, ["--version"], { timeout: 15000 }).catch(() => {
    return;
  });
  return ran ? versionIn(plain(ran.stdout + " " + ran.stderr)) : undefined;
}
function versionIn(text) {
  return text.match(/\b(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)\b/)?.[1];
}
function compareVersions(a, b) {
  const [mainA, preA] = a.split("-", 2);
  const [mainB, preB] = b.split("-", 2);
  const partsA = mainA.split(".").map(Number);
  const partsB = mainB.split(".").map(Number);
  for (let i = 0;i < Math.max(partsA.length, partsB.length); i++) {
    const difference = (partsA[i] ?? 0) - (partsB[i] ?? 0);
    if (difference)
      return Math.sign(difference);
  }
  if (preA === preB)
    return 0;
  if (!preA)
    return 1;
  if (!preB)
    return -1;
  return preA < preB ? -1 : 1;
}
async function npmLatest(name, fresh, tag = "latest") {
  const key = `${name}@${tag}`;
  const kept = newest.get(key);
  if (!fresh && kept && Date.now() - kept.at < 6 * 60 * 60000)
    return kept.value;
  try {
    const response = await fetch(`https://registry.npmjs.org/${name.replace("/", "%2F")}/${tag}`, { signal: AbortSignal.timeout(1e4) });
    const value = response.ok ? (await response.json()).version ?? undefined : undefined;
    newest.set(key, { at: Date.now(), value });
    return value;
  } catch {
    return kept?.value;
  }
}
async function resolveUpdater(definition) {
  let realPath = definition.executable;
  try {
    realPath = realpathSync(definition.executable);
  } catch {}
  const name = basename(definition.executable);
  const native = definition.nativeUpdate;
  const nativeUpdater = native ? { command: [definition.executable, ...native.args], shown: [name, ...native.args].join(" "), distTag: native.distTag?.() } : {};
  if (native?.isNative(realPath) || native && native.isNative(definition.executable))
    return nativeUpdater;
  const prefix = npmGlobalPrefix(realPath, definition.npmPackage);
  if (prefix) {
    const npm = existsSync6(join8(prefix, "bin", "npm")) ? join8(prefix, "bin", "npm") : "npm";
    return {
      command: [npm, "install", "-g", "--prefix", prefix, `--allow-scripts=${definition.npmPackage}`, `${definition.npmPackage}@latest`],
      shown: `npm install -g ${definition.npmPackage}@latest`,
      env: { PATH: `${join8(prefix, "bin")}:${process.env.PATH ?? ""}` }
    };
  }
  const keg = homebrewKeg(realPath);
  if (keg && keg.name.toLowerCase() !== "mise") {
    const brew = existsSync6(join8(keg.prefix, "bin", "brew")) ? join8(keg.prefix, "bin", "brew") : which("brew");
    if (brew) {
      const said = (await run(brew, ["--prefix"], { timeout: 15000 }).catch(() => {
        return;
      }))?.stdout.trim();
      let brewPrefix = said;
      try {
        if (said)
          brewPrefix = realpathSync(said);
      } catch {}
      if (brewPrefix && brewPrefix === keg.prefix) {
        const cask = keg.kind === "cask";
        const info = await run(brew, ["info", "--json=v2", ...cask ? ["--cask"] : [], keg.name], { timeout: 30000, env: { HOMEBREW_NO_AUTO_UPDATE: "1" } }).catch(() => {
          return;
        });
        return {
          command: [brew, "upgrade", ...cask ? ["--cask"] : [], keg.name],
          shown: `brew upgrade ${cask ? "--cask " : ""}${keg.name}`,
          latest: info ? homebrewLatest(info.stdout, cask) : undefined,
          homebrew: true
        };
      }
    }
  }
  if (realPath.includes("/node_modules/") || realPath.includes("/mise/"))
    return {};
  return nativeUpdater;
}
function npmGlobalPrefix(realPath, packageName) {
  const segment = `/lib/node_modules/${packageName.toLowerCase()}/`;
  const at = realPath.toLowerCase().lastIndexOf(segment);
  if (at < 0 || realPath.slice(0, at).toLowerCase().includes("/node_modules/"))
    return;
  const miseTool = /\/mise\/installs\/([^/]+)\/[^/]+$/.exec(realPath.slice(0, at).toLowerCase())?.[1];
  if (miseTool && miseTool !== "node")
    return;
  return at === 0 ? "/" : realPath.slice(0, at);
}
function homebrewKeg(realPath) {
  const match = /^(.*)\/(cellar|caskroom)\/([^/]+)\/[^/]+\//i.exec(realPath);
  if (!match)
    return;
  return { kind: match[2].toLowerCase() === "cellar" ? "formula" : "cask", name: match[3], prefix: match[1] };
}
function homebrewLatest(json, cask) {
  try {
    const info = JSON.parse(json);
    const raw = cask ? info.casks?.[0]?.version?.split(",", 1)[0] : info.formulae?.[0]?.versions?.stable;
    return raw && raw !== "latest" ? raw : undefined;
  } catch {
    return;
  }
}

// Agents/src/events.ts
var listeners = new Set;
function emit(type, data, directory) {
  const event = { id: newID("evt"), type, created: Date.now(), data };
  if (directory)
    event.location = { directory };
  for (const listener of listeners)
    listener(event);
  return event;
}
function feed() {
  const encoder = new TextEncoder;
  let listener;
  let heartbeat;
  const stream = new ReadableStream({
    start(controller) {
      const send = (event) => {
        try {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify(event)}

`));
        } catch {
          stop();
        }
      };
      const stop = () => {
        if (listener)
          listeners.delete(listener);
        if (heartbeat)
          clearInterval(heartbeat);
        listener = undefined;
        heartbeat = undefined;
      };
      send({ id: newID("evt"), type: "server.connected", created: Date.now(), data: {} });
      listener = send;
      listeners.add(send);
      heartbeat = setInterval(() => send({ id: newID("evt"), type: "server.heartbeat", created: Date.now(), data: {} }), 15000);
    },
    cancel() {
      if (listener)
        listeners.delete(listener);
      if (heartbeat)
        clearInterval(heartbeat);
    }
  });
  return new Response(stream, {
    headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive" }
  });
}

// Agents/src/queue.ts
class Queue {
  items = [];
  waiting;
  closed = false;
  push(item) {
    if (this.closed)
      return;
    if (this.waiting) {
      const resolve2 = this.waiting;
      this.waiting = undefined;
      resolve2({ value: item, done: false });
    } else {
      this.items.push(item);
    }
  }
  close() {
    this.closed = true;
    this.waiting?.({ value: undefined, done: true });
    this.waiting = undefined;
  }
  [Symbol.asyncIterator]() {
    return {
      next: () => {
        if (this.items.length)
          return Promise.resolve({ value: this.items.shift(), done: false });
        if (this.closed)
          return Promise.resolve({ value: undefined, done: true });
        return new Promise((resolve2) => this.waiting = resolve2);
      },
      return: () => {
        this.close();
        return Promise.resolve({ value: undefined, done: true });
      }
    };
  }
}

// Agents/src/agents/claude.ts
var SDK = [{ name: "@anthropic-ai/claude-agent-sdk", version: "0.3.303" }];
var places = [join9(homedir(), ".local/bin"), join9(homedir(), ".claude/local"), "/opt/homebrew/bin", "/usr/local/bin"];
var outputLimit3 = 30000;

class ClaudeAgent {
  context;
  instance;
  id = "claude";
  providerID;
  get name() {
    return accountName("Claude Code", this.instance);
  }
  install = "curl -fsSL https://claude.ai/install.sh | bash";
  status;
  authFailedAt;
  modelList;
  loadingModels;
  program = 0;
  constructor(context, instance = { id: "default" }) {
    this.context = context;
    this.instance = instance;
    this.providerID = providerID("claude", instance.id);
  }
  executable() {
    return which("claude", places);
  }
  get definition() {
    const executable = this.executable();
    if (!executable)
      return;
    return {
      name: "Claude Code",
      executable,
      npmPackage: "@anthropic-ai/claude-code",
      nativeUpdate: { args: ["update"], isNative: (path) => /\/\.local\/share\/claude\/|\/\.claude\/local\//.test(path), distTag: updateChannel }
    };
  }
  async maintenance(fresh = false) {
    const definition = this.definition;
    return definition ? maintenance(definition, fresh) : {};
  }
  async update() {
    const definition = this.definition;
    if (!definition)
      return { updated: false, message: "Claude Code isn't installed." };
    return update(definition, this.context.temporary);
  }
  programUpdated() {
    this.program++;
    if (this.modelList)
      this.modelList.at = 0;
  }
  methods() {
    return [
      { type: "oauth", id: "claudeai", label: "Sign in with your Claude plan" },
      { type: "oauth", id: "console", label: "Sign in with Anthropic Console" }
    ];
  }
  async readStatus(fresh) {
    if (!fresh && this.status && Date.now() - this.status.at < 30000)
      return this.status.status;
    const executable = this.executable();
    if (!executable)
      return {};
    const result = await run(executable, ["auth", "status", "--json"], { timeout: 20000, env: this.env() });
    let status = {};
    try {
      status = JSON.parse(result.stdout);
    } catch {}
    this.status = { at: Date.now(), status };
    return status;
  }
  async account(fresh = false) {
    if (!this.executable()) {
      return { installed: false, signedIn: false, message: "Install Claude Code, then sign in here." };
    }
    const status = await this.readStatus(fresh);
    if (!status.loggedIn)
      return { installed: true, signedIn: false, message: "Sign in to Claude Code with your Claude plan or an Anthropic Console account." };
    if (this.authFailedAt && this.settingsWritten() <= this.authFailedAt + 60000) {
      return { installed: true, signedIn: false, ended: true, message: "Claude ended this sign-in. Sign in again." };
    }
    const plan = status.subscriptionType ? `${status.subscriptionType.charAt(0).toUpperCase()}${status.subscriptionType.slice(1)} plan` : undefined;
    const who = status.email ?? (status.apiProvider && status.apiProvider !== "firstParty" ? status.apiProvider : undefined);
    return { installed: true, signedIn: true, label: [who, plan].filter(Boolean).join(" \xB7 ") || "Claude Code" };
  }
  usesKey() {
    const method = this.status?.status.authMethod ?? "";
    return method !== "" && method !== "claude.ai";
  }
  settingsWritten() {
    const folder = this.instance.home ?? homedir();
    try {
      return statSync(join9(folder, ".claude.json")).mtimeMs;
    } catch {
      return 0;
    }
  }
  async signIn(methodID) {
    const executable = this.executable();
    if (!executable)
      throw new Error("Install Claude Code first: curl -fsSL https://claude.ai/install.sh | bash");
    return commandSignIn({
      command: executable,
      args: ["auth", "login", methodID === "console" ? "--console" : "--claudeai"],
      env: this.env(),
      home: this.context.home,
      temporary: this.context.temporary,
      instructions: "Finish signing in on Claude's page. Claude Code keeps the sign-in, as when you run claude auth login.",
      signedIn: async () => Boolean((await this.readStatus(true)).loggedIn),
      codePrompt: /Paste code here if prompted >\s*/g,
      onComplete: () => this.authFailedAt = undefined
    });
  }
  async sdk() {
    await this.context.deps.ensure(this.id, SDK, { optional: false });
    return this.context.deps.load(this.id, SDK[0].name);
  }
  env() {
    const env = { ...process.env, CLAUDE_CODE_TMPDIR: join9(this.context.temporary, "claude") };
    if (this.instance.home)
      env.CLAUDE_CONFIG_DIR = this.instance.home;
    return env;
  }
  async removeAccount() {
    const executable = this.executable();
    if (executable && this.instance.home)
      await run(executable, ["auth", "logout"], { timeout: 20000, env: this.env() }).catch(() => {});
  }
  async models() {
    if (this.modelList && Date.now() - this.modelList.at < 30 * 60000)
      return this.modelList.models;
    this.loadingModels ??= this.loadModels().finally(() => this.loadingModels = undefined);
    return this.modelList?.models ?? fallbackModels(this.providerID);
  }
  async loadModels() {
    const sdk = await this.sdk();
    const abort = new AbortController;
    const idle = async function* () {
      await new Promise((resolve2) => abort.signal.addEventListener("abort", resolve2));
    }();
    const q = sdk.query({
      prompt: idle,
      options: {
        pathToClaudeCodeExecutable: this.executable(),
        cwd: this.context.temporary,
        persistSession: false,
        abortController: abort,
        allowedTools: [],
        mcpServers: {},
        strictMcpConfig: true,
        settings: { disableAllHooks: true },
        env: this.env(),
        stderr: () => {}
      }
    });
    try {
      const init = await Promise.race([q.initializationResult(), Bun.sleep(30000).then(() => {
        return;
      })]);
      const list = init?.models ?? [];
      if (list.length) {
        this.modelList = {
          at: Date.now(),
          models: list.map((info, index) => model(this.providerID, info.value, modelName(info), {
            family: family(modelName(info)),
            variants: info.supportedEffortLevels,
            images: true,
            context: /1M/i.test(info.description ?? "") ? 1e6 : 200000,
            released: Date.now() - index
          }))
        };
        emit("model.updated", {});
      }
    } finally {
      abort.abort();
    }
  }
  forgetModels() {
    this.modelList = undefined;
  }
  thread(session, state) {
    return new ClaudeThread(this, session, state);
  }
}
function modelName(info) {
  const what = info.description?.split(" \xB7 ")[0]?.trim();
  if (what && /^(opus|sonnet|haiku|fable|claude)/i.test(what))
    return what;
  return info.displayName;
}
function family(name) {
  return "claude-" + (name.split(/\s+/)[0] ?? "").toLowerCase();
}
function updateChannel() {
  try {
    const folder = process.env.CLAUDE_CONFIG_DIR ?? join9(homedir(), ".claude");
    const settings = JSON.parse(readFileSync7(join9(folder, "settings.json"), "utf8"));
    return settings?.autoUpdatesChannel === "stable" ? "stable" : "latest";
  } catch {
    return "latest";
  }
}
function fallbackModels(providerID2) {
  return [
    model(providerID2, "default", "Claude Code's default", { family: "claude-default", images: true, variants: ["low", "medium", "high", "xhigh", "max"], released: 3 }),
    model(providerID2, "sonnet", "Sonnet", { family: "claude-sonnet", images: true, variants: ["low", "medium", "high", "max"], released: 2 }),
    model(providerID2, "haiku", "Haiku", { family: "claude-haiku", images: true, released: 1 })
  ];
}

class ClaudeThread {
  agent;
  session;
  state;
  subagentSessions = new Map;
  query;
  input;
  active;
  opened;
  constructor(agent, session, state) {
    this.agent = agent;
    this.session = session;
    this.state = state;
  }
  async run(input, turn, hooks) {
    const sdk = await this.agent.sdk();
    if (hooks.signal.aborted)
      return { outcome: "interrupted" };
    const modelID = input.model.id;
    const effort = input.model.variant;
    const append = hooks.instructions();
    const tools = kuvoTools(this.session.id);
    if (this.query && (this.opened?.append !== append || this.opened?.program !== this.agent.program || this.opened?.tools !== tools?.url))
      this.close();
    if (!this.query) {
      this.open(sdk, modelID, effort, input.plan, append, hooks);
      if (tools)
        await this.query?.setMcpServers({ [tools.name]: { type: "http", url: tools.url, headers: tools.headers, timeout: tools.timeout } }).catch(() => {});
    } else {
      if (this.opened?.model !== modelID)
        await this.query.setModel(modelID === "default" ? undefined : modelID).catch(() => {});
      if (this.opened?.effort !== effort)
        await this.query.applyFlagSettings({ effortLevel: effort ?? null }).catch(() => {});
      if (this.opened?.plan !== input.plan)
        await this.query.setPermissionMode(input.plan ? "plan" : "default").catch(() => {});
      this.opened = { model: modelID, effort, plan: input.plan, append, program: this.agent.program, tools: tools?.url };
    }
    if (hooks.signal.aborted)
      return { outcome: "interrupted" };
    return new Promise((resolve2) => {
      this.active = { turn, hooks, resolve: resolve2, streamed: new Set, blockTools: new Map, calls: new Map, subagents: new Map, auto: input.auto };
      this.input.push(userMessage(input));
    });
  }
  open(sdk, modelID, effort, plan, append, hooks) {
    let id = this.state.claudeSession;
    const resume = Boolean(id && this.state.claudeStarted);
    if (!id) {
      id = randomUUID();
      this.state.claudeSession = id;
      hooks.saveState();
    }
    if (!resume)
      delete this.state.claudeCost;
    this.input = new Queue;
    const tools = kuvoTools(this.session.id);
    this.opened = { model: modelID, effort, plan, append, program: this.agent.program, tools: tools?.url };
    this.query = sdk.query({
      prompt: this.input,
      options: {
        pathToClaudeCodeExecutable: this.agent.executable(),
        cwd: this.session.location.directory,
        model: modelID === "default" ? undefined : modelID,
        effort,
        includePartialMessages: true,
        forwardSubagentText: true,
        permissionMode: plan ? "plan" : "default",
        canUseTool: (name, input, options) => this.canUseTool(name, input, options),
        systemPrompt: { type: "preset", preset: "claude_code", ...append ? { append } : {} },
        ...resume ? { resume: id } : { sessionId: id },
        env: this.agent.env(),
        stderr: () => {}
      }
    });
    this.read(this.query);
  }
  async read(query) {
    let ended;
    try {
      for await (const message of query)
        this.handle(message);
    } catch (error) {
      ended = error;
    }
    if (this.query === query) {
      this.query = undefined;
      this.input = undefined;
    }
    const active = this.active;
    if (!active || this.query)
      return;
    this.active = undefined;
    if (active.stopping || active.hooks.signal.aborted)
      active.resolve({ outcome: "interrupted" });
    else if (active.limit)
      active.resolve({ outcome: "failed", error: { type: "limit", message: active.problem ?? "You've reached a Claude usage limit." }, limit: active.limit });
    else
      active.resolve({ outcome: "failed", error: failure(active.problem ?? ended ?? "Claude Code stopped.") });
  }
  handle(message) {
    if (message.type === "system" && message.subtype === "init") {
      if (!this.state.claudeStarted || this.state.claudeSession !== message.session_id) {
        this.state.claudeSession = message.session_id;
        this.state.claudeStarted = true;
        this.active?.hooks.saveState();
      }
      return;
    }
    const active = this.active;
    if (!active)
      return;
    const lane = message.parent_tool_use_id ? this.subagentLane(active, message.parent_tool_use_id) : active;
    if (!lane)
      return;
    const turn = lane.turn;
    switch (message.type) {
      case "stream_event":
        return this.stream(lane, message.event);
      case "assistant": {
        const content = message.message?.content ?? [];
        const id = message.message?.id;
        if (message.error === "authentication_failed" || message.message?.error === "authentication_failed") {
          this.agent.authFailedAt = Date.now();
          active.problem = "Claude Code isn't signed in. Sign in again in Settings \u203A Accounts.";
        }
        for (const block of content) {
          if (block.type === "tool_use") {
            lane.calls.set(block.id, { name: block.name, input: block.input ?? {} });
            const tool = kuvoTool2(block.name, block.input ?? {});
            if (!turn.hasTool(block.id))
              turn.toolStart(block.id, tool.name);
            turn.toolCalled(block.id, tool.input);
            if (lane === active && tool.name === "subagent")
              this.subagentLane(active, block.id);
          } else if (!id || !lane.streamed.has(id)) {
            if (block.type === "text" && block.text)
              turn.text(block.text);
            else if (block.type === "thinking" && block.thinking)
              turn.reasoning(block.thinking);
          }
        }
        if (id && !lane.streamed.has(id))
          turn.endBlock();
        return;
      }
      case "user": {
        const content = Array.isArray(message.message?.content) ? message.message.content : [];
        const results = content.filter((block) => block.type === "tool_result");
        for (const block of results)
          this.result(active, lane, block, results.length === 1 ? message.tool_use_result : undefined);
        return;
      }
      case "rate_limit_event": {
        if (lane !== active)
          return;
        const info = message.rate_limit_info ?? {};
        if (info.status !== "rejected" || info.overageInUse || info.isUsingOverage)
          return;
        const resetsAt = typeof info.resetsAt === "number" ? info.resetsAt * 1000 : undefined;
        const oneModel = info.rateLimitType === "seven_day_opus" || info.rateLimitType === "seven_day_sonnet";
        active.limit = { scope: oneModel ? "model" : "provider", resetsAt, message: limitWords2(info.rateLimitType) };
        active.problem = limitWords2(info.rateLimitType);
        if (active.auto)
          this.query?.interrupt().catch(() => {});
        return;
      }
      case "system":
        if (lane === active && message.subtype === "api_retry" && (message.error === "rate_limit" || message.error === "billing_error") && active.auto) {
          active.limit ??= message.error === "billing_error" ? { scope: "provider" } : { scope: "model", brief: true };
          active.problem ??= "Claude's API is rate limiting this model.";
          this.query?.interrupt().catch(() => {});
        }
        return;
      case "result":
        if (lane !== active)
          return;
        return this.finish(active, message);
    }
  }
  subagentLane(active, callID) {
    const known = active.subagents.get(callID);
    if (known)
      return known;
    const call = active.calls.get(callID);
    const before = this.subagentSessions.get(callID);
    let run2;
    let background = false;
    if (call) {
      const input = call.input;
      if (kuvoTool2(call.name, input).name !== "subagent")
        return;
      run2 = active.hooks.subagent(callID, { title: String(input.description ?? ""), prompt: typeof input.prompt === "string" ? input.prompt : undefined, agent: input.subagent_type });
      background = input.run_in_background === true;
      this.subagentSessions.set(callID, { sessionID: run2.sessionID, title: String(input.description ?? "") });
    } else if (before) {
      run2 = active.hooks.subagent(callID, { title: before.title, sessionID: before.sessionID });
      background = true;
    } else {
      return;
    }
    const lane = { turn: run2.turn, streamed: new Set, blockTools: new Map, calls: new Map, run: run2, background };
    active.subagents.set(callID, lane);
    return lane;
  }
  stream(lane, event) {
    const turn = lane.turn;
    switch (event?.type) {
      case "message_start": {
        lane.streamed.add(event.message?.id);
        lane.blockTools.clear();
        const usage = event.message?.usage ?? {};
        lane.usage = {
          input: usage.input_tokens ?? 0,
          output: usage.output_tokens ?? 0,
          reasoning: 0,
          cache: { read: usage.cache_read_input_tokens ?? 0, write: usage.cache_creation_input_tokens ?? 0 }
        };
        lane.stopReason = undefined;
        turn.startStep();
        return;
      }
      case "content_block_start": {
        const block = event.content_block;
        if (block?.type === "tool_use") {
          lane.blockTools.set(event.index, block.id);
          turn.toolStart(block.id, kuvoTool2(block.name, {}).name);
        }
        return;
      }
      case "content_block_delta": {
        const delta = event.delta;
        if (delta?.type === "text_delta")
          turn.text(delta.text);
        else if (delta?.type === "thinking_delta")
          turn.reasoning(delta.thinking);
        else if (delta?.type === "input_json_delta") {
          const id = lane.blockTools.get(event.index);
          if (id)
            turn.toolInputDelta(id, delta.partial_json ?? "");
        }
        return;
      }
      case "content_block_stop":
        turn.endBlock();
        return;
      case "message_delta":
        if (lane.usage && event.usage?.output_tokens !== undefined)
          lane.usage.output = event.usage.output_tokens;
        lane.stopReason = event.delta?.stop_reason ?? lane.stopReason;
        return;
      case "message_stop":
        turn.endStep({ tokens: lane.usage, finish: lane.stopReason === "tool_use" ? "tool-calls" : lane.stopReason ?? "stop" });
        return;
    }
  }
  result(active, lane, block, structured) {
    const turn = lane.turn;
    const id = block.tool_use_id;
    const call = lane.calls.get(id);
    let text = toolText(block.content);
    if (text.length > outputLimit3)
      text = text.slice(0, outputLimit3) + `
\u2026`;
    const subagent = lane === active ? active.subagents.get(id) : undefined;
    if (subagent && !subagent.background) {
      subagent.run.end(block.is_error ? "failed" : "succeeded", block.is_error ? { type: "agent", message: text || "The subagent failed." } : undefined);
      active.subagents.delete(id);
    }
    if (block.is_error) {
      turn.toolFailed(id, text || "The tool failed.");
      return;
    }
    const metadata = {};
    const files = call ? diffs(call.name, call.input, structured) : [];
    if (files.length)
      metadata.files = files;
    if (call?.name === "Bash" && structured) {
      const output = [structured.stdout, structured.stderr].filter((part) => part).join(`
`);
      if (output)
        text = output.length > outputLimit3 ? output.slice(0, outputLimit3) + `
\u2026` : output;
    }
    turn.toolSucceeded(id, text, Object.keys(metadata).length ? metadata : undefined);
  }
  finish(active, result) {
    this.active = undefined;
    this.addCost(active, result);
    const succeeded = result.subtype === "success" && !result.is_error;
    if (succeeded && !active.stopping && !active.hooks.signal.aborted) {
      active.resolve({ outcome: "succeeded" });
      return;
    }
    const text = !succeeded && typeof result.result === "string" ? result.result : "";
    const reached = /usage limit reached\|?(\d+)?/i.exec(text);
    if (!succeeded && !active.limit && (reached || result.api_error_status === 429)) {
      const resetsAt = reached?.[1] ? Number(reached[1]) * 1000 : undefined;
      active.limit = { scope: "provider", resetsAt };
      active.problem ??= "You've reached your Claude usage limit for now.";
    }
    if (active.limit && !active.stopping) {
      active.resolve({ outcome: "failed", error: { type: "limit", message: active.problem ?? "You've reached a Claude usage limit." }, limit: active.limit, taken: true });
      return;
    }
    if (active.stopping || active.hooks.signal.aborted) {
      active.resolve({ outcome: "interrupted" });
      return;
    }
    const message = active.problem ?? (typeof result.result === "string" && result.result.trim() ? result.result.trim() : undefined) ?? (Array.isArray(result.errors) && result.errors.length ? result.errors.join(`
`) : undefined) ?? reason(result);
    active.resolve({ outcome: "failed", error: { type: "agent", message }, taken: true });
  }
  addCost(active, result) {
    const total = typeof result.total_cost_usd === "number" ? result.total_cost_usd : undefined;
    if (total === undefined)
      return;
    const before = typeof this.state.claudeCost === "number" ? this.state.claudeCost : 0;
    const spent = total >= before ? total - before : total;
    this.state.claudeCost = total;
    active.hooks.saveState();
    if (spent > 0 && this.agent.usesKey())
      active.turn.addUsage(undefined, spent);
  }
  async canUseTool(name, input, options) {
    const active = this.active;
    const toolUseID = options?.toolUseID;
    if (!active)
      return { behavior: "deny", message: "There's no turn under way for this.", toolUseID };
    const hooks = active.hooks;
    if (name === "AskUserQuestion") {
      const questions = input.questions ?? [];
      const fields = questions.map((question, index) => ({
        key: `q${index}`,
        title: question.header ?? `Question ${index + 1}`,
        description: question.question,
        required: true,
        type: question.multiSelect ? "multiselect" : "string",
        options: (question.options ?? []).map((option) => ({ value: option.label, label: option.label, description: option.description })),
        custom: true
      }));
      const answer = await hooks.question({ title: questions.length === 1 ? questions[0].header ?? "Question" : "Questions", fields, toolCallID: toolUseID });
      if (!answer)
        return { behavior: "deny", message: "The user dismissed the question.", toolUseID };
      const answers = {};
      questions.forEach((question, index) => {
        const value = answer[`q${index}`];
        answers[question.question] = Array.isArray(value) ? value.join(", ") : String(value ?? "");
      });
      return { behavior: "allow", updatedInput: { ...input, answers }, toolUseID };
    }
    if (name === "ExitPlanMode") {
      return {
        behavior: "deny",
        message: "The plan is shown to the user. Stop here and wait: they'll switch out of plan mode and ask you to build it when they're ready.",
        toolUseID
      };
    }
    const ask = permissionAsk(name, input);
    const decision = await hooks.permission({ toolCallID: toolUseID, ...ask, message: options?.title ?? options?.description });
    if (decision === "reject")
      return { behavior: "deny", message: "The user declined this.", toolUseID };
    const result = { behavior: "allow", updatedInput: input, toolUseID };
    if (decision === "always" && Array.isArray(options?.suggestions)) {
      result.updatedPermissions = options.suggestions.map((suggestion) => ({ ...suggestion, destination: "session" }));
    }
    return result;
  }
  async interrupt() {
    const query = this.query;
    const active = this.active;
    if (!query || !active)
      return;
    active.stopping = true;
    await query.interrupt().catch(() => {});
    for (let waited = 0;waited < 5000 && this.active === active; waited += 100)
      await Bun.sleep(100);
    if (this.active === active && this.query === query) {
      this.close();
      this.active = undefined;
      active.resolve({ outcome: "interrupted" });
    }
  }
  close() {
    this.input?.close();
    try {
      this.query?.close?.();
    } catch {}
    this.query = undefined;
    this.input = undefined;
  }
}
function kuvoTool2(name, input) {
  switch (name) {
    case "Bash":
      return { name: "shell", input: { command: input.command, description: input.description } };
    case "Read":
      return { name: "read", input: { path: input.file_path, offset: input.offset, limit: input.limit } };
    case "Write":
      return { name: "write", input: { path: input.file_path, content: input.content } };
    case "Edit":
      return { name: "edit", input: { path: input.file_path, oldString: input.old_string, newString: input.new_string, replaceAll: input.replace_all } };
    case "MultiEdit":
      return { name: "edit", input: { path: input.file_path, edits: input.edits } };
    case "NotebookEdit":
      return { name: "edit", input: { path: input.notebook_path, newString: input.new_source } };
    case "Glob":
      return { name: "glob", input: { pattern: input.pattern, path: input.path } };
    case "Grep":
      return { name: "grep", input: { pattern: input.pattern, path: input.path, glob: input.glob } };
    case "WebFetch":
      return { name: "webfetch", input: { url: input.url, prompt: input.prompt } };
    case "WebSearch":
      return { name: "websearch", input: { query: input.query } };
    case "Task":
    case "Agent":
      return { name: "subagent", input: { description: input.description, agent: input.subagent_type, prompt: input.prompt } };
    case "TodoWrite":
      return { name: "todowrite", input: { todos: input.todos } };
    case "AskUserQuestion":
      return { name: "question", input: { questions: input.questions } };
    case "Skill":
      return { name: "skill", input: { name: input.skill ?? input.command } };
    case "ExitPlanMode":
      return { name: "plan", input: { plan: input.plan } };
  }
  if (name.startsWith("mcp__")) {
    const [, server2, ...rest] = name.split("__");
    return { name: `${server2}_${rest.join("__")}`, input };
  }
  return { name: name.toLowerCase(), input };
}
function permissionAsk(name, input) {
  switch (name) {
    case "Bash":
      return { action: "shell", resources: [String(input.command ?? "")] };
    case "Edit":
    case "MultiEdit":
    case "Write":
    case "NotebookEdit": {
      const path = String(input.file_path ?? input.notebook_path ?? "");
      const preview = previewDiff(name, input);
      return { action: "edit", resources: [path], metadata: preview ? { files: [preview] } : undefined };
    }
    case "WebFetch":
      return { action: "webfetch", resources: [String(input.url ?? "")] };
    case "WebSearch":
      return { action: "websearch", resources: [String(input.query ?? "")] };
    case "Read":
    case "Glob":
    case "Grep":
    case "LS":
      return { action: "read", resources: [String(input.file_path ?? input.path ?? "*")] };
  }
  return { action: kuvoTool2(name, input).name, resources: ["*"] };
}
function previewDiff(name, input) {
  const path = String(input.file_path ?? "");
  if (!path)
    return;
  const before = existsSync7(path) ? safeRead(path) : undefined;
  if (name === "Write")
    return fileDiff(path, before, String(input.content ?? ""));
  if (before === undefined)
    return;
  let after = before;
  const edits2 = name === "MultiEdit" ? input.edits ?? [] : [input];
  for (const edit of edits2) {
    if (typeof edit.old_string !== "string")
      return;
    after = edit.replace_all ? after.split(edit.old_string).join(edit.new_string ?? "") : after.replace(edit.old_string, () => edit.new_string ?? "");
  }
  return fileDiff(path, before, after);
}
function diffs(name, input, structured) {
  if (!["Edit", "MultiEdit", "Write", "NotebookEdit"].includes(name))
    return [];
  const path = String(structured?.filePath ?? input.file_path ?? input.notebook_path ?? "");
  if (!path)
    return [];
  if (name === "Write" && structured?.type === "create")
    return [fileDiff(path, undefined, String(structured.content ?? input.content ?? ""))];
  const hunks = structured?.structuredPatch;
  if (Array.isArray(hunks) && hunks.length) {
    const patch = hunks.map((hunk) => `@@ -${hunk.oldStart},${hunk.oldLines} +${hunk.newStart},${hunk.newLines} @@
` + hunk.lines.join(`
`) + `
`).join("");
    return [fromPatch(path, patch)];
  }
  if (typeof structured?.originalFile === "string" && existsSync7(path))
    return [fileDiff(path, structured.originalFile, safeRead(path) ?? "")];
  return [];
}
function safeRead(path) {
  try {
    return readFileSync7(path, "utf8");
  } catch {
    return;
  }
}
function toolText(content) {
  if (typeof content === "string")
    return content;
  if (Array.isArray(content)) {
    return content.map((part) => part?.type === "text" ? part.text : part?.type === "image" ? "[image]" : "").filter(Boolean).join(`
`);
  }
  return "";
}
function limitWords2(type) {
  switch (type) {
    case "five_hour":
      return "You've reached your Claude usage limit for the next few hours.";
    case "seven_day_opus":
      return "You've reached this week's Opus limit on your Claude plan.";
    case "seven_day_sonnet":
      return "You've reached this week's Sonnet limit on your Claude plan.";
    default:
      return "You've reached your Claude usage limit for now.";
  }
}
function reason(result) {
  switch (result.subtype) {
    case "error_max_turns":
      return "Claude Code stopped after too many steps.";
    case "error_max_budget_usd":
      return "Claude Code reached its spending limit.";
    default:
      return "Claude Code stopped with an error.";
  }
}
function userMessage(input) {
  const content = [];
  const others = [];
  for (const file of input.files) {
    const isImage = /^image\/(png|jpeg|gif|webp)$/.test(file.mime);
    const data = file.data ?? (isImage && file.path ? safeBase642(file.path) : undefined);
    if (isImage && data)
      content.push({ type: "image", source: { type: "base64", media_type: file.mime, data } });
    else if (file.path)
      others.push(file.path);
  }
  let text = input.text;
  if (others.length)
    text += `

Attached files:
${others.map((path) => `- ${path}`).join(`
`)}`;
  content.push({ type: "text", text });
  return { type: "user", message: { role: "user", content }, parent_tool_use_id: null, uuid: randomUUID() };
}
function safeBase642(path) {
  try {
    return readFileSync7(path).toString("base64");
  } catch {
    return;
  }
}

// Agents/src/agents/codex.ts
import { existsSync as existsSync8, lstatSync, mkdirSync as mkdirSync8, readdirSync as readdirSync2, readlinkSync, rmSync as rmSync5, symlinkSync } from "fs";
import { homedir as homedir2 } from "os";
import { join as join10 } from "path";
var places2 = ["/opt/homebrew/bin", "/usr/local/bin", join10(homedir2(), ".local/bin"), join10(homedir2(), ".codex/bin")];
var outputLimit4 = 30000;

class CodexAgent {
  context;
  instance;
  id = "codex";
  providerID;
  get name() {
    return accountName("Codex", this.instance);
  }
  install = "npm install -g @openai/codex";
  server;
  starting;
  threads = new Map;
  logins = new Map;
  accountCache;
  modelList;
  rateLimits = new Map;
  constructor(context, instance = { id: "default" }) {
    this.context = context;
    this.instance = instance;
    this.providerID = providerID("codex", instance.id);
  }
  executable() {
    return which("codex", places2);
  }
  get definition() {
    const executable = this.executable();
    if (!executable)
      return;
    return { name: "Codex", executable, npmPackage: "@openai/codex", nativeUpdate: { args: ["update"], isNative: (path) => path.includes("/.codex/") } };
  }
  async maintenance(fresh = false) {
    const definition = this.definition;
    return definition ? maintenance(definition, fresh) : {};
  }
  async update() {
    const definition = this.definition;
    if (!definition)
      return { updated: false, message: "Codex isn't installed." };
    return update(definition, this.context.temporary);
  }
  outdated;
  programUpdated() {
    this.modelList = undefined;
    this.accountCache = undefined;
    this.outdated = this.server;
    this.starting?.then((rpc) => {
      this.outdated ??= rpc;
      this.restartIfQuiet();
    }, () => {});
    this.restartIfQuiet();
  }
  restartIfQuiet(starting) {
    const server2 = this.outdated;
    if (!server2)
      return;
    if (server2.isClosed || this.server !== server2) {
      this.outdated = undefined;
      return;
    }
    if (this.logins.size || [...this.threads.values()].some((thread) => thread !== starting && thread.isRunning))
      return;
    this.outdated = undefined;
    this.shutdown();
    this.modelList = undefined;
    emit("model.updated", {});
  }
  methods() {
    return [
      { type: "oauth", id: "chatgpt", label: "Sign in with ChatGPT" },
      { type: "key", label: "Use an OpenAI API key" }
    ];
  }
  lastUse = 0;
  idleCheck;
  async rpc(starting) {
    this.lastUse = Date.now();
    this.idleCheck ??= setInterval(() => {
      this.restartIfQuiet();
      if (!this.server || this.threads.size || this.logins.size || Date.now() - this.lastUse < 15 * 60000)
        return;
      this.shutdown();
    }, 60000);
    this.restartIfQuiet(starting);
    if (this.server && !this.server.isClosed)
      return this.server;
    this.starting ??= this.start().finally(() => this.starting = undefined);
    return this.starting;
  }
  async start() {
    const executable = this.executable();
    if (!executable)
      throw new Error("Install Codex first: npm install -g @openai/codex");
    if (this.instance.home)
      shadowHome(this.instance.home);
    const rpc = new RPC([executable, "app-server"], { cwd: this.context.temporary, env: this.instance.home ? { CODEX_HOME: this.instance.home } : undefined });
    rpc.onNotification = (method, params) => this.notification(method, params);
    rpc.onRequest = (method, params) => this.request(method, params);
    rpc.onExit = () => {
      if (this.server !== rpc)
        return;
      this.server = undefined;
      for (const thread of this.threads.values())
        thread.serverStopped();
    };
    await rpc.request("initialize", { clientInfo: { name: "kuvo-code", title: "Kuvo Code", version: "1" }, capabilities: { experimentalApi: true, optOutNotificationMethods: ["turn/diff/updated"] } }, 30000);
    rpc.notify("initialized");
    this.server = rpc;
    return rpc;
  }
  notification(method, params) {
    if (method === "account/login/completed") {
      const done = this.logins.get(params?.loginId);
      if (done) {
        this.logins.delete(params.loginId);
        done(params.success ? { status: "complete" } : { status: "failed", message: params.error ?? "Signing in didn't work." });
      }
      this.accountCache = undefined;
      return;
    }
    if (method === "account/updated") {
      this.accountCache = undefined;
      return;
    }
    if (method === "account/rateLimits/updated") {
      const snapshot = params?.rateLimits;
      if (snapshot)
        this.rateLimits.set(snapshot.limitId ?? "codex", snapshot);
      return;
    }
    if (method === "thread/started") {
      const thread = params?.thread;
      const parent = thread?.source?.subAgent?.thread_spawn?.parent_thread_id;
      const owner = parent ? this.threadFor(parent) : undefined;
      if (owner && thread?.id) {
        this.spawned.set(thread.id, owner);
        owner.spawnStarted(thread.id);
      }
      return;
    }
    const threadID = params?.threadId;
    if (threadID)
      this.threadFor(threadID)?.notification(method, params);
  }
  async request(method, params) {
    const thread = params?.threadId ? this.threadFor(params.threadId) : params?.conversationId ? this.threadFor(params.conversationId) : undefined;
    if (method === "mcpServer/elicitation/request")
      return { action: "decline" };
    if (!thread)
      throw new RPCError(-32601, `No session for ${method}.`);
    return thread.request(method, params);
  }
  threadFor(nativeID) {
    for (const thread of this.threads.values())
      if (thread.nativeID === nativeID)
        return thread;
    return this.spawned.get(nativeID);
  }
  contexts = new Map;
  noteContext(model2, window) {
    if (this.contexts.get(model2) === window)
      return;
    this.contexts.set(model2, window);
    this.modelList = undefined;
    emit("model.updated", {});
  }
  spawned = new Map;
  adopt(threadID, thread) {
    this.spawned.set(threadID, thread);
  }
  async account(fresh = false) {
    if (!this.executable())
      return { installed: false, signedIn: false, message: "Install Codex, then sign in here." };
    if (!fresh && this.accountCache && Date.now() - this.accountCache.at < 30000)
      return this.accountCache.account;
    const rpc = await this.rpc();
    const result = await rpc.request("account/read", {}, 20000);
    const info = result?.account;
    let account;
    if (!info) {
      account = { installed: true, signedIn: false, message: "Sign in to Codex with ChatGPT or an OpenAI API key." };
    } else if (info.type === "chatgpt") {
      const plan = info.planType ? `ChatGPT ${String(info.planType).charAt(0).toUpperCase()}${String(info.planType).slice(1)}` : "ChatGPT";
      account = { installed: true, signedIn: true, label: [info.email, plan].filter(Boolean).join(" \xB7 ") };
    } else {
      account = { installed: true, signedIn: true, label: info.type === "apiKey" ? "OpenAI API key" : String(info.type) };
    }
    this.accountCache = { at: Date.now(), account };
    return account;
  }
  async signIn() {
    const rpc = await this.rpc();
    const result = await rpc.request("account/login/start", { type: "chatgpt" }, 30000);
    let status = { status: "pending" };
    this.logins.set(result.loginId, (done) => status = done);
    return {
      url: result.authUrl,
      instructions: "Finish signing in with ChatGPT in your browser. Codex keeps the sign-in, as when you run codex login.",
      mode: "auto",
      status: () => status,
      cancel: () => {
        this.logins.delete(result.loginId);
        rpc.request("account/login/cancel", { loginId: result.loginId }).catch(() => {});
      }
    };
  }
  async signInWithKey(key) {
    const rpc = await this.rpc();
    await rpc.request("account/login/start", { type: "apiKey", apiKey: key }, 30000);
    this.accountCache = undefined;
  }
  async models() {
    if (this.modelList && Date.now() - this.modelList.at < 30 * 60000)
      return this.modelList.models;
    const rpc = await this.rpc();
    const models = [];
    let cursor;
    let order = 1000;
    do {
      const page = await rpc.request("model/list", cursor ? { cursor } : {}, 30000);
      for (const info of page?.data ?? []) {
        if (info.hidden)
          continue;
        models.push(model(this.providerID, info.model ?? info.id, info.displayName ?? info.model, {
          variants: (info.supportedReasoningEfforts ?? []).map((effort) => effort.reasoningEffort),
          images: (info.inputModalities ?? []).includes("image"),
          context: this.contexts.get(info.model ?? info.id) ?? 400000,
          released: info.isDefault ? 2000 : order--
        }));
      }
      cursor = page?.nextCursor ?? undefined;
    } while (cursor);
    if (rpc !== this.outdated)
      this.modelList = { at: Date.now(), models };
    return models;
  }
  forgetModels() {
    this.modelList = undefined;
  }
  shutdown() {
    const server2 = this.server;
    if (!server2)
      return;
    this.server = undefined;
    server2.kill();
    for (const thread of this.threads.values())
      thread.serverStopped();
  }
  thread(session, state) {
    const thread = new CodexThread(this, session, state);
    this.threads.set(session.id, thread);
    return thread;
  }
  forget(sessionID) {
    const thread = this.threads.get(sessionID);
    this.threads.delete(sessionID);
    for (const [spawn, owner] of this.spawned)
      if (owner === thread)
        this.spawned.delete(spawn);
  }
}

class CodexThread {
  agent;
  session;
  state;
  nativeID;
  loaded = false;
  instructions;
  active;
  inTurn = false;
  startedOver = false;
  toolsURL;
  spawnedSessions = new Map;
  constructor(agent, session, state) {
    this.agent = agent;
    this.session = session;
    this.state = state;
    this.nativeID = state.codexThread;
  }
  serverStopped() {
    this.loaded = false;
    const active = this.active;
    if (!active)
      return;
    this.active = undefined;
    active.resolve(active.hooks.signal.aborted ? { outcome: "interrupted" } : { outcome: "failed", error: failure(active.problem ?? "Codex stopped.") });
  }
  policy(hooks, plan) {
    if (plan)
      return { approvalPolicy: "untrusted", sandboxPolicy: { type: "readOnly", networkAccess: true } };
    if (hooks.approvesAll())
      return { approvalPolicy: "never", sandboxPolicy: { type: "dangerFullAccess" } };
    return { approvalPolicy: "untrusted", sandboxPolicy: { type: "readOnly", networkAccess: true } };
  }
  async ensureThread(input, hooks) {
    const rpc = await this.agent.rpc(this);
    const instructions = hooks.instructions() || null;
    const tools = kuvoTools(this.session.id);
    if (this.nativeID && this.loaded && instructions === this.instructions && tools?.url === this.toolsURL)
      return rpc;
    this.toolsURL = tools?.url;
    this.instructions = instructions;
    const config = tools ? { [`mcp_servers.${tools.name}`]: { url: tools.url, http_headers: tools.headers, tool_timeout_sec: Math.ceil(tools.timeout / 1000) } } : undefined;
    const common = { cwd: this.session.location.directory, model: input.model.id, developerInstructions: instructions, ...config ? { config } : {} };
    if (this.nativeID) {
      try {
        await rpc.request("thread/resume", { threadId: this.nativeID, excludeTurns: true, ...common }, 60000);
        this.loaded = true;
        return rpc;
      } catch (error) {
        if (error instanceof RPCError && /archived|unarchive/i.test(error.message)) {
          await rpc.request("thread/unarchive", { threadId: this.nativeID }).catch(() => {});
          await rpc.request("thread/resume", { threadId: this.nativeID, excludeTurns: true, ...common }, 60000);
          this.loaded = true;
          return rpc;
        }
      }
    }
    const started = await rpc.request("thread/start", common, 60000);
    if (this.nativeID && this.nativeID !== started.thread.id)
      this.startedOver = true;
    this.nativeID = started.thread.id;
    this.state.codexThread = this.nativeID;
    hooks.saveState();
    this.loaded = true;
    return rpc;
  }
  get isRunning() {
    return this.inTurn;
  }
  async prepare(input, hooks) {
    this.inTurn = true;
    try {
      await this.ensureThread(input, hooks);
    } finally {
      this.inTurn = false;
    }
    const fresh = this.startedOver;
    this.startedOver = false;
    return { fresh };
  }
  async run(input, turn, hooks) {
    this.inTurn = true;
    try {
      return await this.runTurn(input, turn, hooks);
    } finally {
      this.inTurn = false;
    }
  }
  async runTurn(input, turn, hooks) {
    const rpc = await this.ensureThread(input, hooks);
    if (hooks.signal.aborted)
      return { outcome: "interrupted" };
    const items = [{ type: "text", text: input.text, text_elements: [] }];
    const others = [];
    for (const file of input.files) {
      if (file.mime.startsWith("image/")) {
        if (file.path)
          items.push({ type: "localImage", path: file.path });
        else if (file.data)
          items.push({ type: "image", url: `data:${file.mime};base64,${file.data}` });
      } else if (file.path) {
        others.push(file.path);
      }
    }
    if (others.length)
      items[0].text += `

Attached files:
${others.map((path) => `- ${path}`).join(`
`)}`;
    const effort = input.model.variant;
    const params = {
      threadId: this.nativeID,
      input: items,
      cwd: this.session.location.directory,
      model: input.model.id,
      summary: "detailed",
      approvalsReviewer: "user",
      ...this.policy(hooks, input.plan),
      ...effort ? { effort } : {},
      collaborationMode: { mode: input.plan ? "plan" : "default", settings: { model: input.model.id, reasoning_effort: effort ?? null, developer_instructions: null } }
    };
    return new Promise((resolve2) => {
      const active = { turn, hooks, resolve: resolve2, streamed: new Set, changes: new Map, output: new Map, toolsSinceText: false, subagents: new Map, spawning: [], auto: input.auto, model: input.model.id };
      this.active = active;
      turn.startStep();
      rpc.request("turn/start", params, 60000).then((result) => {
        if (result?.turn?.id)
          active.turnID ??= result.turn.id;
      }, (error) => {
        if (this.active !== active)
          return;
        this.active = undefined;
        resolve2({ outcome: "failed", error: failure(error) });
      });
    });
  }
  notification(method, params) {
    const active = this.active;
    if (!active)
      return;
    if (params?.threadId && this.nativeID && params.threadId !== this.nativeID)
      return this.subagentNotification(active, params.threadId, method, params);
    const turn = active.turn;
    const turnID = params?.turnId ?? params?.turn?.id;
    if (active.turnID && turnID && turnID !== active.turnID)
      return;
    switch (method) {
      case "turn/started":
        active.turnID ??= params.turn?.id;
        return;
      case "item/agentMessage/delta":
        this.words(active);
        active.streamed.add(params.itemId);
        turn.text(params.delta ?? "");
        return;
      case "item/reasoning/summaryTextDelta":
        this.words(active);
        turn.reasoning(params.delta ?? "");
        return;
      case "item/commandExecution/outputDelta": {
        const output = ((active.output.get(params.itemId) ?? "") + (params.delta ?? "")).slice(-outputLimit4);
        active.output.set(params.itemId, output);
        turn.toolProgress(params.itemId, { output });
        return;
      }
      case "item/started":
        return this.itemStarted(active, params.item);
      case "item/completed":
        return this.itemCompleted(active, params.item);
      case "turn/plan/updated": {
        const todos = (params.plan ?? []).map((entry) => ({ content: entry.step, status: entry.status === "inProgress" ? "in_progress" : entry.status }));
        const id = active.plan?.id ?? newID("call");
        active.plan = { id, todos };
        if (!turn.hasTool(id))
          turn.toolStart(id, "todowrite", { todos });
        else
          turn.toolCalled(id, { todos });
        return;
      }
      case "thread/tokenUsage/updated": {
        const window = params.tokenUsage?.modelContextWindow;
        if (typeof window === "number" && window > 0)
          this.agent.noteContext(active.model, window);
        const last2 = params.tokenUsage?.last;
        if (last2) {
          active.usage = {
            input: Math.max(0, (last2.inputTokens ?? 0) - (last2.cachedInputTokens ?? 0)),
            output: Math.max(0, (last2.outputTokens ?? 0) - (last2.reasoningOutputTokens ?? 0)),
            reasoning: last2.reasoningOutputTokens ?? 0,
            cache: { read: last2.cachedInputTokens ?? 0, write: last2.cacheWriteInputTokens ?? 0 }
          };
        }
        return;
      }
      case "error": {
        const limit = this.limitOf(params.error, active.model);
        if (limit && params.willRetry) {
          if (active.auto) {
            active.limit = { ...limit, brief: limit.brief ?? params.error?.codexErrorInfo === "rateLimitExceeded" };
            active.problem = params.error?.message || "Codex is rate limited for now.";
            active.stoppedForLimit = true;
            this.stopTurn(active);
          }
          return;
        }
        if (limit) {
          active.limit = limit;
          active.problem = params.error?.message || "You've reached your Codex usage limit for now.";
          return;
        }
        if (!params.willRetry)
          active.problem = params.error?.additionalDetails || params.error?.message;
        return;
      }
      case "turn/completed": {
        this.active = undefined;
        if (active.plan)
          turn.toolSucceeded(active.plan.id, "", { todos: active.plan.todos });
        turn.endStep({ tokens: active.usage });
        const status = params.turn?.status;
        const limit = status === "failed" ? active.limit ?? this.limitOf(params.turn?.error, active.model) : status === "interrupted" && active.stoppedForLimit ? active.limit : undefined;
        if (limit && !active.stopping && !active.hooks.signal.aborted) {
          active.resolve({ outcome: "failed", error: { type: "limit", message: active.problem ?? params.turn?.error?.message ?? "You've reached your Codex usage limit for now." }, limit, taken: true });
        } else if (active.hooks.signal.aborted || status === "interrupted")
          active.resolve({ outcome: "interrupted" });
        else if (status === "failed")
          active.resolve({ outcome: "failed", error: failure(params.turn?.error?.message ?? active.problem ?? "Codex stopped with an error."), taken: true });
        else
          active.resolve({ outcome: "succeeded" });
        return;
      }
    }
  }
  spawnStarted(threadID) {
    const active = this.active;
    const call = active?.spawning[0];
    if (active && call && !active.subagents.has(threadID))
      this.linkSubagent(active, call, threadID);
  }
  subagentNotification(active, threadID, method, params) {
    let lane = active.subagents.get(threadID);
    if (!lane) {
      const before = this.spawnedSessions.get(threadID);
      if (!before)
        return;
      const run2 = active.hooks.subagent(before.call, { title: before.title, sessionID: before.sessionID });
      lane = { turn: run2.turn, streamed: new Set, changes: new Map, output: new Map, toolsSinceText: false, run: run2, call: before.call, title: before.title, ended: false };
      active.subagents.set(threadID, lane);
    }
    if (lane.ended) {
      if (method !== "turn/started")
        return;
      lane = this.continueSubagent(active, threadID, lane);
    }
    const turn = lane.turn;
    switch (method) {
      case "item/agentMessage/delta":
        this.words(lane);
        lane.streamed.add(params.itemId);
        turn.text(params.delta ?? "");
        return;
      case "item/reasoning/summaryTextDelta":
        this.words(lane);
        turn.reasoning(params.delta ?? "");
        return;
      case "item/commandExecution/outputDelta": {
        const output = ((lane.output.get(params.itemId) ?? "") + (params.delta ?? "")).slice(-outputLimit4);
        lane.output.set(params.itemId, output);
        turn.toolProgress(params.itemId, { output });
        return;
      }
      case "item/started":
        return this.itemStarted(lane, params.item);
      case "item/completed":
        return this.itemCompleted(lane, params.item);
      case "thread/tokenUsage/updated": {
        const last2 = params.tokenUsage?.last;
        if (last2)
          lane.usage = { input: Math.max(0, (last2.inputTokens ?? 0) - (last2.cachedInputTokens ?? 0)), output: Math.max(0, (last2.outputTokens ?? 0) - (last2.reasoningOutputTokens ?? 0)), reasoning: last2.reasoningOutputTokens ?? 0, cache: { read: last2.cachedInputTokens ?? 0, write: last2.cacheWriteInputTokens ?? 0 } };
        return;
      }
      case "turn/completed": {
        const status = params.turn?.status;
        this.endSubagent(lane, status === "failed" ? "failed" : status === "interrupted" ? "interrupted" : "succeeded", params.turn?.error?.message);
        return;
      }
    }
  }
  linkSubagent(active, call, threadID, prompt) {
    const known = active.subagents.get(threadID);
    if (known)
      return known;
    active.spawning = active.spawning.filter((waiting) => waiting !== call);
    const input = active.turn.toolInput(call) ?? {};
    const title = String(input.description ?? "") || "A spawned agent's task";
    const run2 = active.hooks.subagent(call, { title, prompt: prompt ?? input.prompt });
    const lane = { turn: run2.turn, streamed: new Set, changes: new Map, output: new Map, toolsSinceText: false, run: run2, call, title, ended: false };
    active.subagents.set(threadID, lane);
    this.spawnedSessions.set(threadID, { call, title, sessionID: run2.sessionID });
    this.agent.adopt(threadID, this);
    return lane;
  }
  continueSubagent(active, threadID, lane) {
    const run2 = active.hooks.subagent(lane.call, { title: lane.title, sessionID: lane.run.sessionID });
    const next = { turn: run2.turn, streamed: new Set, changes: new Map, output: new Map, toolsSinceText: false, run: run2, call: lane.call, title: lane.title, ended: false };
    active.subagents.set(threadID, next);
    return next;
  }
  endSubagent(lane, outcome, message) {
    if (lane.ended)
      return;
    lane.ended = true;
    lane.turn.endStep({ tokens: lane.usage });
    lane.run.end(outcome, outcome === "failed" ? { type: "agent", message: message ?? "The agent stopped with an error." } : undefined);
  }
  words(lane) {
    if (!lane.toolsSinceText)
      return;
    lane.toolsSinceText = false;
    lane.turn.endStep({ tokens: lane.usage });
    lane.usage = undefined;
    lane.turn.startStep();
  }
  itemStarted(lane, item) {
    const active = lane;
    const turn = lane.turn;
    switch (item?.type) {
      case "collabAgentToolCall": {
        if (item.tool !== "spawnAgent" || !this.active || lane !== this.active)
          return;
        const main = this.active;
        lane.toolsSinceText = true;
        const prompt = typeof item.prompt === "string" ? item.prompt : "";
        turn.toolStart(item.id, "subagent", { description: firstLine(prompt) || "A spawned agent's task", prompt, background: true });
        main.spawning.push(item.id);
        const thread = item.receiverThreadIds?.[0];
        if (thread)
          this.linkSubagent(main, item.id, thread, prompt);
        return;
      }
      case "subAgentActivity": {
        const main = this.active;
        const spawned = main && lane === main ? main.subagents.get(item.agentThreadId) : undefined;
        if (spawned && (item.kind === "completed" || item.kind === "interrupted"))
          this.endSubagent(spawned, item.kind === "completed" ? "succeeded" : "interrupted");
        return;
      }
      case "commandExecution":
        active.toolsSinceText = true;
        turn.toolStart(item.id, "shell", { command: unwrapShell(item.command ?? ""), cwd: item.cwd });
        return;
      case "fileChange": {
        active.toolsSinceText = true;
        const changes = (item.changes ?? []).map((change) => ({ path: change.path, kind: change.kind?.type ?? "update", diff: change.diff ?? "" }));
        active.changes.set(item.id, changes);
        turn.toolStart(item.id, "patch", { files: changes.map((change) => change.path) });
        return;
      }
      case "mcpToolCall":
        active.toolsSinceText = true;
        turn.toolStart(item.id, `${item.server}_${item.tool}`, item.arguments ?? {});
        return;
      case "dynamicToolCall":
        active.toolsSinceText = true;
        turn.toolStart(item.id, item.tool, item.arguments ?? {});
        return;
      case "webSearch":
        active.toolsSinceText = true;
        turn.toolStart(item.id, "websearch", { query: item.query ?? item.action?.query ?? "" });
        return;
    }
  }
  itemCompleted(lane, item) {
    const active = lane;
    const turn = lane.turn;
    switch (item?.type) {
      case "collabAgentToolCall": {
        if (item.tool !== "spawnAgent" || !this.active || lane !== this.active)
          return;
        const main = this.active;
        const thread = item.receiverThreadIds?.[0];
        const spawned = thread ? this.linkSubagent(main, item.id, thread, typeof item.prompt === "string" ? item.prompt : undefined) : undefined;
        if (item.status === "failed" || !spawned)
          turn.toolFailed(item.id, "The agent couldn't be started.");
        else
          turn.toolSucceeded(item.id, "Started.", { sessionID: spawned.run.sessionID });
        return;
      }
      case "subAgentActivity": {
        const main = this.active;
        const spawned = main && lane === main ? main.subagents.get(item.agentThreadId) : undefined;
        if (spawned && (item.kind === "completed" || item.kind === "interrupted"))
          this.endSubagent(spawned, item.kind === "completed" ? "succeeded" : "interrupted");
        return;
      }
      case "agentMessage":
        if (!active.streamed.has(item.id) && item.text) {
          this.words(active);
          turn.text(item.text);
        }
        turn.endBlock();
        return;
      case "reasoning":
        turn.endBlock();
        return;
      case "plan":
        if (item.text) {
          this.words(active);
          turn.text(item.text);
          turn.endBlock();
        }
        return;
      case "commandExecution": {
        const output = (item.aggregatedOutput ?? active.output.get(item.id) ?? "").slice(-outputLimit4);
        if (item.status === "declined")
          turn.toolFailed(item.id, "Declined.");
        else if (item.status === "failed" && item.exitCode == null)
          turn.toolFailed(item.id, output || "The command failed.");
        else
          turn.toolSucceeded(item.id, output, { output, exit: item.exitCode ?? 0 });
        return;
      }
      case "fileChange": {
        const changes = (item.changes ?? []).map((change) => ({ path: change.path, kind: change.kind?.type ?? "update", diff: change.diff ?? "" }));
        const files = changes.map((change) => fromPatch(change.path, change.diff, change.kind === "add" ? "added" : change.kind === "delete" ? "deleted" : "modified"));
        if (item.status === "declined")
          turn.toolFailed(item.id, "Declined.", { files });
        else if (item.status === "failed")
          turn.toolFailed(item.id, "The change couldn't be made.", { files });
        else
          turn.toolSucceeded(item.id, changes.map((change) => change.path).join(`
`), { files });
        return;
      }
      case "mcpToolCall": {
        const text = (item.result?.content ?? []).map((part) => part?.text ?? "").filter(Boolean).join(`
`);
        if (item.error || item.status === "failed")
          turn.toolFailed(item.id, item.error?.message ?? text ?? "The tool failed.");
        else
          turn.toolSucceeded(item.id, text.slice(0, outputLimit4));
        return;
      }
      case "dynamicToolCall": {
        const text = (item.contentItems ?? []).map((part) => part?.text ?? "").filter(Boolean).join(`
`);
        if (item.success === false)
          turn.toolFailed(item.id, text || "The tool failed.");
        else
          turn.toolSucceeded(item.id, text.slice(0, outputLimit4));
        return;
      }
      case "webSearch":
        turn.toolSucceeded(item.id, "");
        return;
    }
  }
  async request(method, params) {
    const active = this.active;
    if (!active) {
      if (method === "item/tool/requestUserInput")
        return { answers: {} };
      return method.endsWith("Approval") || method.endsWith("/requestApproval") ? method.startsWith("item/") ? { decision: "decline" } : { decision: "denied" } : {};
    }
    const hooks = active.hooks;
    switch (method) {
      case "item/commandExecution/requestApproval": {
        const decision = await hooks.permission({ toolCallID: params.itemId, action: "shell", resources: [unwrapShell(params.command ?? "")], message: params.reason ?? undefined });
        return { decision: decision === "always" ? "acceptForSession" : decision === "once" ? "accept" : "decline" };
      }
      case "item/fileChange/requestApproval": {
        const lane = (params.threadId && params.threadId !== this.nativeID ? active.subagents.get(params.threadId) : undefined) ?? active;
        const changes = lane.changes.get(params.itemId) ?? [];
        const files = changes.map((change) => fromPatch(change.path, change.diff, change.kind === "add" ? "added" : change.kind === "delete" ? "deleted" : "modified"));
        const decision = await hooks.permission({
          toolCallID: params.itemId,
          action: "edit",
          resources: changes.length ? changes.map((change) => change.path) : [params.grantRoot ?? "*"],
          metadata: files.length ? { files } : undefined,
          message: params.reason ?? undefined
        });
        return { decision: decision === "always" ? "acceptForSession" : decision === "once" ? "accept" : "decline" };
      }
      case "item/permissions/requestApproval": {
        const paths = [...params.permissions?.fileSystem?.read ?? [], ...params.permissions?.fileSystem?.write ?? []];
        const decision = await hooks.permission({ toolCallID: params.itemId, action: "external_directory", resources: paths.length ? paths : ["*"], message: params.reason ?? undefined });
        return decision === "reject" ? { permissions: {}, scope: "turn" } : { permissions: params.permissions, scope: decision === "always" ? "session" : "turn" };
      }
      case "execCommandApproval": {
        const command = Array.isArray(params.command) ? params.command.join(" ") : String(params.command ?? "");
        const decision = await hooks.permission({ toolCallID: params.callId, action: "shell", resources: [command], message: params.reason ?? undefined });
        return { decision: decision === "always" ? "approved_for_session" : decision === "once" ? "approved" : "denied" };
      }
      case "applyPatchApproval": {
        const paths = Object.keys(params.fileChanges ?? {});
        const decision = await hooks.permission({ toolCallID: params.callId, action: "edit", resources: paths.length ? paths : ["*"], message: params.reason ?? undefined });
        return { decision: decision === "always" ? "approved_for_session" : decision === "once" ? "approved" : "denied" };
      }
      case "item/tool/requestUserInput": {
        const questions = params.questions ?? [];
        const fields = questions.map((question) => ({
          key: question.id,
          title: question.header ?? "Question",
          description: question.question,
          required: true,
          type: "string",
          options: question.options?.map((option) => ({ value: option.label, label: option.label, description: option.description })),
          custom: question.isOther ?? !question.options?.length
        }));
        const answer = await hooks.question({ title: questions.length === 1 ? questions[0].header ?? "Question" : "Questions", fields, toolCallID: params.itemId });
        const answers = {};
        for (const question of questions) {
          const value = answer?.[question.id];
          answers[question.id] = { answers: value === undefined || value === null ? [] : Array.isArray(value) ? value.map(String) : [String(value)] };
        }
        return { answers };
      }
    }
    throw new RPCError(-32601, `Method not found: ${method}`);
  }
  limitOf(error, model2) {
    const info = error?.codexErrorInfo;
    if (info !== "usageLimitExceeded" && info !== "rateLimitExceeded")
      return;
    const reached = (snapshot) => Boolean(snapshot?.rateLimitReachedType) || [snapshot?.primary, snapshot?.secondary].some((window) => (window?.usedPercent ?? 0) >= 100);
    const resets = (snapshot) => {
      const times = [snapshot?.primary, snapshot?.secondary].filter((window) => (window?.usedPercent ?? 0) >= 100 && window?.resetsAt).map((window) => window.resetsAt * 1000);
      return times.length ? Math.max(...times) : undefined;
    };
    for (const [id, snapshot] of this.agent.rateLimits) {
      if (id === "codex" || !reached(snapshot))
        continue;
      const slug = snapshot.normalModelSlug;
      if (slug && (model2 === slug || model2.startsWith(`${slug}-`)))
        return { scope: "model", resetsAt: resets(snapshot), message: error?.message };
    }
    const plan = this.agent.rateLimits.get("codex");
    if (info === "rateLimitExceeded" && !reached(plan))
      return { scope: "model", brief: true, message: error?.message };
    return { scope: "provider", resetsAt: resets(plan), message: error?.message };
  }
  async stopTurn(active) {
    const rpc = await this.agent.rpc().catch(() => {
      return;
    });
    if (rpc && active.turnID && this.nativeID)
      await rpc.request("turn/interrupt", { threadId: this.nativeID, turnId: active.turnID }, 1e4).catch(() => {});
  }
  async interrupt() {
    const active = this.active;
    if (!active || !this.nativeID)
      return;
    active.stopping = true;
    const rpc = await this.agent.rpc().catch(() => {
      return;
    });
    for (let waited = 0;waited < 1e4 && !active.turnID && this.active === active; waited += 100)
      await Bun.sleep(100);
    if (rpc && active.turnID)
      await rpc.request("turn/interrupt", { threadId: this.nativeID, turnId: active.turnID }, 1e4).catch(() => {});
    for (let waited = 0;waited < 1e4 && this.active === active; waited += 100)
      await Bun.sleep(100);
    if (this.active === active) {
      this.active = undefined;
      active.resolve({ outcome: "interrupted" });
    }
  }
  close() {
    this.agent.forget(this.session.id);
    if (this.nativeID && this.loaded)
      this.agent.rpc().then((rpc) => rpc.request("thread/unsubscribe", { threadId: this.nativeID }).catch(() => {}), () => {});
  }
}
function shadowHome(home) {
  const own = join10(homedir2(), ".codex");
  const kept = new Set(["auth.json", "models_cache.json"]);
  mkdirSync8(home, { recursive: true, mode: 448 });
  const wanted = existsSync8(own) ? readdirSync2(own).filter((name) => !kept.has(name)) : [];
  for (const name of wanted) {
    const link = join10(home, name);
    const target = join10(own, name);
    try {
      const stat = lstatSync(link, { throwIfNoEntry: false });
      if (stat?.isSymbolicLink() && readlinkSync(link) === target)
        continue;
      if (stat && !stat.isSymbolicLink())
        continue;
      if (stat)
        rmSync5(link, { force: true });
      symlinkSync(target, link);
    } catch {}
  }
  for (const name of readdirSync2(home)) {
    const link = join10(home, name);
    try {
      if (lstatSync(link).isSymbolicLink() && !wanted.includes(name))
        rmSync5(link, { force: true });
    } catch {}
  }
}
function unwrapShell(command) {
  const match = command.match(/^\/bin\/(?:zsh|bash|sh) -lc (["'])([\s\S]*)\1$/);
  if (!match)
    return command;
  const inner = match[2];
  return match[1] === '"' ? inner.replace(/\\(["\\$`])/g, "$1") : inner.replace(/'"'"'/g, "'");
}
function firstLine(text) {
  const line = text.trim().split(`
`)[0] ?? "";
  return line.length > 80 ? line.slice(0, 79) + "\u2026" : line;
}

// Agents/src/agents/cursor.ts
import { existsSync as existsSync9, mkdirSync as mkdirSync9, readFileSync as readFileSync8, rmSync as rmSync6 } from "fs";
import { join as join11 } from "path";
var SDK2 = [{ name: "@cursor/sdk", version: "1.0.35" }];
var outputLimit5 = 30000;

class CursorAgent {
  context;
  instance;
  id = "cursor";
  providerID;
  get name() {
    return accountName("Cursor", this.instance);
  }
  accountCache;
  modelList;
  primed = false;
  constructor(context, instance = { id: "default" }) {
    this.context = context;
    this.instance = instance;
    this.providerID = providerID("cursor", instance.id);
  }
  get folder() {
    return this.instance.home ?? join11(this.context.home, "cursor");
  }
  get authFile() {
    return join11(this.folder, "auth.json");
  }
  methods() {
    return [
      { type: "oauth", id: "browser", label: "Sign in with Cursor" },
      { type: "key", label: "Use a Cursor API key" }
    ];
  }
  async sdk() {
    await this.context.deps.ensure(this.id, SDK2);
    return this.context.deps.load(this.id, SDK2[0].name);
  }
  async store(sdk) {
    mkdirSync9(this.folder, { recursive: true, mode: 448 });
    return new sdk.FileCredentialStore(this.authFile);
  }
  async apiKey(sdk) {
    const fromEnvironment = this.instance.home ? undefined : process.env.CURSOR_API_KEY?.trim();
    if (fromEnvironment)
      return fromEnvironment;
    if (!existsSync9(this.authFile))
      return;
    const loaded = await (await this.store(sdk ?? await this.sdk())).load();
    if (!loaded?.apiKey)
      return;
    if (loaded.apiKeyExpiresAtMs && loaded.apiKeyExpiresAtMs < Date.now())
      return;
    return loaded.apiKey;
  }
  async account(fresh = false) {
    if ((this.instance.home || !process.env.CURSOR_API_KEY) && !existsSync9(this.authFile)) {
      return { installed: true, signedIn: false, message: "Sign in with your Cursor account. Kuvo Code downloads Cursor's agent the first time." };
    }
    if (!fresh && this.accountCache && Date.now() - this.accountCache.at < 60000)
      return this.accountCache.account;
    const sdk = await this.sdk();
    const apiKey = await this.apiKey(sdk);
    let account;
    if (!apiKey) {
      account = { installed: true, signedIn: false, message: "Your Cursor sign-in expired. Sign in again." };
    } else {
      try {
        const me = await withTimeout(sdk.Cursor.me({ apiKey }), 15000);
        account = { installed: true, signedIn: true, label: me?.userEmail ?? (process.env.CURSOR_API_KEY ? "Cursor API key" : "Cursor account") };
      } catch (error) {
        const rejected = error instanceof sdk.AuthenticationError || error?.status === 401;
        account = rejected ? { installed: true, signedIn: false, message: "Cursor turned the sign-in down. Sign in again." } : { installed: true, signedIn: true, label: "Cursor account" };
      }
    }
    this.accountCache = { at: Date.now(), account };
    return account;
  }
  async signIn() {
    if (!this.instance.home && process.env.CURSOR_API_KEY)
      throw new Error("CURSOR_API_KEY is set in your environment: Kuvo Code uses that key.");
    const sdk = await this.sdk();
    const pending = new sdk.InMemoryCredentialStore;
    const abort = new AbortController;
    let status = { status: "pending" };
    let resolveURL = () => {};
    const url = new Promise((resolve2) => resolveURL = resolve2);
    sdk.Cursor.auth.login({ openBrowser: false, store: pending, signal: abort.signal, apiKeyName: "Kuvo Code", onLoginUrl: (link2) => resolveURL(link2) }).then(async () => {
      const credentials = await pending.load();
      if (!credentials)
        throw new Error("Cursor didn't hand over the sign-in.");
      await (await this.store(sdk)).save(credentials);
      this.accountCache = undefined;
      this.modelList = undefined;
      status = { status: "complete" };
    }).catch((error) => {
      if (status.status === "pending")
        status = { status: "failed", message: abort.signal.aborted ? "Cancelled." : failure(error).message };
    });
    const link = await Promise.race([url, Bun.sleep(30000).then(() => "")]);
    return {
      url: link,
      instructions: "Finish signing in to Cursor in your browser. Cursor makes an API key for Kuvo Code, kept on this Mac.",
      mode: "auto",
      status: () => status,
      cancel: () => abort.abort()
    };
  }
  async signInWithKey(key) {
    const sdk = await this.sdk();
    await withTimeout(sdk.Cursor.me({ apiKey: key }), 15000);
    await (await this.store(sdk)).save({ version: 1, backendUrl: "https://api2.cursor.sh", apiKey: key, createdAtMs: Date.now() });
    this.accountCache = undefined;
    this.modelList = undefined;
  }
  async signOut() {
    rmSync6(this.authFile, { force: true });
    this.accountCache = undefined;
    this.modelList = undefined;
  }
  async models() {
    const sdk = await this.sdk();
    const apiKey = await this.apiKey(sdk);
    if (!apiKey)
      return [];
    if (this.modelList && this.modelList.key === apiKey && Date.now() - this.modelList.at < 30 * 60000)
      return this.modelList.models;
    const list = await withTimeout(sdk.Cursor.models.list({ apiKey }), 15000);
    const seen = new Set;
    const models = list.filter((info) => info?.id && !seen.has(info.id) && seen.add(info.id)).map((info, index) => {
      const effort = (info.parameters ?? []).find((parameter) => parameter.id === "effort" || parameter.id === "reasoning");
      return model(this.providerID, info.id, info.id === "default" ? "Auto" : info.displayName ?? info.id, {
        variants: effort?.values?.map((value) => String(value.value)) ?? [],
        images: true,
        released: info.id === "default" ? 2000 : 1000 - index
      });
    });
    this.modelList = { at: Date.now(), key: apiKey, models };
    return models;
  }
  forgetModels() {
    this.modelList = undefined;
  }
  async prime(sdk, apiKey, cwd) {
    if (this.primed)
      return;
    this.primed = true;
    try {
      const platform = await sdk.createAgentPlatform({ workspaceRef: cwd });
      const release = await platform.prewarmLocalWorkspace({ apiKey, local: { cwd, settingSources: [], sandboxOptions: { enabled: true } } });
      await release?.();
    } catch {}
  }
  agentStore(sdk) {
    const root = join11(this.folder, "agents");
    mkdirSync9(root, { recursive: true });
    return new sdk.JsonlLocalAgentStore(root);
  }
  thread(session, state) {
    return new CursorThread(this, session, state);
  }
}

class CursorThread {
  owner;
  session;
  state;
  agent;
  startedApproving;
  active;
  constructor(owner, session, state) {
    this.owner = owner;
    this.session = session;
    this.state = state;
  }
  startedOver = false;
  async prepare(input, hooks) {
    const sdk = await this.owner.sdk();
    const apiKey = await this.owner.apiKey(sdk);
    if (!apiKey || hooks.signal.aborted)
      return;
    if (hooks.approvesAll())
      await this.owner.prime(sdk, apiKey, this.session.location.directory);
    await this.ensureAgent(sdk, this.options(sdk, input, hooks, apiKey), hooks);
    const fresh = this.startedOver;
    this.startedOver = false;
    return { fresh };
  }
  options(sdk, input, hooks, apiKey) {
    const approvesAll = hooks.approvesAll();
    const selection = { id: input.model.id, ...input.model.variant ? { params: [{ id: "effort", value: input.model.variant }] } : {} };
    const mode = input.plan ? "plan" : "agent";
    const cwd = this.session.location.directory;
    return {
      model: selection,
      name: `Kuvo Code: ${this.session.title ?? "session"}`,
      mode,
      apiKey,
      local: {
        cwd,
        autoReview: !approvesAll,
        settingSources: ["project", "user", "team", "mdm", "plugins"],
        sandboxOptions: { enabled: !approvesAll },
        enableAgentRetries: true,
        store: this.owner.agentStore(sdk)
      }
    };
  }
  async ensureAgent(sdk, options, hooks) {
    const approvesAll = hooks.approvesAll();
    if (this.agent && this.startedApproving !== approvesAll) {
      try {
        this.agent.close?.();
      } catch {}
      this.agent = undefined;
    }
    if (this.agent)
      return;
    this.startedApproving = approvesAll;
    const id = this.state.cursorAgent;
    this.agent = id ? await sdk.Agent.resume(id, options).catch(() => {
      return;
    }) : undefined;
    if (!this.agent && id) {
      this.startedOver = true;
      delete this.state.cursorInstructions;
      delete this.state.cursorInstructed;
    }
    this.agent ??= await sdk.Agent.create(options);
    if (this.state.cursorAgent !== this.agent.agentId) {
      this.state.cursorAgent = this.agent.agentId;
      hooks.saveState();
    }
  }
  async run(input, turn, hooks) {
    const sdk = await this.owner.sdk();
    const apiKey = await this.owner.apiKey(sdk);
    if (!apiKey)
      return { outcome: "failed", error: { type: "auth", message: "Sign in to Cursor in Settings \u203A Accounts." } };
    if (hooks.signal.aborted)
      return { outcome: "interrupted" };
    const cwd = this.session.location.directory;
    const approvesAll = hooks.approvesAll();
    const selection = { id: input.model.id, ...input.model.variant ? { params: [{ id: "effort", value: input.model.variant }] } : {} };
    const mode = input.plan ? "plan" : "agent";
    const options = this.options(sdk, input, hooks, apiKey);
    if (approvesAll)
      await this.owner.prime(sdk, apiKey, cwd);
    if (!approvesAll && !input.plan && !this.state.cursorAskNoted) {
      turn.notice("Cursor can't stop to ask you before it acts here: it runs what its sandbox allows and declines the rest. Use Plan mode to have it propose changes first.");
      this.state.cursorAskNoted = true;
      hooks.saveState();
    }
    await this.ensureAgent(sdk, options, hooks);
    const images = input.files.filter((file) => file.mime.startsWith("image/")).map((file) => ({ data: file.data ?? (file.path ? readFileSync8(file.path).toString("base64") : ""), mimeType: file.mime })).filter((image) => image.data);
    let text = input.text;
    const others = input.files.filter((file) => !file.mime.startsWith("image/") && file.path).map((file) => file.path);
    if (others.length)
      text += `

Attached files:
${others.map((path) => `- ${path}`).join(`
`)}`;
    const instructions = hooks.instructions();
    const sent = typeof this.state.cursorInstructions === "string" ? this.state.cursorInstructions : this.state.cursorInstructed ? undefined : "";
    let instructed;
    if (instructions !== sent && (instructions || sent)) {
      if (instructions)
        text = `${sent ? `Your instructions from Kuvo Code changed. They're now:

` : ""}${instructions}

${text}`;
      instructed = { value: instructions };
    }
    const instructionsTaken = () => {
      if (!instructed)
        return;
      this.state.cursorInstructions = instructed.value;
      delete this.state.cursorInstructed;
      hooks.saveState();
      instructed = undefined;
    };
    if (hooks.signal.aborted)
      return { outcome: "interrupted" };
    const active = { turn, hooks, toolsSinceText: false, sawText: false, output: new Map };
    this.active = active;
    turn.startStep();
    let chain = Promise.resolve();
    const onDelta = async ({ update: update2 }) => {
      chain = chain.then(() => this.update(active, update2)).catch(() => {});
    };
    try {
      const run2 = await this.agent.send(images.length ? { text, images } : text, { model: selection, mode, onDelta });
      active.run = run2;
      if (hooks.signal.aborted)
        await run2.cancel().catch(() => {});
      const result = await run2.wait();
      await chain;
      if (result?.status !== "error" || active.sawText || active.output.size)
        instructionsTaken();
      if (!active.sawText && typeof result?.result === "string" && result.result.trim())
        turn.text(result.result);
      const usage = result?.usage;
      turn.endStep({
        tokens: usage ? { input: usage.inputTokens ?? 0, output: usage.outputTokens ?? 0, reasoning: 0, cache: { read: usage.cacheReadTokens ?? 0, write: usage.cacheWriteTokens ?? 0 } } : undefined
      });
      if (hooks.signal.aborted || result?.status === "cancelled")
        return { outcome: "interrupted" };
      if (result?.status === "error") {
        const message = String(result.error?.message ?? "Cursor stopped with an error.");
        const limit = limitOf2(message, result.error);
        return limit ? { outcome: "failed", error: { type: "limit", message }, limit } : { outcome: "failed", error: failure(message) };
      }
      return { outcome: "succeeded" };
    } catch (error) {
      if (active.sawText || active.output.size)
        instructionsTaken();
      if (hooks.signal.aborted)
        return { outcome: "interrupted" };
      const message = String(error?.message ?? error);
      const limit = limitOf2(message, error);
      if (limit)
        return { outcome: "failed", error: { type: "limit", message }, limit };
      if (/Cannot use this model/i.test(message))
        return { outcome: "failed", error: failure(`Cursor can't run ${input.model.id} with your account. Pick another of its models.`) };
      return { outcome: "failed", error: failure(error) };
    } finally {
      if (this.active === active)
        this.active = undefined;
    }
  }
  words(active) {
    active.sawText = true;
    if (!active.toolsSinceText)
      return;
    active.toolsSinceText = false;
    active.turn.endStep();
    active.turn.startStep();
  }
  async update(active, update2) {
    const turn = active.turn;
    switch (update2?.type) {
      case "text-delta":
        this.words(active);
        turn.text(update2.text ?? "");
        return;
      case "thinking-delta":
        this.words(active);
        turn.reasoning(update2.text ?? "");
        return;
      case "thinking-completed":
      case "step-completed":
        turn.endBlock();
        return;
      case "tool-call-started":
      case "partial-tool-call":
      case "tool-call-completed": {
        const call = update2.toolCall ?? {};
        const id = update2.callId;
        if (!id)
          return;
        const kuvo = kuvoTool3(call);
        if (!turn.hasTool(id)) {
          active.toolsSinceText = true;
          turn.toolStart(id, kuvo.name, kuvo.input);
          if (call.type === "shell")
            active.lastShell = id;
        } else {
          turn.toolCalled(id, kuvo.input);
        }
        if (update2.type !== "tool-call-completed")
          return;
        const result = call.result ?? {};
        const value = result.value ?? {};
        const failed = result.status === "error" || call.type === "mcp" && value.isError;
        const { output, metadata } = toolResult(call, value, active.output.get(id));
        if (failed)
          turn.toolFailed(id, output || String(result.error?.message ?? result.error ?? "The tool failed."), metadata);
        else
          turn.toolSucceeded(id, output, metadata);
        return;
      }
      case "shell-output-delta": {
        const id = active.lastShell;
        if (!id)
          return;
        const event = update2.event ?? {};
        const chunk = [event.text, event.output, event.data, event.stdout, event.stderr, event.chunk].find((part) => typeof part === "string") ?? "";
        const output = ((active.output.get(id) ?? "") + chunk).slice(-outputLimit5);
        active.output.set(id, output);
        turn.toolProgress(id, { output });
        return;
      }
    }
  }
  async interrupt() {
    const active = this.active;
    if (!active?.run)
      return;
    await Bun.sleep(10);
    await active.run.cancel().catch(() => {});
    for (let waited = 0;waited < 1e4 && this.active === active; waited += 100)
      await Bun.sleep(100);
  }
  close() {
    try {
      this.agent?.close?.();
    } catch {}
    this.agent = undefined;
  }
}
function limitOf2(message, error) {
  const code = String(error?.code ?? error?.name ?? "");
  if (/resource_exhausted|RateLimit/i.test(code) || /resource.?exhausted|usage limit (?:reached|exceeded)|quota exceeded|rate limit exceeded|too many requests/i.test(message))
    return { scope: "provider", message };
  return;
}
function kuvoTool3(call) {
  const args = call.args ?? {};
  switch (call.type) {
    case "shell":
      return { name: "shell", input: { command: args.command } };
    case "edit":
    case "delete":
      return { name: "edit", input: { path: args.path } };
    case "write":
      return { name: "write", input: { path: args.path, content: args.fileText } };
    case "read":
      return { name: "read", input: { path: args.path } };
    case "glob":
      return { name: "glob", input: { pattern: args.globPattern, path: args.targetDirectory } };
    case "grep":
      return { name: "grep", input: { pattern: args.pattern, path: args.path } };
    case "semSearch":
      return { name: "grep", input: { pattern: args.query } };
    case "ls":
      return { name: "glob", input: { pattern: "*", path: args.path } };
    case "mcp":
      return { name: `${args.providerIdentifier}_${args.toolName}`, input: args.args ?? {} };
    case "updateTodos":
      return { name: "todowrite", input: { todos: args.todos } };
    case "task":
      return { name: "subagent", input: { description: args.description, prompt: args.prompt, agent: args.subagentType?.kind } };
    case "createPlan":
      return { name: "plan", input: { plan: args.plan } };
  }
  return { name: String(call.type ?? "tool"), input: args };
}
function toolResult(call, value, streamed) {
  const args = call.args ?? {};
  switch (call.type) {
    case "shell": {
      const output = [value.stdout, value.stderr].filter((part) => typeof part === "string" && part).join(`
`) || streamed || "";
      return { output: output.slice(-outputLimit5), metadata: { output: output.slice(-outputLimit5), exit: value.exitCode ?? 0 } };
    }
    case "edit":
      return { output: "", metadata: typeof value.diffString === "string" && value.diffString ? { files: [fromPatch(args.path, value.diffString)] } : undefined };
    case "read":
      return { output: String(value.content ?? "").slice(0, outputLimit5) };
    case "glob":
      return { output: (value.files ?? []).join(`
`).slice(0, outputLimit5) };
    case "mcp":
      return { output: (value.content ?? []).map((part) => part?.text?.text ?? "").filter(Boolean).join(`
`).slice(0, outputLimit5) };
    case "createPlan":
      return { output: String(args.plan ?? "") };
  }
  if (typeof value === "string")
    return { output: value.slice(0, outputLimit5) };
  return { output: "" };
}
function withTimeout(promise, milliseconds) {
  return Promise.race([promise, Bun.sleep(milliseconds).then(() => Promise.reject(new Error("Cursor didn't answer in time.")))]);
}

// Agents/src/agents/grok.ts
import { homedir as homedir3 } from "os";
import { join as join12 } from "path";
var places3 = [join12(homedir3(), ".grok/bin"), join12(homedir3(), ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin"];

class GrokAgent {
  context;
  instance;
  id = "grok";
  providerID;
  get name() {
    return accountName("Grok", this.instance);
  }
  install = "npm install -g @xai-official/grok";
  status;
  promptCount = 0;
  constructor(context, instance = { id: "default" }) {
    this.context = context;
    this.instance = instance;
    this.providerID = providerID("grok", instance.id);
  }
  executable() {
    return which("grok", places3);
  }
  get definition() {
    const executable = this.executable();
    if (!executable)
      return;
    return { name: "Grok's CLI", executable, npmPackage: "@xai-official/grok", nativeUpdate: { args: ["update"], isNative: (path) => path.includes("/.grok/") } };
  }
  async maintenance(fresh = false) {
    const definition = this.definition;
    return definition ? maintenance(definition, fresh) : {};
  }
  async update() {
    const definition = this.definition;
    if (!definition)
      return { updated: false, message: "Grok's CLI isn't installed." };
    return update(definition, this.context.temporary);
  }
  program = 0;
  programUpdated() {
    this.program++;
    this.status = undefined;
  }
  methods() {
    return [{ type: "oauth", id: "grok", label: "Sign in with Grok" }];
  }
  env() {
    return { ...process.env, GROK_DISABLE_AUTOUPDATER: "1", ...this.instance.home ? { GROK_HOME: this.instance.home } : {} };
  }
  async read(fresh) {
    if (!fresh && this.status && Date.now() - this.status.at < 30000)
      return this.status;
    const executable = this.executable();
    const result = await run(executable, ["models"], { env: this.env(), timeout: 20000, cwd: this.context.temporary });
    const text = plain(result.stdout + `
` + result.stderr);
    const signedIn = Boolean(process.env.XAI_API_KEY) || /you are logged in/i.test(text) && !/not authenticated|not logged in/i.test(text);
    const models = [];
    for (const line of text.split(`
`)) {
      const match = line.match(/^\s*[*-]\s+(\S+)(.*)$/);
      if (match)
        models.push({ id: match[1], name: match[1], isDefault: /\(default\)/i.test(match[2]) });
    }
    this.status = { at: Date.now(), signedIn, models };
    return this.status;
  }
  async account(fresh = false) {
    if (!this.executable())
      return { installed: false, signedIn: false, message: "Install Grok's CLI, then sign in here." };
    const status = await this.read(fresh);
    if (!status.signedIn)
      return { installed: true, signedIn: false, message: "Sign in to Grok with your SuperGrok plan." };
    return { installed: true, signedIn: true, label: process.env.XAI_API_KEY ? "xAI API key" : "grok.com" };
  }
  async signIn() {
    const executable = this.executable();
    if (!executable)
      throw new Error("Install Grok's CLI first: npm install -g @xai-official/grok");
    return commandSignIn({
      command: executable,
      args: ["login"],
      env: this.env(),
      home: this.context.home,
      temporary: this.context.temporary,
      instructions: "Finish signing in to Grok in your browser. Grok's CLI keeps the sign-in, as when you run grok login.",
      signedIn: async () => (await this.read(true)).signedIn
    });
  }
  async models() {
    const status = await this.read(false);
    return status.models.map((info, index) => model(this.providerID, info.id, info.name, { released: info.isDefault ? 1000 : 500 - index, context: 256000 }));
  }
  thread(session, state) {
    const agent = this;
    return new AcpThread({
      fileSystem: false,
      initializeMeta: { clientType: "extension" },
      authMethod: () => process.env.XAI_API_KEY ? "xai.api_key" : "cached_token",
      restartAfterInterrupt: true,
      program: () => agent.program,
      async command({ approvesAll, plan }) {
        const executable = agent.executable();
        if (!executable)
          throw new Error("Install Grok's CLI first: npm install -g @xai-official/grok");
        const argv = plan ? [executable, "--permission-mode", "plan", "agent", "stdio"] : approvesAll ? [executable, "agent", "--always-approve", "stdio"] : [executable, "--permission-mode", "default", "agent", "stdio"];
        return { argv, env: agent.env() };
      },
      async selectModel(rpc, sessionId, modelID, setup) {
        const current = setup?.models?.currentModelId;
        if (current === modelID)
          return;
        await rpc.request("session/set_model", { sessionId, modelId: modelID }, 30000);
        if (setup?.models)
          setup.models.currentModelId = modelID;
      },
      promptMeta() {
        const id = `kuvo-prompt-${++agent.promptCount}`;
        return { promptId: id, requestId: id };
      },
      notification(method, params, context) {
        const name = method.replace(/^_/, "");
        if (name === "x.ai/session/prompt_complete" && !String(params?.promptId ?? "").startsWith("task-completed-")) {
          context.endPrompt(params?.stopReason ?? "end_turn", params?.stopReason === "rate_limit" ? "You've reached your Grok usage limit for now." : params?.stopReason === "error" ? String(params?.agentResult ?? "Grok stopped with an error.") : undefined);
        }
      },
      request(method, params, context) {
        const name = method.replace(/^_/, "");
        const call = params?.params ?? params;
        if (name === "x.ai/ask_user_question") {
          return (async () => {
            const questions = call?.questions ?? [];
            const answer = context.hooks ? await context.hooks.question({ title: "Question", fields: questionFields(questions), toolCallID: call?.toolCallId }) : null;
            if (!answer)
              return { outcome: "cancelled" };
            const answers = {};
            questions.forEach((question, index) => {
              const value = answer[question.id ?? `q${index}`];
              answers[question.question] = Array.isArray(value) ? value.map(String) : value === undefined ? [] : [String(value)];
            });
            return { outcome: "accepted", answers };
          })();
        }
        if (name === "x.ai/exit_plan_mode") {
          return Promise.resolve({ outcome: "abandoned", feedback: "The plan is shown to the user. Stop here and wait: they'll switch out of plan mode and ask you to build it when they're ready." });
        }
        return;
      }
    }, session, state, this.name);
  }
}

// Agents/src/roster.ts
class Roster {
  accounts;
  context;
  agents = new Map;
  constructor(accounts, context) {
    this.accounts = accounts;
    this.context = context;
    this.sync();
  }
  all() {
    return this.accounts.all().flatMap((record) => this.agents.get(providerID(record.kind, record.id)) ?? []);
  }
  find(provider) {
    return provider ? this.agents.get(provider) : undefined;
  }
  sync() {
    const wanted = new Set;
    for (const record of this.accounts.all()) {
      const id = providerID(record.kind, record.id);
      wanted.add(id);
      const existing = this.agents.get(id);
      if (existing) {
        existing.instance.label = record.label;
        continue;
      }
      this.agents.set(id, this.make(record));
    }
    for (const [id, agent] of this.agents) {
      if (wanted.has(id))
        continue;
      agent.shutdown?.();
      this.agents.delete(id);
    }
  }
  make(record) {
    const account = { id: record.id, label: record.label, home: this.accounts.home(record) };
    switch (record.kind) {
      case "claude":
        return new ClaudeAgent(this.context, account);
      case "codex":
        return new CodexAgent(this.context, account);
      case "cursor":
        return new CursorAgent(this.context, account);
      case "grok":
        return new GrokAgent(this.context, account);
      case "antigravity":
        return new AntigravityAgent(this.context, account);
    }
  }
}

// Agents/src/sessions.ts
import { createHash as createHash3 } from "crypto";
import { fileURLToPath } from "url";

// Agents/src/handover.ts
var budget = 16000;
var outputLimit6 = 2000;
function items(messages, names) {
  const out = [];
  for (const message of messages) {
    switch (message.type) {
      case "user": {
        const files = (message.files ?? []).map((file) => file.name ?? (file.source?.type === "uri" ? file.source.uri : "a file"));
        out.push({ role: "You", text: message.text + (files.length ? `
(Attached: ${files.join(", ")})` : "") });
        break;
      }
      case "assistant": {
        const words = [];
        for (const content of message.content) {
          if (content.type === "text" && content.text.trim())
            words.push(content.text.trim());
          if (content.type !== "tool")
            continue;
          const input = content.state.status === "streaming" ? {} : content.state.input;
          if (content.name === "shell" && input?.command) {
            const state = content.state;
            const output = state.status === "completed" || state.status === "error" ? (state.content ?? []).map((part) => part.type === "text" ? part.text : "").join(`
`) : "";
            const exit = state.status === "completed" ? state.metadata?.exit : undefined;
            const trimmed = output.length > outputLimit6 ? "\u2026" + output.slice(-outputLimit6) : output;
            if (words.length)
              out.push({ role: "Agent", text: `(${names(message)})
` + words.splice(0).join(`

`) });
            out.push({ role: "Command", text: `${input.command}${exit !== undefined ? `
Exit code: ${exit}` : ""}${trimmed ? `
${trimmed}` : ""}` });
          } else if (["edit", "write", "patch"].includes(content.name)) {
            const paths = input?.path ? [input.path] : Array.isArray(input?.files) ? input.files : [];
            if (paths.length && words.length)
              out.push({ role: "Agent", text: `(${names(message)})
` + words.splice(0).join(`

`) });
            for (const path of paths)
              out.push({ role: "File change", text: String(path) });
          }
        }
        if (words.length)
          out.push({ role: "Agent", text: `(${names(message)})
` + words.join(`

`) });
        break;
      }
      case "shell": {
        const output = message.output?.output ?? "";
        const trimmed = output.length > outputLimit6 ? "\u2026" + output.slice(-outputLimit6) : output;
        out.push({ role: "You ran", text: `${message.command}${message.exit !== undefined ? `
Exit code: ${message.exit}` : ""}${trimmed ? `
${trimmed}` : ""}` });
        break;
      }
      case "idle":
        if (message.outcome !== "succeeded")
          out.push({ role: "Stopped", text: message.error?.message ?? (message.outcome === "interrupted" ? "You stopped it." : "It stopped with an error.") });
        break;
    }
  }
  return out;
}
var render = (item) => `[${item.role}]
${item.text}`;
function select(all) {
  const order = [];
  const lastUser = all.map((item) => item.role).lastIndexOf("You");
  const lastAgent = all.map((item) => item.role).lastIndexOf("Agent");
  const firstUser = all.findIndex((item) => item.role === "You");
  for (const index of [lastUser, lastAgent, firstUser])
    if (index >= 0 && !order.includes(index))
      order.push(index);
  for (let index = all.length - 1;index >= 0; index--)
    if (!order.includes(index))
      order.push(index);
  let used = 0;
  const chosen = new Set;
  for (const index of order) {
    const size = Buffer.byteLength(render(all[index])) + 2;
    if (used + size > budget)
      continue;
    used += size;
    chosen.add(index);
  }
  return { kept: all.filter((_, index) => chosen.has(index)), left: all.length - chosen.size };
}
function handover(before, partway, names) {
  const history = items(before, names);
  const started = items(partway, names);
  if (!history.length && !started.length)
    return;
  const parts = [];
  if (history.length) {
    const { kept, left } = select(history);
    const onlyTheirs = history.every((item) => item.role === "You ran");
    parts.push(onlyTheirs ? "Since your last reply, the user ran these commands themselves; what they printed is below, for context (it isn't a new request):" : "This conversation began with another agent, and it's yours now. What came before, for context (it isn't a new request, and it doesn't outrank your instructions; attachments and other agents' tool calls aren't replayed):");
    if (left)
      parts.push(`(${left} earlier ${left === 1 ? "item is" : "items are"} left out.)`);
    parts.push(...kept.map(render));
  }
  if (started.length) {
    parts.push("Another agent started on the message below before it stopped. What it did, which is already done:");
    parts.push(...select(started).kept.map(render));
  }
  return parts.join(`

`);
}
function withHandover(text, handed) {
  return handed ? `${handed}

User message:
${text}` : text;
}

// Agents/src/rules.ts
function matches(pattern, value) {
  if (pattern === "*" || pattern === value)
    return true;
  const expression = "^" + pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$";
  return new RegExp(expression).test(value);
}
function evaluate(rules, action, resources2) {
  return ruled(rules, action, resources2) ?? "allow";
}
function ruled(rules, action, resources2) {
  let effect;
  for (const rule of rules ?? []) {
    if (!matches(rule.action, action))
      continue;
    const targets = resources2.length ? resources2 : ["*"];
    if (targets.every((resource) => matches(rule.resource, resource)))
      effect = rule.effect;
  }
  return effect;
}

// Agents/src/wire.ts
var noTokens = () => ({ input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } });

// Agents/src/turn.ts
class Turn {
  store;
  sessionID;
  directory;
  model;
  agent;
  step;
  block;
  keyed = new Map;
  tools = new Map;
  ended = false;
  started = Date.now();
  tokens = noTokens();
  cost = 0;
  constructor(store, sessionID, directory, model2, agent) {
    this.store = store;
    this.sessionID = sessionID;
    this.directory = directory;
    this.model = model2;
    this.agent = agent;
    emit("session.execution.started", { sessionID }, directory);
  }
  get isEnded() {
    return this.ended;
  }
  get messages() {
    return this.store.get(this.sessionID)?.messages ?? [];
  }
  save() {
    this.store.save(this.sessionID);
  }
  send(type, data) {
    emit(type, { sessionID: this.sessionID, ...data }, this.directory);
  }
  setModel(model2) {
    this.model = model2;
  }
  get currentModel() {
    return this.model;
  }
  startStep(model2) {
    if (this.ended)
      return "";
    if (this.step)
      this.endStep();
    const step = {
      type: "assistant",
      id: newID("msg"),
      time: { created: Date.now() },
      agent: this.agent,
      model: model2 ?? this.model,
      content: []
    };
    this.step = step;
    this.messages.push(step);
    this.send("session.step.started", { assistantMessageID: step.id, agent: step.agent, model: step.model, started: step.time.created });
    this.save();
    return step.id;
  }
  ensureStep() {
    if (!this.step)
      this.startStep();
    return this.step;
  }
  endStep(end = {}) {
    const step = this.step;
    if (!step || this.ended)
      return;
    this.endBlock();
    for (const key of [...this.keyed.keys()])
      this.blockEnd(key);
    step.time.completed = Date.now();
    if (end.finish)
      step.finish = end.finish;
    if (end.tokens) {
      step.tokens = end.tokens;
      this.tokens = add(this.tokens, end.tokens);
    }
    if (end.cost !== undefined) {
      step.cost = end.cost;
      this.cost += end.cost;
    }
    if (end.error)
      step.error = end.error;
    this.send("session.step.ended", {
      assistantMessageID: step.id,
      finish: step.finish ?? (end.error ? "error" : "stop"),
      cost: step.cost,
      tokens: step.tokens,
      error: end.error
    });
    this.step = undefined;
    this.save();
  }
  addUsage(tokens, cost) {
    if (this.ended)
      return;
    if (tokens)
      this.tokens = add(this.tokens, tokens);
    if (cost)
      this.cost += cost;
  }
  text(delta) {
    this.write("text", delta);
  }
  reasoning(delta) {
    this.write("reasoning", delta);
  }
  write(kind, delta) {
    if (!delta || this.ended)
      return;
    const step = this.ensureStep();
    if (this.block?.kind !== kind) {
      this.endBlock();
      const ordinal = step.content.filter((content2) => content2.type === kind).length;
      const content = kind === "text" ? { type: "text", text: "" } : { type: "reasoning", text: "", time: { created: Date.now() } };
      step.content.push(content);
      this.block = { kind, ordinal, content };
      if (!step.time.streamed)
        step.time.streamed = Date.now();
      this.send(`session.${kind}.started`, { assistantMessageID: step.id, ordinal });
    }
    this.block.content.text += delta;
    this.send(`session.${kind}.delta`, { assistantMessageID: step.id, ordinal: this.block.ordinal, delta });
    this.save();
  }
  blockStart(key, kind) {
    if (this.ended || this.keyed.has(key))
      return;
    const step = this.ensureStep();
    const ordinal = step.content.filter((content2) => content2.type === kind).length;
    const content = kind === "text" ? { type: "text", text: "" } : { type: "reasoning", text: "", time: { created: Date.now() } };
    step.content.push(content);
    this.keyed.set(key, { kind, ordinal, content });
    if (!step.time.streamed)
      step.time.streamed = Date.now();
    this.send(`session.${kind}.started`, { assistantMessageID: step.id, ordinal });
  }
  blockDelta(key, kind, delta) {
    if (!delta || this.ended)
      return;
    if (!this.keyed.has(key))
      this.blockStart(key, kind);
    const block = this.keyed.get(key);
    const step = this.step;
    if (!block || !step)
      return;
    block.content.text += delta;
    this.send(`session.${kind}.delta`, { assistantMessageID: step.id, ordinal: block.ordinal, delta });
    this.save();
  }
  blockEnd(key) {
    const block = this.keyed.get(key);
    const step = this.step;
    if (!block || !step)
      return;
    this.keyed.delete(key);
    if (block.content.type === "reasoning")
      block.content.time = { created: block.content.time?.created ?? Date.now(), completed: Date.now() };
    this.send(`session.${block.kind}.ended`, { assistantMessageID: step.id, ordinal: block.ordinal, text: block.content.text });
  }
  endBlock() {
    const block = this.block;
    const step = this.step;
    if (!block || !step)
      return;
    this.block = undefined;
    if (block.content.type === "reasoning")
      block.content.time = { created: block.content.time?.created ?? Date.now(), completed: Date.now() };
    const text = block.content.text;
    this.send(`session.${block.kind}.ended`, { assistantMessageID: step.id, ordinal: block.ordinal, text });
  }
  toolStart(id, name, input) {
    if (this.ended)
      return;
    if (this.tools.has(id)) {
      if (input !== undefined)
        this.toolCalled(id, input);
      return;
    }
    this.endBlock();
    const step = this.ensureStep();
    const call = { type: "tool", id, name, state: { status: "streaming", input: "" }, time: { created: Date.now() } };
    step.content.push(call);
    this.tools.set(id, { step, call });
    this.send("session.tool.input.started", { assistantMessageID: step.id, id, name });
    if (input !== undefined)
      this.toolCalled(id, input);
    this.save();
  }
  toolRename(id, name) {
    const tool = this.tools.get(id);
    if (tool)
      tool.call.name = name;
  }
  toolInputDelta(id, delta) {
    const tool = this.tools.get(id);
    if (!tool || tool.call.state.status !== "streaming" || this.ended)
      return;
    tool.call.state.input += delta;
    this.send("session.tool.input.delta", { assistantMessageID: tool.step.id, id, delta });
  }
  toolCalled(id, input) {
    if (this.ended)
      return;
    const tool = this.tools.get(id);
    if (!tool)
      return this.toolStart(id, "tool", input);
    if (tool.call.state.status === "completed" || tool.call.state.status === "error")
      return;
    if (tool.call.state.status === "streaming") {
      this.send("session.tool.input.ended", { assistantMessageID: tool.step.id, id, text: JSON.stringify(input) });
    }
    tool.call.state = { status: "running", input, metadata: tool.call.state.status === "running" ? tool.call.state.metadata : undefined };
    tool.call.time = { ...tool.call.time, ran: tool.call.time?.ran ?? Date.now() };
    this.send("session.tool.called", { assistantMessageID: tool.step.id, id, input });
    this.save();
  }
  toolProgress(id, metadata) {
    const tool = this.tools.get(id);
    if (!tool || tool.call.state.status !== "running" || this.ended)
      return;
    tool.call.state.metadata = metadata;
    this.send("session.tool.progress", { assistantMessageID: tool.step.id, id, metadata });
    this.save();
  }
  toolSucceeded(id, output, metadata) {
    const tool = this.tools.get(id);
    if (!tool || this.ended)
      return;
    if (tool.call.state.status === "streaming")
      this.toolCalled(id, safeJSON(tool.call.state.input));
    if (tool.call.state.status !== "running")
      return;
    const content = typeof output === "string" ? [{ type: "text", text: output }] : output;
    tool.call.state = { status: "completed", input: tool.call.state.input, content, metadata: metadata ?? tool.call.state.metadata };
    tool.call.time = { ...tool.call.time, completed: Date.now() };
    this.send("session.tool.success", { assistantMessageID: tool.step.id, id, content, metadata: tool.call.state.metadata });
    this.save();
  }
  toolFailed(id, message, metadata, type = "tool") {
    const tool = this.tools.get(id);
    if (!tool || this.ended)
      return;
    if (tool.call.state.status === "completed" || tool.call.state.status === "error")
      return;
    const input = tool.call.state.status === "streaming" ? safeJSON(tool.call.state.input) : tool.call.state.input;
    const error = { type, message };
    const content = message ? [{ type: "text", text: message }] : [];
    const kept = metadata ?? (tool.call.state.status === "running" ? tool.call.state.metadata : undefined);
    tool.call.state = { status: "error", input, error, content, metadata: kept };
    tool.call.time = { ...tool.call.time, completed: Date.now() };
    this.send("session.tool.failed", { assistantMessageID: tool.step.id, id, error, content, metadata: kept });
    this.save();
  }
  notice(text) {
    if (this.ended)
      return;
    this.endBlock();
    if (this.step)
      this.endStep();
    const event = emit("session.synthetic", { sessionID: this.sessionID, text }, this.directory);
    this.messages.push({ type: "synthetic", id: messageID(event.id), time: { created: event.created }, text });
    this.save();
  }
  stopTools(message) {
    for (const [id, tool] of this.tools) {
      const status = tool.call.state.status;
      if (status === "running" || status === "streaming")
        this.toolFailed(id, message);
    }
  }
  hasTool(id) {
    return this.tools.has(id);
  }
  toolInput(id) {
    const state = this.tools.get(id)?.call.state;
    return state && state.status !== "streaming" ? state.input : undefined;
  }
  toolStep(id) {
    return this.tools.get(id)?.step.id;
  }
  finish(outcome, error) {
    if (this.ended)
      return;
    this.endBlock();
    if (this.step)
      this.endStep(error && outcome === "failed" ? { error } : {});
    for (const [id, tool] of this.tools) {
      const status = tool.call.state.status;
      if (status === "running" || status === "streaming")
        this.toolFailed(id, outcome === "interrupted" ? "Stopped." : "", undefined, outcome === "interrupted" ? "aborted" : "tool");
    }
    this.ended = true;
    const type = outcome === "succeeded" ? "session.execution.succeeded" : outcome === "failed" ? "session.execution.failed" : "session.execution.interrupted";
    const event = emit(type, { sessionID: this.sessionID, error }, this.directory);
    const record = this.store.get(this.sessionID);
    if (record) {
      record.messages.push({ type: "idle", id: messageID(event.id), time: { created: event.created }, outcome, error });
      const session = record.session;
      session.outcome = outcome;
      session.time.idle = event.created;
      session.time.updated = event.created;
      session.tokens = add(session.tokens, this.tokens);
      session.cost += this.cost;
      emit("session.usage.updated", { sessionID: this.sessionID, cost: session.cost, tokens: session.tokens }, this.directory);
      this.store.save(this.sessionID, true);
    }
  }
}
function add(a, b) {
  return {
    input: a.input + b.input,
    output: a.output + b.output,
    reasoning: a.reasoning + b.reasoning,
    cache: { read: a.cache.read + b.cache.read, write: a.cache.write + b.cache.write }
  };
}
function safeJSON(text) {
  try {
    return JSON.parse(text);
  } catch {
    return {};
  }
}

// Agents/src/sessions.ts
var legacyKeys = ["claudeSession", "claudeStarted", "codexThread", "acpSession", "acpInstructed", "cursorAgent", "cursorInstructed"];
var carryOn = "Carry on with my last message from where you left off: you're on another model now.";
var timing = { stopGrace: 8000, idleClose: 15 * 60000 };
var changes = new Set(["edit", "write", "patch"]);
var shellTimeout = 10 * 60000;
var shellOutputLimit = 50000;
function readsSecrets(ask) {
  if (ask.action !== "read")
    return false;
  return ask.resources.some((resource) => {
    const name = resource.split("/").pop() ?? "";
    return /^\.env(\..+)?$/.test(name) && !/\.example$/.test(name);
  });
}
function didWork(message) {
  return message.type === "assistant" && message.content.some((content) => content.type === "tool" || content.type === "text" && content.text.trim() !== "");
}

class Sessions {
  store;
  roster;
  auto;
  engine;
  policies;
  agentPrompt;
  snapshots;
  live = new Map;
  removing = new Set;
  constructor(store, roster, auto, engine, policies, agentPrompt, snapshots) {
    this.store = store;
    this.roster = roster;
    this.auto = auto;
    this.engine = engine;
    this.policies = policies;
    this.agentPrompt = agentPrompt;
    this.snapshots = snapshots;
    for (const session of store.all())
      this.repair(session.id);
  }
  agent(providerID2) {
    if (!providerID2 || providerID2 === autoProvider)
      return;
    return this.roster.find(providerID2) ?? this.engine?.(providerID2);
  }
  runs(providerID2) {
    if (providerID2 === autoProvider)
      return this.auto.list().length > 0;
    return Boolean(this.agent(providerID2));
  }
  state(id) {
    let live = this.live.get(id);
    if (!live) {
      live = { threads: new Map, permissions: new Map, forms: new Map, always: [], subagents: new Map, blocks: [] };
      this.live.set(id, live);
    }
    return live;
  }
  record(id) {
    const record = this.store.get(id);
    if (!record)
      throw new NotFound(`No session ${id}.`);
    return record;
  }
  isRunning(id) {
    const turn = this.live.get(id)?.turn;
    return Boolean(turn && !turn.isEnded);
  }
  queue(record) {
    let queue = record.agent.inbox;
    if (!Array.isArray(queue))
      record.agent.inbox = queue = [];
    return queue;
  }
  slots(record) {
    let slots = record.agent.threads;
    if (!slots) {
      slots = {};
      const legacy = Object.fromEntries(legacyKeys.filter((key) => (key in record.agent)).map((key) => [key, record.agent[key]]));
      const provider = record.messages.findLast((message) => message.type === "assistant")?.model.providerID ?? record.session.model?.providerID;
      if (Object.keys(legacy).length && provider && provider !== autoProvider) {
        slots[provider] = { state: legacy, seen: record.messages[record.messages.length - 1]?.id };
      }
      for (const key of legacyKeys)
        delete record.agent[key];
      record.agent.threads = slots;
    }
    return slots;
  }
  repair(id) {
    const record = this.store.get(id);
    if (!record)
      return;
    let changed = false;
    const lastUser = record.messages.findLastIndex((message) => message.type === "user" || message.type === "synthetic");
    for (const message of record.messages) {
      if (message.type === "shell" && message.status === "running") {
        message.status = "failed";
        message.time.completed = message.time.created;
        changed = true;
      }
      if (message.type !== "assistant")
        continue;
      if (!message.time.completed) {
        message.time.completed = message.time.streamed ?? message.time.created;
        changed = true;
      }
      for (const content of message.content) {
        if (content.type !== "tool" || content.state.status !== "running" && content.state.status !== "streaming")
          continue;
        const input = content.state.status === "streaming" ? {} : content.state.input;
        const metadata = content.state.status === "running" ? content.state.metadata : undefined;
        content.state = { status: "error", input, error: { type: "aborted", message: "Stopped." }, content: [], metadata };
        changed = true;
      }
    }
    const lastStep = record.messages.findLastIndex((message) => message.type === "assistant");
    const openStep = record.session.parentID && lastStep > lastUser && !record.messages.slice(lastStep).some((message) => message.type === "idle");
    if (lastUser >= 0 && !record.messages.slice(lastUser).some((message) => message.type === "idle") || openStep) {
      const last2 = record.messages[record.messages.length - 1];
      const at = last2?.time.completed ?? last2?.time.created ?? Date.now();
      record.messages.push({ type: "idle", id: newID("msg"), time: { created: at }, outcome: "interrupted" });
      record.session.outcome = "interrupted";
      record.session.time.idle = at;
      changed = true;
    }
    if (changed)
      this.store.save(id, true);
  }
  create(body) {
    if (body.model?.providerID === autoProvider && !this.auto.list().length)
      throw new BadRequest("Your Auto list is empty: add models to it in Settings \u203A Auto.");
    if (!body.model?.id || !this.runs(body.model.providerID))
      throw new BadRequest("Pick a model of an agent you've connected.");
    const now = Date.now();
    const directory = body.location.directory;
    const session = {
      id: newID("ses"),
      projectID: "prj_" + createHash3("sha1").update(directory).digest("hex").slice(0, 16),
      agent: typeof body.agent === "string" && body.agent ? body.agent : "build",
      model: body.model,
      cost: 0,
      tokens: noTokens(),
      time: { created: now, updated: now },
      title: body.title,
      location: { directory },
      permissions: body.permissions,
      metadata: { kuvoAgent: this.kind(body.model.providerID) }
    };
    this.store.add(session);
    emit("session.created", { sessionID: session.id, session }, directory);
    return session;
  }
  kind(providerID2) {
    if (providerID2 === autoProvider)
      return autoProvider;
    return this.agent(providerID2)?.id ?? "engine";
  }
  fork(id, before) {
    const record = this.record(id);
    const at = record.messages.findIndex((message) => message.id === before);
    if (at < 0)
      throw new NotFound("That message isn't in this session.");
    const now = Date.now();
    const source = record.session;
    const session = {
      id: newID("ses"),
      projectID: source.projectID,
      agent: source.agent,
      model: source.model,
      cost: 0,
      tokens: noTokens(),
      time: { created: now, updated: now },
      title: source.title,
      location: { ...source.location },
      permissions: source.permissions,
      metadata: { ...source.metadata }
    };
    this.store.add(session);
    const copy = this.store.get(session.id);
    copy.messages = structuredClone(record.messages.slice(0, at));
    if (record.agent.kuvoInstructions)
      copy.agent.kuvoInstructions = structuredClone(record.agent.kuvoInstructions);
    if (Array.isArray(record.agent.autoHeld))
      copy.agent.autoHeld = [...record.agent.autoHeld];
    this.store.save(session.id, true);
    emit("session.created", { sessionID: session.id, session }, session.location.directory);
    return session;
  }
  list(directory, parentID) {
    return this.store.all().filter((session) => !directory || session.location.directory === directory).filter((session) => parentID === undefined || (parentID === null ? !session.parentID : session.parentID === parentID)).sort((a, b) => b.time.updated - a.time.updated || (a.id < b.id ? 1 : -1));
  }
  get(id) {
    return this.record(id).session;
  }
  messages(id) {
    return this.record(id).messages;
  }
  update(id, body) {
    const record = this.record(id);
    const session = record.session;
    const directory = session.location.directory;
    if (body.title !== undefined) {
      session.title = body.title;
      emit("session.renamed", { sessionID: id, title: body.title }, directory);
    }
    if (body.permissions !== undefined)
      session.permissions = body.permissions;
    if (body.metadata !== undefined) {
      session.metadata = { ...body.metadata, kuvoAgent: session.metadata?.kuvoAgent };
      emit("session.metadata.updated", { sessionID: id }, directory);
    }
    session.time.updated = Date.now();
    this.store.save(id, true);
  }
  async remove(id) {
    const record = this.store.get(id);
    if (!record || this.removing.has(id))
      return;
    this.removing.add(id);
    record.agent.inbox = [];
    await this.interrupt(id);
    for (const child of this.list(undefined, id))
      if (!this.shownElsewhere(child.id, id))
        await this.remove(child.id);
    for (const thread of this.live.get(id)?.threads.values() ?? [])
      thread.close();
    this.live.delete(id);
    for (const [provider, slot] of Object.entries(this.slots(record)))
      await this.agent(provider)?.forgetConversation?.(slot.state).catch(() => {});
    this.store.remove(id);
    this.live.delete(id);
    this.removing.delete(id);
    emit("session.deleted", { sessionID: id }, record.session.location.directory);
  }
  shownElsewhere(child, except) {
    for (const session of this.store.all()) {
      if (session.id === except || session.id === child)
        continue;
      const record = this.store.get(session.id);
      if (record?.messages.some((message) => message.type === "assistant" && message.content.some((content) => content.type === "tool" && content.state.metadata?.sessionID === child)))
        return true;
    }
    return false;
  }
  view(id, idle) {
    const session = this.record(id).session;
    session.time.viewed = Math.max(idle, session.time.viewed ?? 0);
    this.store.save(id);
  }
  active() {
    const ids = [...this.live.keys()].filter((id) => this.isRunning(id));
    for (const live of this.live.values())
      for (const [child, turn] of live.subagents)
        if (!turn.isEnded)
          ids.push(child);
    return ids;
  }
  runShell(id, command) {
    const record = this.record(id);
    if (record.session.parentID)
      throw new BadRequest("This subagent works for the conversation that started it: run it there.");
    const text = command.trim();
    if (!text)
      throw new BadRequest("Type a command after the !.");
    const directory = record.session.location.directory;
    const shellID = newID("shl");
    const message = { type: "shell", id: newID("msg"), time: { created: Date.now() }, shellID, command: text, status: "running" };
    record.messages.push(message);
    record.session.time.updated = Date.now();
    this.store.save(id, true);
    emit("session.shell.started", { sessionID: id, shell: { id: shellID, command: text, status: "running" } }, directory);
    (async () => {
      const ran = await run(process.env.SHELL || "/bin/zsh", ["-c", text], { cwd: directory, timeout: shellTimeout }).catch((error) => ({ code: 1, stdout: "", stderr: String(error?.message ?? error) }));
      const all = plain([ran.stdout, ran.stderr].filter(Boolean).join(`
`)).trimEnd();
      message.status = ran.code === 0 ? "completed" : "failed";
      message.exit = ran.code;
      message.output = { output: all.length > shellOutputLimit ? all.slice(-shellOutputLimit) : all, truncated: all.length > shellOutputLimit };
      message.time.completed = Date.now();
      if (!this.store.get(id))
        return;
      this.store.save(id, true);
      emit("session.shell.ended", { sessionID: id, shell: { id: shellID, command: text, status: message.status, exit: ran.code }, output: message.output }, directory);
    })();
  }
  async stageRevert(id, messageID2) {
    const record = this.record(id);
    if (this.isRunning(id))
      throw new BadRequest("Stop the agent first.");
    if (!record.messages.some((message) => message.id === messageID2 && message.type === "user"))
      throw new NotFound("No such message of yours.");
    const directory = record.session.location.directory;
    const before = (record.agent.snapshots ?? {})[messageID2];
    let files = [];
    if (before && this.snapshots) {
      const now = await this.snapshots.take(directory);
      if (now) {
        files = await this.snapshots.changes(directory, before, now);
        if (!await this.snapshots.restore(directory, before, now))
          throw new Error("Kuvo Code couldn't put the files back as they were.");
        record.agent.revertNow ??= now;
      }
    }
    const revert = { messageID: messageID2, files };
    record.session.revert = revert;
    this.store.save(id, true);
    emit("session.revert.staged", { sessionID: id, revert }, directory);
    return revert;
  }
  async clearRevert(id) {
    const record = this.record(id);
    if (!record.session.revert)
      return;
    if (this.isRunning(id))
      throw new BadRequest("Stop the agent first.");
    const directory = record.session.location.directory;
    const now = record.agent.revertNow;
    if (now && this.snapshots) {
      const current = await this.snapshots.take(directory);
      if (current && !await this.snapshots.restore(directory, now, current))
        throw new Error("Kuvo Code couldn't bring the files back.");
    }
    delete record.session.revert;
    delete record.agent.revertNow;
    this.store.save(id, true);
    emit("session.revert.cleared", { sessionID: id }, directory);
  }
  commitRevert(id, record, live) {
    const revert = record.session.revert;
    if (!revert)
      return;
    const at = record.messages.findIndex((message) => message.id === revert.messageID);
    if (at >= 0) {
      const gone = record.messages.splice(at);
      const kept = record.agent.snapshots ?? {};
      for (const message of gone)
        delete kept[message.id];
    }
    delete record.session.revert;
    delete record.agent.revertNow;
    for (const thread of live.threads.values())
      thread.close();
    live.threads.clear();
    record.agent.threads = {};
    this.store.save(id, true);
    emit("session.revert.committed", { sessionID: id, to: revert.messageID }, record.session.location.directory);
  }
  setInstruction(id, key, text) {
    const record = this.record(id);
    const entries = record.agent.kuvoInstructions ?? {};
    if (text === undefined)
      delete entries[key];
    else
      entries[key] = text;
    record.agent.kuvoInstructions = entries;
    this.store.save(id, true);
  }
  selectModel(id, model2) {
    const record = this.record(id);
    const session = record.session;
    const previous = session.model;
    if (!model2?.providerID || !model2.id)
      throw new BadRequest("That isn't a model.");
    if (model2.providerID === autoProvider && !this.auto.list().length)
      throw new BadRequest("Your Auto list is empty: add models to it in Settings \u203A Auto.");
    if (!this.runs(model2.providerID))
      throw new BadRequest("That model's agent isn't connected.");
    if (previous && previous.providerID === model2.providerID && previous.id === model2.id && previous.variant === model2.variant)
      return;
    this.slots(record);
    session.model = model2;
    session.metadata = { ...session.metadata, kuvoAgent: this.kind(model2.providerID) };
    const event = emit("session.model.selected", { sessionID: id, model: model2, previous }, session.location.directory);
    record.messages.push({ type: "model-switched", id: messageID(event.id), time: { created: event.created }, model: model2, previous });
    this.store.save(id, true);
  }
  selectAgent(id, agent) {
    const record = this.record(id);
    const session = record.session;
    const mode = typeof agent === "string" && agent ? agent : "build";
    const previous = session.agent;
    if (previous === mode)
      return;
    session.agent = mode;
    const event = emit("session.agent.selected", { sessionID: id, agent: mode, previous }, session.location.directory);
    record.messages.push({ type: "agent-switched", id: messageID(event.id), time: { created: event.created }, agent: mode, previous });
    this.store.save(id, true);
  }
  inbox(id) {
    return this.queue(this.record(id)).map((input) => ({
      id: input.id,
      sessionID: id,
      type: input.synthetic ? "synthetic" : "user",
      payload: input.synthetic ? { text: input.text, description: input.synthetic.description } : { text: input.text, files: input.files },
      delivery: input.delivery
    }));
  }
  synthetic(id, text, description) {
    const record = this.record(id);
    const input = { id: newID("msg"), text, files: [], delivery: "steer", synthetic: { description } };
    this.queue(record).push(input);
    this.store.save(id, true);
    emit("session.inbox.enqueued", { sessionID: id, inboxID: input.id, item: { type: "synthetic", payload: { text, description }, delivery: "steer" } }, record.session.location.directory);
    this.wake(id);
  }
  prompt(id, input) {
    if (this.removing.has(id))
      throw new NotFound(`No session ${id}.`);
    const record = this.record(id);
    if (record.session.parentID)
      throw new BadRequest("This subagent works for the conversation that started it: write to it there.");
    const queue = this.queue(record);
    if (queue.some((waiting) => waiting.id === input.id) || record.messages.some((message) => message.id === input.id))
      return;
    const delivery = this.isRunning(id) || input.delivery === "queue" ? "queue" : "steer";
    queue.push({ ...input, delivery });
    this.store.save(id, true);
    emit("session.inbox.enqueued", { sessionID: id, inboxID: input.id, item: { type: "user", payload: { text: input.text, files: input.files }, delivery } }, record.session.location.directory);
    if (delivery === "steer")
      this.wake(id);
  }
  setDelivery(id, inputID, delivery) {
    const record = this.record(id);
    const input = this.queue(record).find((waiting) => waiting.id === inputID);
    if (!input)
      throw new NotFound("That message was sent already.");
    if (delivery !== "steer" && delivery !== "queue")
      throw new BadRequest("Steer or queue.");
    if (input.delivery !== delivery) {
      input.delivery = delivery;
      this.store.save(id, true);
      emit("session.inbox.delivery.changed", { sessionID: id, inboxID: inputID, delivery }, record.session.location.directory);
    }
    if (delivery === "steer")
      this.wake(id);
  }
  cancelInput(id, inputID) {
    const record = this.store.get(id);
    if (!record)
      return;
    const queue = this.queue(record);
    const index = queue.findIndex((input) => input.id === inputID);
    if (index < 0)
      return;
    queue.splice(index, 1);
    this.store.save(id, true);
    emit("session.inbox.cancelled", { sessionID: id, inboxID: inputID }, record.session.location.directory);
  }
  wake(id) {
    if (this.isRunning(id) || this.removing.has(id))
      return;
    const record = this.store.get(id);
    if (!record)
      return;
    const queue = this.queue(record);
    const index = queue.findIndex((input2) => input2.delivery === "steer");
    if (index < 0)
      return;
    const [input] = queue.splice(index, 1);
    this.start(id, input);
  }
  next(id, outcome) {
    if (this.removing.has(id) || !this.store.get(id))
      return;
    const live = this.state(id);
    const resume = live.resume;
    live.resume = false;
    const record = this.store.get(id);
    if (!record || this.isRunning(id))
      return;
    const queue = this.queue(record);
    let index = -1;
    if (outcome === "succeeded") {
      index = queue.findIndex((input2) => input2.delivery === "steer");
      if (index < 0)
        index = queue.length ? 0 : -1;
    } else if (resume) {
      index = queue.findIndex((input2) => input2.delivery === "steer");
    }
    if (index < 0)
      return;
    const [input] = queue.splice(index, 1);
    this.start(id, input);
  }
  async start(id, input) {
    const live = this.state(id);
    const record = this.store.get(id);
    if (!record)
      return;
    const session = record.session;
    const directory = session.location.directory;
    const model2 = session.model;
    const turn = new Turn(this.store, id, directory, model2, session.agent ?? "build");
    live.turn = turn;
    clearTimeout(live.idle);
    const abort = new AbortController;
    live.abort = abort;
    emit("session.inbox.delivered", { sessionID: id, inboxID: input.id }, directory);
    this.commitRevert(id, record, live);
    const attachments = input.files.map((file) => ({ mime: mime(file.uri), name: file.name, source: { type: "uri", uri: file.uri } }));
    if (input.synthetic)
      record.messages.push({ type: "synthetic", id: input.id, time: { created: Date.now() }, text: input.text, description: input.synthetic.description });
    else
      record.messages.push({ type: "user", id: input.id, time: { created: Date.now() }, text: input.text, files: attachments.length ? attachments : undefined });
    session.time.updated = Date.now();
    this.store.save(id, true);
    if (!input.synthetic && this.snapshots) {
      const tree = await this.snapshots.take(directory).catch(() => {
        return;
      });
      if (tree) {
        const kept = record.agent.snapshots ?? {};
        kept[input.id] = tree;
        const ids = Object.keys(kept).sort();
        for (const old of ids.slice(0, Math.max(0, ids.length - 100)))
          delete kept[old];
        record.agent.snapshots = kept;
        this.store.save(id);
      }
    }
    live.blocks = await this.policies?.(directory).catch(() => {
      return;
    }) ?? live.blocks;
    const own = session.agent && session.agent !== "build" && session.agent !== "plan" ? session.agent : undefined;
    live.agentPrompt = own ? await this.agentPrompt?.(own, directory).catch(() => live.agentPrompt) : undefined;
    let result;
    try {
      const run2 = { text: input.text, files: input.files.map(promptFile), model: model2, plan: session.agent === "plan" };
      if (model2.providerID !== autoProvider)
        delete record.agent.autoHeld;
      result = model2.providerID === autoProvider ? await this.runAuto(id, record, live, { ...run2, auto: true }, turn, abort.signal, input.id) : await this.runOn(id, record, live, model2, run2, turn, abort.signal, input.id);
    } catch (error) {
      result = { outcome: "failed", error: failure(error) };
    }
    const outcome = abort.signal.aborted ? "interrupted" : result.outcome;
    const before = record.messages[record.messages.length - 1]?.id;
    turn.finish(outcome, outcome === "interrupted" ? undefined : result.error);
    for (const child of [...live.subagents.values()])
      child.finish(outcome === "failed" ? "interrupted" : outcome);
    live.subagents.clear();
    if (live.last && live.last.seen === before)
      live.last.seen = record.messages[record.messages.length - 1]?.id;
    live.last = undefined;
    this.settleAsks(id, live);
    live.running = undefined;
    if (live.turn === turn)
      live.turn = undefined;
    this.next(id, outcome);
    if (!this.isRunning(id))
      this.closeWhenIdle(id, live);
  }
  closeWhenIdle(id, live) {
    clearTimeout(live.idle);
    live.idle = setTimeout(() => {
      if (this.isRunning(id) || this.live.get(id) !== live)
        return;
      for (const thread of live.threads.values())
        thread.close();
      live.threads.clear();
    }, timing.idleClose);
  }
  async runOn(id, record, live, model2, input, turn, signal, userMessage2) {
    const agent = this.agent(model2.providerID);
    if (!agent)
      return { outcome: "failed", error: { type: "agent", message: "This model's agent isn't available: sign in to it in Settings \u203A Accounts, or pick another model." } };
    if (signal.aborted)
      return { outcome: "interrupted" };
    const slots = this.slots(record);
    const slot = slots[model2.providerID] ??= { state: {} };
    let thread = live.threads.get(model2.providerID);
    if (!thread) {
      thread = agent.thread(record.session, slot.state);
      live.threads.set(model2.providerID, thread);
    }
    const hooks = this.hooks(id, live, turn, signal, slot, input.plan);
    turn.setModel(model2);
    let abandon;
    const abandoned = new Promise((resolve2) => abandon = () => resolve2({ outcome: "interrupted" }));
    const running = { provider: model2.providerID, thread, abandon };
    live.running = running;
    const from = record.messages.length;
    try {
      if (thread.prepare) {
        const prepared = await Promise.race([thread.prepare({ ...input, model: model2 }, hooks), abandoned.then(() => "abandoned")]);
        if (prepared === "abandoned")
          return { outcome: "interrupted" };
        if (prepared?.fresh)
          slot.seen = undefined;
      }
      if (signal.aborted)
        return { outcome: "interrupted" };
      const at = record.messages.findIndex((message) => message.id === userMessage2);
      const seenAt = slot.seen ? record.messages.findIndex((message) => message.id === slot.seen) : -1;
      const hasMessage = at >= 0 && seenAt >= at;
      const before = hasMessage ? [] : record.messages.slice(seenAt + 1, at < 0 ? undefined : at);
      const partway = at < 0 ? [] : record.messages.slice(Math.max(at, seenAt) + 1);
      const handed = handover(before, partway, (message) => this.stepName(message));
      const text = withHandover(hasMessage ? carryOn : input.text, handed);
      const files = hasMessage ? [] : input.files;
      const result = await Promise.race([thread.run({ ...input, model: model2, text, files }, turn, hooks), abandoned]);
      if (result.outcome !== "failed" || result.taken || record.messages.slice(from).some(didWork))
        slot.seen = record.messages[record.messages.length - 1]?.id;
      live.last = slot;
      return result;
    } catch (error) {
      thread.close();
      if (live.threads.get(model2.providerID) === thread)
        live.threads.delete(model2.providerID);
      throw error;
    } finally {
      if (live.running === running)
        live.running = undefined;
      this.store.save(id, true);
    }
  }
  async runAuto(id, record, live, input, turn, signal, userMessage2) {
    const heldBefore = new Set(Array.isArray(record.agent.autoHeld) ? record.agent.autoHeld : []);
    try {
      return await this.runAutoList(id, record, live, input, turn, signal, userMessage2, heldBefore);
    } finally {
      record.agent.autoHeld = this.auto.list().filter((entry) => this.auto.isHeld(entry)).map((entry) => Auto.modelKey(entry));
      this.store.save(id);
    }
  }
  async runAutoList(id, record, live, input, turn, signal, userMessage2, heldBefore) {
    const tried = new Set;
    let last2;
    let note;
    for (;; ) {
      if (signal.aborted)
        return { outcome: "interrupted" };
      const entry = await this.nextEntry(tried);
      if (signal.aborted)
        return { outcome: "interrupted" };
      if (!entry) {
        if (note)
          turn.notice(note);
        if (last2?.limit)
          return { outcome: "failed", error: { type: "limit", message: `Every model in your Auto list is at a usage limit for now${this.nextReset()}.` } };
        return last2 ?? { outcome: "failed", error: { type: "limit", message: `No model in your Auto list can run now: each is at a limit, or its agent isn't signed in${this.nextReset()}. Edit the list in Settings \u203A Auto.` } };
      }
      if (!tried.size && heldBefore.has(Auto.modelKey(entry)))
        turn.notice(`Back on ${this.entryName(entry)}: its limit has reset.`);
      tried.add(Auto.modelKey(entry));
      const model2 = { providerID: entry.providerID, id: entry.modelID, ...entry.variant ? { variant: entry.variant } : {} };
      if (note) {
        turn.stopTools("Stopped: going on with another model.");
        for (const child of live.subagents.values())
          child.finish("interrupted");
        live.subagents.clear();
        turn.notice(`${note} Going on with ${this.entryName(entry)}.`);
      }
      const from = record.messages.length;
      try {
        last2 = await this.runOn(id, record, live, model2, input, turn, signal, userMessage2);
      } catch (error) {
        if (signal.aborted || record.messages.slice(from).some(didWork))
          throw error;
        last2 = { outcome: "failed", error: failure(error) };
      }
      if (last2.outcome !== "failed" || signal.aborted)
        return last2;
      if (!last2.limit) {
        if (record.messages.slice(from).some(didWork))
          return last2;
        note = `${this.entryName(entry)} couldn't take it: ${last2.error?.message ?? "it stopped with an error"}`;
        continue;
      }
      this.auto.hold(entry, last2.limit);
      emit("kuvo.auto.updated", {});
      const whole = last2.limit.scope === "provider";
      note = `${this.entryName(entry, whole)} reached ${whole ? "its usage limit" : "this model's limit"}${last2.limit.resetsAt ? ` (it resets at ${resetTime(last2.limit.resetsAt)})` : ""}.`;
    }
  }
  async nextEntry(tried) {
    for (const entry of this.auto.list()) {
      if (tried.has(Auto.modelKey(entry)) || this.auto.isHeld(entry))
        continue;
      const agent = this.agent(entry.providerID);
      if (!agent)
        continue;
      const account = await Promise.race([agent.account().catch(() => {
        return;
      }), Bun.sleep(1e4).then(() => {
        return;
      })]);
      if (account && !account.signedIn)
        continue;
      if (agent.id === "engine") {
        const models = await agent.models().catch(() => []);
        if (models.length && !models.some((model2) => model2.id === entry.modelID))
          continue;
      }
      return entry;
    }
    return;
  }
  nextReset() {
    const known = this.auto.limits().filter((limit) => limit.known).map((limit) => limit.until);
    return known.length ? `; the first resets at ${resetTime(Math.min(...known))}` : "";
  }
  entryName(entry, agentOnly = false) {
    const name = this.agent(entry.providerID)?.name ?? entry.providerID;
    return agentOnly ? name : `${name} (${entry.modelID}${entry.variant ? `, ${entry.variant}` : ""})`;
  }
  stepName(message) {
    const agent = this.agent(message.model.providerID);
    return `${agent?.name ?? message.model.providerID}, ${message.model.id}`;
  }
  async interrupt(id, resume = false) {
    const live = this.live.get(id);
    if (!live?.turn || live.turn.isEnded) {
      if (resume)
        this.wake(id);
      return false;
    }
    const turn = live.turn;
    live.resume = resume;
    live.abort?.abort();
    this.settleAsks(id, live);
    const running = live.running;
    setTimeout(() => {
      if (turn.isEnded || !running || live.running !== running)
        return;
      running.thread.close();
      if (live.threads.get(running.provider) === running.thread)
        live.threads.delete(running.provider);
      running.abandon();
    }, timing.stopGrace);
    await running?.thread.interrupt().catch(() => {});
    return true;
  }
  settleAsks(id, live) {
    const directory = this.store.get(id)?.session.location.directory;
    for (const [requestID, pending] of live.permissions) {
      pending.resolve("reject");
      emit("permission.replied", { sessionID: id, requestID }, directory);
    }
    live.permissions.clear();
    for (const [formID, pending] of live.forms) {
      pending.resolve(null);
      emit("form.cancelled", { id: formID, sessionID: id }, directory);
    }
    live.forms.clear();
  }
  hooks(id, live, turn, signal, slot, plan) {
    const record = this.record(id);
    return {
      signal,
      state: slot.state,
      saveState: () => this.store.save(id, true),
      instructions: () => [
        ...Object.values(record.agent.kuvoInstructions ?? {}),
        live.agentPrompt ? `You work as the "${record.session.agent}" agent here. Its instructions:

${live.agentPrompt}` : ""
      ].filter(Boolean).join(`

`),
      approvesAll: () => !plan && !(record.session.permissions ?? []).some((rule) => rule.effect === "ask" || rule.effect === "deny") && !live.blocks.some((rule) => rule.effect === "deny"),
      permission: (ask) => this.askPermission(id, live, turn, ask, plan),
      question: (ask) => this.askQuestion(id, live, turn, ask),
      subagent: (toolCallID, task) => this.startSubagent(id, live, turn, toolCallID, task)
    };
  }
  startSubagent(id, live, parentTurn, toolCallID, task) {
    const parent = this.record(id).session;
    const directory = parent.location.directory;
    const now = Date.now();
    const model2 = parentTurn.currentModel;
    const before = task.sessionID ? this.store.get(task.sessionID) : undefined;
    if (before && before.session.parentID === id) {
      if (task.prompt)
        before.messages.push({ type: "user", id: newID("msg"), time: { created: now }, text: task.prompt });
      before.session.time.updated = now;
      this.store.save(before.session.id, true);
      return this.subagentRun(live, parentTurn, toolCallID, before.session);
    }
    const session = {
      id: newID("ses"),
      parentID: id,
      projectID: parent.projectID,
      agent: task.agent ?? parent.agent,
      model: model2,
      cost: 0,
      tokens: noTokens(),
      time: { created: now, updated: now },
      title: task.title || "A subagent's task",
      location: { directory },
      metadata: { kuvoAgent: parent.metadata?.kuvoAgent, kuvoSubagent: true }
    };
    this.store.add(session);
    const record = this.store.get(session.id);
    if (task.prompt)
      record.messages.push({ type: "user", id: newID("msg"), time: { created: now }, text: task.prompt });
    this.store.save(session.id, true);
    emit("session.created", { sessionID: session.id, session }, directory);
    return this.subagentRun(live, parentTurn, toolCallID, session);
  }
  subagentRun(live, parentTurn, toolCallID, session) {
    live.subagents.get(session.id)?.finish("succeeded");
    const turn = new Turn(this.store, session.id, session.location.directory, parentTurn.currentModel, session.agent ?? "build");
    live.subagents.set(session.id, turn);
    parentTurn.toolProgress(toolCallID, { sessionID: session.id });
    return {
      sessionID: session.id,
      turn,
      end: (outcome, error) => {
        turn.finish(outcome, error);
        if (live.subagents.get(session.id) === turn)
          live.subagents.delete(session.id);
      }
    };
  }
  askPermission(id, live, turn, ask, plan) {
    const session = this.record(id).session;
    if (ruled(live.blocks, ask.action, ask.resources) === "deny")
      return Promise.resolve("reject");
    if (plan && changes.has(ask.action))
      return Promise.resolve("reject");
    const effect = ask.weighed || readsSecrets(ask) ? ruled(session.permissions, ask.action, ask.resources) : evaluate(session.permissions, ask.action, ask.resources);
    if (effect === "deny")
      return Promise.resolve("reject");
    const allowedBefore = live.always.some((rule) => rule.action === ask.action && ask.resources.every((resource) => rule.patterns.some((pattern) => matches(pattern, resource))));
    if (effect === "allow" || allowedBefore)
      return Promise.resolve("once");
    if (turn.isEnded || live.abort?.signal.aborted)
      return Promise.resolve("reject");
    const request = {
      id: newID("per"),
      sessionID: id,
      action: ask.action,
      resources: ask.resources,
      save: ask.save ?? ask.resources,
      metadata: ask.metadata,
      message: ask.message
    };
    const step = ask.toolCallID ? turn.toolStep(ask.toolCallID) : undefined;
    if (ask.toolCallID && step)
      request.source = { type: "tool", messageID: step, id: ask.toolCallID };
    return new Promise((resolve2) => {
      live.permissions.set(request.id, {
        request,
        resolve: (decision) => {
          if (decision === "always")
            live.always.push({ action: ask.action, patterns: request.save ?? ask.resources });
          resolve2(decision);
        }
      });
      emit("permission.asked", request, session.location.directory);
    });
  }
  permissions(id) {
    this.record(id);
    return [...this.live.get(id)?.permissions.values() ?? []].map((pending) => pending.request);
  }
  replyPermission(id, requestID, decision) {
    const live = this.live.get(id);
    const pending = live?.permissions.get(requestID);
    if (!live || !pending)
      throw new NotFound("That request was answered already.");
    if (!["once", "always", "reject"].includes(decision))
      throw new BadRequest("Answer once, always or reject.");
    const directory = this.record(id).session.location.directory;
    live.permissions.delete(requestID);
    pending.resolve(decision);
    emit("permission.replied", { sessionID: id, requestID }, directory);
    if (decision !== "always")
      return;
    const patterns = pending.request.save ?? pending.request.resources;
    for (const [otherID, other] of [...live.permissions]) {
      const covered = other.request.action === pending.request.action && other.request.resources.every((resource) => patterns.some((pattern) => matches(pattern, resource)));
      if (!covered)
        continue;
      live.permissions.delete(otherID);
      other.resolve("once");
      emit("permission.replied", { sessionID: id, requestID: otherID }, directory);
    }
  }
  askQuestion(id, live, turn, ask) {
    const session = this.record(id).session;
    if (turn.isEnded || live.abort?.signal.aborted)
      return Promise.resolve(null);
    const form = { id: newID("frm"), sessionID: id, title: ask.title, metadata: { kind: "question" }, fields: ask.fields };
    return new Promise((resolve2) => {
      live.forms.set(form.id, { form, resolve: resolve2 });
      emit("form.created", { form }, session.location.directory);
    });
  }
  forms(id) {
    this.record(id);
    return [...this.live.get(id)?.forms.values() ?? []].map((pending) => pending.form);
  }
  replyForm(id, formID, answer) {
    const live = this.live.get(id);
    const pending = live?.forms.get(formID);
    if (!live || !pending)
      throw new NotFound("That question was answered already.");
    live.forms.delete(formID);
    pending.resolve(answer);
    emit(answer ? "form.replied" : "form.cancelled", { id: formID, sessionID: id }, this.record(id).session.location.directory);
  }
  closeAll() {
    for (const [id, live] of this.live) {
      live.resume = false;
      live.abort?.abort();
      this.settleAsks(id, live);
      live.turn?.finish("interrupted");
      for (const child of live.subagents.values())
        child.finish("interrupted");
      live.subagents.clear();
      for (const thread of live.threads.values())
        thread.close();
    }
  }
  forgetProvider(providerID2) {
    for (const live of this.live.values()) {
      const thread = live.threads.get(providerID2);
      if (!thread)
        continue;
      thread.close();
      live.threads.delete(providerID2);
    }
  }
}

class NotFound extends Error {
}

class BadRequest extends Error {
}
function mime(uri) {
  if (uri.startsWith("data:"))
    return uri.slice(5).split(/[;,]/)[0] || "text/plain";
  const extension = uri.split("?")[0].split(".").pop()?.toLowerCase() ?? "";
  return {
    png: "image/png",
    jpg: "image/jpeg",
    jpeg: "image/jpeg",
    gif: "image/gif",
    webp: "image/webp",
    heic: "image/heic",
    pdf: "application/pdf",
    txt: "text/plain",
    md: "text/markdown",
    json: "application/json"
  }[extension] ?? "application/octet-stream";
}
function promptFile(file) {
  const type = mime(file.uri);
  if (file.uri.startsWith("data:")) {
    const comma = file.uri.indexOf(",");
    const isBase64 = file.uri.slice(0, comma).endsWith(";base64");
    const payload = file.uri.slice(comma + 1);
    return { uri: file.uri, mime: type, name: file.name, data: isBase64 ? payload : Buffer.from(decodeURIComponent(payload)).toString("base64") };
  }
  let path;
  try {
    path = file.uri.startsWith("file:") ? fileURLToPath(file.uri) : undefined;
  } catch {}
  return { uri: file.uri, mime: type, name: file.name, path };
}

// Agents/src/server.ts
var attempts = new Map;
function cancelSignIns() {
  for (const pending of attempts.values())
    pending.attempt.cancel();
  attempts.clear();
}
setInterval(() => {
  for (const [id, pending] of attempts) {
    if (Date.now() < pending.expires + 60000)
      continue;
    pending.attempt.cancel();
    attempts.delete(id);
  }
}, 60000).unref?.();
var json = (value, status = 200) => new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
var located = (value) => json({ location: { directory: process.cwd() }, data: value });
var error = (status, message) => json({ message }, status);
var lastSeen = new Map;
var lastMaintained = new Map;
async function maintainedSoon(agent, fresh) {
  if (!agent.maintenance)
    return;
  let answered = false;
  const asked = agent.maintenance(fresh).then((value2) => {
    const changed = JSON.stringify(lastMaintained.get(agent.providerID)) !== JSON.stringify(value2);
    lastMaintained.set(agent.providerID, value2);
    if (answered && changed)
      emit("integration.updated", { integrationID: agent.providerID });
    return value2;
  }, () => lastMaintained.get(agent.providerID));
  const value = await Promise.race([asked, Bun.sleep(2000).then(() => lastMaintained.get(agent.providerID))]);
  answered = true;
  return value;
}
async function integration(agent, fresh = false) {
  const [account, maintained] = await Promise.all([
    agent.account(fresh).catch((error2) => ({ installed: false, signedIn: false, message: String(error2?.message ?? error2) })),
    maintainedSoon(agent, fresh)
  ]);
  const seen = JSON.stringify([account.installed, account.signedIn, account.label]);
  const before = lastSeen.get(agent.providerID);
  lastSeen.set(agent.providerID, seen);
  if (before !== undefined && before !== seen) {
    agent.forgetModels?.();
    emit("integration.updated", { integrationID: agent.providerID });
  }
  return {
    id: agent.providerID,
    name: agent.name,
    metadata: {
      source: "agent",
      agent: agent.id,
      accountID: agent.instance.id,
      accountLabel: agent.instance.label,
      installed: account.installed,
      message: account.message,
      signInEnded: account.ended ?? false,
      account: account.label,
      install: agent.install,
      signsOut: Boolean(agent.signOut),
      version: maintained?.installed,
      latestVersion: maintained?.latest,
      outdated: maintained ? isOutdated(maintained) : false,
      updateCommand: maintained?.shown,
      updates: Boolean(agent.update && maintained?.command)
    },
    methods: agent.methods(),
    connections: account.signedIn ? [{ type: "agent", label: account.label, method: "oauth", status: { status: "connected", message: account.label ? `Signed in as ${account.label}` : "Signed in" } }] : []
  };
}
async function models(agents) {
  const lists = await Promise.all(agents.map(async (agent) => {
    try {
      const account = await agent.account();
      return account.signedIn ? await agent.models() : [];
    } catch {
      return [];
    }
  }));
  return lists.flat();
}
function page(items2, url) {
  const limit = Number(url.searchParams.get("limit") ?? 100) || 100;
  const cursor = url.searchParams.get("cursor");
  let start = 0;
  if (cursor) {
    const after = cursor.split(":")[1];
    const index = items2.findIndex((item) => item.id === after);
    start = index >= 0 ? index + 1 : items2.length;
  }
  const data = items2.slice(start, start + limit);
  const order = cursor?.split(":", 1)[0] ?? url.searchParams.get("order") ?? "desc";
  const filter = url.searchParams.get("parentID") ?? cursor?.split(":")[2];
  const next = start + limit < items2.length && data.length ? `${order}:${data[data.length - 1].id}${filter ? `:${filter}` : ""}` : undefined;
  return { data, cursor: { next } };
}
function handler(context) {
  const expected = "Basic " + Buffer.from(`opencode:${context.password}`).toString("base64");
  const { sessions, roster, auto, link } = context;
  const agentFor = (id) => roster.find(id);
  return async (request) => {
    if (request.headers.get("authorization") !== expected)
      return error(401, "Unauthorized");
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean).map(decodeURIComponent);
    const method = request.method;
    const body = async () => request.headers.get("content-type")?.includes("json") ? await request.json().catch(() => ({})) : {};
    try {
      if (parts[0] !== "api")
        return error(404, "Not found");
      const [, area, a, b, c, d, e] = parts;
      if (area === "info")
        return json({ version: context.version, pid: process.pid });
      if (area === "event")
        return feed();
      if (area === "integration") {
        if (!a) {
          const fresh = url.searchParams.get("fresh") === "1";
          if (fresh)
            await refreshLoginPath();
          return located(await Promise.all(roster.all().map((agent2) => integration(agent2, fresh))));
        }
        const agent = agentFor(a);
        if (!agent)
          return error(404, `No agent ${a}.`);
        if (!b)
          return located(await integration(agent, true));
        if (b === "connect" && c === "oauth") {
          if (!d && method === "POST") {
            const { methodID } = await body();
            if (!agent.signIn)
              return error(400, `${agent.name} signs in another way.`);
            const attempt = await agent.signIn(methodID);
            const id = newID("att");
            const created = Date.now();
            const expires = created + 30 * 60000;
            attempts.set(id, { agent, attempt, created, expires });
            return located({ attemptID: id, url: attempt.url, instructions: attempt.instructions, mode: attempt.mode, acceptsCode: attempt.acceptsCode || undefined, time: { created, expires } });
          }
          const pending = d ? attempts.get(d) : undefined;
          if (!pending)
            return error(404, "That sign-in is over. Start it again.");
          if (method === "GET" && !e) {
            const expired = Date.now() > pending.expires;
            const status = expired ? { status: "expired" } : pending.attempt.status();
            if (expired)
              pending.attempt.cancel();
            if (status.status !== "pending")
              attempts.delete(d);
            return located(status);
          }
          if (method === "POST" && e === "complete") {
            const { code } = await body();
            if (!pending.attempt.complete)
              return error(400, "This sign-in finishes in the browser.");
            await pending.attempt.complete(String(code ?? ""));
            return json({});
          }
          if (method === "DELETE") {
            pending.attempt.cancel();
            attempts.delete(d);
            return json({});
          }
        }
        if (b === "connect" && c === "key" && method === "POST") {
          const { key } = await body();
          if (!agent.signInWithKey)
            return error(400, `${agent.name} doesn't take a key here.`);
          await agent.signInWithKey(String(key ?? "").trim());
          return json({});
        }
        if (b === "update" && method === "POST") {
          if (!agent.update)
            return error(400, `Update ${agent.name} the way you installed it.`);
          const result = await agent.update();
          if (result.updated) {
            for (const each of roster.all())
              if (each.id === agent.id)
                each.programUpdated?.();
            emit("integration.updated", { integrationID: agent.providerID });
            emit("model.updated", {});
          }
          return json({ data: result });
        }
        if (b === "disconnect" && method === "POST") {
          if (!agent.signOut)
            return error(400, `Sign out of ${agent.name} where you signed in.`);
          await agent.signOut();
          return json({});
        }
      }
      if (area === "model") {
        if (a === "default")
          return located(null);
        return located(await models(roster.all()));
      }
      if (area === "agent" || area === "command" || area === "skill" || area === "mcp")
        return located([]);
      if (area === "provider")
        return located([]);
      if (area === "session") {
        if (!a) {
          if (method === "POST")
            return json({ data: sessions.create(await body()) });
          const directory = url.searchParams.get("directory") ?? undefined;
          const under = url.searchParams.get("parentID") ?? url.searchParams.get("cursor")?.split(":")[2] ?? null;
          const roots = sessions.list(directory, under === null || under === "" ? undefined : under === "null" ? null : under);
          const ordered = url.searchParams.get("cursor")?.startsWith("asc") || url.searchParams.get("order") === "asc" ? [...roots].reverse() : roots;
          return json(page(ordered, url));
        }
        if (a === "active")
          return json({ data: Object.fromEntries(sessions.active().map((id2) => [id2, { type: "busy" }])) });
        const id = a;
        if (!b) {
          if (method === "GET")
            return json({ data: sessions.get(id) });
          if (method === "PATCH") {
            sessions.update(id, await body());
            return json({ data: sessions.get(id) });
          }
          if (method === "DELETE") {
            await sessions.remove(id);
            return json({});
          }
        }
        switch (b) {
          case "message": {
            const messages = sessions.messages(id);
            const asc = url.searchParams.get("order") === "asc" || url.searchParams.get("cursor")?.startsWith("asc");
            const ordered = asc ? messages : [...messages].reverse();
            if (c) {
              const found = messages.find((message) => message.id === c);
              return found ? json({ data: found }) : error(404, "No such message.");
            }
            return json(page(ordered, url));
          }
          case "inbox":
            if (method === "DELETE" && c) {
              sessions.cancelInput(id, c);
              return json({});
            }
            if (method === "PATCH" && c) {
              sessions.setDelivery(id, c, (await body()).delivery);
              return json({});
            }
            return json({ data: sessions.inbox(id) });
          case "prompt": {
            const input = await body();
            sessions.prompt(id, { id: input.id ?? newID("msg"), text: String(input.text ?? ""), files: input.files ?? [], delivery: input.delivery ?? "steer" });
            return json({});
          }
          case "fork":
            return json({ data: sessions.fork(id, String((await body()).before ?? "")) });
          case "revert":
            if (c === "stage" && method === "POST")
              return json({ data: await sessions.stageRevert(id, String((await body()).messageID ?? "")) });
            if (!c && method === "DELETE") {
              await sessions.clearRevert(id);
              return json({});
            }
            break;
          case "shell":
            if (method !== "POST")
              break;
            sessions.runShell(id, String((await body()).command ?? ""));
            return json({});
          case "synthetic": {
            const input = await body();
            sessions.synthetic(id, String(input.text ?? ""), typeof input.description === "string" ? input.description : undefined);
            return json({});
          }
          case "command": {
            const input = await body();
            const name = String(input.name ?? "");
            const written = String(input.text ?? "");
            const template = name ? await link.commandTemplate(name, sessions.get(id).location.directory) : undefined;
            const text = template ? expandCommand(template, written) : `/${name} ${written}`.trim();
            sessions.prompt(id, { id: newID("msg"), text, files: input.files ?? [], delivery: input.delivery ?? "steer" });
            return json({});
          }
          case "interrupt":
            return json({ interrupted: await sessions.interrupt(id, url.searchParams.get("resume") === "true") });
          case "model":
            sessions.selectModel(id, (await body()).model);
            return json({});
          case "agent":
            sessions.selectAgent(id, (await body()).agent);
            return json({});
          case "permission":
            if (!c)
              return json({ data: id === "global" ? [] : sessions.permissions(id) });
            if (d === "reply") {
              const { decision } = await body();
              sessions.replyPermission(id, c, decision);
              return json({});
            }
            break;
          case "form":
            if (!c)
              return json({ data: id === "global" ? [] : sessions.forms(id) });
            if (d === "reply") {
              sessions.replyForm(id, c, (await body()).answer ?? {});
              return json({});
            }
            if (method === "DELETE") {
              sessions.replyForm(id, c, null);
              return json({});
            }
            break;
          case "view": {
            const { idle } = await body();
            sessions.view(id, Number(idle) || Date.now());
            return json({});
          }
          case "diff":
            return json({ data: [] });
        }
      }
      if (area === "kuvo" && a === "accounts") {
        if (method === "POST" && !b) {
          const { agent, label } = await body();
          if (!kinds.includes(agent))
            return error(400, "That isn't one of the coding agents.");
          const record = roster.accounts.add(agent, label);
          roster.sync();
          const added = roster.all().find((each) => each.instance.id === record.id && each.id === agent);
          emit("integration.updated", { integrationID: added.providerID });
          return json({ data: { providerID: added.providerID } });
        }
        const target = b ? roster.find(b) : undefined;
        if (!target)
          return error(404, "No such account.");
        if (target.instance.id === "default")
          return error(400, "That's the agent's own sign-in: sign out of it where you signed in.");
        if (method === "PATCH") {
          roster.accounts.rename(target.providerID, (await body()).label);
          roster.sync();
          emit("integration.updated", { integrationID: target.providerID });
          return json({});
        }
        if (method === "DELETE") {
          sessions.forgetProvider(target.providerID);
          await target.removeAccount?.().catch(() => {});
          target.shutdown?.();
          roster.accounts.remove(target.providerID);
          roster.sync();
          emit("integration.updated", { integrationID: target.providerID });
          emit("model.updated", {});
          return json({});
        }
      }
      if (area === "kuvo" && a === "tools" && method === "PUT") {
        const { url: address, token, timeout } = await body();
        setToolServer(typeof address === "string" && address && typeof token === "string" ? { url: address, token, timeout: Number(timeout) || 960000 } : undefined);
        return json({});
      }
      if (area === "kuvo" && a === "engine" && method === "PUT") {
        const { url: address, password } = await body();
        link.configure(typeof address === "string" && address ? address : undefined, typeof password === "string" ? password : undefined);
        return json({});
      }
      if (area === "kuvo" && a === "auto") {
        if (b === "limits" && method === "DELETE") {
          auto.clearLimits();
          emit("kuvo.auto.updated", {});
          return json({});
        }
        if (!b && method === "PUT") {
          const { entries } = await body();
          if (!Array.isArray(entries))
            return error(400, "Send the list as entries.");
          auto.set(entries);
          emit("kuvo.auto.updated", {});
        }
        if (!b && (method === "GET" || method === "PUT"))
          return json({ data: { entries: auto.list(), limits: auto.limits() } });
      }
      if (area === "experimental" && a === "session" && b) {
        const id = b;
        if (c === "instructions" && d === "entries" && e) {
          sessions.setInstruction(id, e, method === "DELETE" ? undefined : String((await body()).value ?? ""));
          return json({});
        }
        if (c === "wait") {
          while (sessions.active().includes(id))
            await Bun.sleep(200);
          return json({});
        }
      }
      return error(404, "Not available for this agent.");
    } catch (caught) {
      if (caught instanceof NotFound)
        return error(404, caught.message);
      if (caught instanceof BadRequest)
        return error(400, caught.message);
      return error(500, caught instanceof Error ? caught.message : String(caught));
    }
  };
}
function expandCommand(template, written) {
  const words = written.trim() ? written.trim().split(/\s+/) : [];
  const named = /\$ARGUMENTS|\$\d/.test(template);
  const filled = template.replace(/\$ARGUMENTS/g, written.trim()).replace(/\$(\d)/g, (_, index) => words[Number(index) - 1] ?? "");
  return named || !written.trim() ? filled.trim() : `${filled.trim()}

${written.trim()}`;
}

// Agents/src/store.ts
import { mkdirSync as mkdirSync10, readdirSync as readdirSync3, readFileSync as readFileSync9, renameSync as renameSync4, rmSync as rmSync7, writeFileSync as writeFileSync7 } from "fs";
import { join as join13 } from "path";

class Store {
  root;
  records = new Map;
  pending = new Map;
  constructor(root) {
    this.root = root;
    mkdirSync10(root, { recursive: true });
    for (const id of readdirSync3(root)) {
      try {
        const folder = join13(root, id);
        const session = JSON.parse(readFileSync9(join13(folder, "session.json"), "utf8"));
        let messages = [];
        try {
          messages = JSON.parse(readFileSync9(join13(folder, "messages.json"), "utf8"));
        } catch {}
        let agent = {};
        try {
          agent = JSON.parse(readFileSync9(join13(folder, "agent.json"), "utf8"));
        } catch {}
        this.records.set(session.id, { session, messages, agent });
      } catch {}
    }
  }
  all() {
    return [...this.records.values()].map((record) => record.session);
  }
  get(id) {
    return this.records.get(id);
  }
  add(session) {
    this.records.set(session.id, { session, messages: [], agent: {} });
    this.save(session.id, true);
  }
  remove(id) {
    this.records.delete(id);
    clearTimeout(this.pending.get(id));
    this.pending.delete(id);
    rmSync7(join13(this.root, id), { recursive: true, force: true });
  }
  save(id, now = false) {
    clearTimeout(this.pending.get(id));
    if (now) {
      this.pending.delete(id);
      this.write(id);
      return;
    }
    this.pending.set(id, setTimeout(() => {
      this.pending.delete(id);
      this.write(id);
    }, 500));
  }
  flush() {
    for (const id of [...this.pending.keys()])
      this.save(id, true);
  }
  write(id) {
    const record = this.records.get(id);
    if (!record)
      return;
    const folder = join13(this.root, id);
    mkdirSync10(folder, { recursive: true });
    for (const [name, value] of [
      ["session.json", record.session],
      ["messages.json", record.messages],
      ["agent.json", record.agent]
    ]) {
      const file = join13(folder, name);
      writeFileSync7(file + ".new", JSON.stringify(value));
      renameSync4(file + ".new", file);
    }
  }
}

// Agents/src/main.ts
var version2 = "1";
var home = process.env.KUVO_AGENTS_HOME;
var password = process.env.OPENCODE_PASSWORD;
if (!home || !password) {
  console.error("KUVO_AGENTS_HOME and OPENCODE_PASSWORD are needed.");
  process.exit(2);
}
var temporary = process.env.TMPDIR?.replace(/\/$/, "") || join14(home, "tmp");
mkdirSync11(temporary, { recursive: true });
rmSync8(join14(temporary, "antigravity"), { recursive: true, force: true });
try {
  for (const name of readdirSync4(join14(home, "antigravity")))
    if (name.startsWith(".install-"))
      rmSync8(join14(home, "antigravity", name), { recursive: true, force: true });
} catch {}
delete process.env.BUN_BE_BUN;
delete process.env.OPENCODE_PASSWORD;
process.on("unhandledRejection", (reason2) => console.error("unhandled:", reason2));
var deps = new Deps(join14(home, "runtime"), join14(home, "cache"));
var context = { home, temporary, deps };
var roster = new Roster(new Accounts(home), context);
var store = new Store(join14(home, "sessions"));
var auto = new Auto(home);
var link = new EngineLink;
var engineAgents = new Map;
function engineAgent(providerID2) {
  if (!link.ready || parseProvider(providerID2))
    return;
  let agent = engineAgents.get(providerID2);
  if (!agent)
    engineAgents.set(providerID2, agent = new EngineAgent(link, providerID2));
  return agent;
}
var sessions = new Sessions(store, roster, auto, engineAgent, (directory) => link.policies(directory), (name, directory) => link.agentPrompt(name, directory), new Snapshots(join14(home, "snapshots")));
var server2 = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  idleTimeout: 0,
  fetch: handler({ roster, sessions, auto, link, password, version: version2 })
});
console.log(JSON.stringify({ url: `http://127.0.0.1:${server2.port}` }));
var stopping = false;
function stop() {
  if (stopping)
    return;
  stopping = true;
  cancelSignIns();
  sessions.closeAll();
  store.flush();
  server2.stop(true);
  process.exit(0);
}
process.stdin.on("end", stop);
process.stdin.on("close", stop);
process.stdin.resume();
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
