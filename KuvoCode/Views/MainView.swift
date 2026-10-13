import OpenCodeKit
import SwiftUI

/// The workspace, laid out like Rex: open sessions as tabs in the title bar, and
/// cards floating on the window's glass (sessions, the conversation, changes).
struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(Catalog.self) private var catalog
    @Environment(Workspace.self) private var workspace
    @Environment(\.openSettings) private var openSettings

    /// Open tabs, in order: session IDs, or `draft:<folder>` for a new session
    /// that doesn't exist on the server until its first message.
    @SceneStorage("tabs") private var tabStorage = ""
    /// The active tab.
    @SceneStorage("selection") private var selection: String?
    @SceneStorage("showsSidebar") private var showsSidebar = true
    @SceneStorage("showsPanel") private var showsPanel = false
    /// The panel over the conversation, for room.
    @State private var panelExpanded = false
    @AppStorage("sessionsWidth") private var sessionsWidth = 280.0
    @AppStorage("changesWidth") private var changesWidth = 420.0
    @State private var showsProviders = false
    @State private var focus = Pane.conversation
    /// The window's content width; the title bar is sized from it.
    @State private var contentWidth: CGFloat = 1200

    enum Pane { case sessions, conversation, changes }

    private var tabs: [String] {
        get { tabStorage.split(separator: "\n").map(String.init) }
        nonmutating set { tabStorage = newValue.joined(separator: "\n") }
    }

    private var utilities: Utilities { app.utilities }

    private var sessionID: String? {
        selection.flatMap { SidebarView.draftDirectory(from: $0) == nil ? $0 : nil }
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

    var body: some View {
        // Cards are sized from the room the window actually has, so they never spill
        // past its edges. The gaps between them are drag handles for resizing.
        GeometryReader { proxy in
            let layout = PaneLayout(
                available: proxy.size.width,
                sessions: showsSidebar ? sessionsWidth : nil,
                changes: showsPanel && !panelExpanded ? changesWidth : nil
            )
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
                if showsPanel && panelExpanded {
                    utilitiesPane
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                } else {
                    conversationCard
                        .frame(maxWidth: .infinity)
                }
                if let width = layout.changes {
                    PaneResizer(
                        width: Binding(get: { width }, set: { changesWidth = $0 }),
                        range: PaneLayout.changesRange.lowerBound...max(PaneLayout.changesRange.lowerBound, layout.changesMax),
                        side: .trailing
                    )
                    utilitiesPane
                        .frame(width: width)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { contentWidth = $0 }
        .padding(.horizontal, Metrics.paneGap)
        .padding(.bottom, Metrics.paneGap)
        .animation(.ui, value: showsSidebar)
        .animation(.ui, value: showsPanel)
        .animation(.ui, value: panelExpanded)
        .onDisappear { utilities.closeAll() }
        // The agent started browsing: show it.
        .onChange(of: utilities.revealRequest) { withAnimation(.ui) { showsPanel = true } }
        .toolbar { titleBar }
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
        .sheet(isPresented: $showsProviders) {
            ProvidersView()
                .frame(width: 720, height: 620)
        }
        .focusedSceneValue(\.sessionActions, actions)
        .onChange(of: sessionID) { _, id in
            if let id { workspace.markViewed(id) }
        }
        .onChange(of: workspace.session(sessionID)?.time.idle) {
            if let sessionID { workspace.markViewed(sessionID) }
        }
        .task(id: activeDirectory) {
            if let activeDirectory { await workspace.loadBranch(for: activeDirectory) }
        }
        .onChange(of: workspace.sessions.map(\.id)) { _, ids in dropClosedSessions(ids) }
        .onChange(of: workspace.isLoaded) { startIfEmpty() }
        .onAppear(perform: startIfEmpty)
        #if DEBUG
        .task(id: workspace.isLoaded) { await runDemoIfAsked() }
        #endif
    }

    // MARK: Title bar

    @ToolbarContentBuilder private var titleBar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 16) {
                ProjectIdentity(
                    name: activeDirectory.map { ($0 as NSString).lastPathComponent },
                    branch: activeDirectory.flatMap { workspace.branches[$0] },
                    showsSidebar: $showsSidebar
                )
                if !tabItems.isEmpty {
                    TabStrip(tabs: tabItems, selection: $selection, close: closeTab, closeAll: closeTabs(except:))
                }
            }
            // A width from the window (minus the traffic lights and the Changes button), so a
            // narrow window squeezes the tabs instead of pushing them into a » menu.
            .frame(width: max(240, contentWidth - 150), alignment: .leading)
        }
        .sharedBackgroundVisibility(.hidden)

        // Mirrors the sessions toggle on the left, and looks the same: a plain icon, not a
        // highlighted toggle.
        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(.ui) { showsPanel.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(showsPanel ? "Hide Panel" : "Show Panel")
            .help(showsPanel ? "Hide Panel (⌥⌘0)" : "Show Panel: Changes, Files, Terminal, Browser (⌥⌘0)")
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private var tabItems: [TabItem] {
        tabs.compactMap { key in
            if SidebarView.draftDirectory(from: key) != nil {
                return TabItem(id: key, title: "New Session", logo: nil, status: .idle)
            }
            guard let session = workspace.session(key) else { return nil }
            return TabItem(id: key, title: session.title ?? "New Session", logo: logo(for: session.model), status: status(of: session))
        }
    }

    private func logo(for ref: ModelRef?) -> String? {
        guard let ref else { return nil }
        return catalog.model(ref)?.makerLogoID ?? ref.providerID
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
        Card(title: "Sessions", isFocused: focus == .sessions, showsHeader: false) {
            EmptyView()
        } content: {
            SidebarView(
                selection: Binding(get: { selection }, set: { id in if let id { openTab(id) } }),
                newSession: newSession,
                openFolder: openFolder,
                showProviders: { showsProviders = true }
            )
        }
        .simultaneousGesture(TapGesture().onEnded { focus = .sessions })
    }

    @ViewBuilder private var conversationCard: some View {
        Group {
            if let id = sessionID, let model = workspace.model(for: id) {
                Card(title: model.session.title ?? "New Session", detail: (model.session.location.directory as NSString).lastPathComponent, isFocused: focus == .conversation) {
                    if let logo = logo(for: model.session.model) { ProviderLogo(id: logo, size: 14) } else { Image(systemName: "bubble.left") }
                } actions: {
                    if !app.isLive {
                        Image(systemName: "bolt.horizontal.circle")
                            .foregroundStyle(.orange)
                            .help("Reconnecting to the engine…")
                    }
                    ContextGauge(model: model)
                    Button("Close Tab", systemImage: "xmark") { closeTab(id) }
                        .help("Close Tab")
                } content: {
                    SessionView(model: model)
                }
                .id(id)
            } else if let directory = draftDirectory {
                Card(title: "New Session", detail: (directory as NSString).lastPathComponent, isFocused: focus == .conversation) {
                    Image(systemName: "square.and.pencil")
                } actions: {
                    Button("Close Tab", systemImage: "xmark") { closeTab(SidebarView.draftTag(directory)) }
                        .help("Close Tab")
                } content: {
                    DraftSessionView(directory: directory) { session, text, files in
                        replaceTab(SidebarView.draftTag(directory), with: session.id)
                        workspace.model(for: session.id)?.send(text, files: files, for: catalog.model(session.model))
                    }
                }
                .id(directory)
            } else {
                Card(title: AppInfo.name, isFocused: focus == .conversation) {
                    Image(systemName: "sparkles")
                } content: {
                    WelcomeView(openFolder: openFolder, showProviders: { showsProviders = true })
                }
            }
        }
        .simultaneousGesture(TapGesture().onEnded { focus = .conversation })
    }

    private var utilitiesPane: some View {
        UtilitiesPane(
            utilities: utilities,
            directory: activeDirectory,
            model: activeModel,
            environment: app.shellEnvironment,
            isExpanded: $panelExpanded,
            isFocused: focus == .changes
        )
        .simultaneousGesture(TapGesture().onEnded { focus = .changes })
    }

    /// Opens the panel on a tool.
    private func showInPanel(_ open: () -> Void) {
        withAnimation(.ui) {
            open()
            showsPanel = true
        }
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
        }
    }

    private func closeTab(_ key: String) {
        var tabs = tabs
        guard let index = tabs.firstIndex(of: key) else { return }
        tabs.remove(at: index)
        withAnimation(.ui) {
            self.tabs = tabs
            if selection == key {
                selection = tabs.indices.contains(index) ? tabs[index] : tabs.last
            }
        }
    }

    /// Closes every tab but `key`, or all of them when it's nil.
    private func closeTabs(except key: String?) {
        withAnimation(.ui) {
            tabs = tabs.filter { $0 == key }
            selection = key
        }
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
        for key in tabs where SidebarView.draftDirectory(from: key) == nil && !known.contains(key) {
            closeTab(key)
        }
    }

    // MARK: Actions

    private var actions: SessionActions {
        let model = activeModel
        return SessionActions(
            hasSession: model != nil,
            canStop: model?.isRunning == true,
            newSession: { newSession(in: nil) },
            openFolder: openFolder,
            stop: { model?.stop() },
            selectAgent: { model?.selectAgent($0) },
            togglePanel: { withAnimation(.ui) { showsPanel.toggle() } },
            showChanges: { showInPanel { utilities.showChanges() } },
            showFiles: { showInPanel { utilities.showFiles() } },
            newTerminal: { showInPanel { utilities.newTerminal(in: activeDirectory, environment: app.shellEnvironment) } },
            newBrowser: { showInPanel { utilities.newBrowser() } },
            toggleSidebar: { withAnimation(.ui) { showsSidebar.toggle() } },
            nextTab: { cycleTabs(by: 1) },
            previousTab: { cycleTabs(by: -1) },
            showProviders: { showsProviders = true }
        )
    }

    /// Starts a draft in `directory`, or in the current project.
    private func newSession(in directory: String?) {
        let directory = directory ?? activeDirectory ?? workspace.projects.first?.directory
        guard let directory else { return openFolder() }
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
        if environment.keys.contains(where: { $0.hasPrefix("KUVO_DEMO_") }) { NSApp.activate() }
        switch environment["KUVO_DEMO_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if environment["KUVO_DEMO_CHANGES"] != nil { showsPanel = true }
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
        if workspace.isLoaded, environment["KUVO_DEMO_PROVIDERS"] != nil { showsProviders = true }
        // KUVO_DEMO_SETTINGS=<tab> opens Settings on that tab: general, accounts, panel, usage, engine.
        if workspace.isLoaded, let tab = environment["KUVO_DEMO_SETTINGS"] {
            UserDefaults.standard.set(tab, forKey: "settings.tab")
            openSettings()
        }
        guard workspace.isLoaded, !Self.ranDemo else { return }
        Self.ranDemo = true
        // KUVO_DEMO_PANEL: tools to open in the panel, comma-separated: terminal,
        // browser=<address>, files, file=<path>, changes, expand.
        for item in (environment["KUVO_DEMO_PANEL"] ?? "").split(separator: ",").map(String.init) {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            switch parts.first {
            case "terminal": utilities.newTerminal(in: activeDirectory, environment: app.shellEnvironment)
            case "browser": utilities.newBrowser(parts.count > 1 ? parts[1] : nil)
            case "files": utilities.showFiles()
            case "file" where parts.count > 1: utilities.open(URL(filePath: parts[1]))
            case "changes": utilities.showChanges()
            case "expand": panelExpanded = true
            default: continue
            }
            showsPanel = true
        }
        // In a task of its own: SwiftUI cancels and restarts this view's task while the
        // window settles, which would cut the session's creation short.
        Task { await runDemoSession(environment) }
    }

    private func runDemoSession(_ environment: [String: String]) async {
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
        guard let prompt = environment["KUVO_DEMO_PROMPT"] else { return newSession(in: folder) }
        let parts = environment["KUVO_DEMO_MODEL"]?.split(separator: "/", maxSplits: 1).map(String.init)
        let model = parts.flatMap { $0.count == 2 ? ModelRef(id: $0[1], providerID: $0[0]) : nil }
        // Like a new session from the UI: the chosen model, or the default one.
        guard let session = try? await workspace.createSession(in: folder, model: model ?? catalog.defaultModel?.ref, agent: "build") else { return }
        openTab(session.id)
        // KUVO_DEMO_FILES: comma-separated paths to attach.
        let files = environment["KUVO_DEMO_FILES"]?.split(separator: ",").map { URL(filePath: String($0)) } ?? []
        workspace.model(for: session.id)?.send(prompt, files: files, for: catalog.model(session.model))
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
            ProgressView().controlSize(.small)
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

/// Shown before there's any project.
struct WelcomeView: View {
    @Environment(Catalog.self) private var catalog
    let openFolder: () -> Void
    let showProviders: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tint)
            Text("Welcome to \(AppInfo.name)")
                .font(.largeTitle.weight(.semibold))
            Text("Open a project folder and tell the agent what to build.\nIt can read, edit and run things there.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Open Folder…", systemImage: "folder", action: openFolder)
                    .buttonStyle(.glassProminent)
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
