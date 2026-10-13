# kuvo-ai

A native macOS app for working with coding agents. *(Working title.)*

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
| `KuvoAI/` | The app (SwiftUI): views, stores, design system |
| `Packages/OpenCodeKit/` | The engine client: API, models, event stream, transcript reducer, engine installer |
| `Config/App.xcconfig` | The app's name and bundle ID, and signing defaults |

## Building

Requires macOS 26 and Xcode 26 or later.

1. Open `KuvoAI.xcodeproj` and run the **KuvoAI** scheme.
2. Optional: to keep one code signature between builds (so macOS remembers
   privacy answers), copy `Config/Signing.local.xcconfig.example` to
   `Config/Signing.local.xcconfig` and set your team. That file is git-ignored.

Tests for the engine client:

```sh
cd Packages/OpenCodeKit && swift test
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
| `KUVO_DEMO_USAGE` | Show the menu bar's usage panel in a sheet |

## Usage in the menu bar

The menu bar shows how much of each subscription is left: Codex (5-hour and weekly
windows), Claude, GitHub Copilot and OpenCode Go. The providers are adapted from
[OpenUsage](https://github.com/robinebers/openusage). They read logins already on the
Mac (the Codex CLI's, Claude Code's, your editor's or gh's) and the accounts connected
in the app. Reading logins from the Keychain and renewing expired logins are off until
you turn them on in Settings › Usage.

## Third-party software

- [opencode](https://github.com/anomalyco/opencode) (MIT), downloaded at runtime.
- [Textual](https://github.com/gonzalezreal/textual) (MIT), for Markdown.
- [OpenUsage](https://github.com/robinebers/openusage) (MIT), the usage providers.
- Provider logos come from [models.dev](https://models.dev).

License texts are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
