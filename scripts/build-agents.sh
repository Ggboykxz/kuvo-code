#!/bin/sh
# Builds the agents bridge (Agents/src) into KuvoCode/Resources/kuvo-agents.js, the one file the
# app ships and runs with the engine's Bun. Run it after changing anything in Agents/src, and
# commit the result. The agents' SDKs aren't in it: the bridge downloads each one the first time
# it's needed.
#   BUN   the Bun to build with (default: `bun` on PATH, else the engine Kuvo Code installed,
#         which is Bun with BUN_BE_BUN=1)
set -eu
cd "$(dirname "$0")/.."

if [ -z "${BUN:-}" ]; then
  if command -v bun >/dev/null 2>&1; then
    BUN=bun
  else
    BUN=$(ls -d "$HOME/Library/Application Support/run.kuvo.code/engine/"*/opencode 2>/dev/null | tail -n 1)
    [ -n "$BUN" ] || { echo "No Bun: install it, or launch Kuvo Code once so it downloads its engine." >&2; exit 1; }
  fi
fi

BUN_BE_BUN=1 "$BUN" build Agents/src/main.ts --target=bun --outfile KuvoCode/Resources/kuvo-agents.js
echo "Built KuvoCode/Resources/kuvo-agents.js"
