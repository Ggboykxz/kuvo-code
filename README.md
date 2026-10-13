# Kuvo Code

A native macOS app for working with coding agents.

It's a client for [opencode](https://github.com/anomalyco/opencode): the opencode
engine does the agent work (models, tools, sign-ins, sessions), and this app is
the interface, written in SwiftUI.

## How it works

- **The engine is opencode itself**, the official signed `@opencode/cli` binary
  (v2), unmodified. On first launch the app downloads the pinned version,
  checks its npm checksum and its code signature, and keeps it in
  `~/Library/Application Support/<bundle id>/engine`.
- **Each launch runs a private server**: `opencode serve --stdio --port 0`
  with a random password. It exits when the app does.
- **Its data is separate** from any opencode you've installed. Sessions,
  accounts and settings live in `~/Library/Application Support/<bundle id>/opencode`.
- **Everything else is the app**: it talks to the server's HTTP API and
  follows its event stream to show live transcripts.

## Project layout

| Path | What's there |
| --- | --- |
| `KuvoCode/` | The app (SwiftUI): views, stores, design system |
| `Packages/OpenCodeKit/` | The engine client: API, models, event stream, transcript reducer, engine installer |
| `Packages/UsageKit/` | The usage tracker in the menu bar, a fork of [OpenUsage](https://github.com/robinebers/openusage) |
| `Config/App.xcconfig` | The app's name and bundle ID, and signing defaults |

## Building

Requires macOS 26 and Xcode 26 or later.

1. Open `KuvoCode.xcodeproj` and run the **KuvoCode** scheme.
2. Optional: to keep one code signature between builds (so macOS remembers
   privacy answers), copy `Config/Signing.local.xcconfig.example` to
   `Config/Signing.local.xcconfig` and set your team. That file is git-ignored.

Tests for the engine client and the usage tracker:

```sh
cd Packages/OpenCodeKit && swift test
cd Packages/UsageKit && swift test
```

Recorded engine responses in `Tests/OpenCodeKitTests/Fixtures` drive most
tests. `LiveServerTests` run against a real binary when `OPENCODE_TEST_BINARY`
points to one.

### Debug launch variables

Debug builds read a few environment variables to put the app in a given state
without clicking:

| Variable | Effect |
| --- | --- |
| `KUVO_OPENCODE_BINARY` | Use this opencode binary instead of the pinned download |
| `KUVO_DEMO_FOLDER`, `KUVO_DEMO_PROMPT`, `KUVO_DEMO_MODEL` | Open a project and start a session with a prompt (`provider/model`) |
| `KUVO_DEMO_PROVIDERS` | Open Accounts (on a provider's sign-in if it names one) |
| `KUVO_DEMO_APPEARANCE` | `light` or `dark` |
| `KUVO_DEMO_CHANGES` | Show the Changes card |
| `KUVO_DEMO_WINDOW` | Window size, as `WIDTHxHEIGHT` |
| `KUVO_DEMO_MENU` | Open the `mode` or `model` menu (`models` for its first submenu) |
| `KUVO_DEMO_USAGE` | Open the menu bar's usage panel on `dashboard`, `customize` or `settings` |

## Usage in the menu bar

The menu bar item tracks your AI plans: limits with pace and reset countdowns, spend
for today, yesterday and the last 30 days with a total across providers, a 30-day trend,
and optional notifications. It covers Claude, Codex, Copilot, Cursor, OpenCode,
OpenRouter, Z.ai, Grok, Antigravity, Devin and Ollama.

It's [UsageKit](Packages/UsageKit), our fork of [OpenUsage](https://github.com/robinebers/openusage)
by Robin Ebers. It reads the logins those tools already keep on the Mac, plus the accounts
connected in Kuvo Code. Kuvo Code's own runs count toward spend. The first click on the item
asks which providers to follow. Its settings are in the panel, also linked from Settings › Usage.

## Third-party software

- [opencode](https://github.com/anomalyco/opencode) (MIT), downloaded at runtime.
- [Textual](https://github.com/gonzalezreal/textual) (MIT), for Markdown.
- [OpenUsage](https://github.com/robinebers/openusage) (MIT), forked as UsageKit for the menu bar.
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (MIT), the usage panel's global shortcut.
- Provider logos come from [models.dev](https://models.dev).

License texts are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
