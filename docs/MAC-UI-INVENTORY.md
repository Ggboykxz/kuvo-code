# Mac UI inventory — generated from the Swift source

Generated on 2026-10-20 by `windows/tools/mac-ui-inventory.mjs` from the source of
truth, `KuvoCode/`. **Do not edit by hand**; run the tool again. The registry that reads
this inventory — what each piece is, what the Windows app does today, and what remains —
is `docs/MAC-UI-MAP.md`.

Scope: 160 Swift files under `KuvoCode/` (27 in `Design/`,
74 in `Views/`, 8 in `App/`, 51 in `Stores/`).
Every row below cites its site as `file:line`.

## 1. Design files (27)

| File | Lines | Purpose (first doc line) |
| --- | ---: | --- |
| `AgentPointer.swift` | 204 | The pointer that shows where the agent acts on a page it browses: it glides to the element, |
| `BotAvatar.swift` | 670 | How a bot looks: a color, a shape and a face, picked when it's made and changed any time. |
| `BotMotion.swift` | 298 | A bot moving, played by Core Animation. BotPose works out its motion over one cycle of its |
| `Card.swift` | 199 | The window's building block: a rounded pane floating on the window's glass, |
| `Clipboard.swift` | 16 | Copying text, as Copy does everywhere: what was on the clipboard goes, the text takes its place. |
| `CodeBlockStyle.swift` | 268 | Code blocks in replies and Markdown: one recessed well with the code and its line numbers, |
| `CodeHighlighter.swift` | 196 | Colors code with Prism.js (bundled in Resources, MIT), off the main thread. Prism |
| `FileDrop.swift` | 70 | Takes files dropped anywhere over what it covers, text fields included: a text field would |
| `Flow.swift` | 63 | Lays views out in rows that wrap when the room runs out, each row against the leading edge, |
| `FolderIcon.swift` | 67 | A folder outline that opens when its project is open. SF Symbols has no open folder, |
| `HoverHighlight.swift` | 37 | A flat control: nothing behind it at rest, a soft fill under the pointer, and a |
| `IconOnlyToolbar.swift` | 38 |  |
| `InlineTitleField.swift` | 55 | A title renamed where it's shown (a session's row in the sidebar, its card's header), all of it |
| `Look.swift` | 150 | Settings › Appearance, beyond light and dark: the accent color, the window's background, and |
| `NativeMenu.swift` | 165 | A SwiftUI button that opens a real AppKit menu, built when clicked. |
| `PillPicker.swift` | 52 | A choice of a few, drawn as the title bar's tabs are: a glass track, the one chosen a raised |
| `PlainDatePicker.swift` | 43 | A date and time to type or step through, without a field's box: for a row in a well, which is |
| `Pressable.swift` | 275 | How the app's small, chrome-less controls show they can be clicked: a clear shade at rest |
| `ProviderLogo.swift` | 90 | A provider's mark, from the same logo set opencode's own apps use |
| `QuoteViews.swift` | 68 | Over the composer: what you're replying to, shortened, with a way to drop it. |
| `RightClickMenu.swift` | 65 | One window-level watcher for every marked view. |
| `ScreenRoom.swift` | 33 | How much of the screen there is above and below a view, read when it's asked, for a popover |
| `ScrollFrameMonitor.swift` | 76 | While the conversation scrolls, counts the frames that came late and the rows and code blocks |
| `Spinner.swift` | 177 | Kuvo Code's loader: its prompt mark (the chevron and the cursor) drawing itself in short |
| `Surfaces.swift` | 212 | The window's materials in one place: the light the canvas carries, the cards' fills, the lit |
| `Theme.swift` | 180 | Shared measurements, so spacing and shapes stay consistent and nest concentrically. |
| `WindowGlass.swift` | 82 | A drag handle in the gap between two cards that resizes the card on one side. |

## 2. View files (74)

| File | Lines | Purpose (first doc line) |
| --- | ---: | --- |
| `AnalyticsNotice.swift` | 38 | A one-time note at the bottom of the sidebar: Kuvo Code shares anonymous usage, what that |
| `BotEditor.swift` | 1092 | Making a bot, or changing one, in the window's main card: how it looks, its name and job, |
| `BrowserAskCard.swift` | 241 | Asks Kuvo Code can't show in a conversation: from a bot in a group chat, or from an agent it |
| `CommandPalette.swift` | 195 | One thing the palette can do: an action, a session to open, or a file to show. |
| `GroupChatView.swift` | 555 | A group chat: what you and its bots said, the one talking now, and where you write. The |
| `GroupEditor.swift` | 348 | Making a group chat, or changing one, in the window's main card: its name, its bots, and |
| `GroupMentions.swift` | 106 | "@Mira" in a group chat, so you see at a glance who's being asked: the name in bold, in the |
| `ImageViewer.swift` | 256 | Pictures you sent, looked at closer without leaving the window: over everything, fitted to it, |
| `MachineForm.swift` | 187 | Adding a machine: an SSH host this Mac can reach with its keys, checked before it's kept. In a |
| `MachineStatusViews.swift` | 135 | A machine's connection, as a dot and a word or two: green when connected, a spinner while |
| `MainView.swift` | 2009 | The workspace, laid out like Rex: open sessions as tabs in the title bar, and |
| `ProjectEditor.swift` | 483 | Creating a project, or changing one, in the window's main card: its name and its folders. |
| `Providers/ConnectView.swift` | 578 | Signing in to one provider, whichever way it supports: browser sign-in, |
| `Providers/CustomProviders.swift` | 243 | Providers you add yourself: a company proxy, a self-hosted server, any service that speaks |
| `Providers/ProvidersView.swift` | 313 | Accounts, a page of Settings: what's connected, the popular providers, and every other one |
| `RootView.swift` | 130 | The window: the engine's setup screen until it's running, then the workspace. |
| `Session/AttachmentViews.swift` | 342 | Something attached to a message: kept by the engine, still on its way (a local file), |
| `Session/AttentionCards.swift` | 582 | The agent wants to do something that needs your OK. |
| `Session/ChangesPanel.swift` | 1173 | What's changed in the project, Codex-style: uncommitted (or unstaged, or staged) |
| `Session/Composer.swift` | 701 | Where you talk to the agent: a floating glass panel with the message field, |
| `Session/ComposerMenus.swift` | 272 | How much the agent may do without asking, for a session. |
| `Session/ContextGauge.swift` | 188 | How full the model's context window is, as a small ring with its number. Clicking it says |
| `Session/ConversationScroll.swift` | 297 | How a conversation scrolls, for the view showing it: whether it keeps to the end, and asking |
| `Session/DiffView.swift` | 80 | A short diff in a recessed well, for a tool call or a permission request: the same lines, |
| `Session/FileLinks.swift` | 161 | File names a reply writes as code (\`src/App.swift\`, \`App.swift:42\`) become links that open |
| `Session/FindBar.swift` | 370 | Find in one conversation: what you look for, every place it is, and the one you're on. |
| `Session/LongText.swift` | 129 | Plain text that can run long and grows while you read it, like the model's thinking. AppKit's |
| `Session/MarkdownChunks.swift` | 207 | A long reply in pieces of a few thousand characters, split between paragraphs, each drawn on its |
| `Session/MathText.swift` | 795 | LaTeX in a reply, drawn as math: \`$…$\` and \`\(…\)\` in a line, \`$$…$$\` and \`\[…\]\` on their own. |
| `Session/ModelPicker.swift` | 500 | Effort levels as people say them: "xhigh" is Extra. |
| `Session/QueueDock.swift` | 167 | Messages waiting for the agent, in a card tucked behind the composer's top edge: those for its |
| `Session/QuoteList.swift` | 89 | The quotes you're answering, each with your answer under it: as tall as they are up to a |
| `Session/SelectionMenu.swift` | 120 | Over what you select in the conversation: Add to Chat (it goes over the composer as a quote |
| `Session/SessionView.swift` | 384 | Something that didn't work (a message that didn't go, an undo), over the composer until you |
| `Session/ShellRow.swift` | 103 | A command you ran with "!": a line like the agent's own steps, saying it was you, with what it |
| `Session/StepsRow.swift` | 176 | How much of the agent's work shows between its replies: each step, the steps summed up in a |
| `Session/ToolCallView.swift` | 498 | One tool call: a single line saying what the agent did, which opens to show |
| `Session/TranscriptView.swift` | 1559 | The conversation. Sticks to the bottom while the agent writes, unless you |
| `Session/WidgetView.swift` | 491 | What an agent made for you with show_widget: a page of its own (a chart, a diagram, a small |
| `Session/YourMessage.swift` | 94 | A message you sent, in a session or a group chat: its bubble, and under the pointer when it |
| `Settings/AgentsSettings.swift` | 285 | The agents: the defaults new sessions start with, the built-in agents (Build, Plan and the |
| `Settings/AppearanceSettings.swift` | 296 | Appearance: light or dark, the accent color, the window, and how messages read, with a |
| `Settings/ArchivedSessionsSettings.swift` | 79 | Archived sessions: out of the sidebar, still searchable; brought back or deleted here. |
| `Settings/BrowserSettings.swift` | 136 | The side panel: what it starts with, and the new tab page. |
| `Settings/CommandsSettings.swift` | 236 | Slash commands: prompts you use often, run by typing "/" and their name in the composer. |
| `Settings/EngineSettings.swift` | 217 | The engine: how it's doing, and how it works: summaries, formatting, the shell, web search, |
| `Settings/GeneralSettings.swift` | 256 | General: the window, where files open, and updates. |
| `Settings/GitSettings.swift` | 141 | Git: how sessions' branches are named, and how commit messages and pull requests are written. |
| `Settings/IntegrationsSettings.swift` | 465 | Integrations: your mail and calendar, chats, socials, code and work tools, for the agent and |
| `Settings/MCPSettings.swift` | 480 | MCP servers: programs on this Mac or services on the web that give the agent more tools. |
| `Settings/MachinesSettings.swift` | 81 | Machines: Linux servers whose engine Kuvo Code runs over SSH, for projects on them. Each can |
| `Settings/PasswordsSettings.swift` | 151 | Passwords: the sign-ins the panel's browser saved, and the sites it doesn't offer to save for. |
| `Settings/PermissionsSettings.swift` | 289 | What the agent may do without asking: a choice for each kind of action, rules for |
| `Settings/PhoneSettings.swift` | 137 | Phone: pairing Kuvo Code for iPhone with this Mac (a QR code to scan), the phones you've |
| `Settings/SettingsControls.swift` | 469 | A text setting, saved when you press Return or leave the field. |
| `Settings/SettingsDetail.swift` | 248 | Where a Settings tab is: on its page, or on something of the page opened in its place (an |
| `Settings/ShortcutsSettings.swift` | 104 | Every keyboard shortcut, by where it's used, with a search field. |
| `Settings/SiteSignInPage.swift` | 185 | Signing in to a service the agent uses on its site (X, Discord…), in a tab of Settings: the |
| `Settings/SkillsSettings.swift` | 550 | Skills: instructions and scripts the agent loads when a task calls for them. The ones it |
| `Settings/StorageSettings.swift` | 350 | Storage: what Kuvo Code keeps on this Mac, by kind, as a bar, and the room you can get back. |
| `SettingsView.swift` | 464 | Settings, in the main window in place of the sessions: a sidebar of pages in groups, with a |
| `Shared/FormFieldsView.swift` | 194 | Renders the engine's form schema natively. The same schema drives the agent's |
| `SidebarView.swift` | 1278 | New Session on top, then projects (each a folder that opens to its sessions), then |
| `TitleBar.swift` | 647 | The tab bar in the title bar can be hidden (View › Hide Tab Bar, or Settings › General). |
| `Utilities/AgentBadge.swift` | 43 | Over a page an agent is browsing: who it is, and Take Over, to have the page to yourself while |
| `Utilities/BrowserChrome.swift` | 252 | Back, forward, and reload (stop while it loads). |
| `Utilities/BrowserSession.swift` | 734 | A browser tab: a web view and what the toolbar shows about it. |
| `Utilities/CodeTextView.swift` | 177 | Code in a read-only text view: selectable across lines, numbered in a ruler, colored |
| `Utilities/FilesView.swift` | 616 | A file tab: the file on the left (rendered, highlighted or previewed), the project's |
| `Utilities/MachineBrowserPane.swift` | 803 | A page of a machine's browser, in its tab: the page live, with back, forward, reload and the |
| `Utilities/NewTabPage.swift` | 180 | What a new tab shows until you go somewhere: the panel's tools (and a way into their |
| `Utilities/OpenQuickly.swift` | 94 | Open Quickly (⇧⌘O): type part of a file's name to find it in any of the project's folders, |
| `Utilities/TerminalSession.swift` | 188 | A shell in the project folder (SwiftTerm, MIT): the login shell with the same |
| `Utilities/UtilitiesPane.swift` | 318 | The right panel: a card whose header is a strip of tabs (Changes, files, terminals, |

## 3. SF Symbols (89 unique, 238 uses)

| Symbol | Uses | Files |
| --- | ---: | --- |
| `xmark` | 18 | KuvoCode/Design/QuoteViews.swift<br>KuvoCode/Views/ImageViewer.swift<br>KuvoCode/Views/MainView.swift<br>KuvoCode/Views/Session/AttentionCards.swift<br>KuvoCode/Views/Session/FindBar.swift<br>KuvoCode/Views/Session/SessionView.swift<br>KuvoCode/Views/TitleBar.swift<br>KuvoCode/Views/Utilities/BrowserChrome.swift<br>KuvoCode/Views/Utilities/UtilitiesPane.swift |
| `chevron.right` | 13 | KuvoCode/Views/GroupChatView.swift<br>KuvoCode/Views/Providers/ProvidersView.swift<br>KuvoCode/Views/Session/AttentionCards.swift<br>KuvoCode/Views/Session/ChangesPanel.swift<br>KuvoCode/Views/Session/ModelPicker.swift<br>KuvoCode/Views/Session/ShellRow.swift<br>KuvoCode/Views/Session/StepsRow.swift<br>KuvoCode/Views/Session/ToolCallView.swift<br>KuvoCode/Views/Session/TranscriptView.swift<br>KuvoCode/Views/Settings/SkillsSettings.swift<br>KuvoCode/Views/Utilities/FilesView.swift |
| `plus` | 10 | KuvoCode/Views/BotEditor.swift<br>KuvoCode/Views/ProjectEditor.swift<br>KuvoCode/Views/Session/ChangesPanel.swift<br>KuvoCode/Views/Settings/AppearanceSettings.swift<br>KuvoCode/Views/SidebarView.swift<br>KuvoCode/Views/Utilities/UtilitiesPane.swift |
| `magnifyingglass` | 9 | KuvoCode/Views/CommandPalette.swift<br>KuvoCode/Views/Providers/ProvidersView.swift<br>KuvoCode/Views/Session/FindBar.swift<br>KuvoCode/Views/Session/ModelPicker.swift<br>KuvoCode/Views/Settings/SettingsControls.swift<br>KuvoCode/Views/SidebarView.swift<br>KuvoCode/Views/Utilities/FilesView.swift<br>KuvoCode/Views/Utilities/OpenQuickly.swift |
| `minus.circle.fill` | 9 | KuvoCode/Views/BotEditor.swift<br>KuvoCode/Views/ProjectEditor.swift<br>KuvoCode/Views/Providers/CustomProviders.swift<br>KuvoCode/Views/Settings/PermissionsSettings.swift<br>KuvoCode/Views/Settings/SettingsControls.swift |
| `checkmark` | 7 | KuvoCode/Design/CodeBlockStyle.swift<br>KuvoCode/Views/ProjectEditor.swift<br>KuvoCode/Views/Session/AttentionCards.swift<br>KuvoCode/Views/Session/ModelPicker.swift<br>KuvoCode/Views/Settings/AgentsSettings.swift<br>KuvoCode/Views/Settings/CommandsSettings.swift<br>KuvoCode/Views/Settings/MCPSettings.swift |
| `folder` | 7 | KuvoCode/Views/ImageViewer.swift<br>KuvoCode/Views/MainView.swift<br>KuvoCode/Views/ProjectEditor.swift<br>KuvoCode/Views/Session/ChangesPanel.swift<br>KuvoCode/Views/Settings/ArchivedSessionsSettings.swift<br>KuvoCode/Views/Settings/GitSettings.swift |
| `arrow.triangle.branch` | 6 | KuvoCode/Views/ProjectEditor.swift<br>KuvoCode/Views/Session/ChangesPanel.swift<br>KuvoCode/Views/Session/SessionView.swift<br>KuvoCode/Views/SidebarView.swift<br>KuvoCode/Views/TitleBar.swift |
| `server.rack` | 6 | KuvoCode/Design/BotAvatar.swift<br>KuvoCode/Views/MachineForm.swift<br>KuvoCode/Views/MachineStatusViews.swift<br>KuvoCode/Views/MainView.swift<br>KuvoCode/Views/Settings/MachinesSettings.swift<br>KuvoCode/Views/SidebarView.swift |
| `xmark.circle.fill` | 6 | KuvoCode/Views/Providers/ProvidersView.swift<br>KuvoCode/Views/Session/AttachmentViews.swift<br>KuvoCode/Views/Session/ToolCallView.swift<br>KuvoCode/Views/Settings/SettingsControls.swift<br>KuvoCode/Views/SidebarView.swift<br>KuvoCode/Views/Utilities/FilesView.swift |
| `chevron.down` | 5 | KuvoCode/Design/Pressable.swift<br>KuvoCode/Views/Session/ComposerMenus.swift<br>KuvoCode/Views/SidebarView.swift<br>KuvoCode/Views/TitleBar.swift<br>KuvoCode/Views/Utilities/FilesView.swift |
| `ellipsis` | 5 | KuvoCode/Views/Session/ChangesPanel.swift<br>KuvoCode/Views/Session/DiffView.swift<br>KuvoCode/Views/Session/QueueDock.swift<br>KuvoCode/Views/Settings/IntegrationsSettings.swift<br>KuvoCode/Views/Utilities/BrowserChrome.swift |
| `checkmark.circle.fill` | 4 | KuvoCode/Views/GroupChatView.swift<br>KuvoCode/Views/Providers/ConnectView.swift<br>KuvoCode/Views/Providers/CustomProviders.swift<br>KuvoCode/Views/Providers/ProvidersView.swift |
| `exclamationmark.triangle.fill` | 4 | KuvoCode/Views/Session/SessionView.swift<br>KuvoCode/Views/Session/TranscriptView.swift<br>KuvoCode/Views/Settings/EngineSettings.swift<br>KuvoCode/Views/Settings/SettingsControls.swift |
| `hand.raised.fill` | 4 | KuvoCode/Views/GroupChatView.swift<br>KuvoCode/Views/Session/ComposerMenus.swift<br>KuvoCode/Views/SidebarView.swift<br>KuvoCode/Views/Utilities/AgentBadge.swift |
| `pause.circle` | 4 | KuvoCode/Views/BotEditor.swift<br>KuvoCode/Views/GroupChatView.swift<br>KuvoCode/Views/Session/QueueDock.swift<br>KuvoCode/Views/SidebarView.swift |
| `play.fill` | 4 | KuvoCode/Views/GroupChatView.swift<br>KuvoCode/Views/MainView.swift<br>KuvoCode/Views/ProjectEditor.swift<br>KuvoCode/Views/Session/QueueDock.swift |
| `square.and.pencil` | 4 | KuvoCode/Views/MainView.swift<br>KuvoCode/Views/SidebarView.swift |
| `trash` | 4 | KuvoCode/Views/BotEditor.swift<br>KuvoCode/Views/Session/QueueDock.swift<br>KuvoCode/Views/Settings/ArchivedSessionsSettings.swift<br>KuvoCode/Views/Settings/PasswordsSettings.swift |
| `alarm` | 3 | KuvoCode/Views/BotEditor.swift<br>KuvoCode/Views/Session/TranscriptView.swift<br>KuvoCode/Views/SidebarView.swift |
| `brain` | 3 | KuvoCode/Views/BotEditor.swift<br>KuvoCode/Views/Session/TranscriptView.swift |
| `bubble.left` | 3 | KuvoCode/Views/MainView.swift |
| `chevron.backward` | 3 | KuvoCode/Views/Settings/SettingsDetail.swift<br>KuvoCode/Views/SettingsView.swift |
| `clock` | 3 | KuvoCode/Views/BotEditor.swift<br>KuvoCode/Views/GroupChatView.swift<br>KuvoCode/Views/GroupEditor.swift |
| `plus.circle` | 3 | KuvoCode/Views/GroupEditor.swift<br>KuvoCode/Views/SidebarView.swift |
| `arrow.clockwise` | 2 | KuvoCode/Views/Session/TranscriptView.swift |
| `arrow.down` | 2 | KuvoCode/Views/Session/ConversationScroll.swift<br>KuvoCode/Views/Session/FindBar.swift |
| `arrow.right` | 2 | KuvoCode/Views/Session/AttentionCards.swift<br>KuvoCode/Views/Utilities/BrowserChrome.swift |
| `arrow.turn.down.right` | 2 | KuvoCode/Views/MachineForm.swift |
| `arrow.up` | 2 | KuvoCode/Views/Session/Composer.swift<br>KuvoCode/Views/Session/FindBar.swift |
| `arrow.up.forward.app` | 2 | KuvoCode/Views/ImageViewer.swift<br>KuvoCode/Views/Utilities/BrowserSession.swift |
| `arrow.up.forward.square` | 2 | KuvoCode/Views/Session/ChangesPanel.swift |
| `bolt.horizontal.circle` | 2 | KuvoCode/Views/MachineStatusViews.swift<br>KuvoCode/Views/MainView.swift |
| `calendar` | 2 | KuvoCode/Views/GroupChatView.swift<br>KuvoCode/Views/GroupEditor.swift |
| `camera.viewfinder` | 2 | KuvoCode/Views/Utilities/BrowserSession.swift<br>KuvoCode/Views/Utilities/MachineBrowserPane.swift |
| `chevron.left` | 2 | KuvoCode/Views/Session/AttentionCards.swift<br>KuvoCode/Views/Session/ModelPicker.swift |
| `doc` | 2 | KuvoCode/Views/Session/FileLinks.swift<br>KuvoCode/Views/Utilities/FilesView.swift |
| `doc.on.doc` | 2 | KuvoCode/Views/Session/SelectionMenu.swift<br>KuvoCode/Views/Settings/PasswordsSettings.swift |
| `exclamationmark.circle.fill` | 2 | KuvoCode/Views/RootView.swift<br>KuvoCode/Views/SidebarView.swift |
| `exclamationmark.triangle` | 2 | KuvoCode/Views/Settings/SkillsSettings.swift<br>KuvoCode/Views/Utilities/MachineBrowserPane.swift |
| `eye` | 2 | KuvoCode/Views/BotEditor.swift<br>KuvoCode/Views/SidebarView.swift |
| `face.smiling` | 2 | KuvoCode/Views/BotEditor.swift<br>KuvoCode/Views/MainView.swift |
| `key.fill` | 2 | KuvoCode/Views/Utilities/BrowserSession.swift |
| `person.2` | 2 | KuvoCode/Views/GroupEditor.swift<br>KuvoCode/Views/MainView.swift |
| `person.crop.circle.badge.plus` | 2 | KuvoCode/Views/MainView.swift<br>KuvoCode/Views/SidebarView.swift |
| `person.crop.circle.badge.questionmark` | 2 | KuvoCode/Views/GroupChatView.swift |
| `sidebar.right` | 2 | KuvoCode/Views/TitleBar.swift<br>KuvoCode/Views/Utilities/FilesView.swift |
| `slider.horizontal.3` | 2 | KuvoCode/Views/MainView.swift |
| `sparkles.rectangle.stack` | 2 | KuvoCode/Views/Session/WidgetView.swift |
| `stop.circle` | 2 | KuvoCode/Views/Session/ToolCallView.swift<br>KuvoCode/Views/Session/TranscriptView.swift |
| `terminal` | 2 | KuvoCode/Views/Session/Composer.swift<br>KuvoCode/Views/Session/ShellRow.swift |
| `text.bubble` | 2 | KuvoCode/Views/Session/ChangesPanel.swift<br>KuvoCode/Views/Session/Composer.swift |
| `arrow.counterclockwise` | 1 | KuvoCode/Views/Session/ModelPicker.swift |
| `arrow.left` | 1 | KuvoCode/Views/Utilities/BrowserChrome.swift |
| `arrow.left.arrow.right` | 1 | KuvoCode/Views/MainView.swift |
| `arrow.triangle.merge` | 1 | KuvoCode/Views/Session/ChangesPanel.swift |
| `arrow.up.right` | 1 | KuvoCode/Views/Session/ContextGauge.swift |
| `arrow.uturn.backward` | 1 | KuvoCode/Views/Session/TranscriptView.swift |
| `bubble.left.and.bubble.right` | 1 | KuvoCode/Views/GroupEditor.swift |
| `bubble.left.and.text.bubble.right` | 1 | KuvoCode/Views/Session/TranscriptView.swift |
| `checklist` | 1 | KuvoCode/Views/GroupChatView.swift |
| `checkmark.circle` | 1 | KuvoCode/Views/GroupChatView.swift |
| `cpu` | 1 | KuvoCode/Views/BotEditor.swift |
| `doc.text.magnifyingglass` | 1 | KuvoCode/Views/Session/ChangesPanel.swift |
| `exclamationmark.circle` | 1 | KuvoCode/Views/GroupChatView.swift |
| `folder.badge.plus` | 1 | KuvoCode/Views/MainView.swift |
| `hammer` | 1 | KuvoCode/Views/Session/TranscriptView.swift |
| `info.circle` | 1 | KuvoCode/Views/GroupChatView.swift |
| `iphone` | 1 | KuvoCode/Views/Settings/PhoneSettings.swift |
| `key` | 1 | KuvoCode/Views/BrowserAskCard.swift |
| `list.bullet` | 1 | KuvoCode/Views/Session/StepsRow.swift |
| `paperclip` | 1 | KuvoCode/Views/Session/Composer.swift |
| `paperplane` | 1 | KuvoCode/Views/Session/TranscriptView.swift |
| `paperplane.fill` | 1 | KuvoCode/Views/Session/TranscriptView.swift |
| `pencil` | 1 | KuvoCode/Views/Session/AttentionCards.swift |
| `person.3` | 1 | KuvoCode/Views/Session/TranscriptView.swift |
| `person.crop.circle` | 1 | KuvoCode/Views/BotEditor.swift |
| `plus.forwardslash.minus` | 1 | KuvoCode/Views/Session/TranscriptView.swift |
| `questionmark.bubble` | 1 | KuvoCode/Views/Session/AttentionCards.swift |
| `questionmark.bubble.fill` | 1 | KuvoCode/Views/Session/AttentionCards.swift |
| `shuffle` | 1 | KuvoCode/Views/BotEditor.swift |
| `sidebar.left` | 1 | KuvoCode/Views/TitleBar.swift |
| `sparkles` | 1 | KuvoCode/Views/Session/ChangesPanel.swift |
| `square.and.arrow.up` | 1 | KuvoCode/Views/BotEditor.swift |
| `star` | 1 | KuvoCode/Views/GroupEditor.swift |
| `stop.fill` | 1 | KuvoCode/Views/Session/Composer.swift |
| `target` | 1 | KuvoCode/Views/GroupEditor.swift |
| `text.badge.checkmark` | 1 | KuvoCode/Views/Session/ChangesPanel.swift |
| `text.quote` | 1 | KuvoCode/Views/Session/SelectionMenu.swift |

## 4. Motion call sites (261)

Every line that starts an animation, a transition, or a matched-geometry effect. The
values they use, and the CSS equivalents, are catalogued in `docs/MAC-UI-MAP.md` §4.

- `KuvoCode/Design/AgentPointer.swift:186` — `withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.32)) {`
- `KuvoCode/Design/AgentPointer.swift:191` — `withAnimation(.easeOut(duration: step.action == .click ? 0.5 : 1.2)) { pulse = true }`
- `KuvoCode/Design/AgentPointer.swift:193` — `withAnimation(.easeOut(duration: 0.35)) { visible = false }`
- `KuvoCode/Design/Card.swift:47` — `.animation(.ui, value: isFocused)`
- `KuvoCode/Design/CodeBlockStyle.swift:172` — `withAnimation(.ui) { copied = true }`
- `KuvoCode/Design/CodeBlockStyle.swift:175` — `withAnimation(.ui) { copied = false }`
- `KuvoCode/Design/CodeBlockStyle.swift:183` — `.contentTransition(.symbolEffect(.replace))`
- `KuvoCode/Design/CodeBlockStyle.swift:205` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Design/HoverHighlight.swift:20` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Design/PillPicker.swift:22` — `withAnimation(.ui) { selection = option.value }`
- `KuvoCode/Design/PillPicker.swift:43` — `.matchedGeometryEffect(id: "pill", in: pill)`
- `KuvoCode/Design/Pressable.swift:63` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Design/Pressable.swift:187` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Design/Pressable.swift:217` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Design/QuoteViews.swift:58` — `Button(isExpanded ? "Show Less" : "Show All") { withAnimation(.ui) { isExpanded.toggle() } }`
- `KuvoCode/Design/Theme.swift:27` — `return .spring(response: 0.32 * slow, dampingFraction: 0.86)`
- `KuvoCode/Design/Theme.swift:30` — `return .spring(response: 0.32, dampingFraction: 0.86)`
- `KuvoCode/Design/WindowGlass.swift:69` — `.onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering } }`
- `KuvoCode/Stores/BrowserAsks.swift:128` — `withAnimation(.ui) { asks.removeAll { $0.id == id } }`
- `KuvoCode/Stores/BrowserAsks.swift:160` — `withAnimation(.ui) { asks.append(ask) }`
- `KuvoCode/Stores/BrowserAsks.swift:174` — `withAnimation(.ui) { asks.removeAll { $0.id == id } }`
- `KuvoCode/Stores/BrowserAsks.swift:182` — `withAnimation(.ui) { asks.removeAll { $0.id == id } }`
- `KuvoCode/Views/AnalyticsNotice.swift:21` — `withAnimation(.ui) {`
- `KuvoCode/Views/AnalyticsNotice.swift:27` — `withAnimation(.ui) { analytics.noticeShown = true }`
- `KuvoCode/Views/BotEditor.swift:78` — `EditorDetail(back: isNew ? "New Bot" : "Edit \(trimmedName)", title: "Add a Machine", onBack: { withAnimation(.ui) { showsAddMachine = false } }) {`
- `KuvoCode/Views/BotEditor.swift:80` — `withAnimation(.ui) {`
- `KuvoCode/Views/BotEditor.swift:85` — `}, cancel: { withAnimation(.ui) { showsAddMachine = false } })`
- `KuvoCode/Views/BotEditor.swift:87` — `.transition(.opacity)`
- `KuvoCode/Views/BotEditor.swift:324` — `.keyframeAnimator(initialValue: 1.0, trigger: look) { content, scale in`
- `KuvoCode/Views/BotEditor.swift:332` — `withAnimation(.ui) { look = .random() }`
- `KuvoCode/Views/BotEditor.swift:477` — `withAnimation(.ui) {`
- `KuvoCode/Views/BotEditor.swift:545` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Views/BotEditor.swift:563` — `withAnimation(.ui) { look.color = tint }`
- `KuvoCode/Views/BotEditor.swift:624` — `withAnimation(.ui) { action() }`
- `KuvoCode/Views/BotEditor.swift:634` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Views/BotEditor.swift:701` — `.animation(.ui, value: selection)`
- `KuvoCode/Views/BotEditor.swift:705` — `.animation(.ui, value: draft == nil)`
- `KuvoCode/Views/BotEditor.swift:736` — `.transition(.opacity.combined(with: .offset(y: -6)))`
- `KuvoCode/Views/BotEditor.swift:781` — `withAnimation(.ui) { action() }`
- `KuvoCode/Views/BotEditor.swift:801` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Views/BotEditor.swift:847` — `.animation(.ui, value: draft == nil)`
- `KuvoCode/Views/BotEditor.swift:1041` — `.transition(.opacity.combined(with: .offset(y: -6)))`
- `KuvoCode/Views/BrowserAskCard.swift:23` — `.transition(.move(edge: .top).combined(with: .opacity))`
- `KuvoCode/Views/GroupChatView.swift:37` — `.transition(.opacity.combined(with: .offset(y: 8)))`
- `KuvoCode/Views/GroupChatView.swift:42` — `.transition(.opacity)`
- `KuvoCode/Views/GroupChatView.swift:60` — `.transition(.opacity.combined(with: .offset(y: 6)))`
- `KuvoCode/Views/GroupChatView.swift:74` — `.animation(.ui, value: groups.paused.contains(group.id))`
- `KuvoCode/Views/GroupChatView.swift:246` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Views/GroupEditor.swift:131` — `.contentTransition(.numericText())`
- `KuvoCode/Views/GroupEditor.swift:134` — `.animation(.ui, value: members)`
- `KuvoCode/Views/GroupEditor.swift:167` — `withAnimation(.ui) {`
- `KuvoCode/Views/GroupEditor.swift:208` — `Toggle(isOn: $meets.animation(.ui)) {`
- `KuvoCode/Views/GroupEditor.swift:237` — `withAnimation(.ui) {`
- `KuvoCode/Views/GroupEditor.swift:345` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Views/ImageViewer.swift:22` — `withAnimation(.easeOut(duration: 0.16)) {`
- `KuvoCode/Views/ImageViewer.swift:28` — `withAnimation(.easeOut(duration: 0.14)) { request = nil }`
- `KuvoCode/Views/ImageViewer.swift:40` — `.animation(.easeOut(duration: 0.15), value: isOpen)`
- `KuvoCode/Views/ImageViewer.swift:50` — `.transition(.opacity)`
- `KuvoCode/Views/ImageViewer.swift:102` — `if scale <= 1 { withAnimation(.ui) { offset = .zero } }`
- `KuvoCode/Views/ImageViewer.swift:117` — `withAnimation(.ui) {`
- `KuvoCode/Views/ImageViewer.swift:163` — `withAnimation(.snappy(duration: 0.22)) { appeared = true }`
- `KuvoCode/Views/ImageViewer.swift:184` — `.contentTransition(.symbolEffect(.replace))`
- `KuvoCode/Views/ImageViewer.swift:233` — `withAnimation(.ui) { copied = true }`
- `KuvoCode/Views/ImageViewer.swift:236` — `withAnimation(.ui) { copied = false }`
- `KuvoCode/Views/MainView.swift:186` — `.transition(.move(edge: .leading).combined(with: .opacity))`
- `KuvoCode/Views/MainView.swift:230` — `.transition(.move(edge: .trailing).combined(with: .opacity))`
- `KuvoCode/Views/MainView.swift:250` — `.transition(.move(edge: .trailing).combined(with: .opacity))`
- `KuvoCode/Views/MainView.swift:267` — `.transition(.opacity)`
- `KuvoCode/Views/MainView.swift:288` — `.animation(.ui, value: showsSidebar)`
- `KuvoCode/Views/MainView.swift:289` — `.animation(.ui, value: showsPanel)`
- `KuvoCode/Views/MainView.swift:290` — `.animation(.ui, value: panelExpanded)`
- `KuvoCode/Views/MainView.swift:291` — `.animation(.ui, value: app.showsSettings)`
- `KuvoCode/Views/MainView.swift:305` — `.onChange(of: utilities.revealRequest) { withAnimation(.ui) { showPanel() } }`
- `KuvoCode/Views/MainView.swift:329` — `.transition(.move(edge: .top).combined(with: .opacity))`
- `KuvoCode/Views/MainView.swift:332` — `.animation(.ui, value: catalog.isSlow)`
- `KuvoCode/Views/MainView.swift:348` — `.transition(.opacity)`
- `KuvoCode/Views/MainView.swift:351` — `.animation(.ui, value: showsOpenQuickly)`
- `KuvoCode/Views/MainView.swift:367` — `.transition(.opacity)`
- `KuvoCode/Views/MainView.swift:370` — `.animation(.ui, value: showsPalette)`
- `KuvoCode/Views/MainView.swift:668` — `withAnimation(.ui) {`
- `KuvoCode/Views/MainView.swift:683` — `withAnimation(.ui) {`
- `KuvoCode/Views/MainView.swift:694` — `withAnimation(.ui) { splitPairs[tab] = nil }`
- `KuvoCode/Views/MainView.swift:722` — `Button("Close", systemImage: "xmark") { withAnimation(.ui) { groupEditor = nil } }`
- `KuvoCode/Views/MainView.swift:726` — `withAnimation(.ui) { groupEditor = nil }`
- `KuvoCode/Views/MainView.swift:736` — `Button("Close", systemImage: "xmark") { withAnimation(.ui) { projectEditor = nil } }`
- `KuvoCode/Views/MainView.swift:743` — `withAnimation(.ui) { projectEditor = nil }`
- `KuvoCode/Views/MainView.swift:751` — `Button("Close", systemImage: "xmark") { withAnimation(.ui) { botEditor = nil } }`
- `KuvoCode/Views/MainView.swift:755` — `withAnimation(.ui) { botEditor = nil }`
- `KuvoCode/Views/MainView.swift:937` — `withAnimation(.ui) {`
- `KuvoCode/Views/MainView.swift:946` — `withAnimation(.ui) {`
- `KuvoCode/Views/MainView.swift:958` — `withAnimation(.ui) {`
- `KuvoCode/Views/MainView.swift:970` — `withAnimation(.ui) {`
- `KuvoCode/Views/MainView.swift:1004` — `withAnimation(.ui) { app.settingsTabs.select(id) }`
- `KuvoCode/Views/MainView.swift:1021` — `withAnimation(.ui) { app.settingsTabs.close(id, machines: app.machines) }`
- `KuvoCode/Views/MainView.swift:1023` — `withAnimation(.ui) { app.settingsTabs.closeOthers(than: except, machines: app.machines) }`
- `KuvoCode/Views/MainView.swift:1033` — `.animation(.ui, value: app.settingsTabs.tabs.map(\.id))`
- `KuvoCode/Views/MainView.swift:1038` — `withAnimation(.ui) { app.showsSettings = false }`
- `KuvoCode/Views/MainView.swift:1053` — `withAnimation(.ui) {`
- `KuvoCode/Views/MainView.swift:1075` — `withAnimation(.ui) {`
- `KuvoCode/Views/MainView.swift:1092` — `withAnimation(.ui) {`
- `KuvoCode/Views/MainView.swift:1131` — `withAnimation(.ui) {`
- `KuvoCode/Views/MainView.swift:1176` — `if app.showsSettings { withAnimation(.ui) { app.settingsTabs.cycle(by: offset) } } else { cycleTabs(by: offset) }`
- `KuvoCode/Views/MainView.swift:1184` — `withAnimation(.ui) { app.settingsTabs.close(app.settingsTabs.selectedID, machines: app.machines) }`
- `KuvoCode/Views/MainView.swift:1199` — `withAnimation(.ui) { selection = tabs[(index + offset + tabs.count) % tabs.count] }`
- `KuvoCode/Views/MainView.swift:1248` — `togglePanel: { withAnimation(.ui) { showPanel(!panelOnScreen) } },`
- `KuvoCode/Views/MainView.swift:1254` — `toggleSidebar: { withAnimation(.ui) { showSidebar(!sidebarOnScreen) } },`
- `KuvoCode/Views/MainView.swift:1264` — `withAnimation(.ui) { app.settingsTabs.show(number: number) }`
- `KuvoCode/Views/MainView.swift:1496` — `withAnimation(.ui) { panelExpanded.toggle() }`
- `KuvoCode/Views/MainView.swift:1598` — `withAnimation(.ui) { showsPanel.toggle() }`
- `KuvoCode/Views/ProjectEditor.swift:59` — `EditorDetail(back: isNew ? "New Project" : "Edit Project", title: "Add a Machine", onBack: { withAnimation(.ui) { showsAddMachine = false } }) {`
- `KuvoCode/Views/ProjectEditor.swift:61` — `withAnimation(.ui) {`
- `KuvoCode/Views/ProjectEditor.swift:65` — `}, cancel: { withAnimation(.ui) { showsAddMachine = false } })`
- `KuvoCode/Views/ProjectEditor.swift:67` — `.transition(.opacity)`
- `KuvoCode/Views/ProjectEditor.swift:242` — `withAnimation(.ui) {`
- `KuvoCode/Views/ProjectEditor.swift:262` — `makePrimary: { withAnimation(.ui) { folders.removeAll { $0 == folder }; folders.insert(folder, at: 0) } },`
- `KuvoCode/Views/ProjectEditor.swift:263` — `remove: { withAnimation(.ui) { folders.removeAll { $0 == folder } } }`
- `KuvoCode/Views/ProjectEditor.swift:317` — `withAnimation(.ui) {`
- `KuvoCode/Views/ProjectEditor.swift:333` — `withAnimation(.ui) {`
- `KuvoCode/Views/ProjectEditor.swift:398` — `.animation(.easeOut(duration: 0.15), value: isActive)`
- `KuvoCode/Views/ProjectEditor.swift:454` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Views/ProjectEditor.swift:481` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Views/Providers/ConnectView.swift:82` — `.transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))`
- `KuvoCode/Views/Providers/ConnectView.swift:86` — `.animation(.ui, value: step)`
- `KuvoCode/Views/Providers/ConnectView.swift:116` — `.transition(.scale(scale: 0.4).combined(with: .opacity))`
- `KuvoCode/Views/Providers/ConnectView.swift:119` — `.animation(.spring(response: 0.4, dampingFraction: 0.6), value: step == .connected)`
- `KuvoCode/Views/Providers/ConnectView.swift:122` — `.contentTransition(.opacity)`
- `KuvoCode/Views/Providers/ConnectView.swift:197` — `.transition(.opacity)`
- `KuvoCode/Views/Providers/ConnectView.swift:210` — `.animation(.ui, value: keyError)`
- `KuvoCode/Views/Providers/ConnectView.swift:228` — `.contentTransition(.symbolEffect(.replace))`
- `KuvoCode/Views/Providers/ConnectView.swift:519` — `withAnimation(.ui) { copied = true }`
- `KuvoCode/Views/Providers/ConnectView.swift:524` — `withAnimation(.ui) { copied = false }`
- `KuvoCode/Views/Providers/ProvidersView.swift:24` — `withAnimation(.ui) { connecting = nil }`
- `KuvoCode/Views/Providers/ProvidersView.swift:207` — `.onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering } }`
- `KuvoCode/Views/RootView.swift:15` — `.transition(.opacity)`
- `KuvoCode/Views/RootView.swift:19` — `SettingsView { withAnimation(.ui) { app.showsSettings = false } }`
- `KuvoCode/Views/RootView.swift:24` — `SettingsBackButton { withAnimation(.ui) { app.showsSettings = false } }`
- `KuvoCode/Views/RootView.swift:30` — `.transition(.opacity)`
- `KuvoCode/Views/RootView.swift:33` — `.transition(.opacity.combined(with: .scale(0.98)))`
- `KuvoCode/Views/RootView.swift:37` — `.animation(.ui, value: app.engine == .ready)`
- `KuvoCode/Views/RootView.swift:38` — `.animation(.ui, value: app.showsSettings)`
- `KuvoCode/Views/RootView.swift:72` — `.transition(.scale.combined(with: .opacity))`
- `KuvoCode/Views/RootView.swift:75` — `.animation(.ui, value: isFailed)`
- `KuvoCode/Views/Session/AttachmentViews.swift:285` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Views/Session/AttachmentViews.swift:328` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Views/Session/AttentionCards.swift:192` — `.animation(.ui, value: index)`
- `KuvoCode/Views/Session/AttentionCards.swift:458` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Views/Session/ChangesPanel.swift:180` — `withAnimation(.ui) {`
- `KuvoCode/Views/Session/ChangesPanel.swift:240` — `withAnimation(.ui) {`
- `KuvoCode/Views/Session/ChangesPanel.swift:599` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Views/Session/ChangesPanel.swift:715` — `withAnimation(.ui) { _ = expandedFolds.insert(row.id) }`
- `KuvoCode/Views/Session/Composer.swift:221` — `.transition(.opacity)`
- `KuvoCode/Views/Session/Composer.swift:241` — `.transition(.opacity)`
- `KuvoCode/Views/Session/Composer.swift:246` — `.animation(.easeOut(duration: 0.15), value: isShell)`
- `KuvoCode/Views/Session/Composer.swift:472` — `.animation(.ui, value: stops && !canSend)`
- `KuvoCode/Views/Session/Composer.swift:473` — `.animation(.easeOut(duration: 0.15), value: canSend)`
- `KuvoCode/Views/Session/Composer.swift:537` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Views/Session/ContextGauge.swift:36` — `.animation(.ui, value: fraction)`
- `KuvoCode/Views/Session/ConversationScroll.swift:108` — `.animation(animation, value: change)`
- `KuvoCode/Views/Session/ConversationScroll.swift:185` — `.transition(.opacity.combined(with: .scale(scale: 0.8)))`
- `KuvoCode/Views/Session/ConversationScroll.swift:188` — `.animation(.ui, value: scroller.followsEnd)`
- `KuvoCode/Views/Session/ConversationScroll.swift:193` — `withAnimation(.ui) { position.scrollTo(edge: .bottom) }`
- `KuvoCode/Views/Session/ConversationScroll.swift:198` — `withAnimation(.ui) { position.scrollTo(id: id, anchor: .center) }`
- `KuvoCode/Views/Session/FindBar.swift:357` — `.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))`
- `KuvoCode/Views/Session/FindBar.swift:360` — `.animation(.ui, value: find.isOn)`
- `KuvoCode/Views/Session/ModelPicker.swift:326` — `withAnimation(.snappy(duration: 0.2)) { turnedTo = next }`
- `KuvoCode/Views/Session/ModelPicker.swift:497` — `.animation(dragging ? nil : .snappy(duration: 0.18), value: selected)`
- `KuvoCode/Views/Session/QueueDock.swift:48` — `.animation(.ui, value: items.map(\.id))`
- `KuvoCode/Views/Session/QuoteList.swift:38` — `Button("Remove All") { withAnimation(.ui) { quotes.removeAll() } }`
- `KuvoCode/Views/Session/QuoteList.swift:49` — `withAnimation(.ui) { quotes.removeAll { $0.id == id } }`
- `KuvoCode/Views/Session/QuoteList.swift:61` — `.transition(.opacity.combined(with: .offset(y: 4)))`
- `KuvoCode/Views/Session/SelectionMenu.swift:28` — `.transition(.opacity.combined(with: .scale(scale: 0.96)))`
- `KuvoCode/Views/Session/SelectionMenu.swift:31` — `.animation(.easeOut(duration: 0.12), value: point == nil)`
- `KuvoCode/Views/Session/SessionView.swift:115` — `.transition(.opacity)`
- `KuvoCode/Views/Session/SessionView.swift:121` — `.transition(.opacity)`
- `KuvoCode/Views/Session/SessionView.swift:127` — `.transition(.move(edge: .bottom).combined(with: .opacity))`
- `KuvoCode/Views/Session/SessionView.swift:164` — `.animation(.ui, value: model.permissions.map(\.id))`
- `KuvoCode/Views/Session/SessionView.swift:165` — `.animation(.ui, value: model.forms.map(\.id))`
- `KuvoCode/Views/Session/SessionView.swift:174` — `.animation(.ui, value: model.waiting.isEmpty)`
- `KuvoCode/Views/Session/SessionView.swift:175` — `.animation(.ui, value: offlineMachine == nil)`
- `KuvoCode/Views/Session/SessionView.swift:176` — `.animation(.ui, value: model.failure)`
- `KuvoCode/Views/Session/SessionView.swift:177` — `.animation(.ui, value: app.browserAsks.asks(for: model.session.id).map(\.id))`
- `KuvoCode/Views/Session/ShellRow.swift:32` — `withAnimation(.ui) { isExpanded.toggle() }`
- `KuvoCode/Views/Session/ShellRow.swift:58` — `.transition(.opacity.combined(with: .move(edge: .top)))`
- `KuvoCode/Views/Session/StepsRow.swift:38` — `withAnimation(.ui) { isExpanded.toggle() }`
- `KuvoCode/Views/Session/StepsRow.swift:56` — `.transition(.opacity)`
- `KuvoCode/Views/Session/ToolCallView.swift:41` — `withAnimation(.ui) { isExpanded.toggle() }`
- `KuvoCode/Views/Session/ToolCallView.swift:83` — `.transition(.opacity.combined(with: .move(edge: .top)))`
- `KuvoCode/Views/Session/TranscriptView.swift:66` — `.transition(Self.rowTransition)`
- `KuvoCode/Views/Session/TranscriptView.swift:733` — `withAnimation(.ui) { isExpanded.toggle() }`
- `KuvoCode/Views/Session/TranscriptView.swift:885` — `withAnimation(.ui) { isExpanded.toggle() }`
- `KuvoCode/Views/Session/TranscriptView.swift:915` — `.transition(.opacity)`
- `KuvoCode/Views/Session/TranscriptView.swift:1158` — `withAnimation(.ui) { copied = true }`
- `KuvoCode/Views/Session/TranscriptView.swift:1161` — `withAnimation(.ui) { copied = false }`
- `KuvoCode/Views/Session/TranscriptView.swift:1166` — `.contentTransition(.symbolEffect(.replace))`
- `KuvoCode/Views/Session/TranscriptView.swift:1300` — `withAnimation(.ui) { folds.set(id, open: !open) }`
- `KuvoCode/Views/Session/TranscriptView.swift:1325` — `.transition(.opacity)`
- `KuvoCode/Views/Session/WidgetView.swift:207` — `.environment(\.showWidgetLarge) { widget in withAnimation(.ui) { large = widget } }`
- `KuvoCode/Views/Session/WidgetView.swift:210` — `LargeWidgetView(widget: large) { withAnimation(.ui) { self.large = nil } }`
- `KuvoCode/Views/Session/WidgetView.swift:211` — `.transition(.opacity.combined(with: .scale(0.985)))`
- `KuvoCode/Views/Session/WidgetView.swift:269` — `.transition(.opacity)`
- `KuvoCode/Views/Session/WidgetView.swift:273` — `withAnimation(.easeInOut(duration: 0.35)) { index = (index + 1) % Self.words.count }`
- `KuvoCode/Views/Session/YourMessage.swift:61` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:128` — `Button(SiteSignIns.shared.isSignedIn(service.id, on: nil) == true ? "Open…" : "Sign In…") { withAnimation(.ui) { app.settingsTabs.open(service) } }`
- `KuvoCode/Views/Settings/SettingsDetail.swift:107` — `.transition(.opacity)`
- `KuvoCode/Views/Settings/SettingsDetail.swift:113` — `navigator?.open(owner, title: title(item)) { withAnimation(.ui) { binding.wrappedValue = nil } }`
- `KuvoCode/Views/Settings/SiteSignInPage.swift:73` — `.transition(.opacity.combined(with: .scale(scale: 0.9)))`
- `KuvoCode/Views/Settings/SiteSignInPage.swift:93` — `.animation(.ui, value: SiteSignIns.shared.isSignedIn(service.id, on: machine))`
- `KuvoCode/Views/SettingsView.swift:26` — `SettingsSidebar(selection: Binding(get: { tabs.page }, set: { page in withAnimation(.ui) { tabs.show(page) } }), search: $search) { page in`
- `KuvoCode/Views/SettingsView.swift:27` — `withAnimation(.ui) { tabs.show(page, inNewTab: true) }`
- `KuvoCode/Views/SettingsView.swift:30` — `withAnimation(.ui) { tabs.preview(page) { navigators[$0]?.detail != nil } }`
- `KuvoCode/Views/SettingsView.swift:57` — `withAnimation(.ui) { tabs.close(tab.id, machines: app.machines) }`
- `KuvoCode/Views/SettingsView.swift:413` — `.transition(.opacity)`
- `KuvoCode/Views/Shared/FormFieldsView.swift:170` — `withAnimation(.ui) { pick(option.value) }`
- `KuvoCode/Views/SidebarView.swift:218` — `.transition(.opacity.combined(with: .move(edge: .bottom)))`
- `KuvoCode/Views/SidebarView.swift:356` — `withAnimation(.ui) { toggle(project.directory) }`
- `KuvoCode/Views/SidebarView.swift:392` — `withAnimation(.ui) {`
- `KuvoCode/Views/SidebarView.swift:439` — `withAnimation(.ui) {`
- `KuvoCode/Views/SidebarView.swift:742` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Views/SidebarView.swift:1051` — `withAnimation(.ui) { isFolded.wrappedValue.toggle() }`
- `KuvoCode/Views/SidebarView.swift:1079` — `.animation(.easeOut(duration: 0.12), value: isHovering)`
- `KuvoCode/Views/TitleBar.swift:104` — `.animation(.ui, value: tabs.map(\.id))`
- `KuvoCode/Views/TitleBar.swift:117` — `let select = { withAnimation(.ui) { selection = tab.id } }`
- `KuvoCode/Views/TitleBar.swift:124` — `.background { if isActive { ActivePill().matchedGeometryEffect(id: "pill", in: pill) } }`
- `KuvoCode/Views/TitleBar.swift:133` — `.background { if isActive { ActivePill().matchedGeometryEffect(id: "pill", in: pill) } }`
- `KuvoCode/Views/TitleBar.swift:150` — `.matchedGeometryEffect(id: "pill", in: pill)`
- `KuvoCode/Views/TitleBar.swift:254` — `.onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }`
- `KuvoCode/Views/TitleBar.swift:301` — `.transition(.scale.combined(with: .opacity))`
- `KuvoCode/Views/TitleBar.swift:304` — `.animation(.ui, value: status)`
- `KuvoCode/Views/TitleBar.swift:574` — `withAnimation(.ui) { showsSidebar.toggle() }`
- `KuvoCode/Views/TitleBar.swift:592` — `withAnimation(.ui) { showsPanel.toggle() }`
- `KuvoCode/Views/Utilities/BrowserSession.swift:298` — `withAnimation(.ui) { self.dialog = dialog }`
- `KuvoCode/Views/Utilities/BrowserSession.swift:315` — `withAnimation(.ui) { self.dialog = nil }`
- `KuvoCode/Views/Utilities/BrowserSession.swift:322` — `withAnimation(.ui) { dialog = nil }`
- `KuvoCode/Views/Utilities/BrowserSession.swift:407` — `withAnimation(.ui) { downloads = (downloads + [entry]).suffix(3) }`
- `KuvoCode/Views/Utilities/BrowserSession.swift:495` — `withAnimation(.ui) { downloads.removeAll { $0.state != .running } }`
- `KuvoCode/Views/Utilities/BrowserSession.swift:522` — `.transition(.move(edge: .top).combined(with: .opacity))`
- `KuvoCode/Views/Utilities/BrowserSession.swift:527` — `.transition(.move(edge: .top).combined(with: .opacity))`
- `KuvoCode/Views/Utilities/BrowserSession.swift:531` — `.transition(.move(edge: .top).combined(with: .opacity))`
- `KuvoCode/Views/Utilities/BrowserSession.swift:543` — `.transition(.opacity)`
- `KuvoCode/Views/Utilities/BrowserSession.swift:546` — `.animation(.ui, value: session.isAgentBrowsing || session.isHeld)`
- `KuvoCode/Views/Utilities/BrowserSession.swift:646` — `Button("Never for This Site") { withAnimation(.ui) { session.dismissPendingLogin(never: true) } }`
- `KuvoCode/Views/Utilities/BrowserSession.swift:648` — `withAnimation(.ui) { session.dismissPendingLogin(never: false) }`
- `KuvoCode/Views/Utilities/BrowserSession.swift:651` — `Button(login.isUpdate ? "Update" : "Save") { withAnimation(.ui) { session.savePendingLogin() } }`
- `KuvoCode/Views/Utilities/BrowserSession.swift:688` — `.animation(.ui, value: download.progress)`
- `KuvoCode/Views/Utilities/FilesView.swift:412` — `Button { withAnimation(.ui) { showsTree.toggle() } } label: {`
- `KuvoCode/Views/Utilities/MachineBrowserPane.swift:37` — `.transition(.move(edge: .top).combined(with: .opacity))`
- `KuvoCode/Views/Utilities/MachineBrowserPane.swift:41` — `.transition(.move(edge: .top).combined(with: .opacity))`
- `KuvoCode/Views/Utilities/MachineBrowserPane.swift:47` — `.animation(.ui, value: browser.dialog)`
- `KuvoCode/Views/Utilities/MachineBrowserPane.swift:48` — `.animation(.ui, value: browser.downloads)`
- `KuvoCode/Views/Utilities/MachineBrowserPane.swift:83` — `.transition(.opacity)`
- `KuvoCode/Views/Utilities/MachineBrowserPane.swift:86` — `.animation(.ui, value: browser.isAgentBrowsing || browser.isHeld)`
- `KuvoCode/Views/Utilities/NewTabPage.swift:58` — `Button("Remove from Suggested") { withAnimation(.ui) { utilities.history.remove(site) } }`
- `KuvoCode/Views/Utilities/NewTabPage.swift:79` — `withAnimation(.ui) { utilities.replace(tabID, with: open) }`
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:57` — `close: { withAnimation(.ui) { utilities.close(tab.id) } }`
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:62` — `Button("Close Tab") { withAnimation(.ui) { utilities.close(tab.id) } }`
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:64` — `withAnimation(.ui) { for other in utilities.visibleTabs where other.id != tab.id { utilities.close(other.id) } }`
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:88` — `withAnimation(.ui) { proxy.scrollTo(id, anchor: .center) }`
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:95` — `withAnimation(.ui) { proxy.scrollTo(id, anchor: .center) }`
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:101` — `Button { withAnimation(.ui) { utilities.newTab() } } label: {`
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:107` — `Button { withAnimation(.ui) { isExpanded.toggle() } } label: {`
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:127` — `.animation(.easeOut(duration: 0.15), value: tabsOverflow)`

## 5. User-facing strings (1208 sites, 933 distinct)

Extracted from `Text`, `Button`, `Label`, `Toggle`, `Picker`, `Section`,
`TextField`, `SecureField`, `Link`, `.help`, `.accessibilityLabel`, prompts and
titles, plus `title:`/`detail:`/`name:` properties. Strings built at runtime by
interpolation are included with their interpolation left visible.

- `KuvoCode/App/KuvoCodeApp.swift:125` — “Check for Updates…”
- `KuvoCode/App/KuvoCodeApp.swift:130` — “New Session”
- `KuvoCode/App/KuvoCodeApp.swift:133` — “New Project…”
- `KuvoCode/App/KuvoCodeApp.swift:136` — “New Chat”
- `KuvoCode/App/KuvoCodeApp.swift:139` — “New Bot…”
- `KuvoCode/App/KuvoCodeApp.swift:141` — “Import Bot…”
- `KuvoCode/App/KuvoCodeApp.swift:143` — “New Group Chat…”
- `KuvoCode/App/KuvoCodeApp.swift:145` — “Open Folder…”
- `KuvoCode/App/KuvoCodeApp.swift:148` — “Open Quickly…”
- `KuvoCode/App/KuvoCodeApp.swift:154` — “Close Tab”
- `KuvoCode/App/KuvoCodeApp.swift:159` — “Close Window”
- `KuvoCode/App/KuvoCodeApp.swift:161` — “Reopen Closed Tab”
- `KuvoCode/App/KuvoCodeApp.swift:166` — “Find in Conversation…”
- `KuvoCode/App/KuvoCodeApp.swift:171` — “Stop”
- `KuvoCode/App/KuvoCodeApp.swift:175` — “Build Mode”
- `KuvoCode/App/KuvoCodeApp.swift:178` — “Plan Mode”
- `KuvoCode/App/KuvoCodeApp.swift:184` — “Show Changes”
- `KuvoCode/App/KuvoCodeApp.swift:186` — “Show Files”
- `KuvoCode/App/KuvoCodeApp.swift:188` — “Run”
- `KuvoCode/App/KuvoCodeApp.swift:191` — “New Terminal”
- `KuvoCode/App/KuvoCodeApp.swift:193` — “New Browser Tab”
- `KuvoCode/App/KuvoCodeApp.swift:196` — “Show Panel”
- `KuvoCode/App/KuvoCodeApp.swift:202` — “Command Palette…”
- `KuvoCode/App/KuvoCodeApp.swift:206` — “Show Sessions”
- `KuvoCode/App/KuvoCodeApp.swift:211` — “Show Next Tab”
- `KuvoCode/App/KuvoCodeApp.swift:214` — “Show Previous Tab”
- `KuvoCode/App/KuvoCodeApp.swift:226` — “Appearance”
- `KuvoCode/App/KuvoCodeApp.swift:232` — “Kuvo Code Help”
- `KuvoCode/App/KuvoCodeApp.swift:233` — “What\u{2019}s New”
- `KuvoCode/App/KuvoCodeApp.swift:234` — “Report an Issue…”
- `KuvoCode/App/KuvoCodeApp.swift:235` — “Contact Us…”
- `KuvoCode/App/KuvoCodeApp.swift:238` — “Settings…”
- `KuvoCode/App/KuvoCodeApp.swift:240` — “Accounts…”
- `KuvoCode/Design/BotAvatar.swift:262` — “On \(machine)”
- `KuvoCode/Design/BotAvatar.swift:263` — “On \(machine)”
- `KuvoCode/Design/BotAvatar.swift:291` — “+\(more)”
- `KuvoCode/Design/Card.swift:105` — “ | ”
- `KuvoCode/Design/CodeBlockStyle.swift:180` — “Copied”
- `KuvoCode/Design/CodeBlockStyle.swift:188` — “Copy Code”
- `KuvoCode/Design/QuoteViews.swift:14` — “Replying to”
- `KuvoCode/Design/QuoteViews.swift:23` — “Don’t Reply to This”
- `KuvoCode/Design/QuoteViews.swift:26` — “Drop the quote”
- `KuvoCode/Design/Spinner.swift:26` — “Working”
- `KuvoCode/Design/Theme.swift:153` — “+\(additions)”
- `KuvoCode/Design/Theme.swift:154` — “−\(deletions)”
- `KuvoCode/Design/WindowGlass.swift:80` — “Drag to resize”
- `KuvoCode/Stores/AgentMail.swift:86` — “[Message from · ses_1]”
- `KuvoCode/Stores/BotGroups.swift:1059` — “\(bot.name) in \(group.name)”
- `KuvoCode/Stores/BotGroups.swift:984` — “\(bot.name) finished its part”
- `KuvoCode/Stores/Bots.swift:13` — “Keeps CI green”
- `KuvoCode/Stores/BotTemplates.swift:100` — “Lens”
- `KuvoCode/Stores/BotTemplates.swift:111` — “Tally”
- `KuvoCode/Stores/BotTemplates.swift:29` — “Herald”
- `KuvoCode/Stores/BotTemplates.swift:39` — “Compass”
- `KuvoCode/Stores/BotTemplates.swift:49` — “Courier”
- `KuvoCode/Stores/BotTemplates.swift:59` — “Echo”
- `KuvoCode/Stores/BotTemplates.swift:69` — “Lookout”
- `KuvoCode/Stores/BotTemplates.swift:79` — “Sage”
- `KuvoCode/Stores/BotTemplates.swift:89` — “Keeper”
- `KuvoCode/Stores/BrowserAgent.swift:518` — “kuvo-agent”
- `KuvoCode/Stores/BrowserAsks.swift:149` — “Signed in to \(ask.host)”
- `KuvoCode/Stores/GitBranches.swift:31` — “Trim note titles”
- `KuvoCode/Stores/Integrations.swift:272` — “Apple Calendar and Reminders”
- `KuvoCode/Stores/Integrations.swift:274` — “Outlook and Microsoft 365”
- `KuvoCode/Stores/Integrations.swift:284` — “Fastmail”
- `KuvoCode/Stores/Integrations.swift:286` — “Other Calendars”
- `KuvoCode/Stores/Integrations.swift:288` — “CALDAV_BASE_URL”
- `KuvoCode/Stores/Integrations.swift:288` — “https://caldav.icloud.com”
- `KuvoCode/Stores/Integrations.swift:288` — “Server”
- `KuvoCode/Stores/Integrations.swift:289` — “CALDAV_USERNAME”
- `KuvoCode/Stores/Integrations.swift:289` — “Username”
- `KuvoCode/Stores/Integrations.swift:289` — “you@icloud.com”
- `KuvoCode/Stores/Integrations.swift:290` — “An app-specific password”
- `KuvoCode/Stores/Integrations.swift:290` — “CALDAV_PASSWORD”
- `KuvoCode/Stores/Integrations.swift:290` — “Password”
- `KuvoCode/Stores/Integrations.swift:292` — “Gmail”
- `KuvoCode/Stores/Integrations.swift:294` — “Google Calendar”
- `KuvoCode/Stores/Integrations.swift:297` — “Slack”
- `KuvoCode/Stores/Integrations.swift:299` — “Discord”
- `KuvoCode/Stores/Integrations.swift:300` — “Telegram”
- `KuvoCode/Stores/Integrations.swift:301` — “WhatsApp”
- `KuvoCode/Stores/Integrations.swift:304` — “LinkedIn”
- `KuvoCode/Stores/Integrations.swift:305` — “Reddit”
- `KuvoCode/Stores/Integrations.swift:306` — “Bluesky”
- `KuvoCode/Stores/Integrations.swift:307` — “Mastodon”
- `KuvoCode/Stores/Integrations.swift:309` — “GitHub”
- `KuvoCode/Stores/Integrations.swift:310` — “github_pat_…”
- `KuvoCode/Stores/Integrations.swift:310` — “Personal access token”
- `KuvoCode/Stores/Integrations.swift:310` — “TOKEN”
- `KuvoCode/Stores/Integrations.swift:311` — “GitLab”
- `KuvoCode/Stores/Integrations.swift:313` — “Linear”
- `KuvoCode/Stores/Integrations.swift:315` — “Notion”
- `KuvoCode/Stores/Integrations.swift:317` — “Jira and Confluence”
- `KuvoCode/Stores/Integrations.swift:319` — “Todoist”
- `KuvoCode/Stores/Integrations.swift:320` — “API token”
- `KuvoCode/Stores/Integrations.swift:320` — “From Settings › Integrations › Developer”
- `KuvoCode/Stores/Integrations.swift:320` — “TODOIST_API_KEY”
- `KuvoCode/Stores/Integrations.swift:321` — “Calendly”
- `KuvoCode/Stores/Integrations.swift:323` — “Figma”
- `KuvoCode/Stores/Integrations.swift:325` — “Asana”
- `KuvoCode/Stores/Integrations.swift:327` — “Zoom”
- `KuvoCode/Stores/Integrations.swift:59` — “Client ID”
- `KuvoCode/Stores/Integrations.swift:59` — “Client secret”
- `KuvoCode/Stores/Integrations.swift:59` — “CLIENT_ID”
- `KuvoCode/Stores/Integrations.swift:59` — “CLIENT_SECRET”
- `KuvoCode/Stores/Integrations.swift:59` — “From your app”
- `KuvoCode/Stores/Integrations.swift:59` — “From your app”
- `KuvoCode/Stores/MachineBrowser.swift:1131` — “run.kuvo.code.machine-browser.write”
- `KuvoCode/Stores/MCPCatalog.swift:39` — “Linear”
- `KuvoCode/Stores/MCPCatalog.swift:40` — “Sentry”
- `KuvoCode/Stores/MCPCatalog.swift:41` — “Notion”
- `KuvoCode/Stores/MCPCatalog.swift:42` — “Atlassian”
- `KuvoCode/Stores/MCPCatalog.swift:43` — “Stripe”
- `KuvoCode/Stores/MCPCatalog.swift:44` — “Supabase”
- `KuvoCode/Stores/MCPCatalog.swift:45` — “Neon”
- `KuvoCode/Stores/MCPCatalog.swift:46` — “Context7”
- `KuvoCode/Stores/MCPCatalog.swift:47` — “Cloudflare Docs”
- `KuvoCode/Stores/MCPCatalog.swift:48` — “Hugging Face”
- `KuvoCode/Stores/MCPCatalog.swift:49` — “Chrome DevTools”
- `KuvoCode/Stores/Notifier.swift:109` — “Reply”
- `KuvoCode/Stores/Passwords.swift:107` — “kuvo-passwords”
- `KuvoCode/Stores/Personalities.swift:26` — “Straight Shooter”
- `KuvoCode/Stores/Personalities.swift:27` — “Cheerleader”
- `KuvoCode/Stores/Personalities.swift:28` — “Mentor”
- `KuvoCode/Stores/Personalities.swift:29` — “Skeptic”
- `KuvoCode/Stores/Personalities.swift:30` — “Pragmatist”
- `KuvoCode/Stores/Personalities.swift:31` — “Perfectionist”
- `KuvoCode/Stores/Personalities.swift:32` — “Visionary”
- `KuvoCode/Stores/Personalities.swift:33` — “Dry Wit”
- `KuvoCode/Stores/ProjectFiles.swift:19` — “api/”
- `KuvoCode/Stores/SkillLibrary.swift:21` — “Anthropic”
- `KuvoCode/Stores/SkillLibrary.swift:21` — “skills”
- `KuvoCode/Stores/SkillLibrary.swift:22` — “OpenAI”
- `KuvoCode/Stores/SkillLibrary.swift:22` — “skills”
- `KuvoCode/Stores/SkillLibrary.swift:23` — “superpowers”
- `KuvoCode/Stores/SkillLibrary.swift:23` — “Superpowers”
- `KuvoCode/Stores/SkillLibrary.swift:24` — “Matt Pocock”
- `KuvoCode/Stores/SkillLibrary.swift:24` — “skills”
- `KuvoCode/Stores/SkillLibrary.swift:25` — “Addy Osmani”
- `KuvoCode/Stores/SkillLibrary.swift:25` — “agent-skills”
- `KuvoCode/Stores/SkillLibrary.swift:26` — “agent-skills”
- `KuvoCode/Stores/SkillLibrary.swift:26` — “Vercel”
- `KuvoCode/Stores/SkillLibrary.swift:27` — “awesome-copilot”
- `KuvoCode/Stores/SkillLibrary.swift:27` — “GitHub Awesome Copilot”
- `KuvoCode/Stores/SkillLibrary.swift:28` — “Hugging Face”
- `KuvoCode/Stores/SkillLibrary.swift:28` — “skills”
- `KuvoCode/Stores/SkillLibrary.swift:29` — “Cloudflare”
- `KuvoCode/Stores/SkillLibrary.swift:29` — “skills”
- `KuvoCode/Stores/SkillLibrary.swift:30` — “skills”
- `KuvoCode/Stores/SkillLibrary.swift:30` — “Trail of Bits”
- `KuvoCode/Stores/SkillLibrary.swift:31` — “Scientific Skills”
- `KuvoCode/Stores/SkillLibrary.swift:31` — “scientific-agent-skills”
- `KuvoCode/Stores/SkillLibrary.swift:32` — “agents”
- `KuvoCode/Stores/SkillLibrary.swift:32` — “wshobson/agents”
- `KuvoCode/Stores/SkillLibrary.swift:81` — “owner/name”
- `KuvoCode/Views/AnalyticsNotice.swift:10` — “Help improve Kuvo Code”
- `KuvoCode/Views/AnalyticsNotice.swift:12` — “Kuvo Code shares anonymous usage: which features you use, how often, what kind of trouble you run into, and the app and macOS versions. Never your code, prompts, files or accounts.”
- `KuvoCode/Views/AnalyticsNotice.swift:17` — “What's Sent”
- `KuvoCode/Views/AnalyticsNotice.swift:20` — “Turn Off”
- `KuvoCode/Views/AnalyticsNotice.swift:26` — “OK”
- `KuvoCode/Views/BotEditor.swift:1017` — “When”
- `KuvoCode/Views/BotEditor.swift:1020` — “What to do”
- `KuvoCode/Views/BotEditor.swift:1021` — “What \(bot.name) does then, like Send me the morning digest”
- `KuvoCode/Views/BotEditor.swift:1034` — “Cancel”
- `KuvoCode/Views/BotEditor.swift:1036` — “Add Wake-Up”
- `KuvoCode/Views/BotEditor.swift:1082` — “Repeats”
- `KuvoCode/Views/BotEditor.swift:131` — “Delete”
- `KuvoCode/Views/BotEditor.swift:150` — “Cancel”
- `KuvoCode/Views/BotEditor.swift:152` — “Its conversation, memory and wake-ups are deleted. This can’t be undone.”
- `KuvoCode/Views/BotEditor.swift:184` — “· \(EffortLevel.title(variant))”
- `KuvoCode/Views/BotEditor.swift:236` — “Show in the Panel”
- `KuvoCode/Views/BotEditor.swift:238` — “MEMORY.md”
- `KuvoCode/Views/BotEditor.swift:281` — “Delete Bot…”
- `KuvoCode/Views/BotEditor.swift:286` — “Delete Bot…”
- `KuvoCode/Views/BotEditor.swift:288` — “Export…”
- `KuvoCode/Views/BotEditor.swift:291` — “Save a file to share \(bot.name): its look, personality and job”
- `KuvoCode/Views/BotEditor.swift:292` — “Export…”
- `KuvoCode/Views/BotEditor.swift:303` — “Cancel”
- `KuvoCode/Views/BotEditor.swift:334` — “Shuffle”
- `KuvoCode/Views/BotEditor.swift:338` — “A random look”
- `KuvoCode/Views/BotEditor.swift:346` — “Name”
- `KuvoCode/Views/BotEditor.swift:346` — “Name, like Scout”
- `KuvoCode/Views/BotEditor.swift:390` — “A workspace of its own, beside its memory”
- `KuvoCode/Views/BotEditor.swift:395` — “Projects”
- `KuvoCode/Views/BotEditor.swift:408` — “Works in”
- `KuvoCode/Views/BotEditor.swift:666` — “None”
- `KuvoCode/Views/BotEditor.swift:673` — “Edit…”
- `KuvoCode/Views/BotEditor.swift:674` — “Delete”
- `KuvoCode/Views/BotEditor.swift:678` — “New…”
- `KuvoCode/Views/BotEditor.swift:682` — “Write a personality of your own”
- `KuvoCode/Views/BotEditor.swift:692` — “Edit”
- `KuvoCode/Views/BotEditor.swift:694` — “Delete”
- `KuvoCode/Views/BotEditor.swift:715` — “Name”
- `KuvoCode/Views/BotEditor.swift:715` — “Name, like Night Owl”
- `KuvoCode/Views/BotEditor.swift:720` — “How it talks”
- `KuvoCode/Views/BotEditor.swift:721` — “How it talks, like Quiet and precise. Explains with examples, and asks before assuming.”
- `KuvoCode/Views/BotEditor.swift:729` — “Cancel”
- `KuvoCode/Views/BotEditor.swift:78` — “Add a Machine”
- `KuvoCode/Views/BotEditor.swift:872` — “Pause Wake-Ups”
- `KuvoCode/Views/BotEditor.swift:873` — “They wait until you turn this off; the ones that came due meanwhile go then.”
- `KuvoCode/Views/BotEditor.swift:886` — “None waiting”
- `KuvoCode/Views/BotEditor.swift:897` — “Watches ”
- `KuvoCode/Views/BotEditor.swift:919` — “Checking…”
- `KuvoCode/Views/BotEditor.swift:933` — “Check Now”
- `KuvoCode/Views/BotEditor.swift:939` — “Run its check now and see what it prints; it doesn’t count as a run, nor wake the bot”
- `KuvoCode/Views/BotEditor.swift:940` — “Stop Watching”
- `KuvoCode/Views/BotEditor.swift:945` — “Stop this watch”
- `KuvoCode/Views/BotEditor.swift:957` — “\(wake.due, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())\(wake.every.map { ”
- `KuvoCode/Views/BotEditor.swift:966` — “Wake Up Now”
- `KuvoCode/Views/BotEditor.swift:971` — “Cancel Wake-Up”
- `KuvoCode/Views/BotEditor.swift:976` — “Cancel this wake-up”
- `KuvoCode/Views/BotEditor.swift:988` — “Add Wake-Up…”
- `KuvoCode/Views/BotEditor.swift:991` — “Schedule a wake-up yourself: what the bot does, and when”
- `KuvoCode/Views/BrowserAskCard.swift:126` — “Username or email”
- `KuvoCode/Views/BrowserAskCard.swift:130` — “Password”
- `KuvoCode/Views/BrowserAskCard.swift:141` — “Saved Passwords”
- `KuvoCode/Views/BrowserAskCard.swift:149` — “Save in Passwords”
- `KuvoCode/Views/BrowserAskCard.swift:152` — “Let agents sign in here on their own”
- `KuvoCode/Views/BrowserAskCard.swift:153` — “Next time, with its saved password, without asking you; it still goes straight into the page. Settings › Passwords lists these sites.”
- `KuvoCode/Views/BrowserAskCard.swift:169` — “Code”
- `KuvoCode/Views/BrowserAskCard.swift:181` — “Not Now”
- `KuvoCode/Views/BrowserAskCard.swift:189` — “I Can’t”
- `KuvoCode/Views/BrowserAskCard.swift:193` — “Show Page”
- `KuvoCode/Views/BrowserAskCard.swift:194` — “Show the browser in the panel”
- `KuvoCode/Views/BrowserAskCard.swift:196` — “Done”
- `KuvoCode/Views/BrowserAskCard.swift:93` — “+\(waiting)”
- `KuvoCode/Views/BrowserAskCard.swift:99` — “\(waiting) more waiting”
- `KuvoCode/Views/CommandPalette.swift:101` — “Nothing matches.”
- `KuvoCode/Views/CommandPalette.swift:46` — “Actions”
- `KuvoCode/Views/CommandPalette.swift:46` — “Recent Sessions”
- `KuvoCode/Views/CommandPalette.swift:61` — “Actions”
- `KuvoCode/Views/CommandPalette.swift:62` — “Sessions”
- `KuvoCode/Views/CommandPalette.swift:63` — “Files”
- `KuvoCode/Views/GroupChatView.swift:143` — “\(Text(”
- `KuvoCode/Views/GroupChatView.swift:155` — “A meeting you scheduled for this chat”
- `KuvoCode/Views/GroupChatView.swift:220` — “Wrap-Up”
- `KuvoCode/Views/GroupChatView.swift:227` — “Report”
- `KuvoCode/Views/GroupChatView.swift:233` — “What \(author?.name ?? ”
- `KuvoCode/Views/GroupChatView.swift:269` — “Copy”
- `KuvoCode/Views/GroupChatView.swift:270` — “Reply”
- `KuvoCode/Views/GroupChatView.swift:272` — “Open \(author.name)’s Conversation”
- `KuvoCode/Views/GroupChatView.swift:337` — “Each bot does its part in its own conversation, and reports back here.”
- `KuvoCode/Views/GroupChatView.swift:341` — “Start the Work”
- `KuvoCode/Views/GroupChatView.swift:343` — “Hand each bot its part”
- `KuvoCode/Views/GroupChatView.swift:378` — “After \(ListFormatter.localizedString(byJoining: after))”
- `KuvoCode/Views/GroupChatView.swift:382` — “After \(ListFormatter.localizedString(byJoining: after))”
- `KuvoCode/Views/GroupChatView.swift:384` — “Starts once their parts are done, with what they report”
- `KuvoCode/Views/GroupChatView.swift:386` — “Needs You”
- `KuvoCode/Views/GroupChatView.swift:388` — “It's waiting on you in its conversation: click to answer”
- `KuvoCode/Views/GroupChatView.swift:393` — “Working”
- `KuvoCode/Views/GroupChatView.swift:397` — “Done”
- `KuvoCode/Views/GroupChatView.swift:400` — “Didn’t Finish”
- `KuvoCode/Views/GroupChatView.swift:437` — “Bring them something to talk through. \(lead.map { ”
- `KuvoCode/Views/GroupChatView.swift:455` — “Paused after a good few turns, so it doesn’t run on.”
- `KuvoCode/Views/GroupChatView.swift:459` — “Keep Going”
- `KuvoCode/Views/GroupChatView.swift:528` — “Ask \(bot.name)”
- `KuvoCode/Views/GroupChatView.swift:66` — “Message \(group.name)…”
- `KuvoCode/Views/GroupEditor.swift:101` — “Delete”
- `KuvoCode/Views/GroupEditor.swift:106` — “Cancel”
- `KuvoCode/Views/GroupEditor.swift:108` — “Its messages are deleted, and its bots stop remembering it. This can’t be undone.”
- `KuvoCode/Views/GroupEditor.swift:140` — “Name”
- `KuvoCode/Views/GroupEditor.swift:140` — “Name, like Release Planning”
- `KuvoCode/Views/GroupEditor.swift:151` — “Purpose”
- `KuvoCode/Views/GroupEditor.swift:151` — “What it's for, like Plan each week's release”
- `KuvoCode/Views/GroupEditor.swift:209` — “Meets on a Schedule”
- `KuvoCode/Views/GroupEditor.swift:220` — “Next meeting”
- `KuvoCode/Views/GroupEditor.swift:223` — “Topic”
- `KuvoCode/Views/GroupEditor.swift:223` — “What to go over, like What changed since yesterday, and what’s in the way”
- `KuvoCode/Views/GroupEditor.swift:262` — “Delete Group Chat…”
- `KuvoCode/Views/GroupEditor.swift:266` — “Cancel”
- `KuvoCode/Views/ImageViewer.swift:122` — “Pinch or double-click to zoom”
- `KuvoCode/Views/ImageViewer.swift:186` — “Copy the picture (⌘C)”
- `KuvoCode/Views/ImageViewer.swift:187` — “Open in Preview”
- `KuvoCode/Views/ImageViewer.swift:191` — “Open in its app”
- `KuvoCode/Views/ImageViewer.swift:193` — “Show in Finder”
- `KuvoCode/Views/ImageViewer.swift:194` — “Show in Finder”
- `KuvoCode/Views/ImageViewer.swift:196` — “Close”
- `KuvoCode/Views/ImageViewer.swift:197` — “Close (Esc)”
- `KuvoCode/Views/MachineForm.swift:40` — “SSH host”
- `KuvoCode/Views/MachineForm.swift:73` — “SSH host”
- `KuvoCode/Views/MachineStatusViews.swift:108` — “This is the conversation as last seen. You can write meanwhile, and send once it’s back.”
- `KuvoCode/Views/MachineStatusViews.swift:118` — “Connect to \(engine.machine.name) again”
- `KuvoCode/Views/MachineStatusViews.swift:68` — “Try Again”
- `KuvoCode/Views/MachineStatusViews.swift:72` — “Connect”
- `KuvoCode/Views/MainView.swift:1884` — “Still loading your accounts and models…”
- `KuvoCode/Views/MainView.swift:1886` — “If macOS is asking for access to a folder, answer that dialog.”
- `KuvoCode/Views/MainView.swift:1908` — “Move to Project”
- `KuvoCode/Views/MainView.swift:1913` — “No projects on this Mac”
- `KuvoCode/Views/MainView.swift:1924` — “Move to Project: carry this chat into one of your projects”
- `KuvoCode/Views/MainView.swift:1982` — “Welcome to \(AppInfo.name)”
- `KuvoCode/Views/MainView.swift:1984` — “Open a project folder and tell the agent what to build.\nIt can read, edit and run things there.”
- `KuvoCode/Views/MainView.swift:1989` — “Open Folder…”
- `KuvoCode/Views/MainView.swift:1991` — “Start a Chat”
- `KuvoCode/Views/MainView.swift:1993` — “A conversation of no project (⌥⌘N)”
- `KuvoCode/Views/MainView.swift:2000` — “Free models work without an account.”
- `KuvoCode/Views/MainView.swift:494` — “Run”
- `KuvoCode/Views/MainView.swift:495` — “Run \(runCommand) (⌘R)”
- `KuvoCode/Views/MainView.swift:578` — “Sessions”
- `KuvoCode/Views/MainView.swift:632` — “Swap”
- `KuvoCode/Views/MainView.swift:633` — “Swap the two sessions”
- `KuvoCode/Views/MainView.swift:634` — “Close Split View”
- `KuvoCode/Views/MainView.swift:635` — “Close Split View”
- `KuvoCode/Views/MainView.swift:722` — “Close”
- `KuvoCode/Views/MainView.swift:723` — “Close”
- `KuvoCode/Views/MainView.swift:736` — “Close”
- `KuvoCode/Views/MainView.swift:737` — “Close”
- `KuvoCode/Views/MainView.swift:751` — “Close”
- `KuvoCode/Views/MainView.swift:752` — “Close”
- `KuvoCode/Views/MainView.swift:765` — “Edit Group Chat”
- `KuvoCode/Views/MainView.swift:766` — “Edit Group Chat: its name, bots and lead”
- `KuvoCode/Views/MainView.swift:767` — “Close Tab”
- `KuvoCode/Views/MainView.swift:768` — “Close Tab”
- `KuvoCode/Views/MainView.swift:789` — “Edit Bot”
- `KuvoCode/Views/MainView.swift:790` — “Edit Bot: its look, job, wake-ups and memory”
- `KuvoCode/Views/MainView.swift:802` — “Close Tab”
- `KuvoCode/Views/MainView.swift:803` — “Close Tab”
- `KuvoCode/Views/MainView.swift:818` — “Close Tab”
- `KuvoCode/Views/MainView.swift:819` — “Close Tab”
- `KuvoCode/Views/MainView.swift:825` — “New Session”
- `KuvoCode/Views/MainView.swift:828` — “Close Tab”
- `KuvoCode/Views/MainView.swift:829` — “Close Tab”
- `KuvoCode/Views/MainView.swift:840` — “Close Tab”
- `KuvoCode/Views/MainView.swift:841` — “Close Tab”
- `KuvoCode/Views/ProjectEditor.swift:126` — “Run”
- `KuvoCode/Views/ProjectEditor.swift:143` — “Worktree setup”
- `KuvoCode/Views/ProjectEditor.swift:213` — “Project name”
- `KuvoCode/Views/ProjectEditor.swift:225` — “location”
- `KuvoCode/Views/ProjectEditor.swift:273` — “Folder on \(machine)”
- `KuvoCode/Views/ProjectEditor.swift:282` — “Add”
- `KuvoCode/Views/ProjectEditor.swift:363` — “Primary”
- `KuvoCode/Views/ProjectEditor.swift:367` — “Sessions run in this folder”
- `KuvoCode/Views/ProjectEditor.swift:369` — “Make Primary”
- `KuvoCode/Views/ProjectEditor.swift:372` — “Run sessions in this folder”
- `KuvoCode/Views/ProjectEditor.swift:379` — “Remove from the project”
- `KuvoCode/Views/ProjectEditor.swift:59` — “Add a Machine”
- `KuvoCode/Views/Providers/ConnectView.swift:154` — “Or set \(names.joined(separator: ”
- `KuvoCode/Views/Providers/ConnectView.swift:173` — “Continue”
- `KuvoCode/Views/Providers/ConnectView.swift:185` — “API key”
- `KuvoCode/Views/Providers/ConnectView.swift:187` — “Paste your key”
- `KuvoCode/Views/Providers/ConnectView.swift:203` — “Connect”
- `KuvoCode/Views/Providers/ConnectView.swift:217` — “Enter this code on the page that opened”
- `KuvoCode/Views/Providers/ConnectView.swift:231` — “Finish signing in with your browser. This updates on its own.”
- `KuvoCode/Views/Providers/ConnectView.swift:240` — “Paste the code”
- `KuvoCode/Views/Providers/ConnectView.swift:246` — “Continue”
- `KuvoCode/Views/Providers/ConnectView.swift:257` — “Waiting for you to finish…”
- `KuvoCode/Views/Providers/ConnectView.swift:263` — “Open the Page Again”
- `KuvoCode/Views/Providers/ConnectView.swift:266` — “Cancel”
- `KuvoCode/Views/Providers/ConnectView.swift:310` — “Done”
- `KuvoCode/Views/Providers/ConnectView.swift:326` — “Try Again”
- `KuvoCode/Views/Providers/ConnectView.swift:336` — “Back”
- `KuvoCode/Views/Providers/ConnectView.swift:344` — “Cancel”
- `KuvoCode/Views/Providers/CustomProviders.swift:110` — “My Company, or Local Server”
- `KuvoCode/Views/Providers/CustomProviders.swift:110` — “Name”
- `KuvoCode/Views/Providers/CustomProviders.swift:124` — “Remove”
- `KuvoCode/Views/Providers/CustomProviders.swift:128` — “Its models go away from the model menu. Sessions that used them need another model.”
- `KuvoCode/Views/Providers/CustomProviders.swift:136` — “Name”
- `KuvoCode/Views/Providers/CustomProviders.swift:137` — “API”
- `KuvoCode/Views/Providers/CustomProviders.swift:143` — “Address”
- `KuvoCode/Views/Providers/CustomProviders.swift:143` — “https://api.example.com/v1”
- `KuvoCode/Views/Providers/CustomProviders.swift:145` — “Add its API key in Accounts once it's set up; it's kept with your other credentials, not in the settings file.”
- `KuvoCode/Views/Providers/CustomProviders.swift:154` — “Model”
- `KuvoCode/Views/Providers/CustomProviders.swift:156` — “Name”
- `KuvoCode/Views/Providers/CustomProviders.swift:158` — “Context”
- `KuvoCode/Views/Providers/CustomProviders.swift:160` — “Output”
- `KuvoCode/Views/Providers/CustomProviders.swift:177` — “Name”
- `KuvoCode/Views/Providers/CustomProviders.swift:177` — “Name”
- `KuvoCode/Views/Providers/CustomProviders.swift:179` — “Context”
- `KuvoCode/Views/Providers/CustomProviders.swift:179` — “Context”
- `KuvoCode/Views/Providers/CustomProviders.swift:182` — “Output”
- `KuvoCode/Views/Providers/CustomProviders.swift:182` — “Output”
- `KuvoCode/Views/Providers/CustomProviders.swift:191` — “Remove Model”
- `KuvoCode/Views/Providers/CustomProviders.swift:195` — “A model ID, as the service names it”
- `KuvoCode/Views/Providers/CustomProviders.swift:195` — “Model ID”
- `KuvoCode/Views/Providers/CustomProviders.swift:198` — “Add”
- `KuvoCode/Views/Providers/CustomProviders.swift:202` — “Models”
- `KuvoCode/Views/Providers/CustomProviders.swift:204` — “Context and output are the most tokens a model takes in and writes; empty means 200,000 and 32,000.”
- `KuvoCode/Views/Providers/CustomProviders.swift:210` — “Headers”
- `KuvoCode/Views/Providers/CustomProviders.swift:212` — “Sent with every request, if the service needs more than a key. Write {env:NAME} to use an environment variable.”
- `KuvoCode/Views/Providers/CustomProviders.swift:23` — “Your Own”
- `KuvoCode/Views/Providers/CustomProviders.swift:25` — “Add Provider…”
- `KuvoCode/Views/Providers/CustomProviders.swift:29` — “For a company proxy, a self-hosted server or any service with an OpenAI- or Anthropic-compatible API.”
- `KuvoCode/Views/Providers/CustomProviders.swift:48` — “Key added”
- `KuvoCode/Views/Providers/CustomProviders.swift:53` — “Add Key”
- `KuvoCode/Views/Providers/CustomProviders.swift:57` — “Edit…”
- `KuvoCode/Views/Providers/ProvidersView.swift:156` — “Clear”
- `KuvoCode/Views/Providers/ProvidersView.swift:192` — “Connect”
- `KuvoCode/Views/Providers/ProvidersView.swift:239` — “Connected”
- `KuvoCode/Views/Providers/ProvidersView.swift:244` — “Connect”
- `KuvoCode/Views/Providers/ProvidersView.swift:279` — “Add Account”
- `KuvoCode/Views/Providers/ProvidersView.swift:282` — “Disconnect”
- `KuvoCode/Views/Providers/ProvidersView.swift:51` — “Search \(catalog.providers.count) providers”
- `KuvoCode/Views/Providers/ProvidersView.swift:84` — “No Results for “\(search.trimmingCharacters(in: .whitespaces))””
- `KuvoCode/Views/Providers/ProvidersView.swift:86` — “Check the spelling, or search for the company that makes the model.”
- `KuvoCode/Views/Providers/ProvidersView.swift:88` — “Clear Search”
- `KuvoCode/Views/RootView.swift:94` — “Try Again”
- `KuvoCode/Views/Session/AttachmentViews.swift:145` — “Remove”
- `KuvoCode/Views/Session/AttachmentViews.swift:288` — “\(item.name) — click to look closer”
- `KuvoCode/Views/Session/AttachmentViews.swift:338` — “Open”
- `KuvoCode/Views/Session/AttachmentViews.swift:339` — “Show in Finder”
- `KuvoCode/Views/Session/AttentionCards.swift:228` — “Previous Question”
- `KuvoCode/Views/Session/AttentionCards.swift:229` — “\(index + 1) of \(questions.count)”
- `KuvoCode/Views/Session/AttentionCards.swift:234` — “Next Question”
- `KuvoCode/Views/Session/AttentionCards.swift:237` — “Dismiss: the agent carries on without your answers”
- `KuvoCode/Views/Session/AttentionCards.swift:282` — “Skip”
- `KuvoCode/Views/Session/AttentionCards.swift:44` — “Deny”
- `KuvoCode/Views/Session/AttentionCards.swift:47` — “Always Allow”
- `KuvoCode/Views/Session/AttentionCards.swift:49` — “Allow”
- `KuvoCode/Views/Session/AttentionCards.swift:507` — “Dismiss: the agent carries on without an answer”
- `KuvoCode/Views/Session/AttentionCards.swift:523` — “Answer”
- `KuvoCode/Views/Session/AttentionCards.swift:534` — “Outlook and Microsoft 365 needs an answer”
- `KuvoCode/Views/Session/ChangesPanel.swift:1021` — “You”
- `KuvoCode/Views/Session/ChangesPanel.swift:1024` — “Comment on line \(comment.side == .old ? ”
- `KuvoCode/Views/Session/ChangesPanel.swift:1035` — “Delete”
- `KuvoCode/Views/Session/ChangesPanel.swift:1094` — “You”
- `KuvoCode/Views/Session/ChangesPanel.swift:1097` — “Add a comment…”
- `KuvoCode/Views/Session/ChangesPanel.swift:110` — “Which of the project's folders to show”
- `KuvoCode/Views/Session/ChangesPanel.swift:1111` — “Cancel”
- `KuvoCode/Views/Session/ChangesPanel.swift:1113` — “Comment”
- `KuvoCode/Views/Session/ChangesPanel.swift:1116` — “Comment (⌘Return)”
- `KuvoCode/Views/Session/ChangesPanel.swift:114` — “Changes”
- `KuvoCode/Views/Session/ChangesPanel.swift:120` — “Branch”
- `KuvoCode/Views/Session/ChangesPanel.swift:121` — “Since \(base)”
- `KuvoCode/Views/Session/ChangesPanel.swift:127` — “Session”
- `KuvoCode/Views/Session/ChangesPanel.swift:128` — “This Session”
- `KuvoCode/Views/Session/ChangesPanel.swift:143` — “What to show: uncommitted, unstaged or staged changes, and more”
- `KuvoCode/Views/Session/ChangesPanel.swift:145` — “This Session”
- `KuvoCode/Views/Session/ChangesPanel.swift:147` — “Not a git repository: showing the agent's edits in this session.”
- `KuvoCode/Views/Session/ChangesPanel.swift:171` — “Commit…”
- `KuvoCode/Views/Session/ChangesPanel.swift:174` — “Commit the changes, and push them if you like”
- `KuvoCode/Views/Session/ChangesPanel.swift:278` — “Commit Changes”
- `KuvoCode/Views/Session/ChangesPanel.swift:280` — “Message”
- `KuvoCode/Views/Session/ChangesPanel.swift:293` — “Have the session's model write a message from the changes”
- `KuvoCode/Views/Session/ChangesPanel.swift:300` — “Push afterwards”
- `KuvoCode/Views/Session/ChangesPanel.swift:311` — “Cancel”
- `KuvoCode/Views/Session/ChangesPanel.swift:389` — “Merge into \(tree.base ?? ”
- `KuvoCode/Views/Session/ChangesPanel.swift:391` — “Create Pull Request”
- `KuvoCode/Views/Session/ChangesPanel.swift:395` — “Show Worktree in Finder”
- `KuvoCode/Views/Session/ChangesPanel.swift:412` — “Ask the Agent to Fix It”
- `KuvoCode/Views/Session/ChangesPanel.swift:415` — “Cancel”
- `KuvoCode/Views/Session/ChangesPanel.swift:418` — “Archive Session and Remove Worktree”
- `KuvoCode/Views/Session/ChangesPanel.swift:424` — “Keep”
- `KuvoCode/Views/Session/ChangesPanel.swift:426` — “OK”
- `KuvoCode/Views/Session/ChangesPanel.swift:466` — “Couldn’t Merge”
- `KuvoCode/Views/Session/ChangesPanel.swift:506` — “Couldn’t Push”
- `KuvoCode/Views/Session/ChangesPanel.swift:575` — “Open in Editor”
- `KuvoCode/Views/Session/ChangesPanel.swift:585` — “More”
- `KuvoCode/Views/Session/ChangesPanel.swift:602` — “Discard”
- `KuvoCode/Views/Session/ChangesPanel.swift:603` — “Cancel”
- `KuvoCode/Views/Session/ChangesPanel.swift:620` — “\(folderText)\(nameText)”
- `KuvoCode/Views/Session/ChangesPanel.swift:639` — “Open With”
- `KuvoCode/Views/Session/ChangesPanel.swift:754` — “Couldn't read this picture”
- `KuvoCode/Views/Session/ChangesPanel.swift:783` — “\(rep.pixelsWide) × \(rep.pixelsHigh)”
- `KuvoCode/Views/Session/ChangesPanel.swift:872` — “\(count) unmodified lines”
- `KuvoCode/Views/Session/ChangesPanel.swift:89` — “Folder”
- `KuvoCode/Views/Session/ChangesPanel.swift:922` — “Comment on This Line”
- `KuvoCode/Views/Session/Composer.swift:107` — “Your comments on the changes go with this message.”
- `KuvoCode/Views/Session/Composer.swift:231` — “Attach Files… You can also drop files here, or paste them.”
- `KuvoCode/Views/Session/Composer.swift:333` — “Send”
- `KuvoCode/Views/Session/Composer.swift:334` — “Queue for After This Run”
- `KuvoCode/Views/Session/Composer.swift:455` — “Stop”
- `KuvoCode/Views/Session/Composer.swift:467` — “Send”
- `KuvoCode/Views/Session/Composer.swift:587` — “↑ ↓ to choose, Return or Tab to insert, Escape to close”
- `KuvoCode/Views/Session/Composer.swift:619` — “↑ ↓ to choose, Return to run, Tab to add to it, Escape to close”
- `KuvoCode/Views/Session/Composer.swift:683` — “Shell”
- `KuvoCode/Views/Session/Composer.swift:685` — “runs \(place)”
- `KuvoCode/Views/Session/Composer.swift:694` — “Runs the command in the project’s folder, without the agent. It and its output join the conversation, and the agent sees them with your next message. Delete the ! to talk to the agent again.”
- `KuvoCode/Views/Session/Composer.swift:96` — “Discard Comments”
- `KuvoCode/Views/Session/ComposerMenus.swift:100` — “Mode”
- `KuvoCode/Views/Session/ComposerMenus.swift:143` — “workplace”
- `KuvoCode/Views/Session/ComposerMenus.swift:153` — “Where the session works: in the project's folder, or in a worktree of its own”
- `KuvoCode/Views/Session/ComposerMenus.swift:158` — “Works in the project's folder”
- `KuvoCode/Views/Session/ComposerMenus.swift:161` — “Works in a copy on a branch of its own”
- `KuvoCode/Views/Session/ComposerMenus.swift:205` — “Model and effort”
- `KuvoCode/Views/Session/ComposerMenus.swift:79` — “mode”
- `KuvoCode/Views/Session/ComposerMenus.swift:95` — “Mode and tool permissions (⌥⌘1 Build, ⌥⌘2 Plan)”
- `KuvoCode/Views/Session/ContextGauge.swift:111` — “\(used.compactTokens) / \(limit.compactTokens)”
- `KuvoCode/Views/Session/ContextGauge.swift:112` — “What the model sees of this session. When it fills up, the conversation is summarized to make room.”
- `KuvoCode/Views/Session/ContextGauge.swift:116` — “Summarize Now”
- `KuvoCode/Views/Session/ContextGauge.swift:119` — “Summarize the conversation so far, to free up the context window”
- `KuvoCode/Views/Session/ContextGauge.swift:126` — “Usage limits · ”
- `KuvoCode/Views/Session/ContextGauge.swift:129` — “Open Usage”
- `KuvoCode/Views/Session/ContextGauge.swift:132` — “Open the usage panel in the menu bar”
- `KuvoCode/Views/Session/ContextGauge.swift:147` — “Cost so far”
- `KuvoCode/Views/Session/ContextGauge.swift:37` — “Context window: \(used.compactTokens) of \(limit.compactTokens) tokens”
- `KuvoCode/Views/Session/ConversationScroll.swift:183` — “Scroll to the End”
- `KuvoCode/Views/Session/DiffView.swift:63` — “\(file.lines.count - maxLines) more lines”
- `KuvoCode/Views/Session/FileLinks.swift:47` — “api/README.md”
- `KuvoCode/Views/Session/FileLinks.swift:87` — “App.swift:42”
- `KuvoCode/Views/Session/FindBar.swift:270` — “Find in Conversation”
- `KuvoCode/Views/Session/FindBar.swift:278` — “Done”
- `KuvoCode/Views/Session/FindBar.swift:280` — “Done (Esc)”
- `KuvoCode/Views/Session/FindBar.swift:287` — “Previous”
- `KuvoCode/Views/Session/FindBar.swift:290` — “Previous Result (⇧Return)”
- `KuvoCode/Views/Session/FindBar.swift:291` — “Next”
- `KuvoCode/Views/Session/FindBar.swift:294` — “Next Result (Return)”
- `KuvoCode/Views/Session/FindBar.swift:299` — “Search Earlier”
- `KuvoCode/Views/Session/FindBar.swift:303` — “Read the rest of the conversation, from its start, and look in it too”
- `KuvoCode/Views/Session/ModelPicker.swift:110` — “Select model”
- `KuvoCode/Views/Session/ModelPicker.swift:155` — “Back”
- `KuvoCode/Views/Session/ModelPicker.swift:159` — “Search models”
- `KuvoCode/Views/Session/ModelPicker.swift:185` — “No models match “\(query)”.”
- `KuvoCode/Views/Session/ModelPicker.swift:289` — “Choose another model”
- `KuvoCode/Views/Session/ModelPicker.swift:310` — “Back to the model's default effort”
- `KuvoCode/Views/Session/QueueDock.swift:101` — “Remove”
- `KuvoCode/Views/Session/QueueDock.swift:104` — “Send Now”
- `KuvoCode/Views/Session/QueueDock.swift:106` — “Edit”
- `KuvoCode/Views/Session/QueueDock.swift:108` — “Remove”
- `KuvoCode/Views/Session/QueueDock.swift:126` — “Steer”
- `KuvoCode/Views/Session/QueueDock.swift:127` — “Send Now”
- `KuvoCode/Views/Session/QueueDock.swift:128` — “Edit”
- `KuvoCode/Views/Session/QueueDock.swift:130` — “Remove”
- `KuvoCode/Views/Session/QueueDock.swift:26` — “Paused”
- `KuvoCode/Views/Session/QueueDock.swift:29` — “Resume”
- `KuvoCode/Views/Session/QueueDock.swift:31` — “Send the waiting messages, one after another”
- `KuvoCode/Views/Session/QueueDock.swift:87` — “Sending…”
- `KuvoCode/Views/Session/QueueDock.swift:99` — “Remove”
- `KuvoCode/Views/Session/QuoteList.swift:34` — “\(quotes.count) quotes”
- `KuvoCode/Views/Session/QuoteList.swift:38` — “Remove All”
- `KuvoCode/Views/Session/QuoteList.swift:51` — “Your answer to this…”
- `KuvoCode/Views/Session/SelectionMenu.swift:54` — “Add to Chat”
- `KuvoCode/Views/Session/SelectionMenu.swift:56` — “Reply to this part: it goes over the composer, to answer under”
- `KuvoCode/Views/Session/SelectionMenu.swift:62` — “Copy”
- `KuvoCode/Views/Session/SessionView.swift:48` — “Something went wrong”
- `KuvoCode/Views/Session/SessionView.swift:59` — “Dismiss”
- `KuvoCode/Views/Session/ShellRow.swift:43` — “Only the end is kept; it printed more.”
- `KuvoCode/Views/Session/ShellRow.swift:64` — “Copy Command”
- `KuvoCode/Views/Session/ShellRow.swift:65` — “Copy Output”
- `KuvoCode/Views/Session/ShellRow.swift:83` — “exit \(exit)”
- `KuvoCode/Views/Session/ToolCallView.swift:108` — “Stopped”
- `KuvoCode/Views/Session/ToolCallView.swift:132` — “Working in the background”
- `KuvoCode/Views/Session/ToolCallView.swift:473` — “Working…”
- `KuvoCode/Views/Session/ToolCallView.swift:54` — “Show it in the panel”
- `KuvoCode/Views/Session/ToolCallView.swift:61` — “Open in Panel”
- `KuvoCode/Views/Session/ToolCallView.swift:63` — “Open in Panel”
- `KuvoCode/Views/Session/ToolCallView.swift:64` — “Show in Finder”
- `KuvoCode/Views/Session/ToolCallView.swift:67` — “Copy Path”
- `KuvoCode/Views/Session/TranscriptView.swift:1038` — “Updated its memory”
- `KuvoCode/Views/Session/TranscriptView.swift:1042` — “Show \(bot.name)'s memory in the panel”
- `KuvoCode/Views/Session/TranscriptView.swift:1052` — “Edited ”
- `KuvoCode/Views/Session/TranscriptView.swift:1056` — “What this turn changed”
- `KuvoCode/Views/Session/TranscriptView.swift:1075` — “Written”
- `KuvoCode/Views/Session/TranscriptView.swift:1085` — “Open in the Panel”
- `KuvoCode/Views/Session/TranscriptView.swift:1089` — “Show All Changes”
- `KuvoCode/Views/Session/TranscriptView.swift:1220` — “To \(Text(address?.name ?? to).fontWeight(.semibold).foregroundStyle(.primary))”
- `KuvoCode/Views/Session/TranscriptView.swift:1224` — “Waiting for its answer”
- `KuvoCode/Views/Session/TranscriptView.swift:1228` — “Didn't go”
- `KuvoCode/Views/Session/TranscriptView.swift:1233` — “Open”
- `KuvoCode/Views/Session/TranscriptView.swift:1235` — “Open \(address?.name ?? to)'s conversation”
- `KuvoCode/Views/Session/TranscriptView.swift:1245` — “\(Text(address?.name ?? to).fontWeight(.semibold)) answered”
- `KuvoCode/Views/Session/TranscriptView.swift:1351` — “From \(Text(from).fontWeight(.semibold).foregroundStyle(.primary))”
- `KuvoCode/Views/Session/TranscriptView.swift:1358` — “Open”
- `KuvoCode/Views/Session/TranscriptView.swift:1360` — “Open \(from)'s conversation”
- `KuvoCode/Views/Session/TranscriptView.swift:1385` — “Work from \(Text(chat).fontWeight(.semibold).foregroundStyle(.primary))”
- `KuvoCode/Views/Session/TranscriptView.swift:1392` — “Open”
- `KuvoCode/Views/Session/TranscriptView.swift:1394` — “Open \(chat)”
- `KuvoCode/Views/Session/TranscriptView.swift:1414` — “\(Text(”
- `KuvoCode/Views/Session/TranscriptView.swift:1429` — “A wake-up the bot scheduled for itself”
- `KuvoCode/Views/Session/TranscriptView.swift:1468` — “Start Its Job”
- `KuvoCode/Views/Session/TranscriptView.swift:1472` — “\(bot.name) reads its job, asks you for anything it needs, and starts”
- `KuvoCode/Views/Session/TranscriptView.swift:45` — “Earlier messages…”
- `KuvoCode/Views/Session/TranscriptView.swift:557` — “Cancel”
- `KuvoCode/Views/Session/TranscriptView.swift:584` — “Undid ”
- `KuvoCode/Views/Session/TranscriptView.swift:585` — “Redo”
- `KuvoCode/Views/Session/TranscriptView.swift:596` — “Sending a message makes the undo final”
- `KuvoCode/Views/Session/TranscriptView.swift:786` — “Retrying (attempt \(retry.attempt)): \(retry.error.message)”
- `KuvoCode/Views/Session/TranscriptView.swift:949` — “Try Again”
- `KuvoCode/Views/Session/TranscriptView.swift:952` — “Send your last message again”
- `KuvoCode/Views/Session/TranscriptView.swift:962` — “Stopped”
- `KuvoCode/Views/Session/TranscriptView.swift:988` — “Build It”
- `KuvoCode/Views/Session/TranscriptView.swift:991` — “Switch to Build mode and have the agent carry out this plan”
- `KuvoCode/Views/Session/WidgetView.swift:146` — “Open Larger”
- `KuvoCode/Views/Session/WidgetView.swift:235` — “Back to the Conversation”
- `KuvoCode/Views/Session/WidgetView.swift:249` — “Back to the Conversation”
- `KuvoCode/Views/Session/WidgetView.swift:301` — “kuvo”
- `KuvoCode/Views/Session/WidgetView.swift:304` — “kuvo”
- `KuvoCode/Views/Session/YourMessage.swift:66` — “Copy”
- `KuvoCode/Views/Session/YourMessage.swift:72` — “New Session From Here”
- `KuvoCode/Views/Session/YourMessage.swift:75` — “Undo From Here…”
- `KuvoCode/Views/Session/YourMessage.swift:83` — “Copy”
- `KuvoCode/Views/Session/YourMessage.swift:84` — “New Session From Here”
- `KuvoCode/Views/Session/YourMessage.swift:85` — “Undo From Here…”
- `KuvoCode/Views/Session/YourMessage.swift:88` — “Undo”
- `KuvoCode/Views/Session/YourMessage.swift:89` — “Cancel”
- `KuvoCode/Views/Settings/AgentsSettings.swift:105` — “Imported”
- `KuvoCode/Views/Settings/AgentsSettings.swift:109` — “Import”
- `KuvoCode/Views/Settings/AgentsSettings.swift:114` — “From Claude Code”
- `KuvoCode/Views/Settings/AgentsSettings.swift:116` — “Agents in ~/.claude/agents, brought over as subagents with their description and instructions. They use the session's model and the permissions here, not the tools and model Claude Code gives them.”
- `KuvoCode/Views/Settings/AgentsSettings.swift:223` — “Name”
- `KuvoCode/Views/Settings/AgentsSettings.swift:223` — “reviewer”
- `KuvoCode/Views/Settings/AgentsSettings.swift:231` — “A short name without spaces. It's how the agent is chosen.”
- `KuvoCode/Views/Settings/AgentsSettings.swift:242` — “Description”
- `KuvoCode/Views/Settings/AgentsSettings.swift:243` — “Use as”
- `KuvoCode/Views/Settings/AgentsSettings.swift:251` — “Model”
- `KuvoCode/Views/Settings/AgentsSettings.swift:252` — “Most steps per message”
- `KuvoCode/Views/Settings/AgentsSettings.swift:252` — “No limit”
- `KuvoCode/Views/Settings/AgentsSettings.swift:253` — “Use this agent”
- `KuvoCode/Views/Settings/AgentsSettings.swift:261` — “Instructions”
- `KuvoCode/Views/Settings/AgentsSettings.swift:271` — “Permissions”
- `KuvoCode/Views/Settings/AgentsSettings.swift:273` — “Added after the ones in Settings › Permissions, so these win for this agent.”
- `KuvoCode/Views/Settings/AgentsSettings.swift:45` — “Mode for new sessions”
- `KuvoCode/Views/Settings/AgentsSettings.swift:46` — “Build”
- `KuvoCode/Views/Settings/AgentsSettings.swift:49` — “Model for new sessions”
- `KuvoCode/Views/Settings/AgentsSettings.swift:50` — “Model for session titles”
- `KuvoCode/Views/Settings/AgentsSettings.swift:52` — “New sessions use the model you picked last; this one is for when there's none. A small, fast model is enough for titles.”
- `KuvoCode/Views/Settings/AgentsSettings.swift:68` — “Off”
- `KuvoCode/Views/Settings/AgentsSettings.swift:79` — “Edit…”
- `KuvoCode/Views/Settings/AgentsSettings.swift:82` — “New Agent…”
- `KuvoCode/Views/Settings/AgentsSettings.swift:84` — “Agents”
- `KuvoCode/Views/Settings/AgentsSettings.swift:86` — “Modes are the agents you pick in the composer. Subagents are ones the agent hands part of a task to.”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:16` — “Mode”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:227` — “Custom Color…”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:258` — “Add a farewell function next to greet.”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:264` — “ to hello.py, with a test for each function. All 4 tests pass.”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:264` — “Added ”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:264` — “farewell(name)”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:30` — “Accent”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:34` — “Window”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:41` — “Window”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:45` — “Colors”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:50` — “Text size”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:57` — “Text size”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:58` — “Messages, replies and the composer.”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:63` — “Typeface”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:64` — “Code always stays monospaced.”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:67` — “Agent’s steps”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:74` — “Agent’s steps”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:79` — “Messages”
- `KuvoCode/Views/Settings/AppearanceSettings.swift:85` — “Reset to Defaults”
- `KuvoCode/Views/Settings/ArchivedSessionsSettings.swift:27` — “Search archived sessions”
- `KuvoCode/Views/Settings/ArchivedSessionsSettings.swift:31` — “Delete All…”
- `KuvoCode/Views/Settings/ArchivedSessionsSettings.swift:46` — “Unarchive”
- `KuvoCode/Views/Settings/ArchivedSessionsSettings.swift:53` — “Delete”
- `KuvoCode/Views/Settings/ArchivedSessionsSettings.swift:71` — “Delete”
- `KuvoCode/Views/Settings/ArchivedSessionsSettings.swift:76` — “Their messages and undo snapshots go too. This can’t be undone.”
- `KuvoCode/Views/Settings/BrowserSettings.swift:105` — “Remove All”
- `KuvoCode/Views/Settings/BrowserSettings.swift:107` — “You’ll be signed out of every site in the panel’s browser. Your other browsers aren’t affected.”
- `KuvoCode/Views/Settings/BrowserSettings.swift:18` — “Start a project’s panel with”
- `KuvoCode/Views/Settings/BrowserSettings.swift:19` — “The first time you open the panel in a project.”
- `KuvoCode/Views/Settings/BrowserSettings.swift:22` — “Show the panel when the agent browses”
- `KuvoCode/Views/Settings/BrowserSettings.swift:23` — “So you can watch it, and step in.”
- `KuvoCode/Views/Settings/BrowserSettings.swift:26` — “New Tab Page”
- `KuvoCode/Views/Settings/BrowserSettings.swift:28` — “Tools”
- `KuvoCode/Views/Settings/BrowserSettings.swift:29` — “Changes, Terminal and Files, as tiles to open, and a way here.”
- `KuvoCode/Views/Settings/BrowserSettings.swift:32` — “Suggested sites”
- `KuvoCode/Views/Settings/BrowserSettings.swift:33` — “The sites you visit most in the panel’s browser.”
- `KuvoCode/Views/Settings/BrowserSettings.swift:35` — “Number of sites”
- `KuvoCode/Views/Settings/BrowserSettings.swift:36` — “\($0)”
- `KuvoCode/Views/Settings/BrowserSettings.swift:60` — “Search engine”
- `KuvoCode/Views/Settings/BrowserSettings.swift:61` — “For anything you type in the address field that isn’t an address.”
- `KuvoCode/Views/Settings/BrowserSettings.swift:64` — “Clear”
- `KuvoCode/Views/Settings/BrowserSettings.swift:67` — “Browsing history”
- `KuvoCode/Views/Settings/BrowserSettings.swift:76` — “None yet.”
- `KuvoCode/Views/Settings/BrowserSettings.swift:78` — “Search sites”
- `KuvoCode/Views/Settings/BrowserSettings.swift:81` — “Remove”
- `KuvoCode/Views/Settings/BrowserSettings.swift:93` — “Website Data”
- `KuvoCode/Views/Settings/BrowserSettings.swift:95` — “Remove All…”
- `KuvoCode/Views/Settings/BrowserSettings.swift:99` — “Sign-ins, cookies and what sites store, kept apart from your other browsers. Removing a site’s data signs you out of it.”
- `KuvoCode/Views/Settings/CommandsSettings.swift:176` — “Delete”
- `KuvoCode/Views/Settings/CommandsSettings.swift:180` — “It's removed from the engine's settings.”
- `KuvoCode/Views/Settings/CommandsSettings.swift:188` — “Name”
- `KuvoCode/Views/Settings/CommandsSettings.swift:188` — “test”
- `KuvoCode/Views/Settings/CommandsSettings.swift:196` — “A short name without spaces: you'll type / and this name.”
- `KuvoCode/Views/Settings/CommandsSettings.swift:205` — “Description”
- `KuvoCode/Views/Settings/CommandsSettings.swift:205` — “Shown in the list when you type /”
- `KuvoCode/Views/Settings/CommandsSettings.swift:206` — “Agent”
- `KuvoCode/Views/Settings/CommandsSettings.swift:207` — “The session's agent”
- `KuvoCode/Views/Settings/CommandsSettings.swift:210` — “Model”
- `KuvoCode/Views/Settings/CommandsSettings.swift:215` — “Run as a subagent”
- `KuvoCode/Views/Settings/CommandsSettings.swift:216` — “In the background, without filling up the conversation.”
- `KuvoCode/Views/Settings/CommandsSettings.swift:222` — “Prompt”
- `KuvoCode/Views/Settings/CommandsSettings.swift:25` — “None yet.”
- `KuvoCode/Views/Settings/CommandsSettings.swift:40` — “Edit…”
- `KuvoCode/Views/Settings/CommandsSettings.swift:43` — “New Command…”
- `KuvoCode/Views/Settings/CommandsSettings.swift:45` — “Your Commands”
- `KuvoCode/Views/Settings/CommandsSettings.swift:47` — “Type / and a command's name at the start of a message to run it. What you type after the name fills in $ARGUMENTS.”
- `KuvoCode/Views/Settings/CommandsSettings.swift:68` — “Imported”
- `KuvoCode/Views/Settings/CommandsSettings.swift:72` — “Import”
- `KuvoCode/Views/Settings/CommandsSettings.swift:80` — “From Claude Code”
- `KuvoCode/Views/Settings/CommandsSettings.swift:82` — “Commands in ~/.claude/commands. Their prompts come over as they are.”
- `KuvoCode/Views/Settings/CommandsSettings.swift:88` — “Also Available”
- `KuvoCode/Views/Settings/EngineSettings.swift:102` — “Off”
- `KuvoCode/Views/Settings/EngineSettings.swift:110` — “Added”
- `KuvoCode/Views/Settings/EngineSettings.swift:111` — “Remove”
- `KuvoCode/Views/Settings/EngineSettings.swift:115` — “From \(variable.name ?? ”
- `KuvoCode/Views/Settings/EngineSettings.swift:117` — “Add API Key…”
- `KuvoCode/Views/Settings/EngineSettings.swift:122` — “Web Search”
- `KuvoCode/Views/Settings/EngineSettings.swift:124` — “Each search service needs its own API key. With none chosen, the agent can't search the web.”
- `KuvoCode/Views/Settings/EngineSettings.swift:128` — “Limits”
- `KuvoCode/Views/Settings/EngineSettings.swift:129` — “Lines of tool output the agent keeps”
- `KuvoCode/Views/Settings/EngineSettings.swift:130` — “Bytes of tool output the agent keeps”
- `KuvoCode/Views/Settings/EngineSettings.swift:131` — “Shrink large images the agent reads”
- `KuvoCode/Views/Settings/EngineSettings.swift:132` — “Largest image width, in pixels”
- `KuvoCode/Views/Settings/EngineSettings.swift:133` — “Largest image height, in pixels”
- `KuvoCode/Views/Settings/EngineSettings.swift:137` — “A pattern, like dist/** or *.log”
- `KuvoCode/Views/Settings/EngineSettings.swift:139` — “Files the Engine Doesn't Watch”
- `KuvoCode/Views/Settings/EngineSettings.swift:141` — “Changes to these don't reach the agent while it works.”
- `KuvoCode/Views/Settings/EngineSettings.swift:146` — “An npm package, like opencode-wakatime”
- `KuvoCode/Views/Settings/EngineSettings.swift:148` — “\(plugin.id): \(plugin.state.error ?? ”
- `KuvoCode/Views/Settings/EngineSettings.swift:152` — “Plugins”
- `KuvoCode/Views/Settings/EngineSettings.swift:154` — “Plugins add tools and change how the engine works. They run code on your Mac, so add only ones you trust.”
- `KuvoCode/Views/Settings/EngineSettings.swift:161` — “Open”
- `KuvoCode/Views/Settings/EngineSettings.swift:163` — “Show in Finder”
- `KuvoCode/Views/Settings/EngineSettings.swift:168` — “Everything in Settings is saved in this file, in opencode's format, and the engine picks up changes as you make them. A project's own opencode.json takes precedence for that project.”
- `KuvoCode/Views/Settings/EngineSettings.swift:26` — “Stopped”
- `KuvoCode/Views/Settings/EngineSettings.swift:27` — “Starting…”
- `KuvoCode/Views/Settings/EngineSettings.swift:29` — “Restart”
- `KuvoCode/Views/Settings/EngineSettings.swift:33` — “Show in Finder”
- `KuvoCode/Views/Settings/EngineSettings.swift:36` — “Sessions, accounts and settings are kept in the data folder, separate from any opencode you have installed.”
- `KuvoCode/Views/Settings/EngineSettings.swift:41` — “Behavior”
- `KuvoCode/Views/Settings/EngineSettings.swift:43` — “Summarize long conversations automatically”
- `KuvoCode/Views/Settings/EngineSettings.swift:44` — “Before the context window fills up, older messages are replaced by a summary.”
- `KuvoCode/Views/Settings/EngineSettings.swift:49` — “Format files after the agent changes them”
- `KuvoCode/Views/Settings/EngineSettings.swift:58` — “Keep recent sessions warm”
- `KuvoCode/Views/Settings/EngineSettings.swift:65` — “Keep snapshots of files”
- `KuvoCode/Views/Settings/EngineSettings.swift:66` — “Undo From Here needs them to put files back.”
- `KuvoCode/Views/Settings/EngineSettings.swift:68` — “Shell”
- `KuvoCode/Views/Settings/EngineSettings.swift:69` — “Your login shell”
- `KuvoCode/Views/Settings/EngineSettings.swift:71` — “\(shell.name) (\(shell.path))”
- `KuvoCode/Views/Settings/EngineSettings.swift:74` — “Subagents can start subagents”
- `KuvoCode/Views/Settings/EngineSettings.swift:78` — “No”
- `KuvoCode/Views/Settings/EngineSettings.swift:79` — “Up to \($0) levels”
- `KuvoCode/Views/Settings/EngineSettings.swift:84` — “Search service”
- `KuvoCode/Views/Settings/EngineSettings.swift:98` — “None”
- `KuvoCode/Views/Settings/EngineSettings.swift:99` — “Any connected service”
- `KuvoCode/Views/Settings/GeneralSettings.swift:140` — “These aren’t in Kuvo Code yet; what it has already stays as it is. API keys are copied into Kuvo Code’s engine, and skills are found where opencode keeps them. The engine starts again to use them.”
- `KuvoCode/Views/Settings/GeneralSettings.swift:142` — “Sign in to \(ListFormatter.localizedString(byJoining: plan.signIns.map(names))) again in Settings › Accounts: a sign-in copied over would be refreshed by both apps, which can sign both out.”
- `KuvoCode/Views/Settings/GeneralSettings.swift:164` — “Sessions”
- `KuvoCode/Views/Settings/GeneralSettings.swift:165` — “When a session finishes or needs your answer while you’re in another app. A permission request can be answered from its notification.”
- `KuvoCode/Views/Settings/GeneralSettings.swift:168` — “Play a sound”
- `KuvoCode/Views/Settings/GeneralSettings.swift:169` — “With each notification.”
- `KuvoCode/Views/Settings/GeneralSettings.swift:173` — “Count on the Dock icon”
- `KuvoCode/Views/Settings/GeneralSettings.swift:174` — “The sessions that finished while you were away, or wait for you.”
- `KuvoCode/Views/Settings/GeneralSettings.swift:177` — “macOS asks the first time there’s something to tell. To change how they look, or to allow them again, use System Settings › Notifications.”
- `KuvoCode/Views/Settings/GeneralSettings.swift:182` — “Open…”
- `KuvoCode/Views/Settings/GeneralSettings.swift:200` — “Share anonymous usage”
- `KuvoCode/Views/Settings/GeneralSettings.swift:201` — “Which features you use and how often, and what kind of trouble you run into, with the app and macOS versions. Never your code, prompts, files or accounts.”
- `KuvoCode/Views/Settings/GeneralSettings.swift:204` — “Privacy and Data”
- `KuvoCode/Views/Settings/GeneralSettings.swift:209` — “Storage…”
- `KuvoCode/Views/Settings/GeneralSettings.swift:211` — “Sessions and accounts”
- `KuvoCode/Views/Settings/GeneralSettings.swift:212` — “Kept on this Mac, in Kuvo Code’s own folder. Messages go only to the model providers you choose.”
- `KuvoCode/Views/Settings/GeneralSettings.swift:215` — “Browser…”
- `KuvoCode/Views/Settings/GeneralSettings.swift:217` — “The panel’s browser”
- `KuvoCode/Views/Settings/GeneralSettings.swift:218` — “Its sign-ins, cookies and history stay apart from your other browsers.”
- `KuvoCode/Views/Settings/GeneralSettings.swift:22` — “Window”
- `KuvoCode/Views/Settings/GeneralSettings.swift:221` — “Passwords…”
- `KuvoCode/Views/Settings/GeneralSettings.swift:223` — “Saved passwords”
- `KuvoCode/Views/Settings/GeneralSettings.swift:224` — “In your Keychain, filled in only when you ask.”
- `KuvoCode/Views/Settings/GeneralSettings.swift:227` — “On This Mac”
- `KuvoCode/Views/Settings/GeneralSettings.swift:239` — “Open…”
- `KuvoCode/Views/Settings/GeneralSettings.swift:24` — “Show the tab bar”
- `KuvoCode/Views/Settings/GeneralSettings.swift:241` — “Usage settings”
- `KuvoCode/Views/Settings/GeneralSettings.swift:242` — “Plan limits, pace and spend for the accounts you connect, like GitHub Copilot, ChatGPT and OpenRouter, live in the menu bar. They count what you use anywhere, not only here.”
- `KuvoCode/Views/Settings/GeneralSettings.swift:245` — “Choose…”
- `KuvoCode/Views/Settings/GeneralSettings.swift:247` — “Providers”
- `KuvoCode/Views/Settings/GeneralSettings.swift:248` — “Which accounts the menu bar shows, and in what order.”
- `KuvoCode/Views/Settings/GeneralSettings.swift:25` — “The row at the top, with the project, its branch and your sessions as tabs. Without it, switch sessions in the sidebar or with ⌘K.”
- `KuvoCode/Views/Settings/GeneralSettings.swift:251` — “Usage tracking is a fork of OpenUsage by Robin Ebers (MIT). It isn’t affiliated with or endorsed by OpenUsage.”
- `KuvoCode/Views/Settings/GeneralSettings.swift:28` — “One tab in two halves”
- `KuvoCode/Views/Settings/GeneralSettings.swift:29` — “One tab with both names”
- `KuvoCode/Views/Settings/GeneralSettings.swift:30` — “Two tabs joined”
- `KuvoCode/Views/Settings/GeneralSettings.swift:32` — “Two sessions side by side”
- `KuvoCode/Views/Settings/GeneralSettings.swift:33` — “How they show in the tab bar.”
- `KuvoCode/Views/Settings/GeneralSettings.swift:37` — “While Agents Work”
- `KuvoCode/Views/Settings/GeneralSettings.swift:39` — “Keep this Mac awake”
- `KuvoCode/Views/Settings/GeneralSettings.swift:40` — “It doesn’t go to sleep on its own while an agent or a bot works on it; the display still can. Sessions on your machines run there either way.”
- `KuvoCode/Views/Settings/GeneralSettings.swift:44` — “Files”
- `KuvoCode/Views/Settings/GeneralSettings.swift:46` — “Each file’s default app”
- `KuvoCode/Views/Settings/GeneralSettings.swift:52` — “Open code and text in”
- `KuvoCode/Views/Settings/GeneralSettings.swift:53` — “For Open in the panel’s files and Open in Editor in Changes. Pictures and other files open in their own apps.”
- `KuvoCode/Views/Settings/GeneralSettings.swift:57` — “opencode”
- `KuvoCode/Views/Settings/GeneralSettings.swift:59` — “Bring Over…”
- `KuvoCode/Views/Settings/GeneralSettings.swift:62` — “Bring over your opencode setup”
- `KuvoCode/Views/Settings/GeneralSettings.swift:67` — “Updates”
- `KuvoCode/Views/Settings/GeneralSettings.swift:70` — “Check for updates automatically”
- `KuvoCode/Views/Settings/GeneralSettings.swift:74` — “Check Now”
- `KuvoCode/Views/Settings/GeneralSettings.swift:78` — “Version \(AppInfo.version)”
- `KuvoCode/Views/Settings/GitSettings.swift:105` — “Show in Finder”
- `KuvoCode/Views/Settings/GitSettings.swift:106` — “Remove…”
- `KuvoCode/Views/Settings/GitSettings.swift:110` — “\(workspace.projectName(item.tree.project)) · \(sessions.count.counting(”
- `KuvoCode/Views/Settings/GitSettings.swift:114` — “Worktrees”
- `KuvoCode/Views/Settings/GitSettings.swift:119` — “Removing one deletes its folder and anything in it that isn’t committed. Its branch stays if it isn’t merged yet.”
- `KuvoCode/Views/Settings/GitSettings.swift:131` — “Remove”
- `KuvoCode/Views/Settings/GitSettings.swift:138` — “Its folder and anything in it that isn’t committed are deleted. Its sessions stay, without a folder to run in.”
- `KuvoCode/Views/Settings/GitSettings.swift:15` — “Branch prefix”
- `KuvoCode/Views/Settings/GitSettings.swift:20` — “Branch prefix”
- `KuvoCode/Views/Settings/GitSettings.swift:21` — “What a session’s own branch starts with, in a worktree. It’s named after the session once it has a title.”
- `KuvoCode/Views/Settings/GitSettings.swift:24` — “Branches”
- `KuvoCode/Views/Settings/GitSettings.swift:28` — “For example: Start with the area changed, like “ui: …”, and never mention tickets.”
- `KuvoCode/Views/Settings/GitSettings.swift:30` — “Commit Messages”
- `KuvoCode/Views/Settings/GitSettings.swift:32` — “Added when Suggest a Message in Changes asks the model for one.”
- `KuvoCode/Views/Settings/GitSettings.swift:37` — “For example: Add a Testing section, and link the issue if the branch names one.”
- `KuvoCode/Views/Settings/GitSettings.swift:39` — “Pull Requests”
- `KuvoCode/Views/Settings/GitSettings.swift:41` — “Added when Create Pull Request writes the title and description.”
- `KuvoCode/Views/Settings/GitSettings.swift:54` — “Instructions”
- `KuvoCode/Views/Settings/GitSettings.swift:79` — “Default”
- `KuvoCode/Views/Settings/GitSettings.swift:79` — “Worktrees folder”
- `KuvoCode/Views/Settings/GitSettings.swift:81` — “Where new worktrees go. A relative path starts at the project’s folder.”
- `KuvoCode/Views/Settings/GitSettings.swift:87` — “None yet. Choose Worktree in a new session’s composer to give it one.”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:129` — “Sign in to \(service.title) in the browser the agent and your bots use, on this Mac or one of your machines”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:133` — “Add App…”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:135` — “Add Key…”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:137` — “Connect”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:143` — “Sign In…”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:145` — “Try Again”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:149` — “Sign In Again…”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:154` — “Reconnect”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:156` — “Remove…”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:162` — “More”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:177` — “this Mac”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:194` — “this Mac”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:223` — “Just ask”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:223` — “The agent and your bots use \(service.title)'s own tools when you mention it, not its website.”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:225` — “On your machines too”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:225` — “Sessions and bots there use this sign-in, kept in step with this Mac.”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:435` — “Couldn’t save it in your Keychain. Try again, or check Keychain Access.”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:443` — “Where to get one”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:48` — “Remove”
- `KuvoCode/Views/Settings/IntegrationsSettings.swift:50` — “The agent and your bots stop using it, and your sign-in or key goes with it.”
- `KuvoCode/Views/Settings/MachinesSettings.swift:16` — “None yet.”
- `KuvoCode/Views/Settings/MachinesSettings.swift:22` — “Add Machine…”
- `KuvoCode/Views/Settings/MachinesSettings.swift:24` — “Machines”
- `KuvoCode/Views/Settings/MachinesSettings.swift:26` — “Linux servers you reach with SSH, like a home server or a VPS. Their projects open next to this Mac’s, and their sessions run there. Kuvo Code installs its engine in ~/.kuvo-code on each, and stops it when you quit.”
- `KuvoCode/Views/Settings/MachinesSettings.swift:31` — “API keys and a GitHub Copilot sign-in go to your machines’ engines, held in memory there and never written to their disks.”
- `KuvoCode/Views/Settings/MachinesSettings.swift:33` — “\(staysHere.formatted(.list(type: .and))) can’t go, so \(staysHere.count == 1 ? ”
- `KuvoCode/Views/Settings/MachinesSettings.swift:37` — “Accounts”
- `KuvoCode/Views/Settings/MachinesSettings.swift:40` — “Add a Machine”
- `KuvoCode/Views/Settings/MachinesSettings.swift:53` — “Remove”
- `KuvoCode/Views/Settings/MachinesSettings.swift:55` — “Its projects leave the sidebar. Its sessions and the engine stay on the machine, for when you add it again.”
- `KuvoCode/Views/Settings/MachinesSettings.swift:72` — “Disconnect”
- `KuvoCode/Views/Settings/MachinesSettings.swift:78` — “Remove…”
- `KuvoCode/Views/Settings/MCPSettings.swift:152` — “Sign In…”
- `KuvoCode/Views/Settings/MCPSettings.swift:154` — “Try Again”
- `KuvoCode/Views/Settings/MCPSettings.swift:162` — “Edit…”
- `KuvoCode/Views/Settings/MCPSettings.swift:163` — “Turn on \(name)”
- `KuvoCode/Views/Settings/MCPSettings.swift:255` — “To keep a key out of the settings file, write {env:NAME} to use one of your environment variables.”
- `KuvoCode/Views/Settings/MCPSettings.swift:290` — “Remove”
- `KuvoCode/Views/Settings/MCPSettings.swift:294` — “The agent loses its tools.”
- `KuvoCode/Views/Settings/MCPSettings.swift:302` — “github”
- `KuvoCode/Views/Settings/MCPSettings.swift:302` — “Name”
- `KuvoCode/Views/Settings/MCPSettings.swift:310` — “A short name without spaces. The server's tools are named after it.”
- `KuvoCode/Views/Settings/MCPSettings.swift:319` — “Runs”
- `KuvoCode/Views/Settings/MCPSettings.swift:323` — “On this Mac”
- `KuvoCode/Views/Settings/MCPSettings.swift:324` — “On the web”
- `KuvoCode/Views/Settings/MCPSettings.swift:328` — “https://example.com/mcp”
- `KuvoCode/Views/Settings/MCPSettings.swift:328` — “URL”
- `KuvoCode/Views/Settings/MCPSettings.swift:335` — “Sign in when the server asks”
- `KuvoCode/Views/Settings/MCPSettings.swift:342` — “Command”
- `KuvoCode/Views/Settings/MCPSettings.swift:348` — “The project's folder”
- `KuvoCode/Views/Settings/MCPSettings.swift:348` — “Working folder”
- `KuvoCode/Views/Settings/MCPSettings.swift:351` — “Let the agent call its tools from code”
- `KuvoCode/Views/Settings/MCPSettings.swift:352` — “Code Mode: the agent looks up this server's tools and combines several in one step, which keeps each message small for a server with many tools. Smaller models may not find its tools this way.”
- `KuvoCode/Views/Settings/MCPSettings.swift:359` — “Headers”
- `KuvoCode/Views/Settings/MCPSettings.swift:367` — “Environment Variables”
- `KuvoCode/Views/Settings/MCPSettings.swift:42` — “None yet.”
- `KuvoCode/Views/Settings/MCPSettings.swift:48` — “Add Server…”
- `KuvoCode/Views/Settings/MCPSettings.swift:50` — “Servers”
- `KuvoCode/Views/Settings/MCPSettings.swift:52` — “MCP servers give the agent more tools, like a database, an issue tracker or your design files. A server on this Mac runs a command; one on the web is a URL.”
- `KuvoCode/Views/Settings/MCPSettings.swift:74` — “Added”
- `KuvoCode/Views/Settings/MCPSettings.swift:78` — “Add”
- `KuvoCode/Views/Settings/MCPSettings.swift:83` — “Popular Servers”
- `KuvoCode/Views/Settings/MCPSettings.swift:85` — “Each from the company behind it, as listed in the official MCP Registry. One that needs an account asks you to sign in here once it's added.”
- `KuvoCode/Views/Settings/MCPSettings.swift:90` — “30000”
- `KuvoCode/Views/Settings/MCPSettings.swift:90` — “Time to start, in milliseconds”
- `KuvoCode/Views/Settings/MCPSettings.swift:91` — “30000”
- `KuvoCode/Views/Settings/MCPSettings.swift:91` — “Time to list tools, in milliseconds”
- `KuvoCode/Views/Settings/MCPSettings.swift:92` — “43200000”
- `KuvoCode/Views/Settings/MCPSettings.swift:92` — “Time for one tool call, in milliseconds”
- `KuvoCode/Views/Settings/MCPSettings.swift:94` — “Timeouts”
- `KuvoCode/Views/Settings/MCPSettings.swift:96` — “For every server, unless one sets its own.”
- `KuvoCode/Views/Settings/PasswordsSettings.swift:106` — “Never Saved For”
- `KuvoCode/Views/Settings/PasswordsSettings.swift:108` — “Sites you chose Never for. Remove one to be offered again.”
- `KuvoCode/Views/Settings/PasswordsSettings.swift:115` — “Delete”
- `KuvoCode/Views/Settings/PasswordsSettings.swift:121` — “It’s removed from your keychain. The site’s own account isn’t affected.”
- `KuvoCode/Views/Settings/PasswordsSettings.swift:23` — “Offer to save passwords”
- `KuvoCode/Views/Settings/PasswordsSettings.swift:24` — “When you sign in to a site in the panel’s browser. Click the key in its toolbar to fill one in.”
- `KuvoCode/Views/Settings/PasswordsSettings.swift:27` — “Kept in your login keychain, where Keychain Access lists them too. Kuvo Code fills one in only when you ask, or for a site you let agents sign in to on their own, and the agent never sees them.”
- `KuvoCode/Views/Settings/PasswordsSettings.swift:33` — “None yet.”
- `KuvoCode/Views/Settings/PasswordsSettings.swift:35` — “Search passwords”
- `KuvoCode/Views/Settings/PasswordsSettings.swift:59` — “Copy Password”
- `KuvoCode/Views/Settings/PasswordsSettings.swift:66` — “Delete”
- `KuvoCode/Views/Settings/PasswordsSettings.swift:82` — “Remove”
- `KuvoCode/Views/Settings/PasswordsSettings.swift:89` — “Agents Sign In On Their Own”
- `KuvoCode/Views/Settings/PasswordsSettings.swift:91` — “When an agent asks to sign in to one of these, its saved password goes straight into the page without asking you. Remove one to be asked again.”
- `KuvoCode/Views/Settings/PasswordsSettings.swift:99` — “Remove”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:180` — “None yet.”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:210` — “Add Rule”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:234` — “Action”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:240` — “Pattern”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:245` — “Effect”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:258` — “Remove Rule”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:31` — “Default”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:32` — “Allow”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:33` — “Ask First”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:34` — “Don't Allow”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:41` — “When the Agent Wants To”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:43` — “For every session and mode, so Allow here also lets Plan mode do it. A session set to Approve All does what's set to Ask First here without asking, and one set to Ask First still asks; Don't Allow holds for all of them.”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:52` — “Rules”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:61` — “None yet. Choosing Always when the agent asks saves an approval here.”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:67` — “\(Self.title(of: permission.action)): \(permission.resource)”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:84` — “Remove”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:88` — “Always Allowed”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:92` — “Like shell:git push *, openrouter or mcp:github”
- `KuvoCode/Views/Settings/PermissionsSettings.swift:94` — “Blocks”
- `KuvoCode/Views/Settings/PhoneSettings.swift:123` — “Pairing code”
- `KuvoCode/Views/Settings/PhoneSettings.swift:21` — “Scan this with Kuvo Code on your iPhone. It works once, for ten minutes.”
- `KuvoCode/Views/Settings/PhoneSettings.swift:24` — “Done”
- `KuvoCode/Views/Settings/PhoneSettings.swift:29` — “Pair a Phone…”
- `KuvoCode/Views/Settings/PhoneSettings.swift:33` — “Pair”
- `KuvoCode/Views/Settings/PhoneSettings.swift:40` — “None yet.”
- `KuvoCode/Views/Settings/PhoneSettings.swift:50` — “Paired \(phone.added.formatted(.relative(presentation: .named)))”
- `KuvoCode/Views/Settings/PhoneSettings.swift:55` — “Remove…”
- `KuvoCode/Views/Settings/PhoneSettings.swift:59` — “Phones”
- `KuvoCode/Views/Settings/PhoneSettings.swift:61` — “A phone you remove can’t reach this Mac again until you pair it again.”
- `KuvoCode/Views/Settings/PhoneSettings.swift:66` — “Relay”
- `KuvoCode/Views/Settings/PhoneSettings.swift:69` — “Relay”
- `KuvoCode/Views/Settings/PhoneSettings.swift:71` — “Where this Mac and your phones meet. Everything between them is encrypted end to end, so the relay only passes along what it can’t read.”
- `KuvoCode/Views/Settings/PhoneSettings.swift:88` — “Remove”
- `KuvoCode/Views/Settings/PhoneSettings.swift:90` — “It won’t reach this Mac or your machines any more. A machine that’s off drops it when it’s next connected.”
- `KuvoCode/Views/Settings/SettingsControls.swift:188` — “Set up by hand in the settings file.”
- `KuvoCode/Views/Settings/SettingsControls.swift:208` — “Remove”
- `KuvoCode/Views/Settings/SettingsControls.swift:211` — “Add”
- `KuvoCode/Views/Settings/SettingsControls.swift:255` — “Add”
- `KuvoCode/Views/Settings/SettingsControls.swift:313` — “Remove”
- `KuvoCode/Views/Settings/SettingsControls.swift:332` — “The engine's settings file can't be changed here”
- `KuvoCode/Views/Settings/SettingsControls.swift:339` — “Open Settings File”
- `KuvoCode/Views/Settings/SettingsControls.swift:340` — “Try Again”
- `KuvoCode/Views/Settings/SettingsControls.swift:465` — “Clear”
- `KuvoCode/Views/Settings/SettingsDetail.swift:182` — “Cancel”
- `KuvoCode/Views/Settings/SettingsDetail.swift:186` — “Cancel”
- `KuvoCode/Views/Settings/SettingsDetail.swift:234` — “Back to \(back) (Esc)”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:15` — “Command palette”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:16` — “New session”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:17` — “New chat”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:18` — “New project”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:19` — “Open a folder as a project”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:20` — “Open Quickly: a project file by name”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:21` — “Accounts”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:22` — “Settings”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:25` — “Stop the agent (or Esc in the composer)”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:26` — “Find in the conversation”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:27` — “Build mode”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:28` — “Plan mode”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:31` — “Close the session tab”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:32` — “Close the window”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:33` — “Reopen the tab you closed last”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:34` — “Next session tab”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:35` — “Previous session tab”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:36` — “That session tab”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:37` — “The last session tab”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:38` — “Show or hide the sidebar”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:39` — “Show or hide the tab bar”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:42` — “Show or hide the panel”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:43` — “Changes”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:44` — “Files”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:45` — “New terminal”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:46` — “Run the project’s run command”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:47` — “New browser tab”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:48` — “Zoom a machine's page in or out”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:51` — “Send”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:52` — “Queue for after the agent is done”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:53` — “New line”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:54` — “In an empty composer: the last waiting message, then what you sent before”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:55` — “At the start: a command”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:56` — “At the start: run a shell command”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:57` — “Mention a file”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:64` — “Search shortcuts”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:70` — “No shortcut matches “\(search)”.”
- `KuvoCode/Views/Settings/ShortcutsSettings.swift:84` — “To change a menu command’s shortcut, use System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts.”
- `KuvoCode/Views/Settings/SiteSignInPage.swift:109` — “Opening \(service.title) on \(engine.machine.name)…”
- `KuvoCode/Views/Settings/SiteSignInPage.swift:69` — “Sign in to \(service.title)”
- `KuvoCode/Views/Settings/SiteSignInPage.swift:85` — “This Mac”
- `KuvoCode/Views/Settings/SiteSignInPage.swift:89` — “Done”
- `KuvoCode/Views/Settings/SkillsSettings.swift:105` — “Open”
- `KuvoCode/Views/Settings/SkillsSettings.swift:112` — “Get Skills”
- `KuvoCode/Views/Settings/SkillsSettings.swift:114` — “These come from their authors on GitHub, not from Kuvo Code. A skill can include scripts the agent may run, so look at what's in one before you add it.”
- `KuvoCode/Views/Settings/SkillsSettings.swift:119` — “A folder, or the address of a skill catalog”
- `KuvoCode/Views/Settings/SkillsSettings.swift:121` — “Other Places”
- `KuvoCode/Views/Settings/SkillsSettings.swift:123` — “A catalog is a web address with an index.json listing its skills.”
- `KuvoCode/Views/Settings/SkillsSettings.swift:247` — “Name”
- `KuvoCode/Views/Settings/SkillsSettings.swift:247` — “release-notes”
- `KuvoCode/Views/Settings/SkillsSettings.swift:255` — “Use it when”
- `KuvoCode/Views/Settings/SkillsSettings.swift:256` — “Use it when”
- `KuvoCode/Views/Settings/SkillsSettings.swift:256` — “Writing release notes from the commits since the last tag”
- `KuvoCode/Views/Settings/SkillsSettings.swift:261` — “The agent reads this to decide when the skill is needed, and loads the instructions only then.”
- `KuvoCode/Views/Settings/SkillsSettings.swift:269` — “Instructions”
- `KuvoCode/Views/Settings/SkillsSettings.swift:271` — “Markdown. Scripts and other files can go in the skill's folder; mention them here so the agent knows to use them.”
- `KuvoCode/Views/Settings/SkillsSettings.swift:284` — “Delete Skill…”
- `KuvoCode/Views/Settings/SkillsSettings.swift:285` — “Show in Finder”
- `KuvoCode/Views/Settings/SkillsSettings.swift:293` — “Delete”
- `KuvoCode/Views/Settings/SkillsSettings.swift:295` — “Its folder, with anything else in it, goes to the Trash.”
- `KuvoCode/Views/Settings/SkillsSettings.swift:30` — “None yet.”
- `KuvoCode/Views/Settings/SkillsSettings.swift:357` — “) && !$0.hasPrefix(”
- `KuvoCode/Views/Settings/SkillsSettings.swift:416` — “Couldn’t load the skills”
- `KuvoCode/Views/Settings/SkillsSettings.swift:433` — “Filter skills”
- `KuvoCode/Views/Settings/SkillsSettings.swift:448` — “Skills”
- `KuvoCode/Views/Settings/SkillsSettings.swift:451` — “This collection is too big for GitHub to list in full, so some of its skills aren't here.”
- `KuvoCode/Views/Settings/SkillsSettings.swift:469` — “OK”
- `KuvoCode/Views/Settings/SkillsSettings.swift:474` — “Add Skill”
- `KuvoCode/Views/Settings/SkillsSettings.swift:475` — “Cancel”
- `KuvoCode/Views/Settings/SkillsSettings.swift:52` — “Edit…”
- `KuvoCode/Views/Settings/SkillsSettings.swift:536` — “Remove”
- `KuvoCode/Views/Settings/SkillsSettings.swift:539` — “Another \(skill.name) is added, from \(installed.repository)”
- `KuvoCode/Views/Settings/SkillsSettings.swift:545` — “Add”
- `KuvoCode/Views/Settings/SkillsSettings.swift:56` — “Remove”
- `KuvoCode/Views/Settings/SkillsSettings.swift:58` — “Use \(skill.name)”
- `KuvoCode/Views/Settings/SkillsSettings.swift:64` — “New Skill…”
- `KuvoCode/Views/Settings/SkillsSettings.swift:66` — “Skills the Agent Can Use”
- `KuvoCode/Views/Settings/SkillsSettings.swift:68` — “The agent loads a skill when a task calls for it. Skills in ~/.claude/skills and ~/.agents/skills, and in a project's .opencode/skills, are found on their own.”
- `KuvoCode/Views/Settings/SkillsSettings.swift:99` — “Another repository on GitHub, like owner/skills”
- `KuvoCode/Views/Settings/SkillsSettings.swift:99` — “Repository”
- `KuvoCode/Views/Settings/StorageSettings.swift:101` — “Delete…”
- `KuvoCode/Views/Settings/StorageSettings.swift:104` — “Downloads for machines”
- `KuvoCode/Views/Settings/StorageSettings.swift:105` — “The Linux engine and browser, kept to set up another machine without downloading them again.”
- `KuvoCode/Views/Settings/StorageSettings.swift:108` — “Files You Can Delete”
- `KuvoCode/Views/Settings/StorageSettings.swift:112` — “Clean Up Old Sessions”
- `KuvoCode/Views/Settings/StorageSettings.swift:116` — “Delete”
- `KuvoCode/Views/Settings/StorageSettings.swift:123` — “New ones start right away. Your sessions aren’t affected.”
- `KuvoCode/Views/Settings/StorageSettings.swift:126` — “Delete”
- `KuvoCode/Views/Settings/StorageSettings.swift:132` — “Machines you’ve added keep their engine and browser. A new one downloads them again.”
- `KuvoCode/Views/Settings/StorageSettings.swift:20` — “\(Self.format(report.total)) used by Kuvo Code”
- `KuvoCode/Views/Settings/StorageSettings.swift:23` — “Refresh”
- `KuvoCode/Views/Settings/StorageSettings.swift:311` — “Unused for more than”
- `KuvoCode/Views/Settings/StorageSettings.swift:314` — “Keep pinned sessions”
- `KuvoCode/Views/Settings/StorageSettings.swift:318` — “None unused for that long.”
- `KuvoCode/Views/Settings/StorageSettings.swift:332` — “Deleting can’t be undone.”
- `KuvoCode/Views/Settings/StorageSettings.swift:48` — “Show in Finder”
- `KuvoCode/Views/Settings/StorageSettings.swift:54` — “Adding it up…”
- `KuvoCode/Views/Settings/StorageSettings.swift:60` — “This Mac”
- `KuvoCode/Views/Settings/StorageSettings.swift:65` — “Review…”
- `KuvoCode/Views/Settings/StorageSettings.swift:67` — “Clean up old sessions”
- `KuvoCode/Views/Settings/StorageSettings.swift:68` — “Delete sessions you haven’t used in a while, with their messages and undo snapshots.”
- `KuvoCode/Views/Settings/StorageSettings.swift:71` — “Manage”
- `KuvoCode/Views/Settings/StorageSettings.swift:73` — “Archived sessions”
- `KuvoCode/Views/Settings/StorageSettings.swift:77` — “Manage”
- `KuvoCode/Views/Settings/StorageSettings.swift:79` — “Worktrees”
- `KuvoCode/Views/Settings/StorageSettings.swift:80` — “Sessions’ own copies of a project, on a branch.”
- `KuvoCode/Views/Settings/StorageSettings.swift:83` — “Manage”
- `KuvoCode/Views/Settings/StorageSettings.swift:85` — “Website data”
- `KuvoCode/Views/Settings/StorageSettings.swift:86` — “What sites keep in the panel’s browser.”
- `KuvoCode/Views/Settings/StorageSettings.swift:89` — “Sessions and Projects”
- `KuvoCode/Views/Settings/StorageSettings.swift:94` — “Delete…”
- `KuvoCode/Views/Settings/StorageSettings.swift:97` — “Logs”
- `KuvoCode/Views/Settings/StorageSettings.swift:98` — “What the engine and the app wrote down while running, for troubleshooting.”
- `KuvoCode/Views/SettingsView.swift:125` — “Back to Sessions”
- `KuvoCode/Views/SettingsView.swift:126` — “Back to Sessions (Esc)”
- `KuvoCode/Views/SettingsView.swift:327` — “Settings”
- `KuvoCode/Views/SettingsView.swift:336` — “No Results”
- `KuvoCode/Views/SettingsView.swift:372` — “Open in New Tab”
- `KuvoCode/Views/SettingsView.swift:408` — “Back to \(page.title) (Esc)”
- `KuvoCode/Views/SettingsView.swift:78` — “Back to Sessions”
- `KuvoCode/Views/Shared/FormFieldsView.swift:122` — “Something else…”
- `KuvoCode/Views/Shared/FormFieldsView.swift:133` — “Open \(link.host() ?? ”
- `KuvoCode/Views/Shared/FormFieldsView.swift:135` — “Done”
- `KuvoCode/Views/Shared/FormFieldsView.swift:91` — “Something else…”
- `KuvoCode/Views/SidebarView.swift:1004` — “Wakes ”
- `KuvoCode/Views/SidebarView.swift:102` — “In Conversations”
- `KuvoCode/Views/SidebarView.swift:1101` — “No projects on this Mac”
- `KuvoCode/Views/SidebarView.swift:1127` — “Waiting for you”
- `KuvoCode/Views/SidebarView.swift:1130` — “Working”
- `KuvoCode/Views/SidebarView.swift:1135` — “The last run failed”
- `KuvoCode/Views/SidebarView.swift:1138` — “Finished”
- `KuvoCode/Views/SidebarView.swift:115` — “Pinned”
- `KuvoCode/Views/SidebarView.swift:1153` — “account”
- `KuvoCode/Views/SidebarView.swift:1175` — “Accounts, usage, Settings and help”
- `KuvoCode/Views/SidebarView.swift:122` — “Bots”
- `KuvoCode/Views/SidebarView.swift:136` — “New Bot or Group Chat”
- `KuvoCode/Views/SidebarView.swift:143` — “New Bot…”
- `KuvoCode/Views/SidebarView.swift:151` — “Make a Bot”
- `KuvoCode/Views/SidebarView.swift:154` — “A teammate with one job, that keeps working while you're away”
- `KuvoCode/Views/SidebarView.swift:161` — “Edit Bot…”
- `KuvoCode/Views/SidebarView.swift:171` — “Edit Group Chat…”
- `KuvoCode/Views/SidebarView.swift:173` — “Delete Group Chat…”
- `KuvoCode/Views/SidebarView.swift:178` — “Projects”
- `KuvoCode/Views/SidebarView.swift:184` — “New Project… (⇧⌘N)”
- `KuvoCode/Views/SidebarView.swift:188` — “Open a folder for the agent to work in.”
- `KuvoCode/Views/SidebarView.swift:200` — “Recents”
- `KuvoCode/Views/SidebarView.swift:272` — “Delete”
- `KuvoCode/Views/SidebarView.swift:276` — “Cancel”
- `KuvoCode/Views/SidebarView.swift:278` — “Its messages are deleted, and its bots stop remembering it. This can’t be undone.”
- `KuvoCode/Views/SidebarView.swift:285` — “Delete and Remove Worktree”
- `KuvoCode/Views/SidebarView.swift:286` — “Delete Session Only”
- `KuvoCode/Views/SidebarView.swift:288` — “Delete”
- `KuvoCode/Views/SidebarView.swift:290` — “Cancel”
- `KuvoCode/Views/SidebarView.swift:293` — “The session and its transcript will be deleted. This can't be undone. ”
- `KuvoCode/Views/SidebarView.swift:295` — “The session and its transcript will be deleted. This can't be undone.”
- `KuvoCode/Views/SidebarView.swift:300` — “Archive and Remove Worktree”
- `KuvoCode/Views/SidebarView.swift:301` — “Archive Only”
- `KuvoCode/Views/SidebarView.swift:303` — “Cancel”
- `KuvoCode/Views/SidebarView.swift:361` — “New Session”
- `KuvoCode/Views/SidebarView.swift:362` — “Edit Project…”
- `KuvoCode/Views/SidebarView.swift:366` — “Connect to \(engine.machine.name)”
- `KuvoCode/Views/SidebarView.swift:371` — “Show in Finder”
- `KuvoCode/Views/SidebarView.swift:375` — “Remove from Sidebar”
- `KuvoCode/Views/SidebarView.swift:383` — “New Session”
- `KuvoCode/Views/SidebarView.swift:409` — “Chats”
- `KuvoCode/Views/SidebarView.swift:415` — “New Chat (⌥⌘N)”
- `KuvoCode/Views/SidebarView.swift:422` — “New Chat”
- `KuvoCode/Views/SidebarView.swift:428` — “Start a Chat”
- `KuvoCode/Views/SidebarView.swift:431` — “A conversation of no project. You can move it into one later.”
- `KuvoCode/Views/SidebarView.swift:526` — “Archived”
- `KuvoCode/Views/SidebarView.swift:535` — “Works in a worktree, on \(tree.branch)”
- `KuvoCode/Views/SidebarView.swift:564` — “\(engine.machine.name) isn’t connected”
- `KuvoCode/Views/SidebarView.swift:566` — “Connecting…”
- `KuvoCode/Views/SidebarView.swift:567` — “Connect Now”
- `KuvoCode/Views/SidebarView.swift:577` — “Unpin”
- `KuvoCode/Views/SidebarView.swift:579` — “Pin”
- `KuvoCode/Views/SidebarView.swift:583` — “Open Beside”
- `KuvoCode/Views/SidebarView.swift:586` — “Rename…”
- `KuvoCode/Views/SidebarView.swift:593` — “Show in Finder”
- `KuvoCode/Views/SidebarView.swift:596` — “Copy as Markdown”
- `KuvoCode/Views/SidebarView.swift:607` — “Export as Markdown…”
- `KuvoCode/Views/SidebarView.swift:610` — “Unarchive”
- `KuvoCode/Views/SidebarView.swift:612` — “Archive”
- `KuvoCode/Views/SidebarView.swift:616` — “Delete…”
- `KuvoCode/Views/SidebarView.swift:697` — “Search”
- `KuvoCode/Views/SidebarView.swift:709` — “Clear”
- `KuvoCode/Views/SidebarView.swift:80` — “New Session”
- `KuvoCode/Views/SidebarView.swift:82` — “New Session (⌘N)”
- `KuvoCode/Views/SidebarView.swift:841` — “New Session in \(project.name)”
- `KuvoCode/Views/SidebarView.swift:89` — “Results”
- `KuvoCode/Views/SidebarView.swift:894` — “New messages”
- `KuvoCode/Views/SidebarView.swift:92` — “No sessions match.”
- `KuvoCode/Views/SidebarView.swift:987` — “Needs you”
- `KuvoCode/Views/SidebarView.swift:994` — “On \(machine), not connected”
- `KuvoCode/Views/SidebarView.swift:998` — “Paused”
- `KuvoCode/Views/TitleBar.swift:244` — “Close Tab”
- `KuvoCode/Views/TitleBar.swift:262` — “Close Tab”
- `KuvoCode/Views/TitleBar.swift:502` — “New branch from \(branch)”
- `KuvoCode/Views/TitleBar.swift:511` — “Return makes it. It starts from \(branch), and changes you haven't committed come along.”
- `KuvoCode/Views/TitleBar.swift:520` — “Switch To”
- `KuvoCode/Views/TitleBar.swift:526` — “New Branch…”
- `KuvoCode/Views/TitleBar.swift:537` — “Switch branches, or start a new one”
- `KuvoCode/Views/TitleBar.swift:542` — “OK”
- `KuvoCode/Views/Utilities/AgentBadge.swift:19` — “You have control”
- `KuvoCode/Views/Utilities/BrowserChrome.swift:110` — “Copy Address”
- `KuvoCode/Views/Utilities/BrowserChrome.swift:112` — “Reload Page”
- `KuvoCode/Views/Utilities/BrowserChrome.swift:115` — “Actual Size”
- `KuvoCode/Views/Utilities/BrowserChrome.swift:116` — “Zoom In”
- `KuvoCode/Views/Utilities/BrowserChrome.swift:117` — “Zoom Out”
- `KuvoCode/Views/Utilities/BrowserChrome.swift:119` — “Browser Settings…”
- `KuvoCode/Views/Utilities/BrowserChrome.swift:121` — “More”
- `KuvoCode/Views/Utilities/BrowserChrome.swift:126` — “More”
- `KuvoCode/Views/Utilities/BrowserChrome.swift:138` — “\(Int((zoom * 100).rounded()))%”
- `KuvoCode/Views/Utilities/BrowserChrome.swift:149` — “Back to actual size (zoom with ⌘+ and ⌘−, or pinch)”
- `KuvoCode/Views/Utilities/BrowserChrome.swift:197` — “Cancel”
- `KuvoCode/Views/Utilities/BrowserChrome.swift:20` — “Back”
- `KuvoCode/Views/Utilities/BrowserChrome.swift:22` — “Back”
- `KuvoCode/Views/Utilities/BrowserChrome.swift:23` — “Forward”
- `KuvoCode/Views/Utilities/BrowserChrome.swift:248` — “Hide”
- `KuvoCode/Views/Utilities/BrowserChrome.swift:25` — “Forward”
- `KuvoCode/Views/Utilities/BrowserChrome.swift:66` — “Search or enter a URL”
- `KuvoCode/Views/Utilities/BrowserSession.swift:579` — “Passwords…”
- `KuvoCode/Views/Utilities/BrowserSession.swift:581` — “Fill Password”
- `KuvoCode/Views/Utilities/BrowserSession.swift:592` — “Add Screenshot to Message”
- `KuvoCode/Views/Utilities/BrowserSession.swift:595` — “Add a screenshot of the page to your message, so the agent sees what you see”
- `KuvoCode/Views/Utilities/BrowserSession.swift:599` — “Open in Your Browser”
- `KuvoCode/Views/Utilities/BrowserSession.swift:601` — “Open in Your Browser”
- `KuvoCode/Views/Utilities/BrowserSession.swift:646` — “Never for This Site”
- `KuvoCode/Views/Utilities/BrowserSession.swift:698` — “Show in Finder”
- `KuvoCode/Views/Utilities/CodeTextView.swift:104` — “Add to Message”
- `KuvoCode/Views/Utilities/FilesView.swift:200` — “Filter files…”
- `KuvoCode/Views/Utilities/FilesView.swift:229` — “No matching files”
- `KuvoCode/Views/Utilities/FilesView.swift:241` — “Reload”
- `KuvoCode/Views/Utilities/FilesView.swift:285` — “Show in Finder”
- `KuvoCode/Views/Utilities/FilesView.swift:287` — “Copy Path”
- `KuvoCode/Views/Utilities/FilesView.swift:385` — “This file can’t be shown here.”
- `KuvoCode/Views/Utilities/FilesView.swift:435` — “\(text)\(Text(”
- `KuvoCode/Views/Utilities/FilesView.swift:439` — “\(text)\(partText)”
- `KuvoCode/Views/Utilities/FilesView.swift:483` — “Open”
- `KuvoCode/Views/Utilities/FilesView.swift:489` — “openwith”
- `KuvoCode/Views/Utilities/FilesView.swift:502` — “Open With”
- `KuvoCode/Views/Utilities/MachineBrowserPane.swift:104` — “Try Again”
- `KuvoCode/Views/Utilities/MachineBrowserPane.swift:131` — “Add Screenshot to Message”
- `KuvoCode/Views/Utilities/MachineBrowserPane.swift:134` — “Add a screenshot of the page to your message, so the agent sees what you see”
- `KuvoCode/Views/Utilities/MachineBrowserPane.swift:163` — “Setting Up the Browser on \(machine)”
- `KuvoCode/Views/Utilities/MachineBrowserPane.swift:165` — “Kuvo Code puts a browser and everything it needs in ~/.kuvo-code on the machine. Nothing is installed on the system.”
- `KuvoCode/Views/Utilities/MachineBrowserPane.swift:174` — “Downloading… \(Int(progress * 100))%”
- `KuvoCode/Views/Utilities/MachineBrowserPane.swift:179` — “Sending it to \(machine)…”
- `KuvoCode/Views/Utilities/MachineBrowserPane.swift:200` — “Save to Mac”
- `KuvoCode/Views/Utilities/MachineBrowserPane.swift:201` — “Copy it into your Downloads folder”
- `KuvoCode/Views/Utilities/MachineBrowserPane.swift:205` — “Show in Finder”
- `KuvoCode/Views/Utilities/NewTabPage.swift:27` — “Changes”
- `KuvoCode/Views/Utilities/NewTabPage.swift:30` — “Terminal”
- `KuvoCode/Views/Utilities/NewTabPage.swift:33` — “Files”
- `KuvoCode/Views/Utilities/NewTabPage.swift:36` — “Customize…”
- `KuvoCode/Views/Utilities/NewTabPage.swift:46` — “Sites you visit in the panel show up here.”
- `KuvoCode/Views/Utilities/NewTabPage.swift:56` — “Open in New Tab”
- `KuvoCode/Views/Utilities/NewTabPage.swift:58` — “Remove from Suggested”
- `KuvoCode/Views/Utilities/NewTabPage.swift:66` — “Search, or enter a URL above.”
- `KuvoCode/Views/Utilities/OpenQuickly.swift:28` — “Open a file in the project”
- `KuvoCode/Views/Utilities/TerminalSession.swift:119` — “Add to Message”
- `KuvoCode/Views/Utilities/TerminalSession.swift:123` — “Copy”
- `KuvoCode/Views/Utilities/TerminalSession.swift:126` — “Paste”
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:102` — “New Tab”
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:105` — “New Tab”
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:173` — “No Project”
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:173` — “Open a project to see its changes.”
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:180` — “No Project”
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:180` — “Open a project to browse its files.”
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:187` — “Close this tab, or open a new one.”
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:187` — “Terminal Closed”
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:200` — “Close this tab, or open a new one.”
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:200` — “Page Closed”
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:216` — “\(machine) isn’t one of your machines anymore. Close this tab.”
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:216` — “Machine Removed”
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:273` — “Close Tab”
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:62` — “Close Tab”
- `KuvoCode/Views/Utilities/UtilitiesPane.swift:63` — “Close Other Tabs”

## 6. Drawn artwork (6)

The Shape and Canvas declarations found by the scan. The hand-written list of all drawn
artwork — including the avatar views, whose drawing is not a single Shape — is in
`docs/MAC-UI-MAP.md` §7.

| Kind | Type | Site |
| --- | --- | --- |
| Shape | `ArrowShape` | `KuvoCode/Design/AgentPointer.swift:198` |
| Shape | `Star` | `KuvoCode/Design/BotAvatar.swift:313` |
| Shape | `BotShape` | `KuvoCode/Design/BotAvatar.swift:535` |
| Canvas | `—` | `KuvoCode/Design/BotAvatar.swift:604` |
| Shape | `FolderShape` | `KuvoCode/Design/FolderIcon.swift:21` |
| Shape | `PromptMark` | `KuvoCode/Design/Spinner.swift:153` |

## 7. Settings pages

Mac, in `SettingsPage` (`KuvoCode/Views/SettingsView.swift`): 23.

- `general`
- `appearance`
- `notifications`
- `phone`
- `shortcuts`
- `privacy`
- `storage`
- `accounts`
- `usage`
- `agents`
- `permissions`
- `commands`
- `skills`
- `integrations`
- `mcp`
- `engine`
- `git`
- `worktrees`
- `archived`
- `machines`
- `panel`
- `browser`
- `passwords`

Windows, in `PAGES` (`windows/app/src/Settings.tsx`): 14.

- appearance — Appearance
- general — General
- keyboard — Keyboard
- mcp — MCP servers
- agents — Agents
- skills — Skills
- commands — Commands
- projects — Projects
- providers — Providers
- usage — Usage
- git — Git
- archived — Archived sessions
- permissions — Permissions
- system — Engine & storage
