#!/usr/bin/env node
// The static gate for the Windows client, in one command:
//
//   node windows/tools/verify.mjs
//   node windows/tools/verify.mjs --no-build
//   node windows/tools/verify.mjs --coverage --no-build
//
// It runs the port tests, the harness tests, the link bridge, then lint, typecheck
// and the page build. The first failure stops the run and exits non-zero, so CI and
// a local check agree on what "green" means.

import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..", "..");
const app = path.join(root, "windows", "app");
const npm = "npm";
const windowsShell = process.platform === "win32";
const node = process.execPath;
const args = new Set(process.argv.slice(2));
const coverage = args.has("--coverage");
const build = !args.has("--no-build");

function run(label, command, commandArgs, cwd = root, shell = false) {
  process.stdout.write(`\n▸ ${label}\n`);
  const started = Date.now();
  const result = spawnSync(command, commandArgs, { cwd, stdio: "inherit", env: process.env, shell });
  const elapsed = ((Date.now() - started) / 1000).toFixed(1);
  if (result.error) {
    console.error(`\n✗ ${label}: ${result.error.message}`);
    process.exit(1);
  }
  if (result.status !== 0) {
    console.error(`\n✗ ${label} (${elapsed}s)`);
    process.exit(result.status ?? 1);
  }
  console.log(`✓ ${label} (${elapsed}s)`);
}

const testFlag = coverage ? ["--experimental-test-coverage"] : [];

run(
  coverage ? "port tests (with coverage)" : "port tests",
  node,
  ["--test", ...testFlag, "windows/*.test.mjs"],
);

run(
  coverage ? "harness tests (with coverage)" : "harness tests",
  node,
  ["--test", ...testFlag, "windows/harness/harness.test.mjs"],
);

run(
  coverage ? "link bridge (with coverage)" : "link bridge",
  node,
  ["--test", ...testFlag, "Packages/KuvoLink/Tests/Bridge/*.test.js"],
);

// The shell's SSH check is plain Node, so its contract runs here too; the ConPTY test
// beside it needs Windows and stays in `npm run test:terminal`.
run(
  coverage ? "ssh check (with coverage)" : "ssh check",
  node,
  ["--test", ...testFlag, "windows/electron/ssh.test.js"],
);

run("lint", npm, ["run", "lint"], app, windowsShell);
run("typecheck", npm, ["run", "typecheck"], app, windowsShell);
if (build) run("page build", npm, ["run", "build"], app, windowsShell);

console.log("\nAll checks passed.");
