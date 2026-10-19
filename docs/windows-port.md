# Windows: audit, and what a Windows harness takes

Kuvo Code is a native Mac app: SwiftUI and AppKit, macOS 26, Apple silicon, with
deep system integration (Liquid Glass, the menu bar, Keychain, Sparkle). There is
no Windows build of it, and there can't be one by porting: SwiftUI doesn't exist
on Windows, AppKit even less so. A Windows harness is a rewrite of the interface
against a different toolkit, reusing what's toolkit-independent.

This document is the audit behind that statement, what was verified, and the
staged path. The first stage's code is in `windows/` and the KuvoLink bridge.

## What the app is made of

647 Swift files, 133,578 lines. Split by what they depend on:

| Part | Lines | Depends on |
| --- | --- | --- |
| `KuvoCode/Views` | 27,530 | SwiftUI, AppKit, WebKit, Textual, SwiftTerm |
| `KuvoCode/Stores` | 15,433 | Foundation, AppKit, Security, WebKit, Network |
| `KuvoCode/Design` | 3,849 | SwiftUI, AppKit, QuartzCore |
| `KuvoCode/App` | 1,432 | SwiftUI, AppKit |
| `Packages/UsageKit` | 40,009 (+35,972 tests) | ~30% AppKit/SwiftUI (menu bar panel, popover); ~60% provider/pricing logic; ~10% macOS-only probes |
| `Packages/OpenCodeKit` | 4,788 (+1,490 tests) | Foundation; the engine launcher is `#if os(macOS)` |
| `Packages/KuvoLink` | 1,867 (+913 tests) | Foundation, CryptoKit; the machines' side is the JS bridge |

The interface — windows, the tabs in the title bar, the changes and review
panels, the composer, the transcript — is the product, and it is the part that
doesn't move. Frameworks without a Windows counterpart in the app: AppKit (108
files), SwiftUI (167), WebKit, Security/Keychain, LocalAuthentication, Sparkle,
ServiceManagement, SwiftTerm (a POSIX PTY terminal), KeyboardShortcuts, plus
menu-bar extras, window vibrancy and the accessibility E2E driver.

## The engine is ready for Windows — verified

The engine is opencode, unmodified: any harness keeps it, and its Windows builds
exist at the exact version Kuvo Code pins (2.0.32). Checked against
`registry.npmjs.org`, and by downloading and hashing the tarballs:

| Package | sha512 (`dist.integrity`) | Inner path |
| --- | --- | --- |
| `@opencode/cli-windows-x64` | `5VdKolj2/NkSk3BuM4qeiYpnNnGRT7szmd2RIv3+aSDPMwD9yRySYkJ2f1WIM7dTDfO5lZHAXVoipt6+i6AD4A==` | `package/bin/opencode.exe` |
| `@opencode/cli-windows-arm64` | `T1UGNtrcgDoovpRD3nLqpfZoUh8+pDPlEewALD3QIUOLvuHyy4kUAFra6lLl5kitzqHN5Lm+2iQKX5F81A5hGw==` | `package/bin/opencode.exe` |

`windows/kuvo-engine.mjs` already installs and starts them under the Mac app's
contract: checksum before unpacking, `serve --stdio --port 0`, `{"url": …}` first
line, `OPENCODE_PASSWORD`/`OPENCODE_CLIENT`, XDG folders of its own, stdin
closing as shutdown. The same code was run end to end against the pinned Linux
build here (install → launch → authenticated `api/info` → stop); the Windows
workflow runs it on `windows-latest`.

What changes for Windows, engine-side: the codesign check becomes the checksum
alone (Windows builds carry no Apple signature), npm's tarball is unpacked with
Windows' `tar`, and the shell environment capture (`ShellEnvironment.swift`,
`$SHELL -ilc`) becomes the process environment, optionally with a PowerShell
profile read. What's left of `kuvo-npx`/`kuvo-wake` (POSIX `sh` scripts the Mac
writes for machines) needs `.cmd`/PowerShell or JS equivalents.

## What a Windows harness must rewrite

- **The whole interface** (~46k lines of app code plus UsageKit's AppKit third):
  a Windows toolkit's window model, tabs, panels, menus and shortcuts.
- **The menu bar extra** (usage strip, popover panel): Windows has a tray, not a
  text strip; the honest shape is a tray icon with a windowed detail view.
- **The terminal** (SwiftTerm, forkpty): ConPTY and a terminal emulator.
- **The panel's browser** (WKWebView, script worlds, message handlers): WebView2,
  different API shapes, same `kuvo-browser.js`/CDP design on the engine side.
- **Credentials** (Keychain, Touch ID): Credential Manager / DPAPI, Windows Hello.
- **Updates and signing** (Sparkle, notarization): MSIX or Squirrel/Velopack,
  Authenticode (EV for SmartScreen), no notarization equivalent.
- **The POSIX surfaces**: `setsid`, `chmod`, `kill -0`, `/proc`, `~/.kuvo-code`
  permissions; `ssh -t` uses the Windows OpenSSH client, which has no
  `ControlMaster` multiplexing, so the tunnel lifecycle changes.
- **Notifications, Dock, login item, screen-sharing detection** (the private
  SkyLight probe has no counterpart; Windows has its own share indicators).

## Three ways to build it, in order of fit

1. **Native rewrite in .NET (WinUI 3 or Avalonia)** — best fit long term: the
   engine contract, the KuvoLink protocol (X25519/AES-GCM/HKDF all exist in
   .NET) and the two JS files carry over; the interface is rewritten. The
   estimate is the interface: ~46k lines of SwiftUI is months for a team, not a
   patch.
2. **Swift on Windows for the logic, a shell for the interface** — maximizes
   logic reuse (OpenCodeKit, UsageKit's providers with path adapters), but
   Swift-on-Windows has no SwiftUI, and C ABI interop into WinUI/WPF is friction
   with little payoff.
3. **A web or Tauri/Electron shell around the engine** — fastest to something
   runnable, and the largest product gap: the review/changes/transcript
   experience is the hand-tuned 27k-line part.

## A staged path

- **Stage 0.** Engine bootstrap for Windows, the link bridge's Windows edges,
  tests and a Windows CI job. No interface.
- **Stage 1 (this change).** A minimal client around the bootstrap: `windows/harness/`
  — sessions, prompts, streaming, permission asks, folded from the engine's events
  by the same rules the Mac app's Transcript uses. Its view is plain HTML/JS so the
  core loop is exercisable everywhere, not only on Windows; a native toolkit (the
  Stage 2 question) replaces the page, not the client under it.
- **Stage 2.** Panel parity: files, terminal (ConPTY), browser (WebView2), the
  changes/review flow — and the native shell for Stage 1's client.
  - **2.1 (this change).** The native shell: `windows/electron/` (Electron) — a
    window, a tray, single instance, and the harness supervised as a child process;
    plus an NSIS installer and a portable build. The shell reuses the harness UI
    verbatim and builds in CI on `windows-latest`.
  - **2.2 (next).** ConPTY terminal, files panel, diff view, tray polish,
    auto-update wiring, code signing.
  - **2.38 (this change).** Providers, the Mac app's way: the engine's own are listed, and
    you can add one of yours with its id, its name, its address and its models — the key is
    not written here, it stays where opencode keeps it.
  - **2.37. The upstream's v0.5.20 behaviour: the sidebar folds away (and
    the conversation moves with it, Ctrl+0), the way the Mac app's does since 0.5.20.
  - **2.36. The Changes panel's pull request, the Mac app's way: the
    branch is pushed, the session's model writes the title and the description (with the
    Git settings' instructions), and the host's pull request page opens with them filled in.
  - **2.35. The import reads opencode's own settings when they are
    `.jsonc` — with comments and trailing commas, the way the tools that write them
    (REA, for one) write them. That is what lets a server installed by another tool
    (REA's 207 reverse-engineering tools, among them) come over to Kuvo Code with one
    click.
  - **2.34. The composer's menus, the Mac app's way: the model and the agent
    are chosen from a searchable list — the models grouped by provider, with their context
    window — instead of a plain drop-down.
  - **2.33. The formulas, the Mac app's MathText: KaTeX renders $inline$
    and $$block$$, the code is put aside first so a dollar sign in a snippet stays one, and
    the fonts travel with the page.
  - **2.32. The image viewer: clicking an attached image opens it over the
    page, the Mac app's way, instead of a new browser tab.
  - **2.31. The Mac app's steps row: between two replies, one line says what
    the agent did — "Thought for 40s, ran 6 commands, read 3 files (1 failed)" — and it opens
    to each step, with the Mac's own words.
  - **2.30. Two more of the Mac app's behaviours: the conversation follows
    the newest words (and offers to come back when you scroll up to read), and selecting a
    passage of the answer offers to *quote* it into the composer, where it joins your next
    message.
  - **2.29. More of the Mac app, in React: the long messages fold with a
    *Show more*, the palette finds the project's files and renames the session, and the
    Changes panel puts a file back as it was. `docs/PARITY.md` now says, feature by
    feature, where the Windows client stands against the Mac app.
  - **2.28. The Changes panel's Branch scope: what the branch added since
    it left its base (the repository's default branch, and the point where they parted), and
    the Mac app's Git settings — the branch prefix and the instructions the model writes
    commit and pull-request messages with.
  - **2.27. The Mac app's Changes panel: an extra tab in the side panel
    with the project's changes, read from git (uncommitted, unstaged, staged) or from the
    session's own edits, each file folded to its changes, a note written on a line that
    goes to the agent with the next message, a commit message the session's model writes
    ("Suggest a Message") and the commit itself.
  - **2.26. The motion layer, in the direction's own hand: the overlays
    rise, the drawer slides, the entries and the questions arrive gently, the engine's dot
    breathes while it works, the scrollbars are thin and quiet. Every duration comes from
    the tokens, so "Motion: Reduced" — and the system's own preference — stop all of it at
    once. With it: the palette answers to the arrow keys, the queue folds away when it is
    long, the split pane reads the session it shows, and files dropped on the composer are
    taken.
  - **2.25. The Mac app's way of putting a session away: a mark of the
    app's own, so it leaves the sidebar but stays searchable — Settings › Archived sessions
    brings it back or deletes it. The Keyboard page lists every shortcut, by where it is
    used, and the ones that were missing work now (Ctrl+N, Ctrl+S, Ctrl+F, Ctrl+,, Ctrl+.).
  - **2.24. The Mac app's searching, in the React view: the sidebar finds
    what was said in any session, the drawer finds the project's files by what is written
    in them, and *Find in conversation* narrows what the export carries.
  - **2.23. The Mac app's General settings on Windows: automatic updates,
    starting at login and keeping the machine awake now live in the app's own settings
    (the shell's file, reached through the harness), and *Bring over from opencode* copies
    the MCP servers, the agents, the commands and the model — the keys stay where they
    are. The context gauge opens its popover (what the window is used for, the cost, and
    *Compact context*).
  - **2.22. The conversation view is React and TypeScript: `windows/app`
    holds the source, `npm run build` bundles it into the page the harness serves, and the
    packed executable carries that build. The state stays a plain object the way the page
    has always kept it; React draws it. The hand-written page stays as a fallback when
    there is no build, so the app never shows nothing.
  - **2.21. The look is bound to OpenDesign's design direction `modern-minimal`
    ("Modern minimal — Linear / Vercel"), read with the tool that ships it
    (`od tools directions --id modern-minimal --json`): system fonts, hairline borders, no
    shadows except what floats, tabular numerals, one accent. The binding is written down in
    `windows/harness/ui/DESIGN.md`. Also: the settings pages belong to the settings — they
    had slipped inside the navigation, which broke every page of it.
  - **2.20. What other tools write into opencode's own settings is now
    visible and can be brought over: the MCP servers the CLI, another agent, or a tool
    like OpenDesign put in `~/.config/opencode/opencode.json` are listed in Settings ▸
    MCP servers, and one click copies them into this app's own settings — in the shape
    this engine reads (`mcp.servers`, `disabled`), since the engine here reads its own
    folder only. The engine is started over afterwards, so the server connects.
  - **2.19. The packaged app served nothing: the executable's page
    files live inside the binary, and the server asked the disk before the blob, so
    every file came back "Not found." in the installed app (the source tree beside
    the build hid it in CI). The blob is asked first now, and the smoke runs the
    executable from a folder with no `ui/` beside it, so this can't pass unnoticed
    again.
  - **2.18.** Forms (the agent's question tool and MCP servers' asks, answered or
    skipped per field type) and revert (undo to before a user message, the words back in the
    composer, redo brings it all back).
  - **2.17. The settings file: MCP servers (list, add, edit, catalog, timeouts,
    on/off, Try Again), agents (defaults, mode, model, steps, instructions, permission
    rules), skills (list, on/off via deny rule, own SKILL.md files), commands (own, with
    agent/model/subagent/template + the engine's own read-only) — edited in pages like the
    Mac app's, saved whole, with a Restart-the-engine button.
  - **2.16. Engine-surface parity: header branch chip (`api/vcs`),
    per-session changed files (`api/session/:id/diff`), the real queue dock on
    the engine's inbox (steer/queue toggle, take back), context compaction,
    read/unread sessions (`api/session/:id/view`), saved-permission rules
    viewer, the engine's read-only lists in settings, and a manual
    light/dark/system appearance mode.
- **Stage 3.** The rest: usage tray, notifications, machines over SSH, phone
  link, packaging, update feed, signing.

## Packaging and release

The Mac pipeline (`scripts/build-app.sh`, `build-dmg.sh`, `appcast.sh`,
`release.yml`) is codesign/notarize/appcast throughout and is Mac-only. A Windows
pipeline needs: an installer (MSIX or Velopack), Authenticode signing (EV
certificate to avoid SmartScreen), an update feed of its own, file associations
for folders and `.kuvobot`, and a `windows-latest` CI job — the same shape,
different tools.

## Licensing

The repository is PolyForm Noncommercial 1.0.0: you may modify and distribute it
for noncommercial purposes with the license and notices passed on; commercial
distribution — including shipping a Windows harness in or for a business —
needs a written license from the copyright holder (`info@kuvo.run`). The MIT
components (opencode itself, UsageKit's OpenUsage fork, Prism, browser-use, the
SPM dependencies) can be reused with attribution, but the harness as a whole is
a derivative of this repository.

## To verify on real Windows first

- Whether `opencode.exe` honors the XDG folder overrides the way the Linux build
  does (the CI job's `e2e` proves it either way as it lands).
- Whether the Windows engine binaries are Authenticode-signed; if they are, the
  installer should check it the way macOS checks codesign.
- Windows OpenSSH's tunnel lifetime without `ControlMaster`, for the machines
  feature.
