#!/usr/bin/env node
// Route dispatcher. Domain handlers live in ./routes/.

import { handle as handleProjects } from "./routes/projects.mjs";
import { handle as handleFiles } from "./routes/files.mjs";
import { handle as handleGit } from "./routes/git.mjs";
import { handle as handleSessions } from "./routes/sessions.mjs";
import { handle as handleModels } from "./routes/models.mjs";
import { handle as handleSettings } from "./routes/settings.mjs";
import { handle as handleMisc } from "./routes/misc.mjs";
import { handle as handleBots } from "./routes/bots.mjs";
import { handle as handleMachines } from "./routes/machines.mjs";
import { handle as handleCredentials } from "./routes/credentials.mjs";

const handlers = [handleProjects, handleFiles, handleGit, handleSessions, handleModels, handleSettings, handleMisc, handleBots, handleMachines, handleCredentials];

export function createApi(ctx) {
  return async function api(request, response, url) {
    for (const handle of handlers) {
      const result = await handle(ctx, request, response, url);
      if (result !== false) return result;
    }
    // Preserve the original behaviour of touching the engine for requests that
    // reach the end of the route list.
    await ctx.ensureEngine();
    return false;
  };
}
