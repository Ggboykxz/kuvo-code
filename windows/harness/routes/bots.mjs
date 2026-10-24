#!/usr/bin/env node
// This computer's bots, read from their own folders under ~/.kuvo-code/bots, as the machine's
// link lists them (kuvo-link.js, `listBots`). A bot is made and changed in Kuvo Code on a Mac,
// which writes what it is told; this side lists the ones that live here and never edits them.
//
// The folders are read here rather than through kuvo-link.js because the harness ships as one
// executable: the bridge uses `import.meta.url` and would not survive the bundle.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { HttpError } from "../server.mjs";

// Read when asked, not when this file loads: the tests point KUVO_HOME at a folder of their own.
const botsFolder = () => path.join(process.env.KUVO_HOME || path.join(os.homedir(), ".kuvo-code"), "bots");

function textOf(file) {
  try { return fs.readFileSync(file, "utf8"); } catch { return null; }
}

function namesIn(folder) {
  try { return fs.readdirSync(folder); } catch { return []; }
}

// Each bot by its session, with what its folder says now: paused, its wake-ups, its watches.
function listBots() {
  const bots = [];
  const home = botsFolder();
  for (const id of namesIn(home)) {
    if (!/^bot_[A-Za-z0-9]+$/.test(id)) continue;
    const folder = path.join(home, id);
    let described;
    try { described = JSON.parse(textOf(path.join(folder, "bot.json")) ?? ""); } catch { continue; }
    const session = (textOf(path.join(folder, "session")) ?? "").trim();
    if (described?.kuvo !== 1 || described.id !== id || typeof described.name !== "string" || !session) continue;
    bots.push({
      id,
      session,
      name: described.name,
      job: typeof described.job === "string" ? described.job : "",
      look: described.look ?? null,
      model: described.model ?? null,
      paused: fs.existsSync(path.join(folder, "paused")),
      wakes: namesIn(path.join(folder, "wakes")).length,
      watching: namesIn(path.join(folder, "watches")).length,
      agents: (textOf(path.join(folder, "via")) ?? "").trim() === "bridge",
      created: String(described.created ?? ""),
    });
  }
  // In the order they were made, as the Mac's list is.
  return bots.sort((a, b) => a.created.localeCompare(b.created));
}

export async function handle(ctx, request, response, url) {
  if (url.pathname !== "/api/bots") return false;
  if (request.method !== "GET" && request.method !== "HEAD") {
    throw new HttpError(405, "Bots are read with GET.");
  }
  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify({ bots: listBots() }));
  return true;
}
