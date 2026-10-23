# Module map — Kuvo Code for Windows

## Page — `windows/app/src`

### `App.tsx`

The window: title bar, session tabs, sidebar, conversation card, composer, split
view and the panel. It also owns the keyboard map and the global `Escape`
behaviour.

Key pieces: `App`, `Header`, `SessionTabs`, `Sidebar`, `Conversation`,
`Composer`, `EntryNodes`, `WorkingLine`, `PermissionCard`, `FormCard`,
`Choice`, `ContextGauge`, `EmptyConversation`.

### `Settings.tsx`

Every Settings page and the settings shell (sidebar, search, page switch).

Key pieces: `Settings`, `SettingGroup`, `SettingRow`, `PAGES`, `PAGE_GROUPS`,
`PAGE_SUBTITLES`, `PAGE_SYMBOLS`, and the page components (`AppearancePage`,
`GeneralPage`, `McpPage`, `AgentsPage`, `BotsPage`, `SkillsPage`, `CommandsPage`,
`ProjectsPage`, `ProvidersPage`, `AccountsPage`, `UsagePage`, `GitPage`,
`WorktreesPage`, `StoragePage`, `IntegrationsPage`, `BrowserPage`,
`PasswordsPage`, `PhonePage`, `AutoPage`, `MachinesPage`, `ArchivedPage`,
`PermissionsPage`, `NotificationsPage`, `PrivacyPage`, `PanelPage`,
`SystemPage`).

To add a page, see `AGENTS.md`.

### `Overlays.tsx`

What floats over the conversation: `Palette`, `OpenQuickly`, `Picker`,
`Drawer` (Files / Changes / Terminal), `DiffModal`, `ProjectEditor`, `Toast`,
`ImageViewer`, `AnalyticsNotice`.

### `store.ts`

The page's state and the actions that change it: `state`, `render`, `useStore`,
`look`/`applyLook`/`loadLook`, `loadSessions`, `openSession`, `openSplit`,
`closeSessionTab`, `cycleTab`, `renameSession`, `deleteSession`, `connectEvents`,
`loadModels`, `loadAgents`, `loadCommands`, `loadProjects`, `saveConfig`,
`worktrees`, `createWorktree`, `removeWorktree`, `notify`, `complain`.

### `api.ts`

The wire types (`SessionSummary`, `Transcript`, `PermissionRequest`, `FormRequest`,
`Model`, `Agent`, `Command`, `VcsInfo`, `SessionDiff`, `EngineState`) and `api()`,
the one fetch wrapper that adds JSON, errors and the harness base URL.

### `Changes.tsx`

The side panel's Changes tab: per-file diffs, review comments, open-in-editor.

### `lib.ts`

Escaping and sanitising HTML, `renderMarkdown`, `renderMath`, relative time,
brief values, error text, token formatting.

### Small pure modules

These are plain `.mjs` files with `.d.mts` declarations, so Node tests can import
them without a bundler:

| Module | Purpose |
| --- | --- |
| `keys.mjs` | Keyboard shortcut parsing, matching and display |
| `filetree.mjs` | Project file tree for the Files tab |
| `filelinks.mjs` | File references in markdown |
| `diff.mjs` | Unified diff parsing and rendering helpers |
| `drafts.mjs` | Composer drafts and attachments |
| `terminal.mjs` | Terminal URL and selection helpers |
| `tab-history.mjs` | Closed-tab history |
| `open-quickly.mjs` | Fuzzy file matching for Open Quickly |
| `review-comments.mjs` | Review comment anchors |
| `compatibility.mjs` | Config compatibility checks |

### Components

- `components/symbols.tsx` — the SVG symbol set (16 pt grid, `currentColor`).
- `components/context-menu.tsx` — right-click menu.
- `components/provider-logo.tsx` — provider marks.
- `components/spinner.tsx` — loading spinner.
- `components/tool-call.tsx` — a tool step's row.
- `components/ai-elements/` — copied AI Elements (Shimmer) with its license.

## Harness — `windows/harness`

### `server.mjs`

`startHarness()` builds the HTTP server. Routes cover:

- page + static assets;
- `/api/state`, `/api/config`, `/api/location`;
- sessions: list/create/open/rename/delete, messages, prompts, stop, model;
- files: tree, read, search, changes, diff;
- git and worktrees;
- models, agents, commands, providers, credentials, integrations;
- usage and plan usage;
- agents detection;
- permissions and questions;
- event stream `/event`.

`HttpError` is the one error shape. The server binds to localhost.

### `engine.mjs`

`EngineClient` spawns the pinned engine, waits for its URL/password, and wraps its
HTTP API: sessions, messages, events, config, providers, credentials, worktrees,
location. `EngineError` carries the engine's status and body.

### `transcript.mjs`

`emptyTranscript`, `fromHistory`, `apply`, `applyAll`. Turns engine events into the
rows the page draws (messages, tool calls, idle/error entries) and tracks running
state, permissions and questions.

### `layout.mjs`

`paneLayout()` and the pane ranges: how the sessions sidebar, conversation,
changes panel and split pane share the width.

### `markdown.mjs`

`conversationMarkdown()` exports a conversation with its project path and summary.

### `models.mjs`

`effortTitle()` maps the engine's effort ids to the labels the page shows.

### Tests

- `harness.test.mjs` — API and reducer contracts against a fake engine.
- `live.test.mjs` — a real engine, a real session, a real free model.
- `ui.dom.test.mjs` — the built page in jsdom.
- `verify.test.mjs` — the page in Chromium via Playwright.

## Shell — `windows/electron`

### `main.js`

Window, menu bar (`New Project…`, `New Chat`, settings, view), tray, recent
projects, global shortcuts, update check/download, `openExternal`, and the SSH
reachability IPC. Owns the harness and terminal-server lifecycle.

### `terminal.js`

`startTerminalServer()`: shell detection, ConPTY via `node-pty`, WebSocket
protocol, resize, exit and restart. The PTY is kept across panel hides.

### `preload.js`

The `window.kuvo` bridge: `terminalPort`, `openExternal`, `showInFolder`,
`sshCheck`, window controls, menu actions, update actions.

### `update-check.js`

`pickRelease()` compares the running version with the release list and picks the
installer asset.

### `ssh.js`

`validDestination()` and `checkDestination()`: argument validation and a
non-blocking `ssh … echo ok` reachability check.

## Tools — `windows/tools`

- `verify.mjs` — the whole static gate (tests, lint, typecheck, build).
- `coverage.mjs` — Node coverage for the port and harness tests.
- `publish-release.py` — waits for CI and uploads the four assets.
- `third-party-licenses.mjs` — generates/checks the Windows license list.
- `capture.mjs` — screenshots for the docs.
- `make-icon.py` — the Windows icon from the macOS art.
- `mac-ui-inventory.mjs` — frozen parity inventory.
