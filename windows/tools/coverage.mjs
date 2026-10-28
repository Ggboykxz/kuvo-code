#!/usr/bin/env node
// Node's built-in test coverage for the Windows client. It is `verify.mjs` without
// the page build, with the coverage reporter turned on.

import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const verify = path.join(here, "verify.mjs");
const result = spawnSync(process.execPath, [verify, "--coverage", "--no-build"], {
  stdio: "inherit",
  env: process.env,
});
process.exit(result.status ?? 1);
