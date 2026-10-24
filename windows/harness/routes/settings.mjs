#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { engineFolders } from "../../kuvo-engine.mjs";
import { HttpError } from "../server.mjs";

export async function handle(ctx, request, response, url) {
  const route = (pattern) => url.pathname.match(pattern)?.slice(1).map(decodeURIComponent) ?? null;
  const json = (what) => {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(what));
  };

        if (url.pathname === "/api/permission/saved" && request.method === "GET") {
          const { client } = await ctx.ensureEngine();
          return json({ saved: await client.savedPermissions() });
        }
        if (url.pathname === "/api/permission/saved" && request.method === "DELETE") {
          const { client } = await ctx.ensureEngine();
          const body = await ctx.readBody(request);
          await client.removeSavedPermission(body.id);
          return json({ ok: true });
        }

        // The engine's read-only lists, for the settings page.
        if (url.pathname === "/api/config-lists" && request.method === "GET") {
          const { client } = await ctx.ensureEngine();
          const [skills, mcp, providers] = await Promise.all([
            client.skills(ctx.currentProject ?? undefined).catch(() => []),
            client.mcpServers(ctx.currentProject ?? undefined).catch(() => []),
            client.providers(ctx.currentProject ?? undefined).catch(() => []),
          ]);
          return json({ skills, mcp, providers });
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
          const body = await ctx.readBody(request);
          writeShellConfig(body ?? {});
          return json(readShellConfig());
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
          const { client } = await ctx.ensureEngine();
          const file = readSettings();
          const live = await client.configSources().catch(() => null);
          return json({ ...file, live, opencode: readOpencodeConfig() });
        }
        if (url.pathname === "/api/config" && request.method === "PUT") {
          const body = await ctx.readBody(request);
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
          const body = await ctx.readBody(request);
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
          const made = await ctx.restartEngine();
          ctx.log("engine started again");
          return json({ ok: true, version: made.version });
        }

        // MCP: live states for the list, and the connect/disconnect of one.
        if (url.pathname === "/api/mcp" && request.method === "GET") {
          const { client } = await ctx.ensureEngine();
          return json({ servers: await client.mcpServers(ctx.currentProject ?? undefined).catch(() => []) });
        }
        const mcp = route(/^\/api\/mcp\/([^/]+)\/(connect|disconnect)$/);
        if (mcp && request.method === "POST") {
          const { client } = await ctx.ensureEngine();
          if (mcp[1] === "connect") await client.mcpConnect(mcp[0], ctx.currentProject ?? undefined);
          else await client.mcpDisconnect(mcp[0]);
          return json({ ok: true });
        }

        // Skills: the engine's own list, plus ours on disk, one SKILL.md per folder.
        if (url.pathname === "/api/integrations" && request.method === "GET") {
          const { client } = await ctx.ensureEngine();
          return json({ integrations: await client.integrations(ctx.currentProject ?? undefined).catch(() => []) });
        }

        if (url.pathname === "/api/providers" && request.method === "GET") {
          const { client } = await ctx.ensureEngine();
          return json({ providers: await client.providers(ctx.currentProject ?? undefined).catch(() => []) });
        }

        if (url.pathname === "/api/skills" && request.method === "GET") {
          const { client } = await ctx.ensureEngine();
          const skills = await client.skills(ctx.currentProject ?? undefined).catch(() => []);
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
            const body = await ctx.readBody(request);
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

  return false;
}
