# Contributing to Kuvo Code

Thanks for helping improve Kuvo Code. It's a native Mac interface for the
opencode engine, so the best changes keep it that way:

- **Native first.** SwiftUI and AppKit. A web view only where the web is the
  content, like the browser tab.
- **The engine stays opencode, unmodified.** Kuvo Code changes how working with
  an agent looks and feels. Changes to how the agent itself behaves (its tools,
  prompts or providers) belong in [opencode](https://github.com/anomalyco/opencode).
- **Few dependencies.** Lean on the system frameworks.

## Before opening a change

- Search existing issues and pull requests first.
- Open an issue before starting a large feature, a new dependency, or a change
  to how the app runs the engine. Small fixes don't need prior approval.
- Keep pull requests focused. Separate mechanical moves from behavior changes.
- If the change is user-facing, say what the docs at
  [kuvo.run/code/docs](https://kuvo.run/code/docs/) need to cover.

## Development setup

You need a Mac with Apple silicon, macOS 26 or later, and Xcode 27 or later.

```sh
git clone https://github.com/serhatandic/kuvo-code.git
cd kuvo-code
open KuvoCode.xcodeproj
```

Run the **KuvoCode** scheme. To build from Terminal instead:

```sh
xcodebuild -project KuvoCode.xcodeproj -scheme KuvoCode -configuration Debug -derivedDataPath build/DerivedData build
open "build/DerivedData/Build/Products/Debug/Kuvo Code.app"
```

To build the release app and its disk image the way CI does:

```sh
./scripts/build-app.sh
./scripts/build-dmg.sh
open "build/Kuvo Code.app"
```

Only these builds update themselves; debug builds have no update feed and hide
the update controls.

Builds are signed ad hoc, so macOS treats every build as a new app and asks for
privacy permissions (like access to Desktop) again. To keep one identity
between builds, copy `Config/Signing.local.xcconfig.example` to
`Config/Signing.local.xcconfig` and set your team. That file is git-ignored.

The first launch downloads the pinned opencode engine. To use another build of
it, set `KUVO_OPENCODE_BINARY` to its path in the scheme's environment.

### Tests

The engine client and the usage tracker have tests:

```sh
cd Packages/OpenCodeKit && swift test
cd Packages/UsageKit && swift test
```

Recorded engine responses in `Tests/OpenCodeKitTests/Fixtures` drive most of
OpenCodeKit's tests. `LiveServerTests` run against a real binary when
`OPENCODE_TEST_BINARY` points to one, and `LiveRemoteEngineTests` against a
Linux machine when `KUVO_TEST_SSH_HOST` names one you reach with SSH (they
install the engine in its `~/.kuvo-code`).

### Project layout

| Path | What's there |
| --- | --- |
| `KuvoCode/` | The app: views, stores and the design system |
| `Packages/OpenCodeKit/` | The engine client: API, models, event stream, transcript reducer, engine installer |
| `Packages/UsageKit/` | The usage tracker in the menu bar, a fork of [OpenUsage](https://github.com/robinebers/openusage) |
| `Config/App.xcconfig` | The app's name and bundle ID, and signing defaults |
| `Licenses/` | License texts for code copied into this repository |

### Debug launch variables

Debug builds read these environment variables to open the app in a given state
without clicking, for trying a change or taking screenshots:

| Variable | Effect |
| --- | --- |
| `KUVO_OPENCODE_BINARY` | Use this opencode binary instead of the pinned download |
| `KUVO_DEMO_FOLDER`, `KUVO_DEMO_PROMPT`, `KUVO_DEMO_MODEL` | Open a project and start a session with a prompt (`provider/model`) |
| `KUVO_DEMO_WORKTREE` | Start that session in a worktree of its own |
| `KUVO_DEMO_DRAFT` | With `KUVO_DEMO_FOLDER` and no prompt: a message typed, not sent, in the new session's composer |
| `KUVO_DEMO_TABS` | Open the project's sessions as tabs |
| `KUVO_DEMO_QUEUE` | Messages to queue once that session's agent is working, separated by `\|` |
| `KUVO_DEMO_NEW_PROJECT` | Open the New Project sheet with these comma-separated folders |
| `KUVO_DEMO_BACKGROUND` | Don't bring the window forward, so it doesn't take the keyboard while you work elsewhere |
| `KUVO_DEMO_FILES` | Comma-separated paths to attach to that prompt |
| `KUVO_DEMO_COMPOSER_FILES` | Comma-separated paths to show as attached in the composer |
| `KUVO_DEMO_PROVIDERS` | Open Accounts (on a provider's sign-in if it names one) |
| `KUVO_DEMO_APPEARANCE` | `light` or `dark` |
| `KUVO_DEMO_CHANGES` | Show the side panel |
| `KUVO_DEMO_PANEL` | Open tools in the panel, comma-separated: `terminal`, `browser=<address>`, `files`, `file=<path>`, `changes`, `run`, `expand` |
| `KUVO_DEMO_WINDOW` | Window size, as `WIDTHxHEIGHT` |
| `KUVO_DEMO_SEARCH` | Type this in the sidebar's search field |
| `KUVO_DEMO_PALETTE` | Open the command palette with this typed in it (empty for none) |
| `KUVO_DEMO_MENU` | Open the `mode` or `model` menu (`models` for its first submenu), or `location` in the New Project sheet |
| `KUVO_DEMO_USAGE` | Open the menu bar's usage panel on `dashboard`, `customize` or `settings`, or `off` to leave the usage tracker out |
| `KUVO_DEMO_SETTINGS` | Open Settings on a page, by its `SettingsPage` name: `general`, `appearance`, `storage`, `accounts`, `agents`, `mcp`, `git`, `browser`, `passwords` and so on |
| `KUVO_DEMO_ADD_MACHINE` | The Add Machine sheet, open, with `KUVO_DEMO_SETTINGS=machines` or over `KUVO_DEMO_NEW_PROJECT` |
| `KUVO_DEMO_WELCOME` | No tabs, so the welcome card shows |
| `KUVO_DEMO_NEW_BOT` | The New Bot sheet, open |
| `KUVO_DEMO_BOT`, `KUVO_DEMO_BOT_PROMPT` | Make the bot `<name>\|<job>\|<instructions>[\|<machine>]` unless one has that name, open it, and give it this task |
| `KUVO_DEMO_EDIT_BOT` | With `KUVO_DEMO_BOT`: that bot's Edit Bot sheet, open |
| `KUVO_DEMO_NAME` | A name to use instead of yours, for the initials on review comments |
| `KUVO_DEMO_COMMENT` | Add a review comment to the session in view, as `<path in the project>:<line>:<text>` |
| `KUVO_ANALYTICS_URL` | Send anonymous usage to this collector, e.g. `http://127.0.0.1:8787/kuvo/code`; debug builds send none otherwise |

### The icon

`scripts/icon.py` generates the app icon as an Icon Composer file in
`KuvoCode/AppIcon.icon`, which Xcode compiles with the app. Run it again after
changing the icon there.

### Dependencies

Kuvo Code depends on Textual, SwiftTerm, Sparkle and, through UsageKit,
KeyboardShortcuts. SwiftTerm stays on 1.11, because 1.12 and later need the
Metal toolchain to build.

If you add or update a package, or change code copied from another project
(`prism-bundle.js`, `buildDomTree.js`, UsageKit), run
`./scripts/third-party-licenses.sh` and commit the updated
`THIRD_PARTY_LICENSES.txt`; CI checks that it's current.

## Workflow

Every change starts from an issue and lands on `main` through a pull request.

1. **Find or open an issue** for the change, and comment that you're working on
   it.
2. **Fork the repository** and create a branch named
   `type/issue-short-description`, for example `fix/42-sidebar-width` or
   `feat/57-session-search`. Use one of these types:

   | Type | For |
   | --- | --- |
   | `feat` | new behavior |
   | `fix` | bug fixes |
   | `perf` | speed, memory or battery improvements |
   | `refactor` | code changes that don't change behavior |
   | `docs` | documentation only |
   | `test` | tests only |
   | `ci` | workflows and build scripts |
   | `chore` | dependencies and other upkeep |

3. **Open a pull request** against `main`.
   - **The title becomes the commit message**, because pull requests are
     squash-merged into a single commit. Write it as one plain sentence that
     says what the change does, in the imperative: "Stop the sidebar from
     growing past its maximum width", not "Fixed sidebar" or "feat: sidebar".
   - **Start the description with `Fixes #42`** (your issue's number), so
     merging closes the issue.
   - Fill in the rest of the template: what changed, why, and how you verified
     it.
   - **If people using Kuvo Code would notice the change, add a line to
     `CHANGELOG.md`** under Unreleased, saying what they'll see. It becomes
     part of the next release's notes, on GitHub and in the app's update
     window.
4. **CI must pass**, and a maintainer reviews and approves the pull request.
   It's then squash-merged and the branch is deleted.

`main` only accepts changes through pull requests.

## Pull requests

Keep commit messages on your branch short and factual; they're combined when
the pull request is merged. Don't include generated build output, credentials,
personal paths, AI session metadata, or co-author trailers added by coding
tools. Screenshots and recordings are welcome for UI changes; make sure they
don't show your sessions, accounts or file paths.

## Contribution license

Kuvo Code is source-available for noncommercial use under the
[PolyForm Noncommercial License](LICENSE). To keep commercial licensing rights
coherent as the project accepts outside work, every contributor must accept
the [Contributor License Agreement](CONTRIBUTOR_LICENSE_AGREEMENT.md).

You retain ownership of your contribution. The agreement grants the project
owner the additional rights needed to include it in both the public
noncommercial project and any separately licensed commercial version. A pull
request can't be merged until every contributor to it has accepted those
terms.
