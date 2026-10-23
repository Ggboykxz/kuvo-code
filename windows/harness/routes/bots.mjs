#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { HttpError } from "../server.mjs";

export async function handle(ctx, request, response, url) {
  const json = (what) => {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(what));
  };

  // List bots from the machine's bridge
  if (url.pathname === "/api/bots" && request.method === "GET") {
    if (!ctx.currentProject) throw new HttpError(400, "No project folder is open.");
    const link = await import("../../Packages/KuvoLink/Sources/KuvoLink/Resources/kuvo-link.js");
    try {
      const bots = link.listBots(ctx.currentProject);
      return json({ bots });
    } catch (error) {
      throw new HttpError(500, error.message);
    }
  }

  // Create or update a bot
  if (url.pathname === "/api/bots" && request.method === "POST") {
    if (!ctx.currentProject) throw new HttpError(400, "No project folder is open.");
    const body = await ctx.readBody(request);
    const { id, name, personality, model, look, machine, project, wakeUps, keys } = body;
    if (!name || !name.trim()) throw new HttpError(400, "A bot needs a name.");
    if (!model || !model.trim()) throw new HttpError(400, "A bot needs a model.");

    const link = await import("../../Packages/KuvoLink/Sources/KuvoLink/Resources/kuvo-link.js");
    try {
      const botDir = path.join(link.K, "bots", id || `bot_${Date.now()}`);
      fs.mkdirSync(path.join(botDir, "wakes"), { recursive: true });
      fs.writeFileSync(path.join(botDir, "MEMORY.md"), `# ${name}'s memory\n`);
      fs.writeFileSync(path.join(botDir, "session"), `ses_${path.basename(botDir)}`);
      const descriptor = {
        kuvo: 1,
        id: path.basename(botDir),
        name: name.trim(),
        job: personality || "Watches the build",
        look: look || { color: "sky", shape: "round", face: "calm" },
        model: { id: model.trim(), providerID: "opencode" },
        created: new Date().toISOString(),
        updated: new Date().toISOString(),
      };
      fs.writeFileSync(path.join(botDir, "bot.json"), JSON.stringify(descriptor, null, 2));
      if (project) fs.writeFileSync(path.join(botDir, "project"), project);
      if (wakeUps) fs.writeFileSync(path.join(botDir, "wakeUps"), JSON.stringify(wakeUps));
      if (keys) fs.writeFileSync(path.join(botDir, "keys"), JSON.stringify(keys));
      return json({ ok: true, id: descriptor.id });
    } catch (error) {
      throw new HttpError(500, error.message);
    }
  }

  // Delete a bot
  if (url.pathname.startsWith("/api/bots/") && request.method === "DELETE") {
    const id = decodeURIComponent(url.pathname.slice("/api/bots/".length));
    const link = await import("../../Packages/KuvoLink/Sources/KuvoLink/Resources/kuvo-link.js");
    try {
      const botDir = path.join(link.K, "bots", id);
      if (fs.existsSync(botDir)) fs.rmSync(botDir, { recursive: true, force: true });
      return json({ ok: true });
    } catch (error) {
      throw new HttpError(500, error.message);
    }
  }

  // Get bot templates
  if (url.pathname === "/api/bots/templates" && request.method === "GET") {
    const link = await import("../../Packages/KuvoLink/Sources/KuvoLink/Resources/kuvo-link.js");
    try {
      const templates = link.botTemplates?.() ?? [];
      return json({ templates });
    } catch {
      return json({ templates: [] });
    }
  }

  return false;
}
