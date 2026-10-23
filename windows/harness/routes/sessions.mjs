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

        if (url.pathname === "/api/sessions" && request.method === "GET") {
          const directory = url.searchParams.get("directory") ?? ctx.currentProject;
          if (!directory) return json({ sessions: [] });
          const { client } = await ctx.ensureEngine();
          return json({ sessions: await client.sessions({ directory }) });
        }
      if (url.pathname === "/api/sessions" && request.method === "POST") {
        const { client } = await ctx.ensureEngine();
          const body = await ctx.readBody(request);
          const directory = ctx.directoryOf(body.directory ?? ctx.currentProject);
          ctx.currentProject = directory;
          return json({ session: await client.createSession({ directory, title: body.title, agent: body.agent, model: body.model }) });
        }
        const diff = route(/^\/api\/sessions\/([^/]+)\/diff$/);
        if (diff && request.method === "GET") {
          const { client } = await ctx.ensureEngine();
          return json({ diff: await client.sessionDiff(diff[0]) });
        }

        const compact = route(/^\/api\/sessions\/([^/]+)\/compact$/);
        if (compact && request.method === "POST") {
          const { client } = await ctx.ensureEngine();
          await client.compact(compact[0]);
          return json({ ok: true });
        }

        const viewed = route(/^\/api\/sessions\/([^/]+)\/view$/);
        if (viewed && request.method === "POST") {
          const { client } = await ctx.ensureEngine();
          const body = await ctx.readBody(request);
          await client.markViewed(viewed[0], body.idle ?? Date.now());
          return json({ ok: true });
        }

        const inbox = route(/^\/api\/sessions\/([^/]+)\/inbox(?:\/([^/]+))?$/);
        if (inbox && request.method === "GET") {
          const { client } = await ctx.ensureEngine();
          return json({ inbox: await client.inbox(inbox[0]) });
        }
        if (inbox && inbox[1] && request.method === "PATCH") {
          const { client } = await ctx.ensureEngine();
          const body = await ctx.readBody(request);
          await client.setDelivery(inbox[0], inbox[1], body.delivery === "queue" ? "queue" : "steer");
          return json({ ok: true });
        }
        if (inbox && inbox[1] && request.method === "DELETE") {
          const { client } = await ctx.ensureEngine();
          await client.cancelInbox(inbox[0], inbox[1]);
          return json({ ok: true });
        }
        if (url.pathname.match(/^\/api\/sessions\/[^/]+\/forms$/) && request.method === "GET") {
          const { client } = await ctx.ensureEngine();
          const id = route(/^\/api\/sessions\/([^/]+)\/forms$/)[0];
          return json({ forms: await client.forms(id) });
        }
        const formReply = route(/^\/api\/sessions\/([^/]+)\/forms\/([^/]+)\/reply$/);
        if (formReply && request.method === "POST") {
          const { client } = await ctx.ensureEngine();
          const body = await ctx.readBody(request);
          await client.replyForm(formReply[0], formReply[1], body.answer ?? {});
          return json({ ok: true });
        }
        const formDismiss = route(/^\/api\/sessions\/([^/]+)\/forms\/([^/]+)$/);
        if (formDismiss && request.method === "DELETE") {
          const { client } = await ctx.ensureEngine();
          await client.dismissForm(formDismiss[0], formDismiss[1], url.searchParams.get("message") ?? undefined);
          return json({ ok: true });
        }

        // Revert: take the session back to before a message; bring it all back again.
        if (url.pathname.match(/^\/api\/sessions\/[^/]+\/revert$/) && request.method === "POST") {
          const { client } = await ctx.ensureEngine();
          const id = route(/^\/api\/sessions\/([^/]+)\/revert$/)[0];
          const body = await ctx.readBody(request);
          const revert = await client.stageRevert(id, body.messageID);
          return json({ revert });
        }
        if (url.pathname.match(/^\/api\/sessions\/[^/]+\/revert$/) && request.method === "DELETE") {
          const { client } = await ctx.ensureEngine();
          const id = route(/^\/api\/sessions\/([^/]+)\/revert$/)[0];
          await client.clearRevert(id);
          return json({ ok: true });
        }
        const mark = async (id, key, value) => {
          const { client } = await ctx.ensureEngine();
          const current = await client.session(id);
          const metadata = { ...(current?.metadata ?? {}), [key]: value };
          await client.updateSession(id, { metadata });
          return metadata;
        };

        // Archiving: a mark of the app's own, as the Mac app keeps it.
        const archive = route(/^\/api\/sessions\/([^/]+)\/archive$/);
        if (archive && request.method === "POST") {
          const body = await ctx.readBody(request);
          const archived = body?.archived !== false;
          await mark(archive[0], "kuvo.archived", archived);
          return json({ ok: true, archived });
        }

        // Pinning: the same mark, the Mac's own key (Workspace.swift:342-364). A pinned
        // session sits at the top of the sidebar, and is not in the recents.
        const pin = route(/^\/api\/sessions\/([^/]+)\/pin$/);
        if (pin && request.method === "POST") {
          const body = await ctx.readBody(request);
          const pinned = body?.pinned !== false;
          await mark(pin[0], "kuvo.pinned", pinned);
          return json({ ok: true, pinned });
        }

        // A note for the agent, under a key: the project's folders, named (ProjectFolders.swift:10,
        // 36-46; OpenCodeAPI.swift:355-358).
        const instruction = route(/^\/api\/sessions\/([^/]+)\/instruction$/);
        if (instruction && request.method === "POST") {
          const { client } = await ctx.ensureEngine();
          const body = await ctx.readBody(request);
          const key = String(body.key ?? "").trim();
          if (!key) throw new HttpError(400, "A note needs a key.");
          const value = String(body.value ?? "");
          await client.setInstruction(instruction[0], key, value);
          return json({ ok: true });
        }

        // The session's own rules: what the agent may do without asking, and what waits for
        // an OK (OpenCodeAPI.swift:339-343).
        const rules = route(/^\/api\/sessions\/([^/]+)\/permissions$/);
        if (rules && request.method === "POST") {
          const { client } = await ctx.ensureEngine();
          const body = await ctx.readBody(request);
          await client.setPermissions(rules[0], Array.isArray(body.permissions) ? body.permissions : []);
          return json({ ok: true });
        }

        const rename = route(/^\/api\/sessions\/([^/]+)\/rename$/);
        if (rename && request.method === "POST") {
          const { client } = await ctx.ensureEngine();
          const body = await ctx.readBody(request);
          await client.renameSession(rename[0], String(body.title ?? "").trim());
          return json({ ok: true });
        }

        const fork = route(/^\/api\/sessions\/([^/]+)\/fork$/);
        if (fork && request.method === "POST") {
          const { client } = await ctx.ensureEngine();
          const body = await ctx.readBody(request);
          const branched = await client.forkSession(fork[0], { before: body.before });
          return json({ session: branched });
        }

        const command = route(/^\/api\/sessions\/([^/]+)\/command$/);
        if (command && request.method === "POST") {
          const { client } = await ctx.ensureEngine();
          const body = await ctx.readBody(request);
          await client.runCommand({ session: command[0], name: body.name, text: body.text, delivery: body.delivery === "queue" ? "queue" : "steer" });
          return json({ ok: true });
        }

        const agent = route(/^\/api\/sessions\/([^/]+)\/agent$/);
        if (agent && request.method === "POST") {
          const { client } = await ctx.ensureEngine();
          const body = await ctx.readBody(request);
          await client.selectAgent(agent[0], body.agent);
          return json({ ok: true });
        }

        const session = route(/^\/api\/sessions\/([^/]+)$/);
        if (session && request.method === "DELETE") {
          const { client } = await ctx.ensureEngine();
          await client.deleteSession(session[0]);
          return json({ ok: true });
        }
        if (session && request.method === "GET") {
          const { client } = await ctx.ensureEngine();
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
          const { client } = await ctx.ensureEngine();
          const body = await ctx.readBody(request);
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
          const { client } = await ctx.ensureEngine();
          await client.interrupt(interrupt[0], await ctx.readBody(request));
          return json({ ok: true });
        }

        const model = route(/^\/api\/sessions\/([^/]+)\/model$/);
        if (model && request.method === "POST") {
          const { client } = await ctx.ensureEngine();
          await client.setModel(model[0], (await ctx.readBody(request)).model);
          return json({ ok: true });
        }

        const permission = route(/^\/api\/sessions\/([^/]+)\/permission\/([^/]+)$/);
        if (permission && request.method === "POST") {
          const { client } = await ctx.ensureEngine();
          const body = await ctx.readBody(request);
          await client.replyPermission({ session: permission[0], permission: permission[1], decision: body.decision, message: body.message });
          return json({ ok: true });
        }

  return false;
}
