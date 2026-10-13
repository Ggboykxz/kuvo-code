import SwiftUI

@main
struct KuvoCodeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            RootView()
                .environment(delegate.model)
                .environment(delegate.model.catalog)
                .environment(delegate.model.workspace)
                .task { await delegate.model.start() }
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands { AppCommands() }

        Settings {
            SettingsView()
                .environment(delegate.model)
                .environment(delegate.model.catalog)
                .environment(delegate.model.usage)
        }

        // How much of each connected plan is left (ChatGPT windows, Copilot requests).
        MenuBarExtra {
            UsageMenu()
                .environment(delegate.model.usage)
                .environment(delegate.model.catalog)
        } label: {
            UsageMenuLabel()
                .environment(delegate.model.usage)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationWillTerminate(_ notification: Notification) {
        // Closing the engine's stdin shuts it down cleanly (it would also exit with us).
        model.stop()
    }

    /// The usage meter stays in the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Menu commands. They act on whatever the focused window exposes.
struct AppCommands: Commands {
    @FocusedValue(\.sessionActions) private var actions
    @AppStorage(Appearance.key) private var appearance = Appearance.system

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { actions?.newSession() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
            Button("Open Folder…") { actions?.openFolder() }
                .keyboardShortcut("o")
                .disabled(actions == nil)
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
            Divider()
            Button("Show Changes") { actions?.toggleChanges() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(actions?.hasSession != true)
        }
        CommandGroup(before: .sidebar) {
            Button("Show Sessions") { actions?.toggleSidebar() }
                .keyboardShortcut("0")
                .disabled(actions == nil)
            Button("Show Next Tab") { actions?.nextTab() }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(actions == nil)
            Button("Show Previous Tab") { actions?.previousTab() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(actions == nil)
            Divider()
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Divider()
        }
        CommandGroup(after: .appSettings) {
            Button("Connect Providers…") { actions?.showProviders() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
    }
}

/// What the menu bar can do in the focused window.
struct SessionActions {
    var hasSession: Bool
    var canStop: Bool
    var newSession: () -> Void
    var openFolder: () -> Void
    var stop: () -> Void
    var selectAgent: (String) -> Void
    var toggleChanges: () -> Void
    var toggleSidebar: () -> Void
    var nextTab: () -> Void
    var previousTab: () -> Void
    var showProviders: () -> Void
}

extension FocusedValues {
    @Entry var sessionActions: SessionActions?
}
