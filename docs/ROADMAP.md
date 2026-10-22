# ROADMAP.md — Kuvo Code for Windows

As of 0.6.0 the Windows client is its own product. The parity documents
(`MAC-UI-MAP.md`, `PARITY.md`, `windows-port.md`) are frozen at 0.5.101 and kept as
historical reference. This file tracks what we build next, in our own order.

## Shipped (0.5.x → 0.6.0)

- Terminal: persistent ConPTY, project folder + real grid, restart, Run interrupts, right-click menu.
- Settings: Appearance, General, Keyboard, MCP, Agents, Skills, Commands, Projects, Providers, Usage, Git, Archived, Permissions, System, Storage, Integrations, Notifications, Privacy, Panel, Browser, Passwords, Phone, Auto, Machines, Worktrees.
- Worktrees: create, list, remove, show in Explorer.
- New Project / New Chat from the menu bar.
- Terminal takes the card's colour (light/dark).

## Now (0.6.x)

- [ ] Provider-plan usage: a panel showing plan limits, pace and spend for connected accounts (Copilot, Codex, Grok, OpenRouter, Z.ai), the way UsageKit does on the Mac — but ours, in the Windows shell.
- [ ] Auto rail: detect coding agents on this machine (Claude Code, Codex, …) and offer them in the model picker.
- [ ] Accounts page: connected accounts with their plan status and sign-in state, richer than Providers.
- [ ] Terminal: search in scrollback, command history, split panes.

## Next (0.7.x)

- [ ] Bots: BotEditor, bot keys, group chats, sub-agents, @-mentions.
- [ ] Machines: SSH sessions, install the engine on a remote, status and wake.
- [ ] Browser settings wired to the panel's browser (search engine, history, website data).
- [ ] Passwords: a real credential store (Windows Credential Manager) instead of localStorage.
- [ ] Phone link: pairing Kuvo Code for iPhone with this PC.

## Later

- [ ] New Browser Tab / integrated browser surface (needs a WebView2 host).
- [ ] Tab-pair style (needs a split conversation view).
- [ ] Offline/air-gapped mode.
- [ ] Auto-update channel choice (stable/beta).

## Decisions

- The Windows client no longer tracks Mac parity. Features are judged on their own value.
- The engine (opencode) stays the backend; we do not fork it.
- One tagged release per behaviour batch, as before.
EOF
echo "created"