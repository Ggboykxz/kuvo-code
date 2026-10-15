import SwiftUI
import OpenCodeKit
import UsageKit

@main
struct KuvoCodeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            RootView()
                .environment(delegate.model)
                .environment(delegate.model.catalog)
                .environment(delegate.model.workspace)
                .environment(delegate.model.bots)
                .environment(delegate.updates)
                .task { await delegate.model.start() }
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        // Settings open in this window (AppModel.openSettings), so there's no Settings scene.
        .commands { AppCommands(model: delegate.model, updates: delegate.updates) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let updates = Updates()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.shared.start()
        Notifier.shared.answer = { [model] session, request, answer in model.workspace.answer(request, in: session, with: answer) }
        Analytics.shared.start()
        UsageMenuBar.shared.onPanelShown = { Analytics.shared.track("usage_panel_opened") }
        #if DEBUG
        // KUVO_DEMO_USAGE=off leaves the usage tracker out, so a second copy of the app
        // (for screenshots) never renews the logins the first one is using.
        if ProcessInfo.processInfo.environment["KUVO_DEMO_USAGE"] == "off" { return }
        #endif
        // Plan limits and spend in the menu bar (UsageKit).
        model.startUsage()
        #if DEBUG
        // KUVO_DEMO_USAGE=dashboard|customize|settings opens the usage panel, for screenshots.
        if let screen = ProcessInfo.processInfo.environment["KUVO_DEMO_USAGE"] {
            Task {
                while !UsageMenuBar.shared.isRunning { try? await Task.sleep(for: .milliseconds(250)) }
                try? await Task.sleep(for: .seconds(3))
                UsageMenuBar.shared.open(screen == "settings" ? .settings : screen == "customize" ? .customize : .dashboard)
            }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Closing the engine's stdin shuts it down cleanly (it would also exit with us).
        model.stop()
        model.stopMachines()
        Analytics.shared.flushBeforeQuit()
    }

    /// Folders dropped on the Dock icon, picked in Finder's Open With, or passed to
    /// `open -a "Kuvo Code" <folder>`: each becomes a project, with a new session in the first.
    func application(_ application: NSApplication, open urls: [URL]) {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for folder in folders.dropFirst().reversed() { model.workspace.addFolder(folder.path(percentEncoded: false)) }
        if let first = folders.first { model.open(.folder(first.path(percentEncoded: false))) }
    }

    /// The Dock icon's menu: the latest sessions, and a new one.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let sessions = model.workspace.projects.flatMap(\.sessions).filter { !Workspace.isArchived($0) }
            .sorted { $0.time.updated > $1.time.updated }.prefix(5)
        for session in sessions {
            let id = session.id
            menu.addItem(ActionItem(session.title ?? "New Session") { [model] in model.open(.session(id)) })
        }
        if !sessions.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ActionItem("New Session") { [model] in model.open(.newSession) })
        return menu
    }

    /// The usage meter stays in the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Menu commands. They act on whatever the focused window exposes.
struct AppCommands: Commands {
    let model: AppModel
    let updates: Updates
    @FocusedValue(\.sessionActions) private var actions
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @AppStorage(TabBar.showsKey) private var showsTabBar = true

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updates.isAvailable {
                Button("Check for Updates…") { updates.check() }
                    .disabled(!updates.canCheck)
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Session") { actions?.newSession() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
            Button("New Project…") { actions?.newProject() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("New Bot…") { actions?.newBot() }
                .disabled(actions == nil)
            Button("Open Folder…") { actions?.openFolder() }
                .keyboardShortcut("o")
                .disabled(actions == nil)
            Button("Open Quickly…") { actions?.openQuickly() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(actions?.hasProject != true)
        }
        // In place of Close and Close All: ⌘W closes the session tab, as in browsers.
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                // Another window in front, like an update window, just closes.
                if let actions, NSApp.keyWindow?.identifier?.rawValue == "main" { actions.closeTab() } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Button("Reopen Closed Tab") { actions?.reopenTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(actions?.canReopenTab != true)
        }
        CommandGroup(before: .textEditing) {
            Button("Find in Conversation…") { actions?.find() }
                .keyboardShortcut("f")
                .disabled(actions?.hasSession != true)
        }
        CommandMenu("Session") {
            Button("Stop") { actions?.stop() }
                .keyboardShortcut(".")
                .disabled(actions?.canStop != true)
            Divider()
            Button("Build Mode") { actions?.selectAgent("build") }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(actions?.hasSession != true)
            Button("Plan Mode") { actions?.selectAgent("plan") }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(actions?.hasSession != true)
        }
        CommandMenu("Tools") {
            Group {
                Button("Show Changes") { actions?.showChanges() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Show Files") { actions?.showFiles() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Run") { actions?.run() }
                    .keyboardShortcut("r")
                    .disabled(actions?.hasProject != true)
                Button("New Terminal") { actions?.newTerminal() }
                    .keyboardShortcut("`", modifiers: .control)
                Button("New Browser Tab") { actions?.newBrowser() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Divider()
                Button("Show Panel") { actions?.togglePanel() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
            }
            .disabled(actions == nil)
        }
        CommandGroup(before: .sidebar) {
            Button("Command Palette…") { actions?.commandPalette() }
                .keyboardShortcut("k")
                .disabled(actions == nil)
            Divider()
            Button("Show Sessions") { actions?.toggleSidebar() }
                .keyboardShortcut("0")
                .disabled(actions == nil)
            Button(showsTabBar ? "Hide Tab Bar" : "Show Tab Bar") { showsTabBar.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Show Next Tab") { actions?.nextTab() }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(actions == nil)
            Button("Show Previous Tab") { actions?.previousTab() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(actions == nil)
            // ⌘1 to ⌘8 show that tab, ⌘9 the last one, as in browsers.
            Menu("Show Tab") {
                ForEach(1...9, id: \.self) { number in
                    Button(number == 9 ? "Last Tab" : "Tab \(number)") { actions?.showTab(number) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")))
                }
            }
            .disabled(actions == nil)
            Divider()
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Kuvo Code Help") { NSWorkspace.shared.open(AppInfo.docs) }
            Button("What\u{2019}s New") { NSWorkspace.shared.open(AppInfo.releases) }
            Button("Report an Issue…") { NSWorkspace.shared.open(AppInfo.newIssue) }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.openSettings() }
                .keyboardShortcut(",")
            Button("Connect Providers…") { actions?.showProviders() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
    }
}

/// What the menu bar can do in the focused window.
struct SessionActions {
    var hasSession: Bool
    /// A session or a new one is open, so there's a project to look in.
    var hasProject: Bool
    var canStop: Bool
    var canReopenTab: Bool
    var newSession: () -> Void
    var openFolder: () -> Void
    var newProject: () -> Void
    var newBot: () -> Void
    var stop: () -> Void
    var selectAgent: (String) -> Void
    var togglePanel: () -> Void
    var showChanges: () -> Void
    var showFiles: () -> Void
    var newTerminal: () -> Void
    /// The project's run command, in a terminal.
    var run: () -> Void
    var newBrowser: () -> Void
    var toggleSidebar: () -> Void
    var nextTab: () -> Void
    var previousTab: () -> Void
    var closeTab: () -> Void
    var reopenTab: () -> Void
    var find: () -> Void
    /// The tab at this place, 1 first; 9 is the last.
    var showTab: (Int) -> Void
    var showProviders: () -> Void
    var openQuickly: () -> Void
    var commandPalette: () -> Void
}

extension FocusedValues {
    @Entry var sessionActions: SessionActions?
}
