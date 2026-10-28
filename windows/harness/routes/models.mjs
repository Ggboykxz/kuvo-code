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

        if (url.pathname === "/api/models/default" && request.method === "GET") {
          const { client } = await ctx.ensureEngine();
          return json({ model: await client.defaultModel(ctx.currentProject ?? undefined) });
        }

        if (url.pathname === "/api/models" && request.method === "GET") {
          const { client } = await ctx.ensureEngine();
          return json({ models: await client.models(ctx.currentProject ?? undefined) });
        }

        if (url.pathname === "/api/agents" && request.method === "GET") {
          const { client } = await ctx.ensureEngine();
          return json({ agents: await client.agents(ctx.currentProject ?? undefined) });
        }

        if (url.pathname === "/api/commands" && request.method === "GET") {
          const { client } = await ctx.ensureEngine();
          return json({ commands: await client.commands(ctx.currentProject ?? undefined) });
        }

  return false;
}
