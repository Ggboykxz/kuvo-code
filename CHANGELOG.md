# Changelog

What changed in each release, for people using Kuvo Code. Add changes people would notice under
Unreleased, in plain words about what they'll see, as part of the change itself. Before a
release, Unreleased is renamed to the version; the release notes come from that section.

## Unreleased

- **Bring your Claude Code agents and commands.** Settings › Agents imports the agents in ~/.claude/agents as subagents, with their descriptions and instructions, and Settings › Commands imports the slash commands in ~/.claude/commands.
- **Attempts.** Under Worktree in a new session's composer, pick 2, 3 or 4 sessions to try the same task, each in a worktree of its own, then compare them and keep the best.
- **Search what was said.** The sidebar's search also looks in conversations, and shows the words around each match; clicking one opens the session with Find on it.
- **Switch branches from the title bar.** Click the branch under the project's name for the repository's branches, latest first, or New Branch….
- **Write your own skills** in Settings › Skills: New Skill… takes a name, when the agent should use it, and its instructions. Edit… changes it later.
- **Answer permission requests from the notification.** When the agent asks while you're in another app, the notification has Allow, Always Allow and Deny buttons.
- **Popular MCP servers in one click.** Settings › MCP lists well-known servers, like Linear, Sentry, Notion, Atlassian, Stripe, Supabase, Neon, Context7 and Hugging Face, each from the company behind it. Add one, and sign in if it needs an account.
- **Create Pull Request** from the Changes tab on any branch other than the main one: it pushes the branch and opens the pull request page on GitHub or GitLab, with a title and description the session's model wrote from the branch's changes.
- **This Session** in the Changes tab shows only what the session's agent changed, apart from your own edits and other sessions'.
- Fixed: outside a git repository, the Changes tab listed the agent's edits without their lines.
- **Command palette (⌘K).** Find a session in any project, a file in this one, or something to do, from New Terminal to any Settings tab, with its shortcut. Before you type, it lists your latest sessions.
- **Run your app with one click.** Give a project a run command, like npm run dev, in Edit Project; the play button in the title bar, or ⌘R, runs it in a terminal in the panel, in the session's folder or worktree. Run again to start it over.
- **Worktrees.** Pick Worktree in a new session's composer and the agent works in its own copy of the project, on a branch of its own named after the session, so several sessions can work at once without touching each other's files or yours. The Changes tab shows everything the branch changed, and its branch menu merges the work into your branch or pushes it and opens a pull request. Archiving the session offers to remove the worktree. A setup command in Edit Project runs in each new worktree, to install dependencies or copy files like .env.
- **Since main** in the Changes tab shows everything a branch changed since it left the main branch, committed or not.
- **Open a folder from outside the app.** Drop it on the Dock icon, choose Open With › Kuvo Code in the Finder, or run `open -a "Kuvo Code" <folder>`, and it opens as a project with a new session. Right-click the Dock icon for your latest sessions and New Session.
- **The engine is opencode 2.0.29.** A reply that runs past the model's length limit now carries on by itself, and the transcript says so in a line.
- **Anonymous usage.** Kuvo Code now shares which features get used and how often, with the app and macOS versions, so work goes where it matters. Never your code, prompts, files or accounts. A note at first launch says so, and you can turn it off there or in Settings › General.

## 0.2.0

- **Set up the agent in Settings.** New Agents, Permissions, MCP, Skills and Commands tabs, and more under Engine, cover what opencode's settings file does: your own agents and their instructions, what the agent may do without asking, MCP servers with their status, slash commands, web search, summaries and more. Changes apply right away.
- **Add your own providers** in Accounts: a company proxy, a self-hosted server or any service with an OpenAI- or Anthropic-compatible API, with its models.
- **Add skills from popular collections on GitHub** in Settings › Skills: see what a skill's files are, add it, and turn any skill on or off.
- **A project can have several folders.** New Project (⇧⌘N, or + next to Projects) names a project and adds its folders; sessions run in the primary one, and the agent can work in the others too and knows them by name. Right-click a project for **Edit Project…** to rename it or add and remove folders.
- The **Files** panel lists all of a project's folders, and its filter looks in all of them. The **Changes** panel has a folder menu to show each folder's changes, and comments there name the folder.
- **Type / for commands:** /init sets up an AGENTS.md that tells the agent about your project, and /review reviews your changes. The conversation shows the command, not the long prompt behind it.
- **Type @ in the composer to mention a file** from any of the project's folders, picked from a list that starts with the files you changed last and narrows as you type.
- **⌘Return queues a message** until the agent is done. Queued messages go one after another, as many as you like, and a message sent with Return while the agent works still reaches it first, at its next step.
- **Messages waiting for the agent are listed above the composer.** Send one now (the agent stops its current step and takes it), put it back in the composer to edit (or press ↑ in an empty composer), or remove it.
- Stop pauses the queue, and so does a failed run, instead of sending the rest into the same error. **Resume** picks it up again.
- **Undo from any of your messages:** hover over it and click Undo From Here to take back the conversation and the agent's file changes since, with the message back in the composer to edit. Redo brings it all back until you send.
- **New Session From Here**, under one of your messages, starts a new session with the conversation up to it, to try another way while keeping this one.
- **Try Again** under a failed run sends your last message again, in place of the failed attempt.
- **Build It** under an answer in Plan mode switches to Build and has the agent carry the plan out.
- **Summarize Now** in the context ring's popover shrinks a long conversation to a summary, to make room before the context window fills up.
- **Files a reply names open with a click**, in the side panel.
- **Open Quickly (⇧⌘O)** finds a file in the project by name and opens it in the side panel.
- **Add to Message**, when you right-click a selection in a file or a terminal in the side panel, puts those lines (as `@src/app.ts:4-6`) or that output in your message.
- When the agent runs code that calls its tools (Code Mode), the step reads "Ran code" and opens to show the code and what it returned.
- **See what a subagent is doing.** When the agent hands part of the task to a subagent, its step opens to show what it was asked and each step it takes, live, then what it found and the tokens and cost it used.
- **Under each reply, "Edited 3 files"** lists what that turn changed, with lines added and removed, each a click from the panel.
- **Commit from the Changes panel**, and push afterwards if you like: Commit… takes what's staged, or all the changes shown, and the session's model can suggest the message.
- **Stage, unstage or discard a file's changes** from its menu in the Changes panel. Discarding asks first, and a new file goes to the Trash.
- **Notifications:** when a session finishes or needs your answer while you're in another app, you get a notification that opens it, and the Dock icon counts the sessions waiting for you. Settings › General turns them off.
- **Pin sessions** you keep coming back to: they stay at the top of the sidebar.
- **Search sessions** from the top of the sidebar, by title or project.
- **Archive sessions** you're done with: they leave the sidebar's lists, and searching still finds them.
- Right-click a session's tab to rename it.
- **Copy or export a conversation as Markdown** from the session's menu in the sidebar, to share it in an issue or a chat.
- **⌘W closes the session tab**, and ⇧⌘T reopens the last one you closed, where it was. ⇧⌘W closes the window.
- A long message, like a pasted log, shows its first lines in the conversation until you click **Show More**.
- **⌘F finds words in the conversation**, highlighting each message they're in.
- **↑ and ↓ in an empty composer go through the messages you sent**, as in a shell.
- What you type in the composer stays there when you switch to another session, and when you quit the app.
- Copy buttons under each reply and, when you hover, under each of your messages.
- Code blocks show their language and have their own **Copy** button.
- Hovering over one of your messages shows when you sent it.
- Right-click a project and choose **Open In** to open it in your editor, terminal or git app.
- Right-click a step that read or changed a file to open the file in the panel or show it in the Finder.
- ⌘1 to ⌘8 show that session tab, and ⌘9 the last one, as in browsers.
- Escape in the composer stops the agent, as ⌘. does.
- While the agent works, the end of the conversation shows how long it's been at it.
- Scrolled up in a conversation, a button takes you back to the newest message.
- A step you stopped, with Stop or Send Now, shows as stopped instead of as a red error.
- The panel no longer shows scroll bars, which took a strip off its content on Macs set to always show them.
- A long conversation sometimes opened part of the way up instead of at its newest message.

## 0.1.2

- **Signing in with Google, Apple and others works in the panel's browser.** Sign-in windows open in their own tab and close themselves when you're done, back on the site you were signing in to.
- **Click the context ring at the top of a conversation** to see what it measures: how full the model's context window is, what the session has cost, and your plan's limits when the usage item follows that account.
- **The terminal sits right on the panel**, in the panel's own color, with no darker box around it and no scroll bar track.
- Links that open a new window always open in a new tab, as in other browsers, so that setting is gone.
- Searching Accounts for a provider that isn't there says so, with a button to clear the search, instead of showing an empty box.
- Closing the panel's last tab leaves a new tab in its place, instead of an empty panel.
- The panel button at the top right of the window is a plain icon, like the sessions button at the top left, and it's the one place to show and hide the panel.
- A narrow panel with a file open no longer spills over the conversation; the file list next to the file gets narrower instead.
- Files and changed lines in the Changes panel are plain rows, not rounded boxes with notches at the edge.
- The line beside a file's line numbers no longer runs up through the file's header.
- The spinner on a working session's tab no longer flies in from the corner of the window.

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
