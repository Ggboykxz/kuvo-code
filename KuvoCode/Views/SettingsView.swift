import OpenCodeKit
import SwiftUI
import UsageKit

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

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
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
