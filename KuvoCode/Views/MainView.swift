import OpenCodeKit
import os
import SwiftUI

/// The workspace, laid out like Rex: open sessions as tabs in the title bar, and
/// cards floating on the window's glass (sessions, the conversation, changes).
struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(Catalog.self) private var catalog
    @Environment(Workspace.self) private var workspace
    @Environment(Bots.self) private var bots
    @Environment(BotGroups.self) private var groups

    /// Open tabs, in order: session IDs, or `draft:<folder>` for a new session
    /// that doesn't exist on the server until its first message.
    @SceneStorage("tabs") private var tabStorage = ""
    /// The active tab.
    @SceneStorage("selection") private var selection: String?
    @SceneStorage("showsSidebar") private var showsSidebar = true
    /// The row at the top: the project, its branch and the tabs. Hidden, sessions are switched
    /// from the sidebar or ⌘K.
    @AppStorage(TabBar.showsKey) private var showsTabBar = true
    @SceneStorage("showsPanel") private var showsPanel = false
    /// The panel over the conversation, for room.
    /// Goes up for ⌘F in the group chat in view.
    @State private var groupFind = 0
    @State private var panelExpanded = false
    /// The room the conversation and the panel share: what the panel takes, expanded.
    @State private var mainAreaWidth: CGFloat = 0
    @AppStorage("sessionsWidth") private var sessionsWidth = 280.0
    @AppStorage("changesWidth") private var changesWidth = 420.0
    @AppStorage(Notifier.badgeKey) private var showsBadge = true
    /// The New Project or Edit Project sheet, while it's open.
    @State private var projectSheet: ProjectSheetRequest?
    /// Making or changing a bot, in the main card while it's open.
    @State private var botEditor: BotEditorRequest?
    /// Making or changing a group chat, the same way.
    @State private var groupEditor: GroupEditorRequest?
    @State private var focus = Pane.conversation
    /// Tabs you closed, last one last, with where they were: ⇧⌘T opens them again.
    @State private var closedTabs: [ClosedTab] = []
    /// Goes up to put the cursor in a new session's composer.
    @State private var draftFocus = 0
    /// Open Quickly's palette is showing.
    @State private var showsOpenQuickly = false
    /// The command palette (⌘K) is showing.
    @State private var showsPalette = false
    /// A tab's session being renamed, and the title being typed.
    @State private var renaming: Session?
    /// The window's content width; the title bar is sized from it.
    @State private var contentWidth: CGFloat = 1200
    /// Where the middle card starts and where the title bar's items start, in the window: the
    /// tabs line up with the card.
    @State private var mainPaneX: CGFloat = 0
    @State private var titleBarX: CGFloat = 0
    @State private var settingsBarX: CGFloat = 0
    @AppStorage(SettingsPage.storageKey) private var settingsPage = SettingsPage.general.rawValue

    enum Pane { case sessions, conversation, changes }

    struct ClosedTab {
        var key: String
        var index: Int
    }

    private var tabs: [String] {
        get { tabStorage.split(separator: "\n").map(String.init) }
        nonmutating set { tabStorage = newValue.joined(separator: "\n") }
    }

    private var utilities: Utilities { app.utilities }

    private var sessionID: String? {
        selection.flatMap { SidebarView.draftDirectory(from: $0) == nil && BotGroups.groupID(fromTab: $0) == nil ? $0 : nil }
    }

    /// The group chat in view.
    private var groupID: String? {
        selection.flatMap(BotGroups.groupID(fromTab:))
    }

    /// The browser tabs of the bots on this Mac in view, a bot's or a group chat's, beside yours.
    private func showBotTabs() {
        let inView = groupID.flatMap { groups.group($0)?.members.compactMap { bots.bot($0) } } ?? [bots.bot(forSession: sessionID)].compactMap { $0 }
        utilities.botsInView = Set(inView.filter { $0.machine == nil }.map(\.id))
    }

    private var draftDirectory: String? {
        selection.flatMap(SidebarView.draftDirectory(from:))
    }

    private var activeModel: SessionModel? {
        sessionID.flatMap(workspace.model(for:))
    }

    /// The active tab's project folder.
    private var activeDirectory: String? {
        activeModel?.session.location.directory ?? draftDirectory
    }

    /// The machine a folder is on, for a project there; nil for this Mac's.
    private func machine(for folder: String?) -> MachineEngine? {
        app.machines.engine(folder.flatMap(RemoteFolder.machine(of:)))
    }

    /// The agents, commands and models of the engine a folder's sessions run on.
    private func catalog(for folder: String?) -> Catalog {
        machine(for: folder)?.catalog ?? catalog
    }

    var body: some View {
        // Cards are sized from the room the window actually has, so they never spill
        // past its edges. The gaps between them are drag handles for resizing.
        GeometryReader { proxy in
            // Expanded, the panel grows over the conversation, which keeps its room (and its
            // layout) underneath for when it comes back.
            let layout = PaneLayout(
                available: proxy.size.width,
                sessions: showsSidebar ? sessionsWidth : nil,
                changes: showsPanel ? changesWidth : nil
            )
            let expands = showsPanel && panelExpanded
            HStack(spacing: 0) {
                if let width = layout.sessions {
                    sessionsCard
                        .frame(width: width)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    PaneResizer(
                        width: Binding(get: { width }, set: { sessionsWidth = $0 }),
                        range: PaneLayout.sessionsRange.lowerBound...max(PaneLayout.sessionsRange.lowerBound, layout.sessionsMax),
                        side: .leading
                    )
                }
                // With the tab bar hidden and no sidebar, the window's buttons and the sidebar
                // button sit over this card's header.
                let controlsInset: CGFloat = !showsTabBar && layout.sessions == nil ? 124 : 0
                ZStack(alignment: .trailing) {
                    HStack(spacing: 0) {
                        conversationCard
                            .frame(maxWidth: .infinity)
                            // It takes its new room at once while the panel or sidebar slides, so its
                            // text wraps once instead of at every step of the slide, which made
                            // the conversation flicker and jump.
                            .transaction(value: showsPanel) { $0.animation = nil }
                            .transaction(value: showsSidebar) { $0.animation = nil }
                            .environment(\.windowControlsInset, controlsInset)
                            // With the tab bar hidden, the panel button sits over the rightmost card.
                            .environment(\.windowControlsTrailingInset, !showsTabBar && layout.changes == nil ? 36 : 0)
                            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minX }) { mainPaneX = $0 }
                            // Under the expanded panel: out of reach, keys too (a card's Return
                            // or Esc), until it's back.
                            .disabled(expands)
                            .allowsHitTesting(!expands)
                            .accessibilityHidden(expands)
                        if let width = layout.changes {
                            PaneResizer(
                                width: Binding(get: { width }, set: { changesWidth = $0 }),
                                range: PaneLayout.changesRange.lowerBound...max(PaneLayout.changesRange.lowerBound, layout.changesMax),
                                side: .trailing
                            )
                            .allowsHitTesting(!expands)
                            // The panel's room; the panel itself is over it, so expanding only
                            // makes it wider, the one card it is.
                            Color.clear.frame(width: width)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { mainAreaWidth = $0 }
                    if showsPanel, layout.changes != nil || expands {
                        utilitiesPane
                            .frame(width: expands ? mainAreaWidth : layout.changes ?? mainAreaWidth)
                            .environment(\.windowControlsInset, expands ? controlsInset : 0)
                            .environment(\.windowControlsTrailingInset, showsTabBar ? 0 : 36)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            // Settings take the window's place. The sessions stay underneath, hidden and out of
            // reach, so the panel's terminals and pages carry on and everything is where it was.
            .opacity(app.showsSettings ? 0 : 1)
            .allowsHitTesting(!app.showsSettings)
            .disabled(app.showsSettings)
            .accessibilityHidden(app.showsSettings)
            .overlay {
                if app.showsSettings {
                    SettingsView(
                        sidebarWidth: min(max(layout.sessions ?? sessionsWidth, PaneLayout.sessionsRange.lowerBound), proxy.size.width * 0.4),
                        topInset: keepsTitleBar ? 0 : Metrics.windowControlsHeight,
                        close: closeSettings
                    )
                    .transition(.opacity)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { contentWidth = $0 }
        .padding(.horizontal, Metrics.paneGap)
        .padding(.bottom, Metrics.paneGap)
        // Without the tab bar, the cards reach up into the title bar; the window's buttons sit
        // at the top of the sidebar.
        .padding(.top, keepsTitleBar ? 0 : Metrics.paneGap)
        .ignoresSafeArea(.container, edges: keepsTitleBar ? [] : .top)
        // Without the tab bar, the panel's button stays at the top right, on the rightmost card's
        // header row, so the panel can still be found.
        .overlay(alignment: .topTrailing) {
            if !showsTabBar && !app.showsSettings {
                PanelToggle(showsPanel: $showsPanel)
                    .padding(.top, Metrics.paneGap + (Metrics.cardHeaderHeight - 28) / 2)
                    .padding(.trailing, Metrics.paneGap + 6)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .animation(.ui, value: showsSidebar)
        .animation(.ui, value: showsPanel)
        .animation(.ui, value: panelExpanded)
        .animation(.ui, value: app.showsSettings)
        // Typing mustn't go on into a composer or terminal that Settings now hide.
        .onChange(of: app.showsSettings) { _, shows in
            if shows { NSApp.mainWindow?.makeFirstResponder(nil) }
            // Leaving Settings closes the sites you were signing in to.
            if !shows { app.settingsTabs.closeAll(machines: app.machines) }
        }
        // Nor into the conversation the expanded panel covers (its composer, if it had the
        // keyboard; the panel's own terminal or page keeps it).
        .onChange(of: showsPanel && panelExpanded) { _, expanded in
            guard expanded, let window = NSApp.mainWindow, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return }
            window.makeFirstResponder(nil)
        }
        // The agent started browsing: show it.
        .onChange(of: utilities.revealRequest) { withAnimation(.ui) { showsPanel = true } }
        // Hiding the tab bar takes the whole row away and the cards reach the top. The sidebar
        // button stays, so the window's buttons keep a toolbar's height, centered on the cards'
        // header row, and the sidebar is a click away. The panel is still ⌥⌘0, and sessions ⌘K.
        .toolbar {
            if app.showsSettings {
                // In Settings, the title bar has the way back, and the tabs once you sign in to a
                // site: the page's, then each site's, from where the page's card starts.
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 0) {
                        SettingsBackButton(close: closeSettings)
                        if !app.settingsTabs.sites.isEmpty {
                            Color.clear.frame(width: max(8, app.settingsTabs.contentX - settingsBarX - 28))
                            TabStrip(tabs: settingsTabItems, selection: settingsTabSelection, close: { id in
                                withAnimation(.ui) { app.settingsTabs.close(id, machines: app.machines) }
                            }, closeAll: { except in
                                withAnimation(.ui) {
                                    for site in app.settingsTabs.sites where site.id != except { app.settingsTabs.close(site.id, machines: app.machines) }
                                }
                            })
                            .transition(.opacity)
                        }
                    }
                    .background(WindowXReader { settingsBarX = $0 })
                    // Room from the window, as the sessions' tabs have, so titles aren't squeezed.
                    .frame(width: max(240, contentWidth - 150), alignment: .leading)
                    .animation(.ui, value: app.settingsTabs.sites.map(\.id))
                }
                .sharedBackgroundVisibility(.hidden)
            } else if showsTabBar {
                titleBar
            } else {
                ToolbarItem(placement: .navigation) { SidebarToggle(showsSidebar: $showsSidebar) }
                    .sharedBackgroundVisibility(.hidden)
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .iconOnlyToolbar()
        .overlay(alignment: .top) {
            if catalog.isSlow {
                SlowEngineNotice()
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.ui, value: catalog.isSlow)
        .overlay(alignment: .top) {
            if showsOpenQuickly, let directory = activeDirectory {
                ZStack(alignment: .top) {
                    // A click outside closes it.
                    Color.black.opacity(0.001)
                        .onTapGesture { showsOpenQuickly = false }
                    OpenQuickly(roots: [directory] + workspace.extraFolders(directory)) { url in
                        showsOpenQuickly = false
                        Analytics.shared.track("open_quickly_used")
                        showInPanel { utilities.show(url) }
                    } dismiss: {
                        showsOpenQuickly = false
                    }
                    .padding(.top, 80)
                }
                .transition(.opacity)
            }
        }
        .animation(.ui, value: showsOpenQuickly)
        .overlay(alignment: .top) {
            if showsPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001)
                        .onTapGesture { showsPalette = false }
                    CommandPalette(
                        initialQuery: Self.demoPaletteQuery,
                        actions: paletteActions,
                        sessions: paletteSessions,
                        roots: activeDirectory.map { [$0] + workspace.extraFolders($0) } ?? [],
                        openFile: { url in showInPanel { utilities.show(url) } },
                        dismiss: { showsPalette = false }
                    )
                    .padding(.top, 80)
                }
                .transition(.opacity)
            }
        }
        .animation(.ui, value: showsPalette)
        .modifier(RenameSession(session: $renaming))
        .sheet(item: $projectSheet) { request in
            ProjectSheet(project: request.project, folders: request.folders, focusesRun: request.focusesRun) { primary, settings in
                workspace.saveProject(primary, settings: settings)
                if request.project == nil { newSession(in: primary) }
            }
        }
        .focusedSceneValue(\.sessionActions, actions)
        // Viewed only while you're here: finished while you're in another app, it waits for you
        // on the Dock icon, and counts as seen when you come back.
        .onChange(of: sessionID) { _, id in
            if let id, NSApp.isActive { workspace.markViewed(id) }
        }
        .onChange(of: workspace.session(sessionID)?.time.idle) {
            if let sessionID, NSApp.isActive { workspace.markViewed(sessionID) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if let sessionID { workspace.markViewed(sessionID) }
        }
        // The panel's browser is that of the place the session in view runs: this Mac's, or its
        // machine's.
        .onChange(of: activeDirectory, initial: true) { _, directory in
            utilities.place = directory.flatMap(RemoteFolder.machine(of:))
        }
        // Its agent's browsing brings pages forward; others' stay where they are.
        .onChange(of: sessionID, initial: true) { _, id in
            utilities.sessionInView = id
            showBotTabs()
        }
        .onChange(of: groupID) { showBotTabs() }
        .onChange(of: groupID.flatMap { groups.group($0)?.members } ?? []) { showBotTabs() }
        .task(id: activeDirectory) {
            if let activeDirectory { await workspace.loadBranch(for: activeDirectory) }
        }
        .onChange(of: workspace.sessions.map(\.id)) { _, ids in dropClosedSessions(ids) }
        .onChange(of: groups.list.map(\.id)) { dropClosedSessions(workspace.sessions.map(\.id)) }
        .onChange(of: workspace.isLoaded) {
            // The list arrives just before loading counts as done, so check it again here.
            dropClosedSessions(workspace.sessions.map(\.id))
            startIfEmpty()
        }
        .onAppear(perform: startIfEmpty)
        .onAppear { Notifier.shared.open = { openTab($0) } }
        .onAppear { utilities.addToMessage = { addToMessage($0) } }
        .onAppear { utilities.attachToMessage = { attachToMessage($0) } }
        .onChange(of: workspace.requestedTab) { _, id in
            guard let id else { return }
            openTab(id)
            workspace.requestedTab = nil
        }
        // From outside the window: a folder opened with Kuvo Code, or the Dock menu.
        .onChange(of: app.request, initial: true) { _, request in
            guard let request else { return }
            app.request = nil
            switch request {
            case .folder(let path):
                workspace.addFolder(path)
                newSession(in: path)
            case .session(let id):
                openTab(id)
            case .newSession:
                newSession(in: nil)
            case .bot(let recipe):
                openBotEditor(bot: nil, recipe: recipe)
            }
        }
        .onChange(of: workspace.waitingCount, initial: true) { Notifier.shared.setBadge(workspace.waitingCount) }
        .onChange(of: showsBadge) { Notifier.shared.setBadge(workspace.waitingCount) }
        #if DEBUG
        .task(id: workspace.isLoaded) { await runDemoIfAsked() }
        #endif
    }

    // MARK: Title bar

    @ToolbarContentBuilder private var titleBar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 0) {
                ProjectIdentity(
                    name: activeDirectory.map(workspace.projectName),
                    branch: activeDirectory.flatMap { workspace.branches[$0] },
                    directory: activeDirectory,
                    isWorktree: activeDirectory.map { workspace.worktrees[$0] != nil } ?? false,
                    environment: app.shellEnvironment,
                    showsSidebar: $showsSidebar
                ) {
                    if let activeDirectory { Task { await workspace.loadBranch(for: activeDirectory) } }
                }
                // Up to the middle card, so the tabs start where it does; without the sidebar
                // there's no room for that, and the tabs follow the project.
                .frame(width: identityWidth, alignment: .leading)
                .padding(.trailing, identityWidth == nil ? 16 : 0)
                if !tabItems.isEmpty {
                    TabStrip(tabs: tabItems, selection: $selection, close: { closeTab($0) }, closeAll: closeTabs(except:)) { id in
                        guard let session = workspace.session(id) else { return }
                        renaming = session
                    }
                }
            }
            .background(WindowXReader { titleBarX = $0 })
            // A width from the window (minus the traffic lights and the buttons on the right), so a
            // narrow window squeezes the tabs instead of pushing them into a » menu.
            .frame(width: max(240, contentWidth - (runCommand == nil ? 150 : 190)), alignment: .leading)
            .modifier(UnderImageViewer())
        }
        .sharedBackgroundVisibility(.hidden)

        if let runCommand {
            ToolbarItem(placement: .primaryAction) {
                Button(action: runProject) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13))
                }
                .buttonStyle(IconButtonStyle(width: 28, height: 28, cornerRadius: 7))
                .accessibilityLabel("Run")
                .help("Run \(runCommand) (⌘R)")
                .modifier(UnderImageViewer())
            }
            .sharedBackgroundVisibility(.hidden)
        }

        ToolbarItem(placement: .primaryAction) { PanelToggle(showsPanel: $showsPanel).modifier(UnderImageViewer()) }
            .sharedBackgroundVisibility(.hidden)
    }

    /// The project's width in the title bar: up to the middle card, when the sidebar leaves
    /// enough room for it.
    private var identityWidth: CGFloat? {
        let room = mainPaneX - titleBarX
        return showsSidebar && titleBarX > 0 && room >= 150 ? room : nil
    }

    private var tabItems: [TabItem] {
        tabs.compactMap { key in
            if let directory = SidebarView.draftDirectory(from: key) {
                return TabItem(id: key, title: Workspace.isChat(directory) ? "New Chat" : "New Session", logo: nil, status: .idle)
            }
            if workspace.waitingMachine(for: key) != nil {
                return TabItem(id: key, title: workspace.remoteTitle(key) ?? "Session", logo: nil, status: .idle)
            }
            if let id = BotGroups.groupID(fromTab: key) {
                guard let group = groups.group(id) else { return nil }
                let status: TabItem.Status = groups.discussing.contains(id) ? .working : groups.isUnread(group) && groupID != id ? .unread : .idle
                return TabItem(id: key, title: group.name, logo: nil, group: faces(of: group), status: status)
            }
            guard let session = workspace.session(key) else { return nil }
            if let bot = bots.bot(forSession: key) {
                return TabItem(id: key, title: bot.name, logo: nil, bot: bot.look, botMood: bots.mood(of: bot, in: workspace), status: status(of: session))
            }
            return TabItem(id: key, title: session.title ?? "New Session", logo: logo(for: session.model, in: session.location.directory), status: status(of: session))
        }
    }

    /// Bots moving in the main card (working in their conversation, talking in a group chat, being
    /// edited): their sidebar rows hold still meanwhile, so each moves in one place at a time.
    /// An idle bot whose conversation is open moves in the sidebar, as nothing in its conversation does.
    private var stagedBots: Set<String> {
        if let request = botEditor { return Set([request.bot?.id].compactMap(\.self)) }
        if groupEditor != nil { return [] }
        if let id = sessionID, let bot = bots.bot(forSession: id), workspace.running.contains(id) { return [bot.id] }
        if let id = groupID, let speaker = groups.speaking[id] { return [speaker] }
        return []
    }

    /// A group chat's bots, the one talking at work.
    private func faces(of group: BotGroup) -> [GroupAvatar.Face] {
        let speaker = groups.speaking[group.id]
        return group.members.compactMap { id in
            bots.bot(id).map { GroupAvatar.Face(look: $0.look, mood: $0.id == speaker ? .working : .idle) }
        }
    }

    private func logo(for ref: ModelRef?, in folder: String? = nil) -> String? {
        guard let ref else { return nil }
        return catalog(for: folder).model(ref)?.makerLogoID ?? ref.providerID
    }

    private func status(of session: Session) -> TabItem.Status {
        if workspace.needsAttention(session.id) { return .waiting }
        if workspace.running.contains(session.id) { return .working }
        if session.outcome == .failed { return .failed }
        if session.isUnread, session.id != sessionID { return .unread }
        return .idle
    }

    // MARK: Cards

    private var sessionsCard: some View {
        // No card of its own: the sessions sit on the window's glass.
        Card(title: "Sessions", isFocused: focus == .sessions, showsHeader: false, showsSurface: false) {
            EmptyView()
        } content: {
            SidebarView(
                selection: Binding(get: { selection }, set: { id in if let id { openTab(id) } }),
                newSession: newSession,
                newProject: { projectSheet = ProjectSheetRequest(project: nil) },
                editProject: { projectSheet = ProjectSheetRequest(project: $0) },
                showProviders: { app.openSettings(.accounts) },
                newBot: { openBotEditor(bot: nil) },
                editBot: { openBotEditor(bot: $0) },
                newGroup: { openGroupEditor(group: nil) },
                editGroup: { openGroupEditor(group: $0) },
                stagedBots: stagedBots
            )
            // Room for the window's buttons above the first row, when they sit here.
            .padding(.top, showsTabBar ? 0 : Metrics.windowControlsHeight)
        }
        .overlay(alignment: .top) {
            if !showsTabBar { WindowDragArea().frame(height: Metrics.windowControlsHeight) }
        }
        .simultaneousGesture(TapGesture().onEnded { focus = .sessions })
    }

    @ViewBuilder private var conversationCard: some View {
        Group {
            if let request = groupEditor {
                Card(title: request.group.map { "Edit \($0.name)" } ?? "New Group Chat", isFocused: focus == .conversation) {
                    if let group = request.group { GroupAvatar(faces: faces(of: group), size: 20) } else { Image(systemName: "person.2") }
                } actions: {
                    Button("Close", systemImage: "xmark") { withAnimation(.ui) { groupEditor = nil } }
                        .help("Close")
                } content: {
                    GroupEditor(group: request.group, newBot: { openBotEditor(bot: nil) }) {
                        withAnimation(.ui) { groupEditor = nil }
                    } created: { group in
                        openTab(BotGroups.tabKey(group.id))
                    }
                }
                .id(request.id)
            } else if let request = botEditor {
                Card(title: request.bot.map { "Edit \($0.name)" } ?? "New Bot", isFocused: focus == .conversation) {
                    if let bot = request.bot { BotAvatar(look: bot.look, size: 18, animates: false) } else { Image(systemName: "face.smiling") }
                } actions: {
                    Button("Close", systemImage: "xmark") { withAnimation(.ui) { botEditor = nil } }
                        .help("Close")
                } content: {
                    BotEditor(bot: request.bot, recipe: request.recipe) {
                        withAnimation(.ui) { botEditor = nil }
                    } created: { bot in
                        openTab(bot.sessionID)
                    }
                }
                .id(request.id)
            } else if let id = groupID, let group = groups.group(id) {
                Card(title: group.name, detail: groupDetail(group), isFocused: focus == .conversation) {
                    GroupAvatar(faces: faces(of: group), size: 20)
                } actions: {
                    Button("Edit Group Chat", systemImage: "slider.horizontal.3") { openGroupEditor(group: group) }
                        .help("Edit Group Chat: its name, bots and lead")
                    Button("Close Tab", systemImage: "xmark") { closeTab(BotGroups.tabKey(id)) }
                        .help("Close Tab")
                } content: {
                    GroupChatView(group: group, findRequest: groupFind)
                }
                .id(BotGroups.tabKey(id))
            } else if let id = sessionID, let model = workspace.model(for: id) {
                let directory = model.session.location.directory
                let machine = machine(for: directory)
                let bot = bots.bot(forSession: id)
                // A bot's card has its name only: its avatar shows where it lives.
                Card(title: bot?.name ?? model.session.title ?? "New Session", detail: bot == nil ? workspace.projectName(directory) : nil, isFocused: focus == .conversation) {
                    if let bot {
                        // Still: in view, the bot moves in its conversation.
                        BotAvatar(look: bot.look, size: 18, mood: bots.mood(of: bot, in: workspace), animates: false)
                            .overlay(alignment: .bottomTrailing) {
                                if let machine = bot.machine { MachineBadge(machine: machine, size: 10).offset(x: 3, y: 3) }
                            }
                    } else if let logo = logo(for: model.session.model, in: directory) { ProviderLogo(id: logo, size: 14) } else { Image(systemName: "bubble.left") }
                } actions: {
                    if let bot {
                        Button("Edit Bot", systemImage: "slider.horizontal.3") { openBotEditor(bot: bot) }
                            .help("Edit Bot: its look, job, wake-ups and memory")
                    }
                    if Workspace.isChat(directory) {
                        MoveToProjectButton(sessionID: id)
                    }
                    if !(machine?.isLive ?? app.isLive) {
                        Image(systemName: "bolt.horizontal.circle")
                            .foregroundStyle(.orange)
                            .help(machine.map { "Reconnecting to \($0.machine.name)…" } ?? "Reconnecting to the engine…")
                    }
                    ContextGauge(model: model)
                        .disabled(machine.map { !$0.isReady || !$0.isLive } ?? false)
                    Button("Close Tab", systemImage: "xmark") { closeTab(id) }
                        .help("Close Tab")
                } content: {
                    SessionView(model: model)
                        .environment(\.bot, bot)
                }
                .environment(catalog(for: directory))
                .id(id)
            } else if let id = sessionID, let engine = app.machines.engine(workspace.waitingMachine(for: id)) {
                Card(title: workspace.remoteTitle(id) ?? "Session", detail: engine.machine.name, isFocused: focus == .conversation) {
                    Image(systemName: "server.rack")
                } actions: {
                    Button("Close Tab", systemImage: "xmark") { closeTab(id) }
                        .help("Close Tab")
                } content: {
                    MachineWaitingView(engine: engine)
                }
                .id(id)
            } else if let directory = draftDirectory, let engine = machine(for: directory), !engine.isReady {
                Card(title: "New Session", detail: workspace.projectName(directory), isFocused: focus == .conversation) {
                    Image(systemName: "square.and.pencil")
                } actions: {
                    Button("Close Tab", systemImage: "xmark") { closeTab(SidebarView.draftTag(directory)) }
                        .help("Close Tab")
                } content: {
                    MachineWaitingView(engine: engine)
                }
                .id(directory)
            } else if let directory = draftDirectory {
                let catalog = catalog(for: directory)
                let isChat = Workspace.isChat(directory)
                Card(title: isChat ? "New Chat" : "New Session", detail: isChat ? nil : workspace.projectName(directory), isFocused: focus == .conversation) {
                    Image(systemName: "square.and.pencil")
                } actions: {
                    Button("Close Tab", systemImage: "xmark") { closeTab(SidebarView.draftTag(directory)) }
                        .help("Close Tab")
                } content: {
                    DraftSessionView(directory: directory, focusRequest: draftFocus) { session, text, files in
                        // The first takes the draft's tab and stays in view; more attempts open at the end.
                        let draft = SidebarView.draftTag(directory)
                        if tabs.contains(draft) {
                            replaceTab(draft, with: session.id)
                        } else if !tabs.contains(session.id) {
                            tabs.append(session.id)
                        }
                        workspace.model(for: session.id)?.submit(text, files: files, for: catalog.model(session.model), queue: false, commands: catalog.commands(in: directory))
                    }
                }
                .environment(catalog)
                .id(directory)
            } else {
                Card(title: AppInfo.name, isFocused: focus == .conversation) {
                    AppLogo(size: 16)
                } content: {
                    WelcomeView(openFolder: openFolder, newChat: { newSession(in: Workspace.chatsFolder) }, showProviders: { app.openSettings(.accounts) })
                }
            }
        }
        .simultaneousGesture(TapGesture().onEnded { focus = .conversation })
    }

    private var utilitiesPane: some View {
        UtilitiesPane(
            utilities: utilities,
            directory: activeDirectory,
            folders: activeDirectory.map { [$0] + workspace.extraFolders($0) } ?? [],
            model: activeModel,
            environment: app.shellEnvironment,
            isExpanded: $panelExpanded,
            isFocused: focus == .changes
        )
        .environment(catalog(for: activeDirectory))
        .simultaneousGesture(TapGesture().onEnded { focus = .changes })
    }

    /// Opens the panel on a tool.
    private func showInPanel(_ open: () -> Void) {
        withAnimation(.ui) {
            open()
            showsPanel = true
            app.showsSettings = false
        }
    }

    /// Makes a bot (from a shared one's `recipe`, if given), or changes `bot`, in the main card.
    private func openBotEditor(bot: Bot?, recipe: BotRecipe? = nil) {
        withAnimation(.ui) {
            panelExpanded = false
            app.showsSettings = false
            groupEditor = nil
            botEditor = BotEditorRequest(bot: bot, recipe: recipe)
        }
        focus = .conversation
    }

    /// Makes a group chat, or changes `group`, in the main card.
    private func openGroupEditor(group: BotGroup?) {
        withAnimation(.ui) {
            panelExpanded = false
            app.showsSettings = false
            botEditor = nil
            groupEditor = GroupEditorRequest(group: group)
        }
        focus = .conversation
    }

    /// Under a group chat's name: who's in it.
    private func groupDetail(_ group: BotGroup) -> String? {
        let names = group.members.compactMap { bots.bot($0)?.name }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// Back from Settings to the sessions, as they were.
    /// Settings' tabs: the page you're on (it stays), then each site you're signing in to.
    private var settingsTabItems: [TabItem] {
        let page = SettingsPage(rawValue: settingsPage) ?? .general
        return [TabItem(id: Self.settingsPageTab, title: page.title, logo: nil, status: .idle, symbol: page.symbol, closes: false)]
            + app.settingsTabs.sites.map { TabItem(id: $0.id, title: $0.service.title, logo: nil, status: .idle, symbol: $0.service.symbol) }
    }

    private static let settingsPageTab = "settings.page"

    /// The title bar keeps its row: with the tab bar, or with Settings' tabs (even when you hid
    /// the tab bar, they need somewhere to be).
    private var keepsTitleBar: Bool {
        showsTabBar || (app.showsSettings && !app.settingsTabs.sites.isEmpty)
    }

    private var settingsTabSelection: Binding<String?> {
        Binding(get: { app.settingsTabs.selected ?? Self.settingsPageTab },
                set: { app.settingsTabs.selected = $0 == Self.settingsPageTab ? nil : $0 })
    }

    private func closeSettings() {
        withAnimation(.ui) { app.showsSettings = false }
    }

    // MARK: Tabs

    /// Shows a session or draft, opening a tab for it next to the current one if needed.
    private func openTab(_ key: String) {
        var tabs = tabs
        if !tabs.contains(key) {
            let index = selection.flatMap { tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? tabs.count
            tabs.insert(key, at: index)
            self.tabs = tabs
        }
        withAnimation(.ui) {
            selection = key
            focus = .conversation
            app.showsSettings = false
            botEditor = nil
            groupEditor = nil
        }
    }

    /// Closes a tab; one you close (rather than a deleted session's) can be reopened.
    private func closeTab(_ key: String, remember: Bool = true) {
        var tabs = tabs
        guard let index = tabs.firstIndex(of: key) else { return }
        tabs.remove(at: index)
        if remember { rememberClosed([ClosedTab(key: key, index: index)]) }
        withAnimation(.ui) {
            self.tabs = tabs
            if selection == key {
                selection = tabs.indices.contains(index) ? tabs[index] : tabs.last
            }
        }
    }

    /// Closes every tab but `key`, or all of them when it's nil.
    private func closeTabs(except key: String?) {
        // Reopened last first, so the leftmost comes back last.
        rememberClosed(tabs.enumerated().filter { $0.element != key }.map { ClosedTab(key: $0.element, index: $0.offset) }.reversed())
        withAnimation(.ui) {
            tabs = tabs.filter { $0 == key }
            selection = key
        }
    }

    private func rememberClosed(_ closed: [ClosedTab]) {
        closedTabs.append(contentsOf: closed)
        if closedTabs.count > 50 { closedTabs.removeFirst(closedTabs.count - 50) }
    }

    /// Not open again already, and not a session deleted since.
    private func canReopen(_ closed: ClosedTab) -> Bool {
        !tabs.contains(closed.key) && (SidebarView.draftDirectory(from: closed.key) != nil || workspace.session(closed.key) != nil
            || groups.group(BotGroups.groupID(fromTab: closed.key)) != nil)
    }

    /// Opens the tab closed last, where it was, skipping sessions deleted since.
    private func reopenClosedTab() {
        while let closed = closedTabs.popLast() {
            var tabs = tabs
            guard canReopen(closed) else { continue }
            tabs.insert(closed.key, at: min(closed.index, tabs.count))
            withAnimation(.ui) {
                self.tabs = tabs
                selection = closed.key
                focus = .conversation
            }
            return
        }
    }

    /// Adds a file's lines ("@src/App.swift:12-20") or a terminal's output to what's in the
    /// composer of the tab in view, and puts the cursor there.
    private func addToMessage(_ addition: String) {
        // With no tab open, a new session gets it.
        if selection == nil { newSession(in: nil) }
        guard let key = selection else { return }
        var text = Drafts.shared[key].text
        let isBlock = addition.hasPrefix("```")
        if !text.isEmpty {
            if isBlock { if !text.hasSuffix("\n") { text += "\n" } } else if !(text.last?.isWhitespace ?? true) { text += " " }
        }
        Drafts.shared[key].text = text + addition + (isBlock ? "\n" : " ")
        if SidebarView.draftDirectory(from: key) != nil { draftFocus += 1 } else { workspace.model(for: key)?.focusComposer() }
        focus = .conversation
    }

    /// Attaches files to the message in the composer of the tab in view, and puts the cursor there.
    private func attachToMessage(_ files: [URL]) {
        if selection == nil { newSession(in: nil) }
        guard let key = selection else { return }
        Drafts.shared[key].files += files.filter { !Drafts.shared[key].files.contains($0) }
        if SidebarView.draftDirectory(from: key) != nil { draftFocus += 1 } else { workspace.model(for: key)?.focusComposer() }
        focus = .conversation
    }

    /// A draft became a real session: it keeps its place in the tab strip.
    private func replaceTab(_ key: String, with id: String) {
        var tabs = tabs
        if let index = tabs.firstIndex(of: key) { tabs[index] = id } else { tabs.append(id) }
        self.tabs = tabs
        selection = id
    }

    private func cycleTabs(by offset: Int) {
        let tabs = tabs
        guard !tabs.isEmpty else { return }
        let index = selection.flatMap { tabs.firstIndex(of: $0) } ?? 0
        withAnimation(.ui) { selection = tabs[(index + offset + tabs.count) % tabs.count] }
    }

    /// Deleted sessions lose their tabs.
    private func dropClosedSessions(_ ids: [String]) {
        guard workspace.isLoaded else { return }
        let known = Set(ids)
        // A machine's sessions wait for it to connect.
        for key in tabs where SidebarView.draftDirectory(from: key) == nil && !known.contains(key) && workspace.waitingMachine(for: key) == nil {
            // A group chat's tab stays as long as the chat does.
            if let id = BotGroups.groupID(fromTab: key), groups.group(id) != nil { continue }
            closeTab(key, remember: false)
        }
        // A selection that isn't one of the tabs (its session went while the app was closed)
        // shows nothing; show the last tab instead.
        if let selection, !tabs.contains(selection) { self.selection = tabs.last }
    }

    // MARK: Actions

    private var actions: SessionActions {
        let model = activeModel
        return SessionActions(
            hasSession: model != nil,
            hasProject: activeDirectory != nil,
            canStop: model?.isRunning == true,
            canReopenTab: closedTabs.contains(where: canReopen),
            newSession: { newSession(in: nil) },
            openFolder: openFolder,
            newProject: { projectSheet = ProjectSheetRequest(project: nil) },
            newBot: { openBotEditor(bot: nil) },
            importBot: { if let recipe = BotRecipe.pick() { openBotEditor(bot: nil, recipe: recipe) } },
            newGroup: { openGroupEditor(group: nil) },
            newChat: { newSession(in: Workspace.chatsFolder) },
            stop: { model?.stop() },
            selectAgent: { model?.selectAgent($0) },
            togglePanel: { withAnimation(.ui) { showsPanel.toggle() } },
            showChanges: { showInPanel { utilities.showChanges() } },
            showFiles: { showInPanel { utilities.showFiles() } },
            newTerminal: { showInPanel { utilities.newTerminal(in: activeDirectory, environment: app.shellEnvironment) } },
            run: runProject,
            newBrowser: { showInPanel { utilities.newBrowser() } },
            toggleSidebar: { withAnimation(.ui) { showsSidebar.toggle() } },
            nextTab: { cycleTabs(by: 1) },
            previousTab: { cycleTabs(by: -1) },
            closeTab: {
                // In Settings, ⌘W goes back to the sessions. With no tab left, it closes the
                // window, as it does in browsers.
                if app.showsSettings { closeSettings() } else if let selection { closeTab(selection) } else { NSApp.keyWindow?.performClose(nil) }
            },
            reopenTab: reopenClosedTab,
            find: {
                if let model = activeModel { model.showFind() } else if selection.flatMap(BotGroups.groupID(fromTab:)) != nil { groupFind += 1 }
            },
            showTab: { number in
                let tabs = tabs
                guard !tabs.isEmpty else { return }
                let index = number == 9 ? tabs.count - 1 : number - 1
                if tabs.indices.contains(index) { openTab(tabs[index]) }
            },
            showProviders: { app.openSettings(.accounts) },
            openQuickly: {
                showsPalette = false
                showsOpenQuickly = true
            },
            commandPalette: {
                showsOpenQuickly = false
                showsPalette.toggle()
            }
        )
    }

    // MARK: Command palette

    #if DEBUG
    private static let demoPaletteQuery = ProcessInfo.processInfo.environment["KUVO_DEMO_PALETTE"] ?? ""
    #else
    private static let demoPaletteQuery = ""
    #endif

    /// Every session not put away, the latest first, with its project.
    private var paletteSessions: [PaletteItem] {
        workspace.projects.flatMap(\.sessions).sorted { $0.time.updated > $1.time.updated }.map { session in
            PaletteItem(id: "session:" + session.id, kind: .session, title: session.title ?? "New Session", detail: workspace.projectName(session.location.directory),
                        symbol: workspace.worktrees[session.location.directory] == nil ? "bubble.left" : "arrow.triangle.branch") { openTab(session.id) }
        }
    }

    /// What the menus do, with their shortcuts, and each Settings tab. The usual ones first.
    private var paletteActions: [PaletteItem] {
        let actions = actions
        var items: [PaletteItem] = []
        func add(_ title: String, _ symbol: String, _ shortcut: String? = nil, detail: String? = nil, _ run: @escaping () -> Void) {
            items.append(PaletteItem(id: "action:" + title, kind: .action, title: title, detail: detail, symbol: symbol, shortcut: shortcut, run: run))
        }
        add("New Session", "square.and.pencil", "⌘N", actions.newSession)
        if actions.hasProject {
            add("Run", "play.fill", "⌘R", detail: runCommand, actions.run)
        }
        add("New Terminal", "terminal", "⌃`", actions.newTerminal)
        add("New Browser Tab", "globe", "⌥⌘B", actions.newBrowser)
        add("Show Changes", "plusminus", "⌥⌘I", actions.showChanges)
        if actions.hasProject {
            add("Open Quickly…", "doc.text.magnifyingglass", "⇧⌘O", actions.openQuickly)
        }
        add("Accounts…", "person.crop.circle", "⇧⌘K", actions.showProviders)
        add("Show Files", "folder", "⌥⌘F", actions.showFiles)
        add(showsPanel ? "Hide Panel" : "Show Panel", "sidebar.right", "⌥⌘0", actions.togglePanel)
        add(showsSidebar ? "Hide Sessions" : "Show Sessions", "sidebar.left", "⌘0", actions.toggleSidebar)
        add(showsTabBar ? "Hide Tab Bar" : "Show Tab Bar", "rectangle.topthird.inset.filled", "⌥⌘T") { showsTabBar.toggle() }
        add("New Project…", "folder.badge.plus", "⇧⌘N", actions.newProject)
        add("New Bot…", "face.smiling", nil) { openBotEditor(bot: nil) }
        add("Open Folder…", "folder", "⌘O", actions.openFolder)
        if let directory = activeDirectory {
            let primary = workspace.projectDirectory(directory)
            add("Edit Project…", "slider.horizontal.3", detail: workspace.projectName(primary)) {
                projectSheet = ProjectSheetRequest(project: workspace.projects.first { $0.directory == primary } ?? Workspace.Project(directory: primary, sessions: [], settings: workspace.settings[primary] ?? .init()))
            }
        }
        if let model = activeModel {
            add("Build Mode", "hammer", "⌥⌘1") { actions.selectAgent("build") }
            add("Plan Mode", "list.bullet.clipboard", "⌥⌘2") { actions.selectAgent("plan") }
            add("Find in Conversation…", "magnifyingglass", "⌘F", actions.find)
            add("Rename Session…", "pencil") {
                renaming = model.session
            }
        }
        if actions.canReopenTab {
            add("Reopen Closed Tab", "arrow.uturn.backward", "⇧⌘T", actions.reopenTab)
        }
        for page in SettingsPage.shown {
            add("Settings › \(page.title)", page.symbol, page == .general ? "⌘," : nil) { app.openSettings(page) }
        }
        return items
    }

    /// The active project's run command, if it has one.
    private var runCommand: String? {
        activeDirectory.flatMap { workspace.settings[workspace.projectDirectory($0)]?.run }
    }

    /// Runs the project's run command in a terminal, in the session's folder (its worktree, if it
    /// has one). Without a command yet, Edit Project opens to set one.
    private func runProject() {
        guard let directory = activeDirectory else { return }
        guard let command = runCommand else {
            let primary = workspace.projectDirectory(directory)
            let project = workspace.projects.first { $0.directory == primary } ?? Workspace.Project(directory: primary, sessions: [], settings: workspace.settings[primary] ?? .init())
            projectSheet = ProjectSheetRequest(project: project, focusesRun: true)
            return
        }
        showInPanel { utilities.run(command, in: directory, environment: app.shellEnvironment) }
    }

    /// Starts a draft in `directory`, or in the current project (a worktree's, for a session in one).
    /// A new session in `directory`, or the project in view, or the latest one; with no project
    /// at all, a chat.
    private func newSession(in directory: String?) {
        let directory = directory ?? activeDirectory.map(workspace.projectDirectory) ?? workspace.projects.first?.directory ?? Workspace.chatsFolder
        openTab(SidebarView.draftTag(directory))
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose a project folder for the agent to work in."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.addFolder(url.path)
        newSession(in: url.path)
    }

    /// With nothing open, pick up where the user left off.
    private func startIfEmpty() {
        guard workspace.isLoaded, tabs.isEmpty, let latest = workspace.projects.first?.sessions.first else { return }
        openTab(latest.id)
    }

    #if DEBUG
    /// The comment and prompt go in once, however often the view reappears.
    private static var ranDemo = false

    /// For trying the app without clicking: KUVO_DEMO_FOLDER opens a project, and
    /// KUVO_DEMO_PROMPT (with KUVO_DEMO_MODEL as "provider/model") starts a session with it.
    /// KUVO_DEMO_PROVIDERS opens Accounts, on that provider's sign-in if it names one.
    /// KUVO_DEMO_APPEARANCE=light|dark forces an appearance. KUVO_DEMO_WINDOW sets the window size.
    /// KUVO_DEMO_COMMENT adds a review comment.
    private func runDemoIfAsked() async {
        let environment = ProcessInfo.processInfo.environment
        // Launched from Terminal for screenshots, the window would otherwise stay inactive.
        // KUVO_DEMO_BACKGROUND leaves the copy behind other apps, so it doesn't take the keyboard.
        if environment.keys.contains(where: { $0.hasPrefix("KUVO_DEMO_") }), environment["KUVO_DEMO_BACKGROUND"] == nil { NSApp.activate() }
        if AppInfo.staysInBackground {
            // Behind every other window, not just the one in front: when you close or hide that,
            // macOS brings forward the app whose window is next.
            Task {
                for _ in 0..<3 {
                    for window in NSApp.windows where window.isVisible { window.orderBack(nil) }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        switch environment["KUVO_DEMO_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if environment["KUVO_DEMO_CHANGES"] != nil { showsPanel = true }
        // KUVO_DEMO_PALETTE=<text>: the command palette, with that typed in it.
        if workspace.isLoaded, environment["KUVO_DEMO_PALETTE"] != nil { showsPalette = true }
        // KUVO_DEMO_WINDOW=WIDTHxHEIGHT resizes the window, for checking narrow layouts.
        if let size = environment["KUVO_DEMO_WINDOW"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
           let window = NSApp.windows.first(where: \.isVisible) {
            var frame = window.frame
            frame.size = CGSize(width: size[0], height: size[1])
            window.setFrame(frame, display: true, animate: false)
            // Again once window restoration has settled.
            try? await Task.sleep(for: .seconds(1))
            window.setFrame(frame, display: true, animate: false)
        }
        if workspace.isLoaded, environment["KUVO_DEMO_PROVIDERS"] != nil { app.openSettings(.accounts) }
        // KUVO_DEMO_NEW_PROJECT=<folder>,<folder>: the New Project sheet with these folders.
        if workspace.isLoaded, let list = environment["KUVO_DEMO_NEW_PROJECT"] {
            projectSheet = ProjectSheetRequest(project: nil, folders: list.split(separator: ",").map(String.init))
        }
        // KUVO_DEMO_SETTINGS=<page> opens Settings on that page, by its SettingsPage name: general,
        // appearance, storage, accounts, agents, mcp, git, browser, passwords and so on.
        if workspace.isLoaded, let tab = environment["KUVO_DEMO_SETTINGS"] {
            app.openSettings(SettingsPage(rawValue: tab))
        }
        guard workspace.isLoaded, !Self.ranDemo else { return }
        Self.ranDemo = true
        // KUVO_DEMO_WELCOME: no tabs, so the welcome card shows.
        if environment["KUVO_DEMO_WELCOME"] != nil {
            tabs = []
            selection = nil
        }
        // The folder's new session first, so the panel's tools open in it.
        if let folder = environment["KUVO_DEMO_FOLDER"], environment["KUVO_DEMO_PROMPT"] == nil { newSession(in: folder) }
        // KUVO_DEMO_PANEL: tools to open in the panel, comma-separated: terminal,
        // browser=<address>, machine=<machine>[=<address>] (a tab in its browser, with a session
        // there in view), files, file=<path>, changes, run (the project's run command), expand.
        for item in (environment["KUVO_DEMO_PANEL"] ?? "").split(separator: ",").map(String.init) {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            switch parts.first {
            case "terminal": utilities.newTerminal(in: activeDirectory, environment: app.shellEnvironment)
            case "browser": utilities.newBrowser(parts.count > 1 ? parts[1] : nil)
            case "machine" where parts.count > 1:
                let rest = parts[1].split(separator: "=", maxSplits: 1).map(String.init)
                // Once a session there is in view, so the tab shows.
                Task {
                    for _ in 0..<60 where utilities.place != rest[0] { try? await Task.sleep(for: .milliseconds(500)) }
                    utilities.newMachinePage(rest[0], address: rest.count > 1 ? rest[1] : nil)
                }
            case "files": utilities.showFiles()
            case "file" where parts.count > 1: utilities.open(RemoteFolder.url(parts[1]))
            case "changes": utilities.showChanges()
            case "run": runProject()
            case "expand": panelExpanded = true
            // toggle=<seconds>: expands and collapses it a few times, that far apart.
            case "toggle" where parts.count > 1:
                let wait = Double(parts[1]) ?? 3
                Task {
                    for _ in 0..<4 {
                        try? await Task.sleep(for: .seconds(wait))
                        withAnimation(.ui) { panelExpanded.toggle() }
                    }
                }
            default: continue
            }
            showsPanel = true
        }
        // KUVO_DEMO_IMPORT_BOT=<path>: New Bot, from that shared bot's file.
        if let path = environment["KUVO_DEMO_IMPORT_BOT"], let data = FileManager.default.contents(atPath: path),
           let recipe = try? JSONDecoder().decode(BotRecipe.self, from: data) {
            openBotEditor(bot: nil, recipe: recipe)
        }
        // KUVO_DEMO_CHAT=<message>: a new chat, with this message sent; KUVO_DEMO_MOVE_CHAT=<folder>
        // then moves the newest chat into that project.
        if let message = environment["KUVO_DEMO_CHAT"] {
            Task {
                while app.api == nil { try? await Task.sleep(for: .seconds(1)) }
                guard let session = try? await workspace.createSession(in: Workspace.chatsFolder, model: nil, agent: nil) else { return }
                openTab(session.id)
                workspace.model(for: session.id)?.submit(message, files: [], for: nil, queue: false, commands: [])
            }
        }
        if let folder = environment["KUVO_DEMO_MOVE_CHAT"] {
            Task {
                while !workspace.isLoaded { try? await Task.sleep(for: .seconds(1)) }
                // With KUVO_DEMO_CHAT, after its reply, while it's open.
                try? await Task.sleep(for: .seconds(environment["KUVO_DEMO_CHAT"] == nil ? 3 : 16))
                let log = Logger(subsystem: "run.kuvo.code", category: "demo")
                guard let chat = workspace.chats.first else { return log.error("KUVO_DEMO_MOVE_CHAT: no chat") }
                do {
                    try await workspace.move(chat.id, toProject: folder)
                    openTab(chat.id)
                } catch {
                    log.error("KUVO_DEMO_MOVE_CHAT failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        // KUVO_DEMO_UNDO_RESEND=<seconds>: in the session in view, undoes its last message, then
        // sends it again after that many seconds.
        if let wait = environment["KUVO_DEMO_UNDO_RESEND"].flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(6))
                guard let id = sessionID, let model = workspace.model(for: id) else { return }
                if !model.isLoaded { await model.load() }
                guard let last = model.transcript.messages.last(where: { if case .user = $0 { true } else { false } }), case .user(let user) = last else { return }
                model.undo(from: user)
                try? await Task.sleep(for: .seconds(wait))
                model.submit(model.draftText, files: model.draftFiles, for: nil, queue: false, commands: [])
                model.draftText = ""
                model.draftFiles = []
            }
        }
        // KUVO_DEMO_MACHINE_BROWSING=<machine>|<seconds>: as if an agent on that machine started
        // using its browser that long after launch, through the same event the engine sends.
        if let value = environment["KUVO_DEMO_MACHINE_BROWSING"] {
            let parts = value.split(separator: "|").map(String.init)
            Task { [workspace] in
                try? await Task.sleep(for: .seconds(parts.count > 1 ? Double(parts[1]) ?? 3 : 3))
                let json = #"{"id":"evt_demo","type":"session.tool.input.started","data":{"sessionID":"ses_demo","assistantMessageID":"msg_demo","id":"call_demo","name":"kuvo-browser_browser_navigate"}}"#
                if let event = try? ServerEvent(json: Data(json.utf8)) { workspace.handle(event, machine: parts[0]) }
            }
        }
        // KUVO_DEMO_ASKING[=<title>]: every few seconds, as if the agent of the session in view (the
        // one with that title, once it shows) started asking in its browser; the ask itself comes
        // from calling the browser's tools.
        if let title = environment["KUVO_DEMO_ASKING"] {
            Task { [workspace] in
                var opened = false
                while true {
                    try? await Task.sleep(for: .seconds(5))
                    if !opened, !["", "1"].contains(title), let session = workspace.sessions.first(where: { $0.title == title }) {
                        openTab(session.id)
                        opened = true
                    }
                    guard let id = sessionID, let session = workspace.session(id) else { continue }
                    workspace.onBrowserAsk?(id, RemoteFolder.machine(of: session.location.directory))
                }
            }
        }
        // KUVO_DEMO_CYCLE_TABS=<seconds>: goes to the next session tab every so often, a few times.
        if let wait = environment["KUVO_DEMO_CYCLE_TABS"].flatMap(Double.init) {
            Task {
                for _ in 0..<4 {
                    try? await Task.sleep(for: .seconds(wait))
                    cycleTabs(by: 1)
                }
            }
        }
        // KUVO_DEMO_REOPEN_WINDOW=<seconds>: closes the window after that long, and opens it again.
        if let wait = environment["KUVO_DEMO_REOPEN_WINDOW"].flatMap(Double.init) {
            Task { [app] in
                try? await Task.sleep(for: .seconds(wait))
                NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.performClose(nil)
                try? await Task.sleep(for: .seconds(2))
                app.openMainWindow?()
            }
        }
        // KUVO_DEMO_TOGGLE_PANEL=<seconds>: shows and hides the panel every so often, a few times.
        if let every = environment["KUVO_DEMO_TOGGLE_PANEL"].flatMap(Double.init) {
            Task {
                for _ in 0..<6 {
                    try? await Task.sleep(for: .seconds(every))
                    withAnimation(.ui) { showsPanel.toggle() }
                }
            }
        }
        // KUVO_DEMO_VIEW_IMAGE=<path>,…: those pictures in the image viewer.
        if let paths = environment["KUVO_DEMO_VIEW_IMAGE"] {
            ImageViewer.shared.show(paths.split(separator: ",").map { AttachmentItem.local(URL(filePath: String($0))) })
        }
        // KUVO_DEMO_NEW_BOT: the New Bot sheet.
        if environment["KUVO_DEMO_NEW_BOT"] != nil { openBotEditor(bot: nil) }
        // In a task of its own: SwiftUI cancels and restarts this view's task while the
        // window settles, which would cut the session's creation short.
        Task { await runDemoSession(environment) }
        Task { await runDemoBot(environment) }
        Task { await runDemoGroup(environment) }
    }

    /// KUVO_DEMO_GROUP=<name>|<bot>,<bot>,…[|<message>] makes that group chat of those bots unless
    /// one has the name, opens it, and sends it the message; KUVO_DEMO_EDIT_GROUP opens its editor.
    private func runDemoGroup(_ environment: [String: String]) async {
        if environment["KUVO_DEMO_NEW_GROUP"] != nil { openGroupEditor(group: nil) }
        guard let spec = environment["KUVO_DEMO_GROUP"] else { return }
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return }
        let members = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { member in
            bots.list.first { $0.name == member.trimmingCharacters(in: .whitespaces) }?.id
        }
        let group = groups.list.first { $0.name == name } ?? groups.create(name: name, members: members)
        openTab(BotGroups.tabKey(group.id))
        if environment["KUVO_DEMO_EDIT_GROUP"] != nil { openGroupEditor(group: group) }
        // KUVO_DEMO_GROUP_UNDO=<seconds>: then undoes from your last message there, into the composer.
        if let wait = environment["KUVO_DEMO_GROUP_UNDO"].flatMap(Double.init) {
            try? await Task.sleep(for: .seconds(wait))
            if let last = groups.messages(in: group.id).last(where: { $0.author == nil && $0.kind != .note }),
               let text = groups.undo(from: last.id, in: group.id) {
                Drafts.shared[BotGroups.tabKey(group.id)].text = text
            }
        }
        guard parts.count > 2, !parts[2].isEmpty else { return }
        while app.api == nil { try? await Task.sleep(for: .seconds(1)) }
        try? await Task.sleep(for: .seconds(2))
        groups.send(parts[2], to: group.id)
        // KUVO_DEMO_GROUP_LATER=<seconds>|<message>: another message, sent while they talk.
        let later = (environment["KUVO_DEMO_GROUP_LATER"] ?? "").split(separator: "|", maxSplits: 1).map(String.init)
        if later.count == 2, let seconds = Double(later[0]) {
            try? await Task.sleep(for: .seconds(seconds))
            groups.send(later[1], to: group.id)
        }
    }

    /// KUVO_DEMO_BOT=<name>|<job>|<instructions>[|<machine>] makes that bot unless one has the
    /// name, and opens it; KUVO_DEMO_BOT_PROMPT then gives it a task, and KUVO_DEMO_EDIT_BOT
    /// opens its Edit Bot sheet.
    private func runDemoBot(_ environment: [String: String]) async {
        guard let spec = environment["KUVO_DEMO_BOT"] else { return }
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return }
        var bot = bots.list.first { $0.name == name }
        if bot == nil {
            if parts.count > 3, let engine = app.machines.engine(parts[3]) {
                while !engine.isReady { try? await Task.sleep(for: .seconds(1)) }
            }
            do {
                bot = try await bots.create(name: name, job: parts.count > 1 ? parts[1] : "", instructions: parts.count > 2 ? parts[2] : "",
                                            look: .random(), model: nil, machine: parts.count > 3 ? parts[3] : nil, project: nil)
            } catch {
                print("KUVO_DEMO_BOT failed: \(error.localizedDescription)")
                return
            }
        }
        guard let bot else { return }
        openTab(bot.sessionID)
        // KUVO_DEMO_EDIT_BOT: its Edit Bot sheet, open.
        if environment["KUVO_DEMO_EDIT_BOT"] != nil { openBotEditor(bot: bot) }
        // KUVO_DEMO_REPLY: a reply sent as a notification's Reply sends it.
        if let reply = environment["KUVO_DEMO_REPLY"] { await workspace.send(reply, to: bot.sessionID) }
        if let prompt = environment["KUVO_DEMO_BOT_PROMPT"], let model = workspace.model(for: bot.sessionID) {
            try? await Task.sleep(for: .seconds(1))
            model.submit(prompt, files: [], for: nil, queue: false, commands: [])
        }
    }

    private func runDemoSession(_ environment: [String: String]) async {
        // KUVO_DEMO_SHOW_IN_PANEL=<path>|<folder or file>: as if the agent of the session in view
        // showed that in the panel (its show_in_panel tool), once it's been connected a while.
        if let spec = environment["KUVO_DEMO_SHOW_IN_PANEL"] {
            let parts = spec.split(separator: "|").map(String.init)
            Task { [workspace] in
                try? await Task.sleep(for: .seconds(18))
                guard let id = sessionID, let session = workspace.session(id), parts.count == 2 else { return }
                let machine = RemoteFolder.machine(of: session.location.directory)
                let said = BrowserTools.shown(parts[0], isFolder: parts[1] == "folder")
                for (type, data) in [
                    ("session.tool.input.started", #""name":"kuvo-browser_show_in_panel""#),
                    ("session.tool.called", #""input":{"path":\#(String(decoding: try! JSONEncoder().encode(parts[0]), as: UTF8.self))}"#),
                    ("session.tool.success", #""content":[{"type":"text","text":\#(String(decoding: try! JSONEncoder().encode(said), as: UTF8.self))}]"#),
                ] {
                    let json = #"{"id":"evt_demo","type":"\#(type)","data":{"sessionID":"\#(id)","assistantMessageID":"msg_demo","id":"call_show",\#(data)}}"#
                    if let event = try? ServerEvent(json: Data(json.utf8)) { workspace.handle(event, machine: machine) }
                }
            }
        }
        // KUVO_DEMO_SESSION=<id>: that session's tab, in view (one on a machine waits for it).
        if let id = environment["KUVO_DEMO_SESSION"] {
            openTab(id)
            // KUVO_DEMO_FIND=<words>: Find in it, looking for those (once it's read, on a machine).
            if let words = environment["KUVO_DEMO_FIND"] {
                Task { [workspace] in
                    for _ in 0..<60 {
                        if let model = workspace.model(for: id), model.isLoaded {
                            try? await Task.sleep(for: .seconds(1))
                            model.showFind(words)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
            }
            // KUVO_DEMO_QUOTES=<n>: that many quotes to answer in its composer.
            if let count = Int(environment["KUVO_DEMO_QUOTES"] ?? "") {
                Drafts.shared[id].quotes = []
                for index in 1...max(count, 1) {
                    let text = "Point \(index): " + String(repeating: "a quoted line from the agent's reply ", count: index % 3 + 1)
                    if let model = workspace.model(for: id) { model.addQuote(text, how: "demo") } else { Drafts.shared.addQuote(text, to: id) }
                }
            }
        }
        // KUVO_DEMO_TABS: the project's sessions as tabs, the one in view staying in view.
        if environment["KUVO_DEMO_TABS"] != nil,
           let project = workspace.projects.first(where: { $0.directory == activeDirectory }) ?? workspace.projects.first {
            let current = selection
            for session in project.sessions.reversed() where !tabs.contains(session.id) { openTab(session.id) }
            if let current { openTab(current) }
        }
        // KUVO_DEMO_COMMENT=<path in the project>:<line>:<text> adds a review comment to the
        // session in view, on that line of the changes.
        if let spec = environment["KUVO_DEMO_COMMENT"], let directory = activeDirectory {
            let parts = spec.split(separator: ":", maxSplits: 2).map(String.init)
            try? await Task.sleep(for: .seconds(2))
            if parts.count == 3, let line = Int(parts[1]), let selection, let model = workspace.model(for: selection),
               let text = try? String(contentsOfFile: directory + "/" + parts[0], encoding: .utf8) {
                let lines = text.components(separatedBy: "\n")
                let snippet = lines.indices.contains(line - 1) ? lines[line - 1].trimmingCharacters(in: .whitespaces) : ""
                model.reviewComments.append(ReviewComment(file: parts[0], line: line, side: .new, snippet: snippet, text: parts[2]))
            }
        }
        guard let folder = environment["KUVO_DEMO_FOLDER"] else { return }
        // KUVO_DEMO_DRAFT: a message typed, not sent, in the new session's composer.
        if let draft = environment["KUVO_DEMO_DRAFT"] { Drafts.shared[SidebarView.draftTag(folder)].text = draft }
        guard let prompt = environment["KUVO_DEMO_PROMPT"] else { return newSession(in: folder) }
        let parts = environment["KUVO_DEMO_MODEL"]?.split(separator: "/", maxSplits: 1).map(String.init)
        let model = parts.flatMap { $0.count == 2 ? ModelRef(id: $0[1], providerID: $0[0]) : nil }
        // Like a new session from the UI: the chosen model, or the default one. KUVO_DEMO_WORKTREE
        // gives it a worktree of its own.
        // A folder on a machine: once the machine is connected and its models are known.
        if let engine = machine(for: folder) {
            for _ in 0..<240 where !engine.isReady || engine.catalog.defaultModel == nil { try? await Task.sleep(for: .milliseconds(250)) }
        }
        let catalog = catalog(for: folder)
        guard let session = try? await workspace.createSession(in: folder, model: model ?? catalog.defaultModel?.ref, agent: catalog.startingAgent(chosen: app.engineConfig.value(at: ["default_agent"])?.string), worktree: environment["KUVO_DEMO_WORKTREE"] != nil) else { return }
        openTab(session.id)
        // KUVO_DEMO_FILES: comma-separated paths to attach.
        let files = environment["KUVO_DEMO_FILES"]?.split(separator: ",").map { URL(filePath: String($0)) } ?? []
        // As the composer sends it: "/" runs a command, "!" a shell command.
        workspace.model(for: session.id)?.submit(prompt, files: files, for: catalog.model(session.model), queue: false, commands: catalog.commands(in: folder))
        // KUVO_DEMO_QUEUE: messages separated by "|", queued once the agent is working.
        guard let queue = environment["KUVO_DEMO_QUEUE"], let model = workspace.model(for: session.id) else { return }
        for _ in 0..<40 where !model.isRunning { try? await Task.sleep(for: .milliseconds(250)) }
        for message in queue.split(separator: "|") {
            model.submit(String(message), files: [], for: catalog.model(session.model), queue: true, commands: catalog.commands(in: folder))
        }
    }
    #endif
}

/// How wide each card gets in the room the window has. The conversation always
/// keeps its minimum; when space runs out, Changes shrinks first, then Sessions,
/// then Changes hides, then Sessions. Widen the window and they come back.
struct PaneLayout {
    static let sessionsRange = 220.0...440.0
    static let changesRange = 300.0...900.0
    static let conversationMinimum = 380.0

    /// Widths of the side cards; nil when hidden (by choice, or for lack of room).
    let sessions: Double?
    let changes: Double?
    /// How wide each side card may be dragged right now.
    let sessionsMax: Double
    let changesMax: Double

    init(available: Double, sessions wanted: Double?, changes wantedChanges: Double?) {
        let gap = Double(Metrics.paneGap)
        var sessions = wanted.map { min(max($0, Self.sessionsRange.lowerBound), Self.sessionsRange.upperBound) }
        var changes = wantedChanges.map { min(max($0, Self.changesRange.lowerBound), Self.changesRange.upperBound) }
        func overflow() -> Double {
            (sessions.map { $0 + gap } ?? 0) + (changes.map { $0 + gap } ?? 0) + Self.conversationMinimum - available
        }
        if let width = changes, overflow() > 0 { changes = max(Self.changesRange.lowerBound, width - overflow()) }
        if let width = sessions, overflow() > 0 { sessions = max(Self.sessionsRange.lowerBound, width - overflow()) }
        if changes != nil, overflow() > 0 { changes = nil }
        if sessions != nil, overflow() > 0 { sessions = nil }
        self.sessions = sessions
        self.changes = changes
        let room = available - Self.conversationMinimum
        sessionsMax = min(Self.sessionsRange.upperBound, room - gap - (changes.map { $0 + gap } ?? 0))
        changesMax = min(Self.changesRange.upperBound, room - gap - (sessions.map { $0 + gap } ?? 0))
    }
}

/// The engine is taking a while, most often because macOS is asking whether it may
/// read a folder (Claude skills or a project on the Desktop, say) and waiting for an answer.
private struct SlowEngineNotice: View {
    var body: some View {
        HStack(spacing: 10) {
            Spinner(size: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("Still loading your accounts and models…")
                    .font(.callout.weight(.medium))
                Text("If macOS is asking for access to a folder, answer that dialog.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Which project sheet to show: New Project, or Edit Project for `project`.
/// The bot editor: a new bot, or changing `bot`.
/// A chat's way into one of this Mac's projects, in its header.
private struct MoveToProjectButton: View {
    let sessionID: String
    @Environment(Workspace.self) private var workspace

    var body: some View {
        NativeMenuButton(opensBelow: true) {
            let menu = NSMenu()
            let projects = workspace.projects.filter { !RemoteFolder.isRemote($0.directory) }
            menu.addItem(.sectionHeader(title: "Move to Project"))
            for project in projects {
                menu.addItem(ActionItem(project.name, image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)) { move(to: project.directory) })
            }
            if projects.isEmpty {
                let none = NSMenuItem(title: "No projects on this Mac", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
            return menu
        } label: {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 13))
                .frame(width: 26, height: 24)
                .hoverHighlight(in: RoundedRectangle(cornerRadius: 6), mutesInk: true)
        }
        .help("Move to Project: carry this chat into one of your projects")
    }

    private func move(to directory: String) {
        Task {
            do {
                try await workspace.move(sessionID, toProject: directory)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

struct BotEditorRequest: Identifiable {
    let id = UUID()
    let bot: Bot?
    /// A shared bot a new one starts from.
    var recipe: BotRecipe?
}

struct GroupEditorRequest: Identifiable {
    let id = UUID()
    let group: BotGroup?
}

struct ProjectSheetRequest: Identifiable {
    let id = UUID()
    let project: Workspace.Project?
    /// Folders a new project starts with.
    var folders: [String] = []
    /// Puts the cursor in the run command, for Run without one.
    var focusesRun = false
}

/// The app's icon, the `>_` mark, as the system renders it (glass and all).
struct AppLogo: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Shown before there's any project.
struct WelcomeView: View {
    @Environment(Catalog.self) private var catalog
    let openFolder: () -> Void
    let newChat: () -> Void
    let showProviders: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            AppLogo(size: 76)
            Text("Welcome to \(AppInfo.name)")
                .font(.largeTitle.weight(.semibold))
            Text("Open a project folder and tell the agent what to build.\nIt can read, edit and run things there.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Open Folder…", systemImage: "folder", action: openFolder)
                    .buttonStyle(.glassProminent)
                Button("Start a Chat", systemImage: "bubble.left", action: newChat)
                    .buttonStyle(.glass)
                    .help("A conversation of no project (⌥⌘N)")
                Button(catalog.connectedProviders.isEmpty ? "Connect an Account…" : "Accounts…", systemImage: "person.crop.circle.badge.plus", action: showProviders)
                    .buttonStyle(.glass)
            }
            .controlSize(.extraLarge)
            .padding(.top, 8)
            if catalog.connectedProviders.isEmpty {
                Text("Free models work without an account.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
