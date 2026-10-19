# Integration plan — the Mac app, feature by feature, onto Windows

How the macOS app's features were read, what the Windows client has today, and the ordered
plan to close what is left.

## How the Mac app was read

Two sources, because neither alone is enough:

1. **The shipped product**, inventoried with REA (the `reverse-engineer-anything` skill):
   `KuvoCode.dmg` (v0.5.21) → `Kuvo Code.app` → its bundle: **157 nodes, 172 occurrences,
   166 edges, source_complete** (112 files, 55 directories, 5 symlinks). Evidence
   `ev_36f899e7223976780ceb801bd5f69f5bd083efde7b4a1bf9774aec7e35908596`.
   What the product ships: `Sparkle.framework` (auto-update), `browser-runtime.json` +
   `kuvo-browser.js` + `buildDomTree.js` (the browser), `prism-bundle.js` (highlighting),
   `Textual_Textual.bundle` (markdown), `swiftui-math_SwiftUIMath.bundle` (formulas),
   `KeyboardShortcuts_KeyboardShortcuts.bundle` (the shortcut recorder), `UsageKit_UsageKit.bundle`
   (usage), `KuvoLink_KuvoLink.bundle/kuvo-link.js` (the link bridge), `AppIcon.icns`,
   `THIRD_PARTY_LICENSES.txt`.
   *Limit, stated plainly:* the Mach-O itself cannot be read from Linux — REA's native
   inspection needs macOS ("Native macOS utilities require macOS") — so the **behaviour**
   came from the source, and the **composition** from the bundle.
2. **The source**, which is in this repository: 646 Swift files, ~133 000 lines
   (`KuvoCode/`, `Packages/OpenCodeKit`), read view by view.

The per-feature ledger is `docs/PARITY.md`; this document is the plan that follows it.

## What is already there

| Area | State |
| --- | --- |
| The conversation, the composer, the queue, the gauge, the steps row, quoting, the viewer, formulas, the searches | ported |
| The Changes panel: git in four scopes, folded files, notes on a line, a commit, a pull request | ported |
| The settings: Appearance, Keyboard, MCP, Agents, Skills, Commands, Permissions, Providers, Git, Archived sessions, Engine & storage, General | ported |
| The shell: window, tray, single instance, terminal (ConPTY), auto-update wiring | ported |
| The design: bound to OpenDesign's `modern-minimal` direction, with the Mac's glass and motions | ported |

## The plan, in order

### 1. The icon and the signature — ours, and it is visible at every launch
The Mac ships `AppIcon.icns`; we ship a 16-pixel placeholder. **Needs:** an `.icns` (or a
1024 PNG to derive one) and its `.ico`. **Lands in:** `windows/electron/build/icon.ico`,
`windows/harness/ui/` (the window's icon on the taskbar).

### 2. The shortcut recorder — the Mac lets you *change* the shortcuts
**Done.** The Mac's `KeyboardShortcuts` bundle is the recorder UI; ours is the same: click
the keys of a shortcut, press the new ones, and they are kept in the app's own settings and
answered to by the key handler. The list is the Mac's, in the groups it uses, with the keys
a Windows user reads (⌘ is Ctrl, ⌥ is Alt). **Lands in:** `windows/app/src/keys.mjs` (the
list and the keys), `windows/app/src/shortcuts.ts` (the app's half), `windows/app/src/App.tsx`
(the handler), the Keyboard page, the settings file.

### 3. The usage panel — what the account spent
The Mac ships `UsageKit` and a usage page. We have the cost per session in the gauge's
popover only. **Needs:** the engine's usage routes, and the Mac's page. **Lands in:**
a new "Usage" settings page, reading the engine's accounts.

### 4. The browser — the Mac's own, shipped as resources
`browser-runtime.json`, `kuvo-browser.js`, `buildDomTree.js`: the Mac can show a page
inside itself and ask the agent about it. **This is upstream surface** (the engine's
`kuvo-browser` tools and the `BrowserAskCard`). Until the engine exposes it on Windows,
the honest state is what `docs/PARITY.md` says: out of scope here.

### 5. The commands the agent runs must find *your* sign-ins
The Mac's v0.5.21 fix lets the agent's commands see the user's own config (`gh`, tools in
`~/.config`). We measured the cost: pointing the engine at the user's config home makes it
lose this app's own settings and skills. **Needs:** the engine to hand its commands the
user's environment while it reads ours. **Until then:** the import path (Settings ▸ General
› Bring over) is the way to get the user's servers, agents and model in.

### 6. The sign-ins we deliberately do not touch
The Mac's Integrations and Passwords pages write OAuth tokens and passwords. Ours does not:
the keys stay where opencode keeps them, and the page only says **which** sign-in is
missing. **If it is ever wanted:** it is a decision about secrets, not a port.

### 7. The upstream surface — the Mac's groups, bots, machines, phone
Group chats, bot recipes, remote machines, the phone link, the site sign-ins: all of it
needs the engine's own routes. **This is a Stage 3 decision, made with the maintainer, not
a port.**

## The rule the plan follows

A feature is ported when it **behaves** the same, not when it looks the same: the same
wording, the same gesture, the same moment it appears, and the same thing it does with
secrets. Where the Mac's behaviour needs the engine to change, that is written here as a
question for the maintainer rather than worked around.
