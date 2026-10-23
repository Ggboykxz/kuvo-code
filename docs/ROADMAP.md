# ROADMAP.md — Kuvo Code for Windows

As of 0.6.0 the Windows client is its own product. The parity documents
(`MAC-UI-MAP.md`, `PARITY.md`, `windows-port.md`) are frozen at 0.5.101 and kept as
historical reference. This file tracks what we build next, in our own order.

## Shipped

### 0.5.x — the port

- Terminal: persistent ConPTY, project folder + real grid, restart, Run interrupts,
  right-click menu.
- Settings: Appearance, General, Keyboard, MCP, Agents, Skills, Commands, Projects,
  Providers, Usage, Git, Archived, Permissions, System, Storage, Integrations,
  Notifications, Privacy, Panel, Browser, Passwords, Phone, Auto, Machines,
  Worktrees.
- Worktrees: create, list, remove, show in Explorer.
- New Project / New Chat from the menu bar.
- Terminal takes the card's colour (light/dark).

### 0.6.0 — our own product

- Parity docs frozen at 0.5.101.
- Version reset and a roadmap of our own.

### 0.6.1 → 0.6.6 — depth before width

- **0.6.1** Provider-plan usage: `/api/usage/plans`, `/api/credential`, Copilot and
  OpenRouter reads, `PlansSection` in Usage.
- **0.6.2** Coding-agent detection: `/api/agents/detect` for Claude Code, Codex,
  Cursor, Grok and Antigravity; Auto shows what is installed.
- **0.6.3** Accounts page: the engine's integrations. Its Connect button did nothing;
  0.6.7 replaced it with a link to Providers.
- **0.6.4** Bots page: a name, a job and a model, stored on this machine.
- **0.6.5** Machines page: a name, an SSH destination, and a reachability test.
- **0.6.6** Panel tabs fade in; opening the panel puts focus in the terminal or the
  Files search.

### 0.6.7 — project hygiene

- `AGENTS.md`, codemaps and a token-optimization guide for coding agents.
- One static gate: `node windows/tools/verify.mjs`, plus `windows/tools/coverage.mjs`.
- Dependency audit in CI; Dependabot watches the three npm manifests.
- Settings and the command palette are real dialogs: focus enters, Tab stays
  inside, focus returns to the opener.
- The SSH reachability check is async and rejects option-like destinations.

## Now (0.7.x)

- [ ] **Bots, complete**: the richer editor (look, keys, machine, project,
  wake-ups), bot keys, group chats, sub-agents and @-mentions. The settings page
  exists; the backend does not.
- [ ] **Machines, complete**: install the engine on a remote over SSH, run sessions
  there, show status and wake. Reachability exists; sessions do not.
- [ ] **Auto rail**: offer the detected coding agents in the model picker and route
  to their CLI through the agents bridge. Detection exists; routing does not.
- [ ] **Passwords**: a real credential store (Windows Credential Manager) instead of
  `localStorage`.
- [ ] **Browser settings** wired to the panel's browser (search engine, history,
  website data) once the panel has a browser.

## Later

- [ ] New Browser Tab / integrated browser surface (needs a WebView2 host).
- [ ] Tab-pair style (needs a split conversation view).
- [ ] Offline/air-gapped mode.
- [ ] Auto-update channel choice (stable/beta).
- [ ] Split `App.tsx`, `Settings.tsx` and `server.mjs` into modules under ~800 lines.

## Decisions

- The Windows client no longer tracks Mac parity. Features are judged on their own
  value.
- The engine (opencode) stays the backend; we do not fork it.
- One tagged release per behaviour batch.
- A surface that only writes `localStorage` is a placeholder; say so in the page and
  here until it is wired to the harness.
