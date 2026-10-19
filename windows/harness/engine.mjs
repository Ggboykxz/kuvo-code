// A client for one running opencode engine, the calls a conversation view needs.
// The routes and payloads mirror Packages/OpenCodeKit's OpenCodeAPI (the Mac app's
// reference client): same auth, same `x-opencode-directory` scoping, same shapes.

export class EngineError extends Error {
  constructor(message, { status, body } = {}) {
    super(message);
    this.name = "EngineError";
    this.status = status;
    this.body = body;
  }
}

/// `msg_…`, ascending, as the Mac app's Identifier makes them: what a prompt's id looks like.
const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
function base62(value) {
  let text = "";
  let rest = value;
  while (rest > 0n) {
    text = alphabet[Number(rest % 62n)] + text;
    rest /= 62n;
  }
  return text;
}

let lastID = null;
export function messageID(now = Date.now()) {
  const stamp = BigInt(now);
  const counter = lastID?.stamp === stamp ? lastID.counter + 1n : 1n;
  lastID = { stamp, counter };
  return `msg_${base62(stamp).padStart(8, "0")}${base62(counter).padStart(2, "0")}`;
}

export class EngineClient {
  constructor({ url, password, fetch: doFetch = fetch }) {
    this.url = url.endsWith("/") ? url : `${url}/`;
    this.password = password;
    this.fetch = doFetch;
  }

  get authorization() {
    return `Basic ${Buffer.from(`opencode:${this.password}`).toString("base64")}`;
  }

  route(path, query) {
    const url = new URL(path, this.url);
    for (const [key, value] of Object.entries(query ?? {})) {
      if (value !== undefined && value !== null) url.searchParams.set(key, String(value));
    }
    return url;
  }

  async request(method, path, { query, body, directory } = {}) {
    const headers = { authorization: this.authorization };
    if (body !== undefined) headers["content-type"] = "application/json";
    // Calls that take a folder carry it here, encoded as the Mac app encodes it: a Windows
    // path can hold characters a header can't.
    if (directory) headers["x-opencode-directory"] = encodeURIComponent(directory);
    const response = await this.fetch(this.route(path, query), {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    if (!response.ok) {
      let message = `The engine refused (HTTP ${response.status}).`;
      try {
        const parsed = JSON.parse(text);
        message = parsed.message ?? parsed.error?.message ?? parsed.error ?? message;
      } catch {
        if (text.trim() !== "") message = text.trim().slice(0, 500);
      }
      throw new EngineError(typeof message === "string" ? message : String(message), { status: response.status, body: text });
    }
    if (text.trim() === "") return null;
    return JSON.parse(text);
  }

  // ---- What the view asks for ----

  async info() {
    return this.request("GET", "api/info");
  }

  async sessions({ directory, limit = 100 } = {}) {
    const page = await this.request("GET", "api/session", { query: { limit, order: "desc", parentID: "null", directory } });
    return page.data ?? [];
  }

  async session(id) {
    return (await this.request("GET", `api/session/${encodeURIComponent(id)}`)).data;
  }

  async createSession({ directory, title, agent, model }) {
    const body = { location: { directory } };
    if (title) body.title = title;
    if (agent) body.agent = agent;
    if (model) body.model = model;
    return (await this.request("POST", "api/session", { body })).data;
  }

  async deleteSession(id) {
    await this.request("DELETE", `api/session/${encodeURIComponent(id)}`);
  }

  async activeSessions() {
    return Object.keys((await this.request("GET", "api/session/active")).data ?? {});
  }

  async messages(id, { limit = 200, order = "asc" } = {}) {
    const page = await this.request("GET", `api/session/${encodeURIComponent(id)}/message`, { query: { limit, order } });
    return page.data ?? [];
  }

  async permissions(session) {
    return (await this.request("GET", `api/session/${encodeURIComponent(session)}/permission`)).data ?? [];
  }

  async replyPermission({ session, permission, decision, message }) {
    const body = { decision };
    if (message) body.message = message;
    await this.request("POST", `api/session/${encodeURIComponent(session)}/permission/${encodeURIComponent(permission)}/reply`, { body });
  }

  /// Sends a message. Returns once the engine has it queued; the reply arrives as events.
  async prompt({ session, id = messageID(), text, files, delivery = "steer" }) {
    const body = { id, text, delivery };
    if (files?.length) body.files = files;
    await this.request("POST", `api/session/${encodeURIComponent(session)}/prompt`, { body });
    return id;
  }

  async interrupt(session, { resume = false } = {}) {
    await this.request("POST", `api/session/${encodeURIComponent(session)}/interrupt`, { query: { resume: resume ? "true" : undefined } });
  }

  async setModel(session, model) {
    await this.request("POST", `api/session/${encodeURIComponent(session)}/model`, { body: { model } });
  }

  async renameSession(session, title) {
    await this.request("PATCH", `api/session/${encodeURIComponent(session)}`, { body: { title } });
  }

  async forkSession(session, { before } = {}) {
    return (await this.request("POST", `api/session/${encodeURIComponent(session)}/fork`, { body: { before } })).data;
  }

  async selectAgent(session, agent) {
    await this.request("POST", `api/session/${encodeURIComponent(session)}/agent`, { body: { agent } });
  }

  async runCommand({ session, name, text, delivery }) {
    const body = { name, text };
    if (delivery) body.delivery = delivery;
    await this.request("POST", `api/session/${encodeURIComponent(session)}/command`, { body });
  }

  async commands(directory) {
    return (await this.request("GET", "api/command", { directory })).data ?? [];
  }

  // ---- The rest of the engine's surface the harness knows but hadn't used ----

  /// The folder's VCS: provider and current branch, shown in the header like the Mac app's.
  async vcs(directory) {
    return (await this.request("GET", "api/vcs", { directory })).data;
  }

  /// The files this session changed, as patches.
  async sessionDiff(session) {
    return (await this.request("GET", `api/session/${encodeURIComponent(session)}/diff`)).data ?? [];
  }

  /// The session's waiting messages, with their steering mode.
  async inbox(session) {
    return (await this.request("GET", `api/session/${encodeURIComponent(session)}/inbox`)).data ?? [];
  }

  async setDelivery(session, item, delivery) {
    await this.request("PATCH", `api/session/${encodeURIComponent(session)}/inbox/${encodeURIComponent(item)}`, { body: { delivery } });
  }

  async cancelInbox(session, item) {
    await this.request("DELETE", `api/session/${encodeURIComponent(session)}/inbox/${encodeURIComponent(item)}`);
  }

  /// Squeezes the conversation into a summary when it nears the context window.
  async compact(session) {
    await this.request("POST", `api/session/${encodeURIComponent(session)}/compact`, { body: {} });
  }

  /// Marks the session read up to its last run (the unread badge's source).
  async markViewed(session, idle) {
    await this.request("POST", `api/session/${encodeURIComponent(session)}/view`, { body: { idle } });
  }

  async savedPermissions() {
    return (await this.request("GET", "api/permission/saved")).data ?? [];
  }

  async removeSavedPermission(id) {
    await this.request("DELETE", `api/permission/saved/${encodeURIComponent(id)}`);
  }

  /// The engine's own read-only lists for the settings page.
  async skills(directory) {
    return (await this.request("GET", "api/skill", { directory })).data ?? [];
  }

  async mcpServers(directory) {
    return (await this.request("GET", "api/mcp", { directory })).data ?? [];
  }

  async providers(directory) {
    return (await this.request("GET", "api/provider", { directory })).data ?? [];
  }

  async defaultModel(directory) {
    return (await this.request("GET", "api/model/default", { directory })).data;
  }

  /// The engine's whole settings, merged live from every source it reads.
  async configSources(directory) {
    return await this.request("GET", "api/config", { directory });
  }

  /// Connects one again ("Try Again" on a failed server).
  async mcpConnect(name, directory) {
    await this.request("POST", `api/experimental/mcp/${encodeURIComponent(name)}/connect`, { directory, body: {} });
  }

  /// Lets go of one ("Try Again" never comes back from this).
  async mcpDisconnect(name) {
    await this.request("POST", `api/experimental/mcp/${encodeURIComponent(name)}/disconnect`, { body: {} });
  }

  /// The models usable in a folder (an engine's list can differ per project).
  async models(directory) {
    return (await this.request("GET", "api/model", { directory })).data ?? [];
  }

  /// The agents usable in a folder (the ones a person picks between, and the rest).
  async agents(directory) {
    return (await this.request("GET", "api/agent", { directory })).data ?? [];
  }

  // ---- Events ----

  /// `GET /api/event`, as parsed events, until the signal says stop or the stream ends.
  /// Frames are SSE: `data:` lines (several join with newlines), `:` comments are keep-alives.
  async *events(signal) {
    const response = await this.fetch(this.route("api/event"), { headers: { authorization: this.authorization, accept: "text/event-stream" }, signal });
    if (!response.ok) throw new EngineError(`The engine's event stream refused (HTTP ${response.status}).`, { status: response.status });
    if (!response.body) throw new EngineError("The engine's event stream had no body.");

    const decoder = new TextDecoder();
    let buffer = "";
    for await (const chunk of response.body) {
      buffer += decoder.decode(chunk, { stream: true });
      let boundary;
      while ((boundary = buffer.indexOf("\n\n")) >= 0) {
        const frame = buffer.slice(0, boundary);
        buffer = buffer.slice(boundary + 2);
        const data = frame
          .split("\n")
          .filter(line => line.startsWith("data:"))
          .map(line => line.slice("data:".length).trimStart())
          .join("\n");
        if (data.trim() === "") continue;
        try {
          yield JSON.parse(data);
        } catch {
          // A frame this version can't read: skip it rather than end the stream.
        }
      }
    }
  }
}
