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

        if (url.pathname === "/api/state" && request.method === "GET") return json(ctx.state());

        // A provider's mark (ProviderLogo.swift): the server fetches it from models.opencode.ai
        // — the same place the Mac fetches it from — and keeps it. A mark that cannot be had
        // is an empty answer, not an error: the page draws the provider's initial instead.
        if (url.pathname.startsWith("/api/logo/") && request.method === "GET") {
          const id = decodeURIComponent(url.pathname.slice("/api/logo/".length));
          const mark = await ctx.logoFor(id);
          response.writeHead(200, { "content-type": "image/svg+xml; charset=utf-8", "cache-control": "public, max-age=86400" });
          response.end(mark ?? "");
          return true;
        }

        if (url.pathname === "/api/project" && request.method === "POST") {
          const body = await ctx.readBody(request);
          ctx.currentProject = ctx.directoryOf(body.directory);
          ctx.rememberProject(ctx.currentProject);
          return json({ project: ctx.currentProject });
        }

        // The project list, kept across runs like the Mac app keeps its own.
        if (url.pathname === "/api/projects" && request.method === "GET") {
          const settings = ctx.projectSettings();
          const names = {};
          const runs = {};
          const folders = {};
          for (const [folder, own] of Object.entries(settings)) {
            if (own && typeof own.name === "string" && own.name) names[folder] = own.name;
            if (own && typeof own.run === "string" && own.run) runs[folder] = own.run;
            if (own && Array.isArray(own.folders) && own.folders.length) folders[folder] = own.folders;
          }
          return json({ projects: ctx.recentProjects(), current: ctx.currentProject, names, runs, folders });
        }
        if (url.pathname === "/api/projects/settings" && request.method === "POST") {
          const body = await ctx.readBody(request);
          const folder = ctx.directoryOf(body.path);
          if (!folder) throw new HttpError(400, "A project needs a folder.");
          const settings = ctx.projectSettings();
          const own = { ...(settings[folder] ?? {}) };
          // Only what the call carries is touched: the name and the run command are the
          // project's own, and one is not lost for the other.
          if (body.name !== undefined) {
            if (body.name === null || body.name === "") delete own.name;
            else own.name = String(body.name).trim();
          }
          if (body.run !== undefined) {
            if (body.run === null || body.run === "") delete own.run;
            else own.run = String(body.run).trim();
          }
          if (body.folders !== undefined) {
            const list = Array.isArray(body.folders) ? body.folders.map(item => String(item)).filter(Boolean) : [];
            if (!list.length) delete own.folders;
            else own.folders = list;
          }
          if (Object.keys(own).length === 0) delete settings[folder];
          else settings[folder] = own;
          ctx.saveProjectSettings(settings);
          return json({ ok: true, name: own.name ?? null, run: own.run ?? null });
        }
        if (url.pathname === "/api/projects" && request.method === "DELETE") {
          const body = await ctx.readBody(request);
          const folder = ctx.directoryOf(body.path);
          ctx.saveRecentProjects(ctx.recentProjects().filter(item => item !== folder));
          return json({ ok: true });
        }

        // Worktrees: the engine makes a git worktree of a project, in its data folder.
        if (url.pathname === "/api/location" && request.method === "GET") {
          const { client } = await ctx.ensureEngine();
          const directory = ctx.directoryOf(url.searchParams.get("directory") ?? ctx.currentProject);
          return json(await client.location(directory));
        }
        if (url.pathname === "/api/worktree" && request.method === "POST") {
          const body = await ctx.readBody(request);
          const { client } = await ctx.ensureEngine();
          const projectID = body.projectID ?? body.projectId ?? body.project;
          const directory = await client.createWorktree(projectID, body.name);
          return json({ directory });
        }
        if (url.pathname === "/api/worktree" && request.method === "DELETE") {
          const body = await ctx.readBody(request);
          const { client } = await ctx.ensureEngine();
          const projectID = body.projectID ?? body.projectId ?? body.project;
          await client.removeWorktree(projectID, body.directory, Boolean(body.force));
          return json({ ok: true });
        }

        // Credentials, kept in memory only: the usage panel's way in to a provider's plan.
        if (url.pathname === "/api/credential" && request.method === "GET") {
          const { client } = await ctx.ensureEngine();
          const answer = await client.credentialSecrets();
          const credentials = Array.isArray(answer) ? answer : (Array.isArray(answer?.data) ? answer.data : (Array.isArray(answer?.credentials) ? answer.credentials : []));
          return json({ credentials });
        }

        // Coding agents on this machine: the Mac's OutsideAgents detects them by their CLI.
        // We do the same, so the user sees which ones are available.
        if (url.pathname === "/api/agents/detect" && request.method === "GET") {
          const { execFile } = await import("node:child_process");
          const { promisify } = await import("node:util");
          const run = promisify(execFile);
          const agents = [
            { id: "claude-code", name: "Claude Code", binary: process.platform === "win32" ? "claude.exe" : "claude", logo: "anthropic" },
            { id: "codex-cli", name: "Codex", binary: process.platform === "win32" ? "codex.exe" : "codex", logo: "openai" },
            { id: "cursor", name: "Cursor", binary: process.platform === "win32" ? "cursor.exe" : "cursor", logo: "cursor" },
            { id: "grok-cli", name: "Grok", binary: process.platform === "win32" ? "grok.exe" : "grok", logo: "xai" },
            { id: "antigravity", name: "Antigravity", binary: process.platform === "win32" ? "antigravity.exe" : "antigravity", logo: "google" },
          ];
          const found = await Promise.all(agents.map(async agent => {
            let installed = false;
            try {
              const cmd = process.platform === "win32" ? "where" : "which";
              await run(cmd, [agent.binary], { stdio: ["ignore", "pipe", "pipe"] });
              installed = true;
            } catch { installed = false; }
            return { ...agent, installed };
          }));
          return json({ agents: found });
        }

        // Plan usage: what each connected provider's own plan says (limits, pace, spend).
        // The Mac reads these through UsageKit; here we ask the providers directly, with the
        // credentials the engine holds, and keep the secrets on this machine.
        if (url.pathname === "/api/usage/plans" && request.method === "GET") {
          const { client } = await ctx.ensureEngine();
          const answer = await client.credentialSecrets();
          const credentials = Array.isArray(answer) ? answer : (Array.isArray(answer?.data) ? answer.data : (Array.isArray(answer?.credentials) ? answer.credentials : []));
          const plans = [];
          for (const credential of credentials) {
            if (!credential?.active) continue;
            const integration = credential.integrationID ?? credential.integration_id;
            const secret = credential.value?.access ?? credential.value?.key;
            if (!secret) continue;
            const signedIn = credential.value?.type === "oauth" || !!credential.value?.access;
            try {
              if (integration === "github-copilot") {
                const response = await fetch("https://api.github.com/copilot_internal/user", {
                  headers: { Authorization: `token ${secret}`, "User-Agent": "Kuvo-Code", Accept: "application/json" },
                });
                if (response.ok) {
                  const data = await response.json();
                  plans.push({ provider: "github-copilot", kind: "copilot", data });
                } else {
                  plans.push({ provider: "github-copilot", kind: "copilot", error: `HTTP ${response.status}` });
                }
              } else if (integration === "openrouter") {
                const response = await fetch("https://openrouter.ai/api/v1/credits", {
                  headers: { Authorization: `Bearer ${secret}`, "User-Agent": "Kuvo-Code" },
                });
                if (response.ok) {
                  const data = await response.json();
                  plans.push({ provider: "openrouter", kind: "openrouter", data: data?.data ?? data });
                } else {
                  plans.push({ provider: "openrouter", kind: "openrouter", error: `HTTP ${response.status}` });
                }
              } else {
                const provider = integration === "openai" ? (signedIn ? "codex" : null)
                  : integration === "xai" ? (signedIn ? "grok" : null)
                  : integration === "zai" || integration === "zai-coding-plan" ? "zai"
                  : integration === "opencode" || integration === "opencode-go" ? "opencode"
                  : null;
                if (provider) plans.push({ provider: integration, kind: provider, status: "not-yet-supported" });
              }
            } catch (error) {
              plans.push({ provider: integration, kind: integration, error: String(error?.message ?? error) });
            }
          }
          return json({ plans });
        }

        // What the settings panel shows about this machine's storage.
        if (url.pathname === "/api/storage" && request.method === "GET") {
          const logsDir = path.join(os.homedir(), ".kuvo-code", "logs");
          const logPath = path.join(logsDir, "harness.log");
          let logSize = 0;
          try { logSize = fs.statSync(logPath).size; } catch {}
          let attachments = null;
          if (ctx.currentProject) {
            const folder = path.join(ctx.currentProject, ".kuvo", "attachments");
            let files = [];
            try { files = fs.readdirSync(folder).map(name => path.join(folder, name)); } catch {}
            attachments = { path: folder, files: files.length, bytes: files.reduce((sum, file) => sum + (fs.statSync(file).size || 0), 0) };
          }
          return json({ logPath, logSize, attachments, engine: ctx.state().engine, project: ctx.currentProject });
        }

        // The page's folder picker: what's under a folder, so someone can walk to theirs.
        if (url.pathname === "/api/browse" && request.method === "GET") {
          const asked = url.searchParams.get("path");
          const home = os.homedir();
          let folder = asked ? path.resolve(asked) : ctx.currentProject ?? home;
          // Keep the picker from wandering outside the user's home (or the open project).
          if (asked && folder !== home && !folder.startsWith(home + path.sep)
              && !(ctx.currentProject && (folder === ctx.currentProject || folder.startsWith(ctx.currentProject + path.sep)))) {
            folder = ctx.currentProject ?? home;
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
          // Stop walking above the user's home.
          const parentAllowed = parent !== folder && (parent === home || parent.startsWith(home + path.sep) || !(folder === home || folder.startsWith(home + path.sep)));
          return json({ path: folder, parent: parentAllowed ? parent : null, folders, files });
        }

  return false;
}
