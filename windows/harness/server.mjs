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
import { fileURLToPath, pathToFileURL } from "node:url";
import { EngineClient, EngineError } from "./engine.mjs";
import { engineFolders, install, launch } from "../kuvo-engine.mjs";
import { createApi } from "./routes.mjs";

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
  const recentFile = () => path.join(os.homedir(), ".kuvo-code", "recent-projects.json");
  const recentProjects = () => {
    try { const list = JSON.parse(fs.readFileSync(recentFile(), "utf8")); return Array.isArray(list) ? list : []; }
    catch { return []; }
  };
  const saveRecentProjects = (list) => {
    try { fs.mkdirSync(path.dirname(recentFile()), { recursive: true }); fs.writeFileSync(recentFile(), JSON.stringify([...new Set(list)].slice(0, 8), null, 2)); } catch {}
  };
  const rememberProject = (folder) => {
    saveRecentProjects([folder, ...recentProjects().filter(item => item !== folder)]);
  };

  // A project's own settings: the name shown instead of the folder's, and the folders the
  // agent works in besides it (the Mac's Workspace.ProjectSettings, stored in its own
  // defaults — Workspace.swift:191-199, 786-795).
  const projectSettingsFile = () => path.join(path.dirname(recentFile()), "project-settings.json");
  const projectSettings = () => {
    try {
      const read = JSON.parse(fs.readFileSync(projectSettingsFile(), "utf8"));
      return read && typeof read === "object" ? read : {};
    } catch { return {}; }
  };
  const saveProjectSettings = (settings) => {
    try { fs.mkdirSync(path.dirname(projectSettingsFile()), { recursive: true }); fs.writeFileSync(projectSettingsFile(), JSON.stringify(settings, null, 2)); } catch {}
  };

  // The providers' marks, fetched once each and kept (the Mac's LogoCache).
  const logos = new Map();
  const logoFor = async (id) => {
    if (!id || !/^[a-z0-9._-]+$/i.test(id)) return null;
    if (logos.has(id)) return logos.get(id);
    let mark = null;
    try {
      const response = await fetch(`https://models.opencode.ai/logos/${id}.svg`, { signal: AbortSignal.timeout(8000) });
      if (response.ok) {
        const text = await response.text();
        if (text.includes("<svg")) mark = text;
      }
    } catch {}
    logos.set(id, mark);
    return mark;
  };

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

  /// Stops the engine and starts it over: the settings file's changes, for instance, get read.
  /// The client that comes back has the new engine's url and password.
  async function restartEngine() {
    if (engine) await engine.stop().catch(() => {});
    engine = null;
    starting = null;
    return ensureEngine();
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

  const api = createApi({
    get currentProject() { return currentProject; },
    set currentProject(value) { currentProject = value; },
    state,
    ensureEngine,
    restartEngine,
    readBody,
    directoryOf,
    recentProjects,
    saveRecentProjects,
    rememberProject,
    projectSettings,
    saveProjectSettings,
    logoFor,
    log,
  });

  async function serveStatic(request, response, url) {
    // Map a URL to a file we're willing to serve, with a traversal guard. The packed
    // executable carries these same files inside itself (build-exe.mjs), and it travels
    // alone — no ui/ folder beside it — so the blob is asked first, and disk is the
    // fallback when there is one. Asking disk first would answer "Not found." for the
    // whole page in the packaged app, behind the source tree that masked it in CI.
    // The built page (React and TypeScript) when there is one, the hand-written page
    // otherwise. Inside the packed executable the build lives in the blob, so it is asked
    // there first — a build on disk and a build in the binary are the same page.
    const built = packed("ui-build/index.html") !== null
      || fs.existsSync(path.join(here, "ui-build", "index.html"));
    const base = built ? "ui-build" : "ui";
    let relative;
    if (url.pathname === "/") relative = `${base}/index.html`;
    else if (url.pathname === "/transcript.mjs") relative = "transcript.mjs";
    else relative = base + url.pathname;
    const respond = async body => {
      const type = MIME[relative.split(".").pop().toLowerCase()] ?? "application/octet-stream";
      response.writeHead(200, { "content-type": type, "cache-control": "no-store" });
      return response.end(body);
    };
    const packedBody = packed(relative);
    if (packedBody !== null) return respond(packedBody);
    // The guard follows the folder the file is served from: the build (ui-build) or the
    // hand-written page (ui), with the reducer beside them.
    const root = relative === "transcript.mjs" ? here : path.join(here, base);
    const resolved = path.resolve(here, relative);
    const inside = resolved.startsWith(root + path.sep) || resolved === path.join(here, "transcript.mjs");
    if (!inside) {
      response.writeHead(404, { "content-type": "text/plain" });
      return response.end("Not found.\n");
    }
    if (!fs.existsSync(resolved) || !fs.statSync(resolved).isFile()) {
      response.writeHead(404, { "content-type": "text/plain" });
      return response.end("Not found.\n");
    }
    return respond(fs.readFileSync(resolved));
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
    // Reject cross-origin browser requests to the localhost API.
    const origin = request.headers.origin;
    if (origin && !/^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/i.test(origin)) {
      response.writeHead(403, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: "That origin isn't allowed." }));
      return;
    }
    response.setHeader("X-Content-Type-Options", "nosniff");
    response.setHeader("X-Frame-Options", "DENY");
    response.setHeader("Referrer-Policy", "no-referrer");
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
    log: (message) => {
      console.error(message);
      try {
        const fs = require("node:fs");
        const path = require("node:path");
        const os = require("node:os");
        const dir = path.join(os.homedir(), ".kuvo-code", "logs");
        fs.mkdirSync(dir, { recursive: true });
        const file = path.join(dir, "harness.log");
        // Rotate once the log grows past 5 MB, keeping three backups.
        try {
          const stats = fs.statSync(file);
          if (stats.size > 5 * 1024 * 1024) {
            for (let i = 2; i >= 0; i--) {
              const from = i === 0 ? file : `${file}.${i}`;
              const to = `${file}.${i + 1}`;
              if (fs.existsSync(from)) fs.renameSync(from, to);
            }
          }
        } catch {}
        fs.appendFileSync(file, `${new Date().toISOString()} ${message}\n`);
      } catch {}
    },
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


// Extracted route handler (routes.mjs) retains: "-U100000" tooBig
