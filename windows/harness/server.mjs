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

  async function api(request, response, url) {
    const route = (pattern) => url.pathname.match(pattern)?.slice(1).map(decodeURIComponent) ?? null;
    const json = (what) => {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(what));
    };

    if (url.pathname === "/api/state" && request.method === "GET") return json(state());

    // A provider's mark (ProviderLogo.swift): the server fetches it from models.opencode.ai
    // — the same place the Mac fetches it from — and keeps it. A mark that cannot be had
    // is an empty answer, not an error: the page draws the provider's initial instead.
    if (url.pathname.startsWith("/api/logo/") && request.method === "GET") {
      const id = decodeURIComponent(url.pathname.slice("/api/logo/".length));
      const mark = await logoFor(id);
      response.writeHead(200, { "content-type": "image/svg+xml; charset=utf-8", "cache-control": "public, max-age=86400" });
      response.end(mark ?? "");
      return;
    }

    if (url.pathname === "/api/project" && request.method === "POST") {
      const body = await readBody(request);
      currentProject = directoryOf(body.directory);
      rememberProject(currentProject);
      return json({ project: currentProject });
    }

    // The project list, kept across runs like the Mac app keeps its own.
    if (url.pathname === "/api/projects" && request.method === "GET") {
      return json({ projects: recentProjects(), current: currentProject });
    }
    if (url.pathname === "/api/projects" && request.method === "DELETE") {
      const body = await readBody(request);
      const folder = directoryOf(body.path);
      saveRecentProjects(recentProjects().filter(item => item !== folder));
      return json({ ok: true });
    }

    // What the settings panel shows about this machine's storage.
    if (url.pathname === "/api/storage" && request.method === "GET") {
      const logsDir = path.join(os.homedir(), ".kuvo-code", "logs");
      const logPath = path.join(logsDir, "harness.log");
      let logSize = 0;
      try { logSize = fs.statSync(logPath).size; } catch {}
      let attachments = null;
      if (currentProject) {
        const folder = path.join(currentProject, ".kuvo", "attachments");
        let files = [];
        try { files = fs.readdirSync(folder).map(name => path.join(folder, name)); } catch {}
        attachments = { path: folder, files: files.length, bytes: files.reduce((sum, file) => sum + (fs.statSync(file).size || 0), 0) };
      }
      return json({ logPath, logSize, attachments, engine: state().engine, project: currentProject });
    }

    // The page's folder picker: what's under a folder, so someone can walk to theirs.
    if (url.pathname === "/api/browse" && request.method === "GET") {
      const asked = url.searchParams.get("path");
      let folder = asked ? path.resolve(asked) : currentProject ?? os.homedir();
      // Keep the picker from wandering outside the user's home (or the open project).
      const home = os.homedir();
      if (asked && folder !== home && !folder.startsWith(home + path.sep)
          && !(currentProject && (folder === currentProject || folder.startsWith(currentProject + path.sep)))) {
        folder = currentProject ?? home;
      }
      let folders = [];
      let files = [];
      try {
        const entries = fs.readdirSync(folder, { withFileTypes: true });
        folders = entries
          .filter(entry => entry.isDirectory() && !entry.name.startsWith("."))
          .map(entry => ({ name: entry.name, path: path.join(folder, entry.name) }))
          .sort((a, b) => a.name.localeCompare(b.name))
          .slice(0, 500);
        files = entries
          .filter(entry => entry.isFile() && !entry.name.startsWith("."))
          .map(entry => ({ name: entry.name, path: path.join(folder, entry.name) }))
          .sort((a, b) => a.name.localeCompare(b.name))
          .slice(0, 500);
      } catch {
        folders = [];
        files = [];
      }
      const parent = path.dirname(folder);
      return json({ path: folder, parent: parent === folder ? null : parent, folders, files });
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
    // A path in the project (what a reply's file link holds) or an absolute one.
    const resolved = path.isAbsolute(asked) ? path.resolve(asked) : path.resolve(currentProject ?? ".", asked);
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

  // File management: delete and create folders.
  if (url.pathname === "/api/file" && request.method === "DELETE") {
    const asked = url.searchParams.get("path");
    if (!asked) throw new HttpError(400, "No file was given.");
    const resolved = path.resolve(asked);
    if (currentProject && resolved !== currentProject && !resolved.startsWith(currentProject + path.sep)) {
      throw new HttpError(403, "That file is outside the project.");
    }
    let stats;
    try { stats = fs.statSync(resolved); }
    catch { throw new HttpError(404, "There's no such file."); }
    if (stats.isDirectory()) fs.rmSync(resolved, { recursive: true, force: true });
    else fs.unlinkSync(resolved);
    return json({ ok: true });
  }
  if (url.pathname === "/api/mkdir" && request.method === "POST") {
    const body = await readBody(request);
    if (!body.path) throw new HttpError(400, "No folder was given.");
    const resolved = path.resolve(body.path);
    if (currentProject && resolved !== currentProject && !resolved.startsWith(currentProject + path.sep)) {
      throw new HttpError(403, "That folder is outside the project.");
    }
    fs.mkdirSync(resolved, { recursive: true });
    return json({ ok: true, path: resolved });
  }

  // Search: which files contain a string, with the matching lines.
  if (url.pathname === "/api/search" && request.method === "GET") {
    const root = currentProject;
    if (!root) throw new HttpError(400, "No project folder is open.");
    const query = String(url.searchParams.get("q") ?? "").trim();
    if (query === "") return json({ matches: [] });
    const matches = [];
    const walk = (dir, depth) => {
      if (depth > 6 || matches.length > 200) return;
      let entries;
      try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
      catch { return; }
      for (const entry of entries) {
        if (entry.name.startsWith(".") || entry.name === "node_modules") continue;
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) { walk(full, depth + 1); continue; }
        if (!entry.isFile()) continue;
        let text;
        try { text = fs.readFileSync(full, "utf8"); }
        catch { continue; }
        const lines = text.split("\n");
        const hits = [];
        lines.forEach((line, index) => {
          if (line.includes(query) && hits.length < 5) hits.push({ line: index + 1, text: line.trim().slice(0, 200) });
        });
        if (hits.length) matches.push({ path: full, hits });
        if (matches.length >= 50) return;
      }
    };
    walk(root, 0);
    return json({ matches });
  }

  // Git: status and diff for the project, if it's a repository.
  if (url.pathname === "/api/git/status" && request.method === "GET") {
    if (!currentProject) throw new HttpError(400, "No project folder is open.");
    const { execFileSync } = await import("node:child_process");
    let output = "";
    try { output = execFileSync("git", ["status", "--porcelain"], { cwd: currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }); }
    catch { return json({ repository: false, entries: [] }); }
    const entries = output.split("\n").filter(Boolean).map(line => ({
      code: line.slice(0, 2),
      path: line.slice(3).trim(),
    }));
    return json({ repository: true, entries });
  }
  if (url.pathname === "/api/git/diff" && request.method === "GET") {
    if (!currentProject) throw new HttpError(400, "No project folder is open.");
    const asked = url.searchParams.get("path");
    const { execFileSync } = await import("node:child_process");
    let output = "";
    try {
      const args = asked ? ["diff", "--", asked] : ["diff"];
      output = execFileSync("git", args, { cwd: currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    } catch { output = ""; }
    return json({ diff: output });
  }

  // Git: stage, unstage, commit.
  if (url.pathname === "/api/git/stage" && request.method === "POST") {
    if (!currentProject) throw new HttpError(400, "No project folder is open.");
    const body = await readBody(request);
    const files = Array.isArray(body.paths) ? body.paths : (body.path ? [body.path] : []);
    const { execFileSync } = await import("node:child_process");
    try { execFileSync("git", ["add", "--", ...files], { cwd: currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }); }
    catch (error) { throw new HttpError(500, error?.stderr?.toString() || error.message); }
    return json({ ok: true });
  }
  if (url.pathname === "/api/git/unstage" && request.method === "POST") {
    if (!currentProject) throw new HttpError(400, "No project folder is open.");
    const body = await readBody(request);
    const files = Array.isArray(body.paths) ? body.paths : (body.path ? [body.path] : []);
    const { execFileSync } = await import("node:child_process");
    try { execFileSync("git", ["reset", "HEAD", "--", ...files], { cwd: currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }); }
    catch (error) { throw new HttpError(500, error?.stderr?.toString() || error.message); }
    return json({ ok: true });
  }
  if (url.pathname === "/api/git/commit" && request.method === "POST") {
    if (!currentProject) throw new HttpError(400, "No project folder is open.");
    const body = await readBody(request);
    const message = String(body.message ?? "").trim();
    if (message === "") throw new HttpError(400, "A commit needs a message.");
    const { execFileSync } = await import("node:child_process");
    let output = "";
    try { output = execFileSync("git", ["commit", "-m", message], { cwd: currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }); }
    catch (error) { throw new HttpError(500, (error?.stdout?.toString() || "") + (error?.stderr?.toString() || error.message)); }
    return json({ ok: true, output });
  }

  // Git: branches, checkout, amend.
  if (url.pathname === "/api/git/branches" && request.method === "GET") {
    if (!currentProject) throw new HttpError(400, "No project folder is open.");
    const { execFileSync } = await import("node:child_process");
    let output = "";
    let current = "";
    try {
      output = execFileSync("git", ["branch", "--list", "--no-abbrev"], { cwd: currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
      current = execFileSync("git", ["branch", "--show-current"], { cwd: currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
    } catch { return json({ repository: false, branches: [], current: "" }); }
    const branches = output.split("\n").map(line => line.trim().replace(/^\* /, "")).filter(Boolean);
    return json({ repository: true, branches, current });
  }
  if (url.pathname === "/api/git/checkout" && request.method === "POST") {
    if (!currentProject) throw new HttpError(400, "No project folder is open.");
    const body = await readBody(request);
    const name = String(body.name ?? "").trim();
    if (name === "") throw new HttpError(400, "No branch was given.");
    const { execFileSync } = await import("node:child_process");
    try { execFileSync("git", ["checkout", name], { cwd: currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }); }
    catch (error) { throw new HttpError(500, error?.stderr?.toString() || error.message); }
    return json({ ok: true });
  }
  if (url.pathname === "/api/git/branch" && request.method === "POST") {
    if (!currentProject) throw new HttpError(400, "No project folder is open.");
    const body = await readBody(request);
    const name = String(body.name ?? "").trim();
    if (name === "") throw new HttpError(400, "No branch name was given.");
    const { execFileSync } = await import("node:child_process");
    try { execFileSync("git", ["checkout", "-b", name], { cwd: currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }); }
    catch (error) { throw new HttpError(500, error?.stderr?.toString() || error.message); }
    return json({ ok: true });
  }
  if (url.pathname === "/api/git/amend" && request.method === "POST") {
    if (!currentProject) throw new HttpError(400, "No project folder is open.");
    const body = await readBody(request);
    const { execFileSync } = await import("node:child_process");
    const message = String(body.message ?? "").trim();
    const args = message ? ["commit", "--amend", "-m", message] : ["commit", "--amend", "--no-edit"];
    try { execFileSync("git", args, { cwd: currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }); }
    catch (error) { throw new HttpError(500, error?.stderr?.toString() || error.message); }
    return json({ ok: true });
  }

  // Search across the project's sessions for a string in their messages.
  if (url.pathname === "/api/search/sessions" && request.method === "GET") {
    if (!currentProject) throw new HttpError(400, "No project folder is open.");
    const query = String(url.searchParams.get("q") ?? "").trim().toLowerCase();
    if (query === "") return json({ matches: [] });
    const { client } = await ensureEngine();
    const sessions = await client.sessions({ directory: currentProject });
    const matches = [];
    for (const session of sessions) {
      try {
        const messages = await client.messages(session.id);
        const hits = [];
        for (const message of messages) {
          const text = (message?.parts ?? []).map(p => p.text ?? "").join(" ").toLowerCase();
          if (text.includes(query) && hits.length < 3) {
            hits.push({ messageID: message.id, snippet: text.slice(Math.max(0, text.indexOf(query) - 40), text.indexOf(query) + 80).trim() });
          }
        }
        if (hits.length) matches.push({ session, hits });
        if (matches.length >= 20) break;
      } catch {}
    }
    return json({ matches });
  }

  const { client } = await ensureEngine();

  if (url.pathname === "/api/sessions" && request.method === "POST") {
      const body = await readBody(request);
      const directory = directoryOf(body.directory ?? currentProject);
      currentProject = directory;
      return json({ session: await client.createSession({ directory, title: body.title, agent: body.agent, model: body.model }) });
    }

    if (url.pathname === "/api/models/default" && request.method === "GET") {
      const { client } = await ensureEngine();
      return json({ model: await client.defaultModel(currentProject ?? undefined) });
    }

    if (url.pathname === "/api/models" && request.method === "GET") {
      return json({ models: await client.models(currentProject ?? undefined) });
    }

    if (url.pathname === "/api/agents" && request.method === "GET") {
      return json({ agents: await client.agents(currentProject ?? undefined) });
    }

    if (url.pathname === "/api/commands" && request.method === "GET") {
      return json({ commands: await client.commands(currentProject ?? undefined) });
    }

    // The project's files, by name: the file links of a reply (the Mac app's FileLinks) ask
    // which of them are real, and the list is the answer.
    if (url.pathname === "/api/project-files" && request.method === "GET") {
      if (!currentProject) throw new HttpError(400, "No project is open.");
      const found = [];
      const skip = new Set(["node_modules", ".git", "dist", "build", ".next", "coverage", ".kuvo"]);
      const walk = (folder, depth) => {
        if (depth > 6 || found.length > 2000) return;
        let entries;
        try { entries = fs.readdirSync(folder, { withFileTypes: true }); }
        catch { return; }
        for (const entry of entries) {
          const full = path.join(folder, entry.name);
          if (entry.isDirectory()) { if (!skip.has(entry.name) && !entry.name.startsWith(".")) walk(full, depth + 1); continue; }
          if (entry.isFile()) found.push(path.relative(currentProject, full).replace(/\\/g, "/"));
        }
      };
      walk(currentProject, 0);
      return json({ files: found });
    }

    // The project's files by name, for the prompt's @-mentions and the palette.
    if (url.pathname === "/api/files" && request.method === "GET") {
      const query = (url.searchParams.get("q") ?? "").toLowerCase();
      if (!currentProject) throw new HttpError(400, "No project is open.");
      const found = [];
      const skip = new Set(["node_modules", ".git", "dist", "build", ".next", "coverage", ".kuvo"]);
      const walk = (folder, depth) => {
        if (depth > 6 || found.length > 500) return;
        let entries;
        try { entries = fs.readdirSync(folder, { withFileTypes: true }); }
        catch { return; }
        for (const entry of entries) {
          const full = path.join(folder, entry.name);
          if (entry.isDirectory()) { if (!skip.has(entry.name) && !entry.name.startsWith(".")) walk(full, depth + 1); continue; }
          if (entry.isFile()) found.push(full);
        }
      };
      walk(currentProject, 0);
      const matches = query
        ? found.filter(file => file.toLowerCase().replace(/\\/g, "/").includes(query))
        : found;
      return json({ files: matches.slice(0, 40).map(file => ({
        path: file,
        name: path.basename(file),
        relative: path.relative(currentProject, file).replace(/\\/g, "/"),
      })) });
    }

    // A project file's raw bytes, for images that the conversation shows.
    if (url.pathname === "/api/raw" && request.method === "GET") {
      const asked = url.searchParams.get("path");
      if (!asked) throw new HttpError(400, "No file was given.");
      const resolved = path.resolve(asked);
      if (currentProject && resolved !== currentProject && !resolved.startsWith(currentProject + path.sep)) {
        throw new HttpError(403, "That file is outside the project.");
      }
      let data;
      try { data = fs.readFileSync(resolved); }
      catch { throw new HttpError(404, "There's no such file."); }
      const kinds = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp", ".bmp": "image/bmp", ".svg": "image/svg+xml", ".ico": "image/x-icon" };
      const type = kinds[path.extname(resolved).toLowerCase()] ?? "application/octet-stream";
      response.writeHead(200, { "content-type": type, "cache-control": "no-store" });
      response.end(data);
      return;
    }

    // A dropped or picked file, staged inside the project so the engine can read it.
    if (url.pathname === "/api/upload" && request.method === "POST") {
      const body = await readBody(request);
      if (!currentProject) throw new HttpError(400, "No project is open.");
      if (!body.data) throw new HttpError(400, "Nothing was uploaded.");
      const name = (body.name ?? "attachment").replace(/[\\/:*?"<>|]/g, "_");
      const folder = path.join(currentProject, ".kuvo", "attachments");
      fs.mkdirSync(folder, { recursive: true });
      const target = path.join(folder, `${Date.now()}-${name}`);
      fs.writeFileSync(target, Buffer.from(String(body.data), "base64"));
      return json({ path: target, name });
    }

    if (url.pathname === "/api/vcs" && request.method === "GET") {
      return json({ vcs: await client.vcs(currentProject ?? undefined) });
    }

    if (url.pathname === "/api/permission/saved" && request.method === "GET") {
      return json({ saved: await client.savedPermissions() });
    }
    if (url.pathname === "/api/permission/saved" && request.method === "DELETE") {
      const body = await readBody(request);
      await client.removeSavedPermission(body.id);
      return json({ ok: true });
    }

    // The engine's read-only lists, for the settings page.
    if (url.pathname === "/api/config-lists" && request.method === "GET") {
      const [skills, mcp, providers] = await Promise.all([
        client.skills(currentProject ?? undefined).catch(() => []),
        client.mcpServers(currentProject ?? undefined).catch(() => []),
        client.providers(currentProject ?? undefined).catch(() => []),
      ]);
      return json({ skills, mcp, providers });
    }

    const diff = route(/^\/api\/sessions\/([^/]+)\/diff$/);
    if (diff && request.method === "GET") {
      return json({ diff: await client.sessionDiff(diff[0]) });
    }

    const compact = route(/^\/api\/sessions\/([^/]+)\/compact$/);
    if (compact && request.method === "POST") {
      await client.compact(compact[0]);
      return json({ ok: true });
    }

    const viewed = route(/^\/api\/sessions\/([^/]+)\/view$/);
    if (viewed && request.method === "POST") {
      const body = await readBody(request);
      await client.markViewed(viewed[0], body.idle ?? Date.now());
      return json({ ok: true });
    }

    const inbox = route(/^\/api\/sessions\/([^/]+)\/inbox(?:\/([^/]+))?$/);
    if (inbox && request.method === "GET") {
      return json({ inbox: await client.inbox(inbox[0]) });
    }
    if (inbox && inbox[1] && request.method === "PATCH") {
      const body = await readBody(request);
      await client.setDelivery(inbox[0], inbox[1], body.delivery === "queue" ? "queue" : "steer");
      return json({ ok: true });
    }
    if (inbox && inbox[1] && request.method === "DELETE") {
      await client.cancelInbox(inbox[0], inbox[1]);
      return json({ ok: true });
    }

    // The shell's own settings — the file the Electron app keeps next to its data. The
    // page shows them and writes them; the shell reads them when it comes forward.
    const shellConfigFile = () => {
      const appData = process.env.APPDATA ?? path.join(os.homedir(), ".config");
      const candidates = [
        path.join(appData, "Kuvo Code", "config.json"),
        path.join(appData, "kuvo-code", "config.json"),
        path.join(os.homedir(), ".config", "Kuvo Code", "config.json"),
      ];
      for (const candidate of candidates) if (fs.existsSync(candidate)) return candidate;
      return candidates[0];
    };
    const readShellConfig = () => {
      const file = shellConfigFile();
      let settings = {};
      try { settings = JSON.parse(fs.readFileSync(file, "utf8")); } catch {}
      return {
        path: file,
        updates: settings.autoUpdate !== false,
        startAtLogin: Boolean(settings.autoStart),
        keepAwake: Boolean(settings.keepAwake),
        git: {
          branchPrefix: typeof settings.git?.branchPrefix === "string" ? settings.git.branchPrefix : "",
          commitInstructions: typeof settings.git?.commitInstructions === "string" ? settings.git.commitInstructions : "",
          pullRequestInstructions: typeof settings.git?.pullRequestInstructions === "string" ? settings.git.pullRequestInstructions : "",
        },
        recentProjects: Array.isArray(settings.recentProjects) ? settings.recentProjects : [],
      };
    };
    const writeShellConfig = next => {
      const file = shellConfigFile();
      let settings = {};
      try { settings = JSON.parse(fs.readFileSync(file, "utf8")); } catch {}
      if (typeof next.updates === "boolean") settings.autoUpdate = next.updates;
      if (typeof next.startAtLogin === "boolean") settings.autoStart = next.startAtLogin;
      if (typeof next.keepAwake === "boolean") settings.keepAwake = next.keepAwake;
      if (next.git && typeof next.git === "object") settings.git = { ...(settings.git ?? {}), ...next.git };
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, JSON.stringify(settings, null, 2));
    };

    if (url.pathname === "/api/app-settings" && request.method === "GET") {
      return json(readShellConfig());
    }
    if (url.pathname === "/api/app-settings" && request.method === "PUT") {
      const body = await readBody(request);
      writeShellConfig(body ?? {});
      return json(readShellConfig());
    }

    // ---- The project's changes, the way the Mac app's Changes panel reads them ----

    /// git, in a folder: what it says, and what it is told to do.
    const git = async (directory, args, input) => {
      const { execFile } = await import("node:child_process");
      const { promisify } = await import("node:util");
      const run = promisify(execFile);
      const { stdout } = await run("git", ["-C", directory, ...args], {
        encoding: "utf8",
        maxBuffer: 32 * 1024 * 1024,
        ...(input ? { input } : {}),
      });
      return stdout;
    };

    const isGitProject = async directory => {
      try {
        await git(directory, ["rev-parse", "--is-inside-work-tree"]);
        return true;
      } catch {
        return false;
      }
    };

    /// The branch the work is compared with: the repository's own default, when there is
    /// one. The Mac app reads it from the engine's VCS; git knows it too.
    const defaultBranch = async directory => {
      for (const name of ["origin/HEAD", "main", "master", "trunk", "develop"]) {
        try {
          const answer = await git(directory, ["rev-parse", "--verify", "--quiet", name]);
          if (answer.trim()) return name.replace(/^origin\//, "");
        } catch {}
      }
      return null;
    };

    /// The files git says have changed, with their patches: the same three scopes the Mac
    /// app offers (what is not committed, what is not staged, what is staged).
    const gitChanges = async (directory, scope) => {
      if (!directory || !(await isGitProject(directory))) return [];
      const files = [];
      const add = async (path, patch, status) => {
        if (!patch) return;
        const lines = patch.split("\n");
        const additions = lines.filter(line => line.startsWith("+") && !line.startsWith("+++")).length;
        const deletions = lines.filter(line => line.startsWith("-") && !line.startsWith("---")).length;
        files.push({ file: path, patch, additions, deletions, status });
      };
      if (scope === "branch") {
        // Since the branch left its base: from where they part, to the files as they are now.
        const base = await defaultBranch(directory);
        let fork = base;
        if (base) {
          try { fork = (await git(directory, ["merge-base", "HEAD", base])).trim() || base; } catch { fork = base; }
        }
        if (!fork) return files;
        const names = (await git(directory, ["diff", "--name-only", fork])).split("\n").filter(Boolean);
        for (const name of names) {
          await add(name, await git(directory, ["diff", "--no-color", "--find-renames", "-U100000", fork, "--", name]), "modified");
        }
        const others = (await git(directory, ["ls-files", "--others", "--exclude-standard"])).split("\n").filter(Boolean);
        for (const name of others) {
          const content = await git(directory, ["diff", "--no-index", "--", "/dev/null", name]).catch(() => "");
          const patch = content || `--- /dev/null\n+++ b/${name}\n@@ -0,0 +1,${content.split("\n").length} @@\n${content.split("\n").map(line => `+${line}`).join("\n")}`;
          await add(name, patch, "added");
        }
        return files;
      }
      if (scope === "unstaged") {
        const names = (await git(directory, ["diff", "--name-only"])).split("\n").filter(Boolean);
        for (const name of names) await add(name, await git(directory, ["diff", "--", name]), "modified");
      } else if (scope === "staged") {
        const names = (await git(directory, ["diff", "--cached", "--name-only"])).split("\n").filter(Boolean);
        for (const name of names) await add(name, await git(directory, ["diff", "--cached", "--", name]), "staged");
      } else {
        const names = (await git(directory, ["diff", "HEAD", "--name-only"])).split("\n").filter(Boolean);
        for (const name of names) await add(name, await git(directory, ["diff", "HEAD", "--", name]), "modified");
        // New files are not in the diff until they are added: their whole content is the change.
        const others = (await git(directory, ["ls-files", "--others", "--exclude-standard"])).split("\n").filter(Boolean);
        for (const name of others) {
          const content = await git(directory, ["diff", "--no-index", "--", "/dev/null", name]).catch(() => "");
          const patch = content || `--- /dev/null\n+++ b/${name}\n@@ -0,0 +1,${content.split("\n").length} @@\n${content.split("\n").map(line => `+${line}`).join("\n")}`;
          await add(name, patch, "added");
        }
      }
      return files;
    };

    if (url.pathname === "/api/changes" && request.method === "GET") {
      const directory = url.searchParams.get("directory") ?? currentProject ?? "";
      const scope = url.searchParams.get("scope") ?? "uncommitted";
      if (!directory) return json({ files: [], scope, git: false });
      const git_ = await isGitProject(directory);
      if (!git_) return json({ files: [], scope, git: false });
      try {
        const base = scope === "branch" ? await defaultBranch(directory) : null;
        return json({ files: await gitChanges(directory, scope), scope, git: true, base, branch: (await git(directory, ["rev-parse", "--abbrev-ref", "HEAD"]).catch(() => "")).trim() });
      } catch (error) {
        return json({ files: [], scope, git: true, problem: error.message });
      }
    }

    // Putting a file back as it was: the panel's per-file action.
    if (url.pathname === "/api/changes/revert" && request.method === "POST") {
      const body = await readBody(request);
      const directory = body?.directory ?? currentProject;
      const file = typeof body?.file === "string" ? body.file : "";
      if (!directory) throw new HttpError(400, "No folder to change.");
      if (!file) throw new HttpError(400, "No file to put back.");
      if (!(await isGitProject(directory))) throw new HttpError(400, "That folder is not a git project.");
      await git(directory, ["checkout", "--", file]);
      return json({ ok: true, file });
    }

    // The commit message the session's model writes, the way the Mac app asks for it.
    if (url.pathname === "/api/changes/suggest" && request.method === "POST") {
      const body = await readBody(request);
      const directory = body?.directory ?? currentProject;
      const session = body?.session;
      if (!directory) throw new HttpError(400, "No folder to read.");
      if (!session) throw new HttpError(400, "No session to ask.");
      const scope = body?.scope ?? "uncommitted";
      const files = (await isGitProject(directory)) ? await gitChanges(directory, scope) : [];
      const diff = files.map(file => `--- a/${file.file}\n+++ b/${file.file}\n${file.patch ?? ""}`).join("\n");
      const instructions = typeof body?.instructions === "string" ? body.instructions.trim() : "";
      const prompt = [
        instructions ? `${instructions}\n\n` : "",
        "Write a git commit message for the changes below. A summary line in the imperative mood, under 72 characters; then, only if it helps, a blank line and a few short lines on what changed and why. Reply with the message alone: no quotes, no code fences.",
        "",
        diff,
      ].join("\n");
      const text = await client.generate(session, prompt);
      return json({ message: text.trim().replace(/^[`"']+|[`"']+$/g, "") });
    }

    // The host's page for a pull request, from the remote's address.
    const pullRequestPage = async (directory, branch, base) => {
      let remote = "";
      try { remote = (await git(directory, ["remote", "get-url", "origin"])).trim(); } catch {}
      if (!remote) return null;
      const match = remote.match(/github\.com[:/]([^/]+\/[^/.]+)(?:\.git)?$/) || remote.match(/gitlab\.com[:/]([^/]+\/[^/.]+)(?:\.git)?$/);
      if (!match) return null;
      const host = remote.includes("gitlab.com") ? "gitlab" : "github";
      const project = match[1];
      return host === "github"
        ? `https://github.com/${project}/compare/${base}...${branch}?expand=1`
        : `https://gitlab.com/${project}/-/merge_requests/new?merge_request[source_branch]=${branch}&merge_request[target_branch]=${base}`;
    };

    // Pushing the branch, the way the Mac does before it opens the pull request's page.
    if (url.pathname === "/api/changes/push" && request.method === "POST") {
      const body = await readBody(request);
      const directory = body?.directory ?? currentProject;
      const branch = typeof body?.branch === "string" ? body.branch : "";
      const base = typeof body?.base === "string" ? body.base : "main";
      if (!directory) throw new HttpError(400, "No folder to push from.");
      if (!branch) throw new HttpError(400, "No branch to push.");
      if (!(await isGitProject(directory))) throw new HttpError(400, "That folder is not a git project.");
      await git(directory, ["push", "-u", "origin", branch]);
      return json({ ok: true, branch, page: await pullRequestPage(directory, branch, base) });
    }

    // The title and the description the session's model writes for the pull request.
    if (url.pathname === "/api/changes/suggest-pr" && request.method === "POST") {
      const body = await readBody(request);
      const directory = body?.directory ?? currentProject;
      const session = body?.session;
      if (!directory) throw new HttpError(400, "No folder to read.");
      if (!session) throw new HttpError(400, "No session to ask.");
      const base = typeof body?.base === "string" ? body.base : "";
      const summary = await git(directory, base ? ["log", `${base}..HEAD`, "--pretty=%s"] : ["log", "--pretty=%s"]).catch(() => "");
      const diff = await git(directory, base ? ["diff", `${base}...HEAD`] : ["diff", "HEAD"]).catch(() => "");
      const instructions = typeof body?.instructions === "string" ? body.instructions.trim() : "";
      const prompt = [
        instructions ? `${instructions}\n\n` : "",
        "Write the title and the description of a pull request for the changes below. Reply with the title on the first line, a blank line, then the description. Say only that.",
        "",
        "The commits:",
        summary,
        "",
        "The changes:",
        diff.slice(0, 20000),
      ].join("\n");
      const text = await client.generate(session, prompt);
      const clean = text.trim().replace(/^[`"']+|[`"']+$/g, "");
      const [title, ...rest] = clean.split("\n\n");
      return json({ title: (title ?? "").trim(), description: rest.join("\n\n").trim() });
    }

    // Committing: what the panel's Commit button does. The message is the model's or yours.
    if (url.pathname === "/api/changes/commit" && request.method === "POST") {
      const body = await readBody(request);
      const directory = body?.directory ?? currentProject;
      const message = typeof body?.message === "string" ? body.message.trim() : "";
      if (!directory) throw new HttpError(400, "No folder to commit in.");
      if (!message) throw new HttpError(400, "A commit needs a message.");
      if (!(await isGitProject(directory))) throw new HttpError(400, "That folder is not a git project.");
      const files = Array.isArray(body?.files) ? body.files.filter(name => typeof name === "string") : [];
      if (files.length) await git(directory, ["add", "--", ...files]);
      else await git(directory, ["add", "-A"]);
      await git(directory, ["commit", "-m", message]);
      const head = await git(directory, ["rev-parse", "--short", "HEAD"]);
      // The push afterwards, as the Mac's commit form does (ChangesPanel.swift:389-397).
      if (body?.push === true) {
        try {
          await git(directory, ["push"]);
        } catch (error) {
          throw new HttpError(500, (error?.stdout?.toString() || "") + (error?.stderr?.toString() || error.message));
        }
      }
      return json({ ok: true, commit: head.trim(), message, pushed: body?.push === true });
    }

    // ---- The engine's settings file, as the Mac app's engine config is ----

    /// Where the engine reads its settings: the Mac app's layout, in this machine's data
    /// folder. A KUVO_ENGINE_CONFIG_ROOT names the file itself, for tests and for moving it.
    const settingsFile = () =>
      process.env.KUVO_ENGINE_CONFIG_ROOT ?? path.join(engineFolders().root, "config", "opencode", "opencode.json");
    const skillsFolder = () => process.env.KUVO_SKILLS_ROOT ?? path.join(path.dirname(settingsFile()), "skills");

    const readSettings = () => {
      const file = settingsFile();
      let text = "";
      try { text = fs.readFileSync(file, "utf8"); } catch {}
      if (text.trim() === "") return { settings: {}, problem: null, path: file };
      try { return { settings: JSON.parse(text), problem: null, path: file }; }
      catch (error) { return { settings: null, problem: error.message, path: file }; }
    };

    /// opencode's own settings — the ones the CLI, another agent, or a tool like OpenDesign
    /// writes into. The engine here reads its own folder only, so what lands there is
    /// invisible until it is brought over.
    const opencodeConfigFile = () => {
      if (process.env.KUVO_OPENCODE_CONFIG_ROOT) return process.env.KUVO_OPENCODE_CONFIG_ROOT;
      const folder = path.join(os.homedir(), ".config", "opencode");
      // opencode reads both; the tools that write it (REA, for one) prefer .jsonc.
      for (const name of ["opencode.jsonc", "opencode.json"]) {
        const candidate = path.join(folder, name);
        if (fs.existsSync(candidate)) return candidate;
      }
      return path.join(folder, "opencode.json");
    };
    /// JSON with comments and trailing commas, the way a .jsonc file is written.
    const parseLoose = text => {
      const without = text
        .replace(/\/\*[\s\S]*?\*\//g, "")
        .replace(/(^|[^:"'\\])\/\/.*$/gm, "$1")
        .replace(/,(\s*[}\]])/g, "$1");
      return JSON.parse(without);
    };
    const readOpencodeConfig = () => {
      const file = opencodeConfigFile();
      let text = "";
      try { text = fs.readFileSync(file, "utf8"); } catch {}
      if (text.trim() === "") return { settings: {}, problem: null, path: file, exists: false };
      try { return { settings: parseLoose(text), problem: null, path: file, exists: true }; }
      catch (error) { return { settings: null, problem: error.message, path: file, exists: true }; }
    };

    /// The MCP servers in a settings file, in the shape this engine reads: under
    /// `mcp.servers`. Older files (and other tools' installers) put them straight under
    /// `mcp`, with `enabled` where this engine writes `disabled` — both are read here.
    const mcpServersIn = settings => {
      const mcp = settings?.mcp;
      if (!mcp || typeof mcp !== "object") return {};
      const servers = {};
      const modern = mcp.servers && typeof mcp.servers === "object" ? mcp.servers : {};
      for (const [name, entry] of Object.entries(modern)) {
        if (entry && typeof entry === "object") servers[name] = entry;
      }
      for (const [name, entry] of Object.entries(mcp)) {
        if (name === "servers" || !entry || typeof entry !== "object" || Array.isArray(entry)) continue;
        const modern_ = { ...entry };
        if (modern_.enabled === false && modern_.disabled === undefined) modern_.disabled = true;
        delete modern_.enabled;
        if (typeof modern_.command === "string") modern_.command = [modern_.command];
        if (modern_.env && !modern_.environment) modern_.environment = modern_.env;
        delete modern_.env;
        if (!servers[name]) servers[name] = modern_;
      }
      return servers;
    };

    if (url.pathname === "/api/config" && request.method === "GET") {
      const file = readSettings();
      const live = await client.configSources().catch(() => null);
      return json({ ...file, live, opencode: readOpencodeConfig() });
    }
    if (url.pathname === "/api/config" && request.method === "PUT") {
      const body = await readBody(request);
      const settings = body?.settings;
      if (typeof settings !== "object" || settings === null || Array.isArray(settings)) {
        throw new HttpError(400, "That isn't a settings object.");
      }
      fs.mkdirSync(path.dirname(settingsFile()), { recursive: true });
      fs.writeFileSync(settingsFile(), JSON.stringify(settings, null, 2) + "\n");
      return json({ ok: true, path: settingsFile() });
    }

    // Bringing over what another tool wrote into opencode's own settings: the MCP servers it
    // lists, in the shape this engine reads. Nothing already here is overwritten.
    if (url.pathname === "/api/config/import" && request.method === "POST") {
      const body = await readBody(request);
      const wanted = typeof body?.name === "string" && body.name ? body.name : null;
      const theirs = readOpencodeConfig();
      if (theirs.problem) throw new HttpError(400, `opencode's settings can't be read: ${theirs.problem}`);
      const mine = readSettings();
      if (!mine.settings) throw new HttpError(400, "This app's settings file has a problem; fix it first.");
      const added = [];
      const skipped = [];
      // The MCP servers, whatever shape they were written in.
      const theirsServers = mcpServersIn(theirs.settings);
      const mineServers = mcpServersIn(mine.settings);
      for (const [name, entry] of Object.entries(theirsServers)) {
        if (wanted && name !== wanted) continue;
        if (mineServers[name]) { skipped.push(`mcp:${name}`); continue; }
        mine.settings.mcp = { ...(mine.settings.mcp ?? {}) };
        mine.settings.mcp.servers = { ...(mine.settings.mcp.servers ?? {}), [name]: entry };
        added.push(`mcp:${name}`);
      }
      // The agents and the commands, when they are asked for by name.
      for (const kind of ["agents", "commands"]) {
        const source = theirs.settings?.[kind];
        if (!source || typeof source !== "object") continue;
        const target = mine.settings[kind] && typeof mine.settings[kind] === "object" ? mine.settings[kind] : {};
        for (const [name, entry] of Object.entries(source)) {
          if (wanted && wanted !== `${kind}:${name}`) continue;
          if (target[name] != null) { skipped.push(`${kind}:${name}`); continue; }
          target[name] = entry;
          added.push(`${kind}:${name}`);
        }
        mine.settings[kind] = target;
      }
      // The model, when there is one and nothing is chosen here yet.
      if (!wanted && typeof theirs.settings?.model === "string" && !mine.settings.model) {
        mine.settings.model = theirs.settings.model;
        added.push("model");
      }
      if (added.length) {
        fs.mkdirSync(path.dirname(settingsFile()), { recursive: true });
        fs.writeFileSync(settingsFile(), JSON.stringify(mine.settings, null, 2) + "\n");
      }
      return json({ ok: true, added, skipped, path: settingsFile() });
    }

    if (url.pathname === "/api/engine/restart" && request.method === "POST") {
      const made = await restartEngine();
      log("engine started again");
      return json({ ok: true, version: made.version });
    }

    // MCP: live states for the list, and the connect/disconnect of one.
    if (url.pathname === "/api/mcp" && request.method === "GET") {
      return json({ servers: await client.mcpServers(currentProject ?? undefined).catch(() => []) });
    }
    const mcp = route(/^\/api\/mcp\/([^/]+)\/(connect|disconnect)$/);
    if (mcp && request.method === "POST") {
      if (mcp[1] === "connect") await client.mcpConnect(mcp[0], currentProject ?? undefined);
      else await client.mcpDisconnect(mcp[0]);
      return json({ ok: true });
    }

    // Skills: the engine's own list, plus ours on disk, one SKILL.md per folder.
    if (url.pathname === "/api/integrations" && request.method === "GET") {
      return json({ integrations: await client.integrations(currentProject ?? undefined).catch(() => []) });
    }

    if (url.pathname === "/api/providers" && request.method === "GET") {
      return json({ providers: await client.providers(currentProject ?? undefined).catch(() => []) });
    }

    if (url.pathname === "/api/skills" && request.method === "GET") {
      const skills = await client.skills(currentProject ?? undefined).catch(() => []);
      return json({ skills, folder: skillsFolder() });
    }
    const skill = route(/^\/api\/skill-file\/([a-z0-9-]{1,64})$/);
    if (skill) {
      const folder = path.join(skillsFolder(), skill[0]);
      if (request.method === "GET") {
        let text = "";
        try { text = fs.readFileSync(path.join(folder, "SKILL.md"), "utf8"); } catch {}
        return json({ id: skill[0], text });
      }
      if (request.method === "PUT") {
        const body = await readBody(request);
        if (typeof body?.text !== "string") throw new HttpError(400, "That isn't skill text.");
        fs.mkdirSync(folder, { recursive: true });
        fs.writeFileSync(path.join(folder, "SKILL.md"), body.text);
        return json({ ok: true, id: skill[0] });
      }
      if (request.method === "DELETE") {
        fs.rmSync(folder, { recursive: true, force: true });
        return json({ ok: true });
      }
    }

    // Forms: what the agent's question tool or an MCP server asks, answered or skipped.
    if (url.pathname.match(/^\/api\/sessions\/[^/]+\/forms$/) && request.method === "GET") {
      const id = route(/^\/api\/sessions\/([^/]+)\/forms$/)[0];
      return json({ forms: await client.forms(id) });
    }
    const formReply = route(/^\/api\/sessions\/([^/]+)\/forms\/([^/]+)\/reply$/);
    if (formReply && request.method === "POST") {
      const body = await readBody(request);
      await client.replyForm(formReply[0], formReply[1], body.answer ?? {});
      return json({ ok: true });
    }
    const formDismiss = route(/^\/api\/sessions\/([^/]+)\/forms\/([^/]+)$/);
    if (formDismiss && request.method === "DELETE") {
      await client.dismissForm(formDismiss[0], formDismiss[1], url.searchParams.get("message") ?? undefined);
      return json({ ok: true });
    }

    // Revert: take the session back to before a message; bring it all back again.
    if (url.pathname.match(/^\/api\/sessions\/[^/]+\/revert$/) && request.method === "POST") {
      const id = route(/^\/api\/sessions\/([^/]+)\/revert$/)[0];
      const body = await readBody(request);
      const revert = await client.stageRevert(id, body.messageID);
      return json({ revert });
    }
    if (url.pathname.match(/^\/api\/sessions\/[^/]+\/revert$/) && request.method === "DELETE") {
      const id = route(/^\/api\/sessions\/([^/]+)\/revert$/)[0];
      await client.clearRevert(id);
      return json({ ok: true });
    }

    // A mark of the app's own, as the Mac app keeps it. The flag goes out with the
    // session's own metadata, because the engine may merge metadata rather than replace
    // it (Workspace.swift:366-375): a session that is both pinned and archived keeps both.
    const mark = async (id, key, value) => {
      const current = await client.session(id);
      const metadata = { ...(current?.metadata ?? {}), [key]: value };
      await client.updateSession(id, { metadata });
      return metadata;
    };

    // Archiving: a mark of the app's own, as the Mac app keeps it.
    const archive = route(/^\/api\/sessions\/([^/]+)\/archive$/);
    if (archive && request.method === "POST") {
      const body = await readBody(request);
      const archived = body?.archived !== false;
      await mark(archive[0], "kuvo.archived", archived);
      return json({ ok: true, archived });
    }

    // Pinning: the same mark, the Mac's own key (Workspace.swift:342-364). A pinned
    // session sits at the top of the sidebar, and is not in the recents.
    const pin = route(/^\/api\/sessions\/([^/]+)\/pin$/);
    if (pin && request.method === "POST") {
      const body = await readBody(request);
      const pinned = body?.pinned !== false;
      await mark(pin[0], "kuvo.pinned", pinned);
      return json({ ok: true, pinned });
    }

    // The session's own rules: what the agent may do without asking, and what waits for
    // an OK (OpenCodeAPI.swift:339-343).
    const rules = route(/^\/api\/sessions\/([^/]+)\/permissions$/);
    if (rules && request.method === "POST") {
      const body = await readBody(request);
      await client.setPermissions(rules[0], Array.isArray(body.permissions) ? body.permissions : []);
      return json({ ok: true });
    }

    const rename = route(/^\/api\/sessions\/([^/]+)\/rename$/);
    if (rename && request.method === "POST") {
      const body = await readBody(request);
      await client.renameSession(rename[0], String(body.title ?? "").trim());
      return json({ ok: true });
    }

    const fork = route(/^\/api\/sessions\/([^/]+)\/fork$/);
    if (fork && request.method === "POST") {
      const body = await readBody(request);
      const branched = await client.forkSession(fork[0], { before: body.before });
      return json({ session: branched });
    }

    const command = route(/^\/api\/sessions\/([^/]+)\/command$/);
    if (command && request.method === "POST") {
      const body = await readBody(request);
      await client.runCommand({ session: command[0], name: body.name, text: body.text, delivery: body.delivery === "queue" ? "queue" : "steer" });
      return json({ ok: true });
    }

    const agent = route(/^\/api\/sessions\/([^/]+)\/agent$/);
    if (agent && request.method === "POST") {
      const body = await readBody(request);
      await client.selectAgent(agent[0], body.agent);
      return json({ ok: true });
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
      const files = Array.isArray(body.files) ? body.files : [];
      // A picture alone is a message, as it is on the Mac (Composer.swift:109-113: the
      // words may be empty when a file goes with them).
      if (text === "" && files.length === 0) throw new HttpError(400, "An empty message has nothing to send.");
      // Attachments travel as the page holds them: the client gives them the shape the
      // engine takes (OpenCodeKit's PromptFile — a URI and a name).
      const id = await client.prompt({ session: prompt[0], id: body.id, text, files, delivery: body.delivery === "queue" ? "queue" : "steer" });
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
