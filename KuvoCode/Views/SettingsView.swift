import OpenCodeKit
import SwiftUI
import UsageKit
import WebKit

struct SettingsView: View {
    /// Every tab is this wide, so switching tabs doesn't make the window jump sideways.
    static let width: CGFloat = 680

    /// Which tab is open; other places (the menu bar's "Accounts…") can set it.
    @AppStorage("settings.tab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") {
                GeneralSettings()
            }
            Tab("Accounts", systemImage: "person.crop.circle", value: "accounts") {
                ProvidersView(context: .settings)
                    .frame(width: SettingsView.width, height: 600)
            }
            Tab("Panel", systemImage: "sidebar.right", value: "panel") {
                PanelSettingsView()
            }
            Tab("Usage", systemImage: "gauge.with.dots.needle.50percent", value: "usage") {
                UsageSettings()
            }
            Tab("Engine", systemImage: "cpu", value: "engine") {
                EngineSettings()
            }
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @AppStorage(Notifier.enabledKey) private var notifies = true
    @Environment(Updates.self) private var updates

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle(isOn: $notifies) {
                Text("Notify me when a session finishes or needs me")
                Text("While you're in another app. The Dock icon counts the sessions waiting for you.")
            }
            if updates.isAvailable {
                @Bindable var updates = updates
                Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width)
        .fixedSize()
    }
}

/// Usage has its own settings in the menu bar panel; this tab points there.
private struct UsageSettings: View {
    var body: some View {
        Form {
            Section {
                Text("Plan limits, pace and spend for Claude, Codex, Copilot, Cursor, OpenCode and more live in the menu bar. Accounts you connect in Kuvo Code count there too, and so do Kuvo Code's own runs.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Usage Settings…") { UsageMenuBar.shared.open(.settings) }
                    Button("Choose Providers…") { UsageMenuBar.shared.open(.customize) }
                }
            } footer: {
                Text("Usage tracking is a fork of OpenUsage by Robin Ebers (MIT). It isn't affiliated with or endorsed by OpenUsage.")
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width)
        .fixedSize()
    }
}

/// The side panel: what it starts with, the new tab page, and the browser.
private struct PanelSettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(PanelSettings.startsWith) private var startsWith = PanelSettings.Start.changes
    @AppStorage(PanelSettings.revealsForAgent) private var revealsForAgent = true
    @AppStorage(PanelSettings.showsTools) private var showsTools = true
    @AppStorage(PanelSettings.showsSuggestions) private var showsSuggestions = true
    @AppStorage(PanelSettings.suggestionCount) private var suggestionCount = 8
    @AppStorage(SearchEngine.key) private var searchEngine = SearchEngine.google
    @State private var confirmingClearData = false

    var body: some View {
        Form {
            Section {
                Picker("Start a project's panel with", selection: $startsWith) {
                    ForEach(PanelSettings.Start.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Show the panel when the agent starts browsing", isOn: $revealsForAgent)
            }
            Section("New Tab Page") {
                Toggle("Show tools", isOn: $showsTools)
                Toggle("Show suggested sites", isOn: $showsSuggestions)
                Picker("Suggested sites", selection: $suggestionCount) {
                    ForEach([4, 8, 12, 16], id: \.self) { Text("\($0)").tag($0) }
                }
                .disabled(!showsSuggestions)
            }
            Section {
                Picker("Search engine", selection: $searchEngine) {
                    ForEach(SearchEngine.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Suggested sites") {
                    Button("Clear") { app.utilities.history.clear() }
                        .disabled(app.utilities.history.sites.isEmpty)
                }
                LabeledContent("Cookies and website data") {
                    Button("Clear…") { confirmingClearData = true }
                }
            } header: {
                Text("Browser")
            } footer: {
                Text("The panel's browser keeps its own cookies and sign-ins, separate from your other browsers.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width)
        .fixedSize()
        .confirmationDialog("Clear the panel browser's cookies and website data?", isPresented: $confirmingClearData) {
            Button("Clear", role: .destructive) {
                let store = WKWebsiteDataStore.default()
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
            }
        } message: {
            Text("You'll be signed out of every site in the panel's browser. Your other browsers aren't affected.")
        }
    }
}

private struct EngineSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            LabeledContent("Engine", value: "opencode \(OpenCodeEngine.version)")
            LabeledContent("Status") {
                switch app.engine {
                case .ready: Label(app.isLive ? "Running" : "Reconnecting", systemImage: "circle.fill").foregroundStyle(app.isLive ? .green : .orange)
                case .failed: Label("Stopped", systemImage: "circle.fill").foregroundStyle(.red)
                default: Text("Starting…")
                }
            }
            LabeledContent("Data") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppInfo.supportDirectory])
                }
            }
            Section {
                Button("Restart Engine") { Task { await app.restart() } }
            } footer: {
                Text("Sessions, accounts and settings are kept in the data folder, separate from any opencode you have installed.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width)
        .fixedSize()
    }
}
