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
  - **2.19 (this change).** The packaged app served nothing: the executable's page
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
