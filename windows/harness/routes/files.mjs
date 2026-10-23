#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { HttpError } from "../server.mjs";

export async function handle(ctx, request, response, url) {
  const route = (pattern) => url.pathname.match(pattern)?.slice(1).map(decodeURIComponent) ?? null;
  const json = (what) => {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(what));
  };

      // Files: read and write within the project. No engine needed.
      if (url.pathname === "/api/file" && request.method === "GET") {
        const asked = url.searchParams.get("path");
        if (!asked) throw new HttpError(400, "No file was given.");
        // A path in the project (what a reply's file link holds) or an absolute one.
        const resolved = path.isAbsolute(asked) ? path.resolve(asked) : path.resolve(ctx.currentProject ?? ".", asked);
        if (ctx.currentProject && resolved !== ctx.currentProject && !resolved.startsWith(ctx.currentProject + path.sep)) {
          throw new HttpError(403, "That file is outside the project.");
        }
        let content;
        try { content = fs.readFileSync(resolved, "utf8"); }
        catch { throw new HttpError(404, "There's no such file."); }
        return json({ path: resolved, content });
      }
      if (url.pathname === "/api/file" && request.method === "POST") {
        const body = await ctx.readBody(request);
        if (!body.path) throw new HttpError(400, "No file was given.");
        const resolved = path.resolve(body.path);
        if (ctx.currentProject && resolved !== ctx.currentProject && !resolved.startsWith(ctx.currentProject + path.sep)) {
          throw new HttpError(403, "That file is outside the project.");
        }
        fs.mkdirSync(path.dirname(resolved), { recursive: true });
        fs.writeFileSync(resolved, String(body.content ?? ""), "utf8");
        return json({ ok: true, path: resolved });
      }
      if (url.pathname === "/api/file" && request.method === "DELETE") {
        const asked = url.searchParams.get("path");
        if (!asked) throw new HttpError(400, "No file was given.");
        const resolved = path.resolve(asked);
        if (ctx.currentProject && resolved !== ctx.currentProject && !resolved.startsWith(ctx.currentProject + path.sep)) {
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
        const body = await ctx.readBody(request);
        if (!body.path) throw new HttpError(400, "No folder was given.");
        const resolved = path.resolve(body.path);
        if (ctx.currentProject && resolved !== ctx.currentProject && !resolved.startsWith(ctx.currentProject + path.sep)) {
          throw new HttpError(403, "That folder is outside the project.");
        }
        fs.mkdirSync(resolved, { recursive: true });
        return json({ ok: true, path: resolved });
      }

      // Search: which files contain a string, with the matching lines.
      if (url.pathname === "/api/search" && request.method === "GET") {
        const root = ctx.currentProject;
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
      // Search across the project's sessions for a string in their messages.
      if (url.pathname === "/api/search/sessions" && request.method === "GET") {
        if (!ctx.currentProject) throw new HttpError(400, "No project folder is open.");
        const query = String(url.searchParams.get("q") ?? "").trim().toLowerCase();
        if (query === "") return json({ matches: [] });
        const { client } = await ctx.ensureEngine();
        const sessions = await client.sessions({ directory: ctx.currentProject });
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
        // The project's files, by name: the file links of a reply (the Mac app's FileLinks) ask
        // which of them are real, and the list is the answer.
        if (url.pathname === "/api/project-files" && request.method === "GET") {
          if (!ctx.currentProject) throw new HttpError(400, "No project is open.");
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
              if (entry.isFile()) found.push(path.relative(ctx.currentProject, full).replace(/\\/g, "/"));
            }
          };
          walk(ctx.currentProject, 0);
          return json({ files: found });
        }
        // The project's files by name, for the prompt's @-mentions, the palette and Open
        // Quickly. Open Quickly asks for the newest first (the Mac's ProjectFiles.newestFirst),
        // and for more of them than the mentions list asks for.
        if (url.pathname === "/api/files" && request.method === "GET") {
          const query = (url.searchParams.get("q") ?? "").toLowerCase();
          const recent = url.searchParams.get("sort") === "recent";
          const asked = Number(url.searchParams.get("limit"));
          const limit = Number.isFinite(asked) && asked > 0 ? Math.min(Math.floor(asked), 2000) : 40;
          if (!ctx.currentProject) throw new HttpError(400, "No project is open.");
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
              if (entry.isFile()) found.push(full);
            }
          };
          walk(ctx.currentProject, 0);
          let matches = query
            ? found.filter(file => file.toLowerCase().replace(/\\/g, "/").includes(query))
            : found;
          if (recent) {
            // A file that vanished as it was read is the oldest, not a reason to fail.
            const when = file => { try { return fs.statSync(file).mtimeMs; } catch { return 0; } };
            matches = [...matches].sort((left, right) => when(right) - when(left));
          }
          return json({ files: matches.slice(0, limit).map(file => ({
            path: file,
            name: path.basename(file),
            relative: path.relative(ctx.currentProject, file).replace(/\\/g, "/"),
          })) });
        }
        if (url.pathname === "/api/raw" && request.method === "GET") {
          const asked = url.searchParams.get("path");
          if (!asked) throw new HttpError(400, "No file was given.");
          const resolved = path.resolve(asked);
          if (ctx.currentProject && resolved !== ctx.currentProject && !resolved.startsWith(ctx.currentProject + path.sep)) {
            throw new HttpError(403, "That file is outside the project.");
          }
          let data;
          try { data = fs.readFileSync(resolved); }
          catch { throw new HttpError(404, "There's no such file."); }
          const kinds = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp", ".bmp": "image/bmp", ".svg": "image/svg+xml", ".ico": "image/x-icon" };
          const type = kinds[path.extname(resolved).toLowerCase()] ?? "application/octet-stream";
          response.writeHead(200, { "content-type": type, "cache-control": "no-store" });
          response.end(data);
          return true;
        }
        if (url.pathname === "/api/upload" && request.method === "POST") {
          const body = await ctx.readBody(request);
          if (!ctx.currentProject) throw new HttpError(400, "No project is open.");
          if (!body.data) throw new HttpError(400, "Nothing was uploaded.");
          const name = (body.name ?? "attachment").replace(/[\\/:*?"<>|]/g, "_");
          const folder = path.join(ctx.currentProject, ".kuvo", "attachments");
          fs.mkdirSync(folder, { recursive: true });
          const target = path.join(folder, `${Date.now()}-${name}`);
          fs.writeFileSync(target, Buffer.from(String(body.data), "base64"));
          return json({ path: target, name });
        }
        if (url.pathname === "/api/vcs" && request.method === "GET") {
          const { client } = await ctx.ensureEngine();
          return json({ vcs: await client.vcs(ctx.currentProject ?? undefined) });
        }

  return false;
}
