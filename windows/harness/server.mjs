#!/usr/bin/env node
// The harness: the pinned engine on this machine, and what a browser page in front of it
// asks for. It supervises the engine itself (windows/kuvo-engine.mjs: install, checksum,
// launch, stop) and serves a small conversation view (ui/) over its HTTP API — the same
// routes and shapes Packages/OpenCodeKit talks to on the Mac.
//
//   node windows/harness/server.mjs [--project <folder>] [--port <port>]
//
// The engine's password stays in here; the page never sees it.

import fs from "node:fs";
import http from "node:http";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { EngineClient, EngineError } from "./engine.mjs";
import { install, launch } from "../kuvo-engine.mjs";

// Packed into an executable (build-exe.mjs), the page's files live inside the binary rather
// than next to it, and node:sea is how they're read back. Beside the source they are files.
const sea = (() => {
  // `require` exists inside the bundled (CommonJS) binary; in source form it doesn't.
  try { return require("node:sea"); } catch { /* source form */ }
  try { return createRequire(import.meta.url)("node:sea"); } catch { /* no SEA (Node < 20.6) */ }
  return null;
})();
// `here` is only needed to read the page from disk, which the packed form never does.
const here = sea?.isSea?.()
  ? process.cwd()
  : path.dirname(fileURLToPath(import.meta.url));
const packed = (name) => {
  if (!sea?.isSea()) return null;
  try {
    return sea.getAsset(name, "utf8");
  } catch {
    return null;
  }
};

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

/// The engine as the harness runs it: the pinned build, started the Mac app's way.
async function defaultClientFor({ binary, log }) {
  const executable = binary ?? await install({ log });
  const engine = await launch({ binary: executable, log });
  const client = new EngineClient({ url: engine.url, password: engine.password });
  const info = await client.info().catch(error => ({ version: null, error: error.message }));
  return { client, version: info.version ?? null, stop: engine.stop };
}

const MIME = {
  html: "text/html; charset=utf-8",
  js: "text/javascript; charset=utf-8",
  mjs: "text/javascript; charset=utf-8",
  css: "text/css; charset=utf-8",
  json: "application/json; charset=utf-8",
  png: "image/png",
  ico: "image/x-icon",
  svg: "image/svg+xml",
  woff2: "font/woff2",
  txt: "text/plain; charset=utf-8",
  md: "text/plain; charset=utf-8",
};

export function startHarness({ project = null, port = Number(process.env.KUVO_HARNESS_PORT ?? 4620), binary = process.env.KUVO_OPENCODE_BINARY ?? null, clientFor = defaultClientFor, log = () => {} } = {}) {
  let currentProject = project === null ? null : path.resolve(project);
  let engine = null;
  let starting = null;
  const state = () => ({
    project: currentProject,
    engine: engine === null
      ? (starting === null ? { status: "stopped" } : { status: "starting" })
      : { status: "running", version: engine.version },
  });

  // One engine, started on first need, kept for the server's lifetime. A start that
  // fails fails the request that asked for it; the next one tries again.
  async function ensureEngine() {
    if (engine) return engine;
    if (starting) return starting;
    log("starting the engine…");
    starting = clientFor({ binary, log })
      .then(made => {
        engine = made;
        log(made.version ? `engine ${made.version} is up` : "engine is up");
        return made;
      })
      .finally(() => {
        starting = null;
      });
    return starting;
  }

  async function readBody(request) {
    let text = "";
    for await (const chunk of request) {
      text += chunk;
      if (text.length > 1 << 20) throw new HttpError(413, "That body is too large.");
    }
    if (text.trim() === "") return {};
    try {
      return JSON.parse(text);
    } catch {
      throw new HttpError(400, "That body isn't JSON.");
    }
  }

  function directoryOf(candidate) {
    if (!candidate) throw new HttpError(400, "No folder was given.");
    const folder = path.resolve(candidate);
    let stats;
    try {
      stats = fs.statSync(folder);
    } catch {
      throw new HttpError(400, `There's no such folder: ${folder}`);
    }
    if (!stats.isDirectory()) throw new HttpError(400, `That's not a folder: ${folder}`);
    return folder;
  }

  async function api(request, response, url) {
    const route = (pattern) => url.pathname.match(pattern)?.slice(1).map(decodeURIComponent) ?? null;
    const json = (what) => {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(what));
    };

    if (url.pathname === "/api/state" && request.method === "GET") return json(state());

    if (url.pathname === "/api/project" && request.method === "POST") {
      const body = await readBody(request);
      currentProject = directoryOf(body.directory);
      return json({ project: currentProject });
    }

    // The page's folder picker: what's under a folder, so someone can walk to theirs.
    if (url.pathname === "/api/browse" && request.method === "GET") {
      const asked = url.searchParams.get("path");
      const folder = asked ? path.resolve(asked) : currentProject ?? os.homedir();
      let folders = [];
      try {
        folders = fs.readdirSync(folder, { withFileTypes: true })
          .filter(entry => entry.isDirectory() && !entry.name.startsWith("."))
          .map(entry => ({ name: entry.name, path: path.join(folder, entry.name) }))
          .sort((a, b) => a.name.localeCompare(b.name))
          .slice(0, 500);
      } catch {
        folders = [];
      }
      const parent = path.dirname(folder);
      return json({ path: folder, parent: parent === folder ? null : parent, folders });
    }

    if (url.pathname === "/api/sessions" && request.method === "GET") {
      const directory = url.searchParams.get("directory") ?? currentProject;
      if (!directory) return json({ sessions: [] });
      const { client } = await ensureEngine();
      return json({ sessions: await client.sessions({ directory }) });
    }

  // Files: read and write within the project. No engine needed.
  if (url.pathname === "/api/file" && request.method === "GET") {
    const asked = url.searchParams.get("path");
    if (!asked) throw new HttpError(400, "No file was given.");
    const resolved = path.resolve(asked);
    if (currentProject && resolved !== currentProject && !resolved.startsWith(currentProject + path.sep)) {
      throw new HttpError(403, "That file is outside the project.");
    }
    let content;
    try { content = fs.readFileSync(resolved, "utf8"); }
    catch { throw new HttpError(404, "There's no such file."); }
    return json({ path: resolved, content });
  }
  if (url.pathname === "/api/file" && request.method === "POST") {
    const body = await readBody(request);
    if (!body.path) throw new HttpError(400, "No file was given.");
    const resolved = path.resolve(body.path);
    if (currentProject && resolved !== currentProject && !resolved.startsWith(currentProject + path.sep)) {
      throw new HttpError(403, "That file is outside the project.");
    }
    fs.mkdirSync(path.dirname(resolved), { recursive: true });
    fs.writeFileSync(resolved, String(body.content ?? ""), "utf8");
    return json({ ok: true, path: resolved });
  }

    const { client } = await ensureEngine();

    if (url.pathname === "/api/sessions" && request.method === "POST") {
      const body = await readBody(request);
      const directory = directoryOf(body.directory ?? currentProject);
      currentProject = directory;
      return json({ session: await client.createSession({ directory, title: body.title, agent: body.agent, model: body.model }) });
    }

    if (url.pathname === "/api/models" && request.method === "GET") {
      return json({ models: await client.models(currentProject ?? undefined) });
    }

    const session = route(/^\/api\/sessions\/([^/]+)$/);
    if (session && request.method === "DELETE") {
      await client.deleteSession(session[0]);
      return json({ ok: true });
    }
    if (session && request.method === "GET") {
      const [id] = session;
      const [detail, messages, permissions, active] = await Promise.all([
        client.session(id),
        client.messages(id),
        client.permissions(id),
        client.activeSessions(),
      ]);
      return json({ session: detail, messages, permissions, running: active.includes(id) });
    }

    const prompt = route(/^\/api\/sessions\/([^/]+)\/prompt$/);
    if (prompt && request.method === "POST") {
      const body = await readBody(request);
      const text = String(body.text ?? "").trim();
      if (text === "") throw new HttpError(400, "An empty message has nothing to send.");
      const id = await client.prompt({ session: prompt[0], id: body.id, text, files: body.files, delivery: body.delivery === "queue" ? "queue" : "steer" });
      return json({ id });
    }

    const interrupt = route(/^\/api\/sessions\/([^/]+)\/interrupt$/);
    if (interrupt && request.method === "POST") {
      await client.interrupt(interrupt[0], await readBody(request));
      return json({ ok: true });
    }

    const model = route(/^\/api\/sessions\/([^/]+)\/model$/);
    if (model && request.method === "POST") {
      await client.setModel(model[0], (await readBody(request)).model);
      return json({ ok: true });
    }

    const permission = route(/^\/api\/sessions\/([^/]+)\/permission\/([^/]+)$/);
    if (permission && request.method === "POST") {
      const body = await readBody(request);
      await client.replyPermission({ session: permission[0], permission: permission[1], decision: body.decision, message: body.message });
      return json({ ok: true });
    }

    return false;
  }

  async function serveStatic(request, response, url) {
    // Map a URL to a file we're willing to serve, with a traversal guard. The packed
    // executable carries these same files inside itself (build-exe.mjs).
    let relative;
    if (url.pathname === "/") relative = "ui/index.html";
    else if (url.pathname === "/transcript.mjs") relative = "transcript.mjs";
    else relative = "ui" + url.pathname;
    const root = relative === "transcript.mjs" ? here : path.join(here, "ui");
    const resolved = path.resolve(here, relative);
    if (!resolved.startsWith(root + path.sep) && resolved !== path.join(here, "transcript.mjs")) {
      response.writeHead(404, { "content-type": "text/plain" });
      return response.end("Not found.\n");
    }
    if (!fs.existsSync(resolved) || !fs.statSync(resolved).isFile()) {
      response.writeHead(404, { "content-type": "text/plain" });
      return response.end("Not found.\n");
    }
    const type = MIME[relative.split(".").pop().toLowerCase()] ?? "application/octet-stream";
    const body = packed(relative) ?? fs.readFileSync(resolved);
    response.writeHead(200, { "content-type": type, "cache-control": "no-store" });
    return response.end(body);
  }

  async function relayEvents(request, response) {
    const made = await ensureEngine();
    response.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      connection: "keep-alive",
    });
    response.write("retry: 2000\n: connected\n\n");
    const heartbeat = setInterval(() => {
      if (!response.writableEnded) response.write(": ping\n\n");
    }, 15_000);
    const controller = new AbortController();
    request.on("close", () => controller.abort());
    try {
      for await (const event of made.client.events(controller.signal)) {
        if (!response.write(`data: ${JSON.stringify(event)}\n\n`)) break;
      }
    } catch (error) {
      if (!controller.signal.aborted) {
        response.write(`data: ${JSON.stringify({ type: "harness.error", data: { message: error.message } })}\n\n`);
      }
    } finally {
      clearInterval(heartbeat);
      response.end();
    }
  }

  const server = http.createServer(async (request, response) => {
    const url = new URL(request.url, `http://${request.headers.host ?? "127.0.0.1"}`);
    try {
      if (url.pathname === "/api/events" && request.method === "GET") return await relayEvents(request, response);
      if (url.pathname.startsWith("/api/")) {
        const answered = await api(request, response, url);
        if (answered === false) {
          response.writeHead(404, { "content-type": "application/json" });
          response.end(JSON.stringify({ error: "No such route." }));
        }
        return;
      }
      return await serveStatic(request, response, url);
    } catch (error) {
      const status = error instanceof HttpError ? error.status : error instanceof EngineError ? 502 : 500;
      const message = error instanceof Error ? error.message : String(error);
      if (!response.headersSent) {
        response.writeHead(status, { "content-type": "application/json" });
        response.end(JSON.stringify({ error: message }));
      } else {
        response.end();
      }
    }
  });

  const listening = new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", () => resolve(server.address().port));
  });

  return {
    server,
    state,
    async url() {
      const actual = await listening;
      return `http://127.0.0.1:${actual}/`;
    },
    async close() {
      if (engine) await engine.stop().catch(() => {});
      // A page with the event stream open would otherwise keep this waiting for ever.
      await new Promise(resolve => {
        server.close(resolve);
        server.closeAllConnections?.();
      });
    },
  };
}

/// The command line: `kuvo-windows-harness [--project <folder>] [--port <port>]`.
export function run() {
  const args = process.argv.slice(2);
  const option = (name) => {
    const at = args.indexOf(name);
    return at >= 0 ? args[at + 1] : undefined;
  };
  const harness = startHarness({
    project: option("--project") ?? process.env.KUVO_HARNESS_PROJECT ?? process.cwd(),
    port: Number(option("--port") ?? process.env.KUVO_HARNESS_PORT ?? 4620),
    log: message => console.error(message),
  });
  harness.url().then(url => {
    console.log(`Kuvo Code (Windows harness) at ${url}`);
    console.log(`project: ${harness.state().project}`);
  });
  process.on("SIGINT", async () => {
    await harness.close();
    process.exit(0);
  });
  return harness;
}

// True only when this file is what was started — which it never is inside the packed
// executable (build-exe.mjs's banner sets KUVO_BUNDLED there, before anything runs): that
// binary has no source file to compare with, and the entry calls `run()` itself.
const main = process.env.KUVO_BUNDLED !== "1" && process.argv[1] && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url));
if (main) run();
