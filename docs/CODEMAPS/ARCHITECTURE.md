# Architecture map — Kuvo Code for Windows

The Windows client is three processes and one engine.

```
┌──────────────────────────────────────────────────────────────┐
│ Electron shell — windows/electron                            │
│  main.js      window, menu bar, tray, updates, SSH check     │
│  terminal.js  ConPTY shell + WebSocket server                │
│  preload.js   contextBridge: terminalPort, openExternal, …   │
└───────────────┬──────────────────────────────────────────────┘
                │ loads http://127.0.0.1:<port>
┌───────────────▼──────────────────────────────────────────────┐
│ Harness — windows/harness                                    │
│  server.mjs     HTTP API, static page, engine proxy          │
│  engine.mjs     opencode client: spawn, HTTP, credentials    │
│  transcript.mjs engine events -> the page's rows             │
│  layout.mjs     pane widths                                  │
│  markdown.mjs   conversation export                          │
└───────────────┬──────────────────────────────────────────────┘
                │ HTTP + event stream (localhost, password)
┌───────────────▼──────────────────────────────────────────────┐
│ opencode engine — pinned, downloaded, never forked           │
└──────────────────────────────────────────────────────────────┘
                ▲
                │ /api/* and /event
┌───────────────┴──────────────────────────────────────────────┐
│ React page — windows/app/src                                 │
│  App.tsx       title bar, sessions, transcript, composer     │
│  Settings.tsx  every Settings page                           │
│  Overlays.tsx  palette, picker, drawer, diff, toasts        │
│  store.ts      state, look, sessions, worktrees              │
└──────────────────────────────────────────────────────────────┘
```

## Lifecycle

1. `main.js` starts the harness. In development the harness is `node server.mjs`;
   in a packaged build it is `resources/harness/kuvo-windows-harness.exe`.
2. The harness installs or finds the pinned engine, starts it with a random
   password, and serves the page from `windows/harness/ui-build` (or the
   hand-written fallback page).
3. The shell opens a `BrowserWindow` on the harness URL.
4. The page calls `/api/*`; the harness proxies to the engine. Engine events are
   forwarded on `/event` (server-sent events), reduced by `transcript.mjs`.
5. The terminal is separate: `terminal.js` listens on `127.0.0.1` on a random
   port and the page connects with a WebSocket. The PTY survives panel hides and
   tab switches.
6. Closing the window stops the engine, the harness and the terminal server.

## Boundaries

- **Engine**: upstream opencode. Do not fork it or patch its prompts/tools here.
- **Harness**: the only process that knows the engine's password and binary.
- **Page**: no Node access. It talks to the harness over HTTP and to the
  terminal over WebSocket; `preload.js` exposes a small, explicit bridge.
- **Shell**: owns OS integration (menu, tray, dialogs, updates, ConPTY). It must
  not block the main process on a subprocess.

## State

- `store.ts` is the page's single mutable store. Components subscribe through
  `useStore()`; mutations call `render()`.
- The engine is the source of truth for sessions, messages and configuration.
- The shell's `config.json` holds window/project preferences and the interface
  sound choice.
- Bots and machines live in the harness (`~/.kuvo-code/bots`, `machines.json`),
  not in the page.
- `localStorage` still holds a few surfaces the page hasn't wired yet
  (notifications, panel preferences, the analytics notice). Those pages say so;
  moving them to the harness is the target architecture.

## Security boundaries

- The harness binds to localhost and requires the engine password it generated.
- The page has a CSP: `default-src 'self'`, `connect-src 'self' ws: wss:`.
- Subprocess arguments (git, ssh, engine) are validated and passed as an argv
  array, never through a shell.
- `github-token-to-revoke.txt` is local-only and never read by the app.
