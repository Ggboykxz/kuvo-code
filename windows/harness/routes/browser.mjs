#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { HttpError } from "../server.mjs";

const BROWSER_DIR = path.join(os.homedir(), ".kuvo-code", "browser");
const ENGINE_FILE = path.join(BROWSER_DIR, "engine.json");
const HISTORY_FILE = path.join(BROWSER_DIR, "history.json");
const COOKIES_FILE = path.join(BROWSER_DIR, "cookies.json");

function readJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return fallback; }
}

function writeJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2));
}

export async function handle(ctx, request, response, url) {
  const json = (what) => {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(what));
  };

  // Search engine
  if (url.pathname === "/api/browser/search-engine" && request.method === "GET") {
    const data = readJson(ENGINE_FILE, { engine: "google" });
    return json({ engine: data.engine });
  }
  if (url.pathname === "/api/browser/search-engine" && request.method === "POST") {
    const body = await ctx.readBody(request);
    const engine = body.engine;
    if (!["google", "bing", "duckduckgo"].includes(engine)) throw new HttpError(400, "Invalid search engine.");
    writeJson(ENGINE_FILE, { engine });
    return json({ ok: true, engine });
  }

  // History
  if (url.pathname === "/api/browser/history" && request.method === "GET") {
    const data = readJson(HISTORY_FILE, { entries: [] });
    return json({ entries: data.entries, count: data.entries.length });
  }
  if (url.pathname === "/api/browser/history" && request.method === "DELETE") {
    writeJson(HISTORY_FILE, { entries: [] });
    return json({ ok: true });
  }

  // Cookies / Website data
  if (url.pathname === "/api/browser/cookies" && request.method === "GET") {
    const data = readJson(COOKIES_FILE, { cookies: [] });
    return json({ cookies: data.cookies });
  }
  if (url.pathname === "/api/browser/cookies" && request.method === "DELETE") {
    writeJson(COOKIES_FILE, { cookies: [] });
    return json({ ok: true });
  }
  if (url.pathname.startsWith("/api/browser/cookies/") && request.method === "DELETE") {
    const domain = decodeURIComponent(url.pathname.slice("/api/browser/cookies/".length));
    const data = readJson(COOKIES_FILE, { cookies: [] });
    data.cookies = data.cookies.filter(c => c.domain !== domain);
    writeJson(COOKIES_FILE, data);
    return json({ ok: true });
  }

  return false;
}
