# File map — Kuvo Code for Windows

```
windows/
  app/                     React + TypeScript conversation view
    app/
      page.tsx             mounts <App /> on the client
      layout.tsx           CSP, KaTeX CSS, terminal vendor scripts
      globals.css          Tailwind layer bound to the Mac tokens
    src/
      App.tsx              title bar, sessions, transcript, composer, panels
      Settings.tsx         every Settings page
      Overlays.tsx         palette, picker, drawer, diff, toast, image viewer
      Changes.tsx          Changes tab and review comments
      store.ts             state, look, sessions, worktrees, engine client
      api.ts               wire types and the fetch wrapper
      lib.ts               markdown, math, escaping, time, errors
      motion.ts            the Mac spring as Motion numbers
      shortcuts.ts         shortcut map and recorder
      focus.ts             dialog focus: remember, contain, restore
      *.mjs / *.d.mts      small pure modules with declarations
      components/          symbols, context menu, spinner, tool call, AI Elements
  harness/                 the local server around the engine
    server.mjs             HTTP API, page, engine proxy, event stream
    engine.mjs             opencode client
    transcript.mjs         engine events -> page rows
    layout.mjs             pane widths
    markdown.mjs           conversation export
    models.mjs             effort labels
    ui/                    hand-written fallback page + styles + vendor
    ui-build/              built page (git-ignored; produced by npm run build)
    harness.test.mjs       API/reducer tests
    live.test.mjs          real engine test
    ui.dom.test.mjs        built page in jsdom
    verify.test.mjs        built page in Chromium
    build-exe.mjs          packs the harness into one .exe
    smoke-exe.mjs          proves the .exe serves the page
  electron/                the native shell
    main.js                window, menu, tray, updates, lifecycle
    terminal.js            ConPTY + WebSocket terminal
    preload.js             window.kuvo bridge
    update-check.js        release picker
    ssh.js                 SSH destination validation + async check
    terminal.test.js       real ConPTY test
    ssh.test.js            destination/argv tests
    build/                 icon assets
  tools/                   verify, coverage, licenses, capture, publish, icon
  kuvo-engine.mjs          the pinned engine installer/launcher
  *.test.mjs               port unit tests (root of windows/)
  THIRD_PARTY_LICENSES.txt generated license list
docs/
  CODEMAPS/                this map
  ROADMAP.md               live product backlog
  releases/                one note per release
  windows-port.md          frozen parity log through 0.5.101
  MAC-UI-MAP.md            frozen Mac UI reference
  PARITY.md                frozen parity reference
  DESIGN.md                design system notes
.github/workflows/
  windows-engine.yml       static gate, live Windows engine, Electron build
.github/dependabot.yml     GitHub Actions + npm updates
AGENTS.md                  instructions for coding agents
```

## Where to change what

| I want to… | Go to |
| --- | --- |
| Add a Settings page | `windows/app/src/Settings.tsx` + `AGENTS.md` |
| Add an HTTP route | `windows/harness/server.mjs` + `harness.test.mjs` |
| Change engine behaviour | `windows/harness/engine.mjs` |
| Change the transcript reducer | `windows/harness/transcript.mjs` |
| Change the terminal | `windows/electron/terminal.js` + `terminal.test.js` |
| Change the window/menu/tray | `windows/electron/main.js` |
| Change the page bridge | `windows/electron/preload.js` |
| Change the page's look | `windows/harness/ui/style.css`, `store.ts` (`look`) |
| Add a symbol | `windows/app/src/components/symbols.tsx` |
| Change the release process | `windows/tools/publish-release.py`, `.github/workflows/windows-engine.yml` |
| Record a decision | `docs/ROADMAP.md` or `docs/releases/` |
