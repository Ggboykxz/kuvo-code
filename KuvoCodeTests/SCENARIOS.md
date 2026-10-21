# Scenarios the app tests guard

The app tests follow the scenarios in `Tests/E2E/SCENARIOS.md` (what people do with Kuvo Code),
by the same IDs. The end-to-end runs try each one for real, with a model; the app tests keep each
one working on every change, on CI, without a model or the network: the app's real stores, real
git and real files, with the engine stubbed at its HTTP API. A bug an end-to-end run found and
fixed (❌→✅ there) gets a test here when it can be tried this way.

Each suite's comment says what it tries; this is where each scenario stands.

| Scenario | Suites | Not guarded yet |
| --- | --- | --- |
| A1, J2 A model ready, or the one you picked when it can't run | StartingModelTests, ProviderCompatibilityTests | |
| A4 Bring over an opencode setup | OpencodeImportTests | |
| A6 Quit with work running, open again | DraftsTests, StoredFilesTests, QueueTests, LastSeenTests | |
| B5 Review the changes, comment on a line, send the comments | SessionEditsTests, SentMessageTests, DraftsTests | |
| B6 Undo a turn, then change your mind | ComposerReturnsTests, AttachmentsTests, UndoRedoTests | |
| B7 Commit with a message, push, make a branch | ChangesCommitTests, ChangesDiscardTests, ChangesStagingTests, ChangesFileNamesTests | |
| B8 A session in a worktree, merged back | WorktreeSessionTests, GitBranchesTests | |
| B9 Plan first, then Build It | AgentAsksTests | |
| B10 Ask First: allow once, always, deny | ComposerReturnsTests, ProjectFoldersTests, PermissionCardsTests | Always Allowed lists every project's (Settings' view code) |
| B11 The agent asks questions, answered in the card | AgentAsksTests | |
| B12 Queue while it works, Stop, Resume | ComposerReturnsTests, QueueTests | |
| B13 Two sessions at once, each with its own asks | AgentAsksTests | |
| B14 Switch model mid-conversation, or elsewhere | SessionsTests | |
| B16 Find in a long conversation | ConversationFindTests | |
| B19 A subagent at work, in the background too | SubagentsAtWorkTests | |
| B17 A folder that isn't a git repository | SessionEditsTests | |
| B18 Rename, archive, restore, delete, search | SidebarListsTests, SessionsTests, SessionTitlesTests, SessionSearchTests, SessionLifecycleTests | |
| B20 Commands and skills | SlashCommandsTests, SkillLibraryTests | |
| C1–C3 Attach pictures, PDFs, files | AttachmentRoutesTests, AttachmentsTests, SentFilesTests | |
| C4 Quote part of a reply and answer it | QuotingTests | |
| C5, C6 Files in the panel; the agent shows one | FileLinksTests, PanelTabsTests, ProjectFilesTests, BrowserHistoryTests | |
| D4 A chat moved into a project | SessionLifecycleTests | |
| E, B15 The agent's browser | BrowserToolServerTests | |
| E5, L33, L34, K6 Sign-ins, codes, passwords | BrowserAsksTests, MachineSignOutTests, PasskeysTests | a machine's Chrome refusing passkeys (checked by hand in Chromium; no Chrome in the tests) |
| F2, F6 A bot's job, told or edited | BotsTests | |
| F3, F4, L15–L19, L26 Wake-ups | WakeUpsTests, StepSummariesTests | |
| F7 Export and import a bot | AgentMessagesTests | |
| F8 Delete a bot | BotDeletionTests, GroupChatTests | |
| F10, L39, L40 Agents writing to each other | AgentMessagesTests, AgentReferencesTests | |
| G1–G4 Group chats, meetings on a schedule | BotsTests, AgentMessagesTests, GroupChatTests | |
| H1, H2 MCP servers | MCPCommandTests, ChromeDevToolsUpgradeTests, IntegrationsTests | |
| H3 An MCP server asks mid-task | AgentAsksTests | |
| H4 A skill from GitHub | SkillLibraryTests | |
| I1 Add a machine, at one or more addresses | AddMachineTests, MachineAddressesTests | choosing the address that answers (needs SSH) |
| I2 A project on a machine | MachineFoldersTests, AttachmentRoutesTests, SignInSyncTests, MachineSignOutTests | |
| I3 A machine that's away | MachineAwayTests | |
| I4 What machines share with this Mac, and what's their own | MachineSettingsTests, CustomAutoPlacesTests, SignInSyncTests | a connected machine's engine starting over with new settings (needs SSH) |
| K1 Settings keep what you change | EngineSettingsFileTests | |
| K3 Notifications | NotificationMaskingTests | |
| L50 Quit mid-job, open again | InterruptedRunTests | |
| The panel's terminal | TerminalColorsTests | |
| Export a conversation | ConversationExportTests | |
| Anonymous usage stays anonymous | AnalyticsPrivacyTests | |
