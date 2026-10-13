# Changelog

What changed in each release, for people using Kuvo Code. Add changes people would notice under
Unreleased, in plain words about what they'll see, as part of the change itself. Before a
release, Unreleased is renamed to the version; the release notes come from that section.

## Unreleased

- **Signing in with Google, Apple and others works in the panel's browser.** Sign-in windows open in their own tab and close themselves when you're done, back on the site you were signing in to.
- Links that open a new window always open in a new tab, as in other browsers, so that setting is gone.
- The spinner on a working session's tab no longer flies in from the corner of the window.
- Searching Accounts for a provider that isn't there says so, with a button to clear the search, instead of showing an empty box.
- The panel button at the top right of the window is a plain icon, like the sessions button at the top left.
- **Click the context ring at the top of a conversation** to see what it measures: how full the model's context window is, what the session has cost, and your plan's limits when the usage item follows that account.
- Closing the panel's last tab leaves a new tab in its place, instead of an empty panel.
- Files and changed lines in the Changes panel are plain rows again, not rounded boxes with notches at the edge.
- **The terminal sits right on the panel**, in the panel's own color, with no darker box around it and no scroll bar track.
- The panel no longer has a hide button of its own; the button at the top right of the window shows and hides it.
- A narrow panel with a file open no longer spills over the conversation; the file list next to the file gets narrower instead.
- The line beside a file's line numbers no longer runs up through the file's header.

## 0.1.1

- **Deleting a session asks first**, since it can't be undone.
- **API keys you paste into the usage panel are kept in your Keychain**, not in a file. Keys saved by 0.1.0 move there on their own.

## 0.1.0

Kuvo Code's first public release: a native Mac harness for coding agents that works with any model, on the opencode engine.

### Highlights

- **Any model.** Sign in with a subscription you already have, add an API key, or start with free models that need no account. Pick the model and effort for each message.
- **Built for the Mac.** SwiftUI and Liquid Glass on macOS 26. Sessions sit under their project in the sidebar, transcripts update live, and edits and commands open to show what they did.
- **Review changes like a pull request.** The Changes tab shows the project's uncommitted changes from git, with unchanged lines folded and pictures shown before and after. Comment on any line, and your comments go to the agent with your next message.
- **Files, terminals and a browser.** The side panel holds them as tabs: the project's files with code highlighted and Markdown rendered, your shell in the project folder, and a web browser. A new tab offers the tools and the sites you visit most, and Settings › Panel sets it up the way you like.
- **Browsing for the agent, with any model.** The agent can open pages in the panel's browser, read them, click, type and scroll, and you see every step.
- **Attach anything.** Drop, paste or pick files of any kind. Pictures show up in the transcript.
- **Plans and spend in the menu bar.** One bar per provider shows the limit closest to running out; click it for pace, reset times and spend for today and the last 30 days. Covers Claude, Codex, Copilot, Cursor, OpenCode, OpenRouter, Z.ai and more.
- **Build and Plan modes.** Plan mode talks a change through before making it. With **Ask First**, the agent asks before it edits files or runs commands.
- **Updates itself.** Kuvo Code checks for signed updates once a day and shows what's new before it installs one. **Kuvo Code › Check for Updates…** checks right away.
- **Kept apart from your own opencode.** The engine is the official opencode, unmodified, with its sessions, accounts and settings in Kuvo Code's own folder.
