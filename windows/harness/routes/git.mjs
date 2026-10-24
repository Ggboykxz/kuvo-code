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

      // Git: status and diff for the project, if it's a repository.
      if (url.pathname === "/api/git/status" && request.method === "GET") {
        if (!ctx.currentProject) throw new HttpError(400, "No project folder is open.");
        const { execFileSync } = await import("node:child_process");
        let output = "";
        try { output = execFileSync("git", ["status", "--porcelain"], { cwd: ctx.currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }); }
        catch { return json({ repository: false, entries: [] }); }
        const entries = output.split("\n").filter(Boolean).map(line => ({
          code: line.slice(0, 2),
          path: line.slice(3).trim(),
        }));
        return json({ repository: true, entries });
      }
      if (url.pathname === "/api/git/diff" && request.method === "GET") {
        if (!ctx.currentProject) throw new HttpError(400, "No project folder is open.");
        const asked = url.searchParams.get("path");
        if (asked && (asked.includes("..") || path.isAbsolute(asked))) throw new HttpError(400, "That path isn't allowed.");
        const { execFileSync } = await import("node:child_process");
        let output = "";
        try {
          const args = asked ? ["diff", "--", asked] : ["diff"];
          output = execFileSync("git", args, { cwd: ctx.currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
        } catch { output = ""; }
        return json({ diff: output });
      }

      // Git: stage, unstage, commit.
      if (url.pathname === "/api/git/stage" && request.method === "POST") {
        if (!ctx.currentProject) throw new HttpError(400, "No project folder is open.");
        const body = await ctx.readBody(request);
        const files = Array.isArray(body.paths) ? body.paths : (body.path ? [body.path] : []);
        if (files.some(file => typeof file !== "string" || file.includes("..") || path.isAbsolute(file))) throw new HttpError(400, "That path isn't allowed.");
        const { execFileSync } = await import("node:child_process");
        try { execFileSync("git", ["add", "--", ...files], { cwd: ctx.currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }); }
        catch (error) { throw new HttpError(500, error?.stderr?.toString() || error.message); }
        return json({ ok: true });
      }
      if (url.pathname === "/api/git/unstage" && request.method === "POST") {
        if (!ctx.currentProject) throw new HttpError(400, "No project folder is open.");
        const body = await ctx.readBody(request);
        const files = Array.isArray(body.paths) ? body.paths : (body.path ? [body.path] : []);
        if (files.some(file => typeof file !== "string" || file.includes("..") || path.isAbsolute(file))) throw new HttpError(400, "That path isn't allowed.");
        const { execFileSync } = await import("node:child_process");
        try { execFileSync("git", ["reset", "HEAD", "--", ...files], { cwd: ctx.currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }); }
        catch (error) { throw new HttpError(500, error?.stderr?.toString() || error.message); }
        return json({ ok: true });
      }
      if (url.pathname === "/api/git/commit" && request.method === "POST") {
        if (!ctx.currentProject) throw new HttpError(400, "No project folder is open.");
        const body = await ctx.readBody(request);
        const message = String(body.message ?? "").trim();
        if (message === "") throw new HttpError(400, "A commit needs a message.");
        const { execFileSync } = await import("node:child_process");
        let output = "";
        try { output = execFileSync("git", ["commit", "-m", message], { cwd: ctx.currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }); }
        catch (error) { throw new HttpError(500, (error?.stdout?.toString() || "") + (error?.stderr?.toString() || error.message)); }
        return json({ ok: true, output });
      }

      // Git: branches, checkout, amend.
      if (url.pathname === "/api/git/branches" && request.method === "GET") {
        if (!ctx.currentProject) throw new HttpError(400, "No project folder is open.");
        const { execFileSync } = await import("node:child_process");
        let output = "";
        let current = "";
        try {
          output = execFileSync("git", ["branch", "--list", "--no-abbrev"], { cwd: ctx.currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
          current = execFileSync("git", ["branch", "--show-current"], { cwd: ctx.currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
        } catch { return json({ repository: false, branches: [], current: "" }); }
        const branches = output.split("\n").map(line => line.trim().replace(/^\* /, "")).filter(Boolean);
        return json({ repository: true, branches, current });
      }
      if (url.pathname === "/api/git/checkout" && request.method === "POST") {
        if (!ctx.currentProject) throw new HttpError(400, "No project folder is open.");
        const body = await ctx.readBody(request);
        const name = String(body.name ?? "").trim();
        if (name === "") throw new HttpError(400, "No branch was given.");
        if (name.startsWith("-") || !/^[A-Za-z0-9._\\/-]+$/.test(name)) throw new HttpError(400, "That branch name isn't allowed.");
        const { execFileSync } = await import("node:child_process");
        try { execFileSync("git", ["checkout", name], { cwd: ctx.currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }); }
        catch (error) { throw new HttpError(500, error?.stderr?.toString() || error.message); }
        return json({ ok: true });
      }
      if (url.pathname === "/api/git/branch" && request.method === "POST") {
        const body = await ctx.readBody(request);
        const directory = ctx.directoryOf(body.directory ?? ctx.currentProject);
        if (!directory) throw new HttpError(400, "No project folder is open.");
        const name = String(body.name ?? "").trim();
        if (name === "") throw new HttpError(400, "No branch name was given.");
        if (name.startsWith("-") || !/^[A-Za-z0-9._\\/-]+$/.test(name)) throw new HttpError(400, "That branch name isn't allowed.");
        const { execFileSync } = await import("node:child_process");
        try { execFileSync("git", ["checkout", "-b", name], { cwd: directory, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }); }
        catch (error) { throw new HttpError(500, error?.stderr?.toString() || error.message); }
        return json({ ok: true });
      }
      if (url.pathname === "/api/git/amend" && request.method === "POST") {
        if (!ctx.currentProject) throw new HttpError(400, "No project folder is open.");
        const body = await ctx.readBody(request);
        const { execFileSync } = await import("node:child_process");
        const message = String(body.message ?? "").trim();
        const args = message ? ["commit", "--amend", "-m", message] : ["commit", "--amend", "--no-edit"];
        try { execFileSync("git", args, { cwd: ctx.currentProject, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }); }
        catch (error) { throw new HttpError(500, error?.stderr?.toString() || error.message); }
        return json({ ok: true });
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
          // Git is asked for the whole file as context, so the unchanged stretches can be
          // folded (ProjectChanges.swift:5-6, 179) — the Mac's own arguments.
          const whole = ["--no-color", "--find-renames", "-U100000"];
          // A file too big to read through (a huge or minified one): named, not shown
          // (ProjectChanges.swift:507-511).
          const maxLines = 20_000;
          const maxLineLength = 20_000;
          const add = async (path, patch, status) => {
            if (!patch) return;
            const lines = patch.split("\n");
            const additions = lines.filter(line => line.startsWith("+") && !line.startsWith("+++")).length;
            const deletions = lines.filter(line => line.startsWith("-") && !line.startsWith("---")).length;
            const tooBig = lines.length > maxLines || lines.some(line => line.length > maxLineLength);
            files.push({ file: path, patch: tooBig ? "" : patch, additions, deletions, status, tooBig });
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
              await add(name, await git(directory, ["diff", ...whole, fork, "--", name]), "modified");
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
            for (const name of names) await add(name, await git(directory, ["diff", ...whole, "--", name]), "modified");
          } else if (scope === "staged") {
            const names = (await git(directory, ["diff", "--cached", "--name-only"])).split("\n").filter(Boolean);
            for (const name of names) await add(name, await git(directory, ["diff", "--cached", ...whole, "--", name]), "staged");
          } else {
            const names = (await git(directory, ["diff", "HEAD", "--name-only"])).split("\n").filter(Boolean);
            for (const name of names) await add(name, await git(directory, ["diff", "HEAD", ...whole, "--", name]), "modified");
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
          const directory = url.searchParams.get("directory") ?? ctx.currentProject ?? "";
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
          const body = await ctx.readBody(request);
          const directory = body?.directory ?? ctx.currentProject;
          const file = typeof body?.file === "string" ? body.file : "";
          if (!directory) throw new HttpError(400, "No folder to change.");
          if (!file) throw new HttpError(400, "No file to put back.");
          if (file.includes("..") || path.isAbsolute(file)) throw new HttpError(400, "That path isn't allowed.");
          if (!(await isGitProject(directory))) throw new HttpError(400, "That folder is not a git project.");
          await git(directory, ["checkout", "--", file]);
          return json({ ok: true, file });
        }

        // The commit message the session's model writes, the way the Mac app asks for it.
        if (url.pathname === "/api/changes/suggest" && request.method === "POST") {
          const { client } = await ctx.ensureEngine();
          const body = await ctx.readBody(request);
          const directory = body?.directory ?? ctx.currentProject;
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
          const body = await ctx.readBody(request);
          const directory = body?.directory ?? ctx.currentProject;
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
          const { client } = await ctx.ensureEngine();
          const body = await ctx.readBody(request);
          const directory = body?.directory ?? ctx.currentProject;
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
          const body = await ctx.readBody(request);
          const directory = body?.directory ?? ctx.currentProject;
          const message = typeof body?.message === "string" ? body.message.trim() : "";
          if (!directory) throw new HttpError(400, "No folder to commit in.");
          if (!message) throw new HttpError(400, "A commit needs a message.");
          if (!(await isGitProject(directory))) throw new HttpError(400, "That folder is not a git project.");
          const files = Array.isArray(body?.files) ? body.files.filter(name => typeof name === "string" && !name.includes("..") && !path.isAbsolute(name)) : [];
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

  return false;
}
