# Keeping agent context small

This repository is large: the macOS app, the Windows client, vendored assets and
three `node_modules` trees. An agent that reads everything burns its context
before it writes a line. These are the rules that keep the working set small.

## Start from the maps

1. `AGENTS.md` — the contract and the commands.
2. `docs/CODEMAPS/ARCHITECTURE.md` — the process boundaries.
3. `docs/CODEMAPS/MODULES.md` — which module owns the behaviour.
4. `docs/CODEMAPS/FILES.md` — the exact path to open.

Only then open source. If the map is stale, fix the map in the same change.

## Read narrowly

- Use `rg <symbol>` and open a 40–80 line window around the hit; do not read a
  2,000-line file end to end to find one function.
- `git diff --stat` and `git diff -- <path>` before `git show`.
- Never open `windows/harness/ui-build/`, `windows/app/.next/`, `node_modules/`,
  `vendor/` or `dist/` unless the task is about the build output itself.
- Prefer the declaration (`.d.mts`) or the test over the implementation when you
  only need the contract.
- For a UI change, read the component and the matching CSS block, not the whole
  stylesheet.

## Keep the working set

- One batch, one concern. Do not carry the bots, machines and terminal work in
  the same context unless they actually interact.
- After an audit, write the findings into `docs/` or an issue, then drop the raw
  output. The document is the durable context.
- Use the ECC memory vault (`.ecc/memory`, local) for handoffs, decisions and
  lessons. It is for the agent; `docs/` is for the team.
- When a task is done, update `docs/ROADMAP.md` and the release note, then start
  the next task with a fresh summary.

## Keep the instructions cheap

- `AGENTS.md` is loaded into every session: keep it under ~200 lines and move
  detail into `docs/`.
- Do not paste generated logs, full test output or large diffs into prompts;
  quote the failing line and the command.
- Prefer `node windows/tools/verify.mjs` over replaying every command by hand.
- Use `npm run test:coverage` when coverage is the question; otherwise `npm test`
  is enough.

## What not to do

- Do not add a new skill, hook or agent definition to this repository just to
  raise a harness score. ECC is installed for the harness, not vendored here.
- Do not copy the macOS parity documents into new prompts; they are frozen
  history.
- Do not re-read a file after an edit to "confirm" it. The edit tool already
  applied the change; run the typechecker or the test instead.
