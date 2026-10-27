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

## 0.7.0 — honest surfaces, measured colour

- [x] Split `server.mjs`, `routes`, `Settings.tsx` and `App.tsx` into modules under
  roughly 800 lines.
- [x] Harden the shell: filesystem containment, IPC validation, CSP, sanitizer and
  git path guards, async agent detection, installer filename validation.
- [x] Settings tell the truth: Bots is read-only, Machines keeps a list and a real
  SSH reachability test, and Browser, Passwords, Phone, Notifications and Panel say
  they are not here yet.
- [x] Auto reports the coding agents installed on this computer; sessions through
  them are not wired.
- [x] Measure the effective light, narrow and dark palettes; all 87 ink/surface
  pairs at WCAG 2.1 AA, gated in `verify.mjs`.
- [x] 44 px touch targets, an off-canvas sidebar at 760 px and narrower, and a
  reduced-motion rule that actually applies.
- [x] Fix the three CI failures: the harness executable's bundle, the invalid
  reduced-motion rule, and the bridge handshake race.

## 0.7.1 — the app answers the hand

- [x] Interface sounds, off by default, synthesized with Web Audio and kept in
  the shell's `config.json`.
- [x] A stack of notes: three at most, newest in front, hovering expands it,
  5.2 s each, and the same words twice in a row are one note.
- [x] Delete a session in its row: Keep is focused first, Escape or moving the
  focus away keeps it, and the native confirm dialog is gone.
- [x] Skeleton rows for Bots, Machines, Accounts and Usage plans.
- [x] Micro-interactions across the page: press fills, icon nudges, selection
  bars, menu stagger, page push, link underlines, copy confirmations, search
  focus, primary lift, swatch ring and the working dot.
- [x] “Motion: Reduced” stops the hard-coded loops as well as the token-driven
  transitions.

## 0.7.2 — find marks every match, and ask in place

- [x] Find marks every match on both sides of the conversation, steps the marks
  themselves, and the sidebar's search results mark the matched words.
- [x] The native confirm dialog is gone: Revert, Remove Server, Remove Agent,
  Delete Skill, Delete Command and archived delete all ask in their rows.
- [x] Toast countdown line that pauses with the stack; file-tree rows fade in;
  attachments pop; queue dock staggers; diff and comment mark move; search
  results stagger; mode thumbnails lift; empty conversation rises.

## Next (0.8.x)

- [ ] The panel's browser: a WebView2 host, its search engine, history and website
  data, and Passwords in Windows Credential Manager.
- [ ] Machines: install the engine over SSH and run sessions there.
- [ ] Coding agents: run sessions through Claude Code, Codex, Cursor, Grok and
  Antigravity.
- [ ] The phone link.
- [ ] Notifications and the Mac's side-panel preferences.
- [ ] Bots: create and edit on Windows, once the Mac's kit and instructions writer
  has a Windows equivalent.
- [ ] Split `store.ts` and `Overlays.tsx` into modules under roughly 800 lines.
- [ ] Find: search the agent's steps and the app's own panels, not only the
  conversation's words.
- [ ] Offline/air-gapped mode and an update channel choice (stable/beta).

## Decisions

- The Windows client no longer tracks Mac parity. Features are judged on their own
  value.
- The engine (opencode) stays the backend; we do not fork it.
- One tagged release per behaviour batch.
- A surface that only writes `localStorage` is a placeholder; say so in the page and
  here until it is wired to the harness.
