import OpenCodeKit
import SwiftUI

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

/// What the menu bar's usage meter may read. Both are opt-in: they touch other tools' logins.
private struct UsageSettings: View {
    @AppStorage(UsageStore.readsKeychainKey) private var readsKeychain = false
    @AppStorage(UsageStore.renewsLoginsKey) private var renewsLogins = false
    @Environment(UsageStore.self) private var usage

    var body: some View {
        Form {
            Section {
                LabeledContent("Codex") { Text("Codex CLI login (~/.codex), or a Codex sign-in in Accounts") }
                LabeledContent("Claude") { Text("Claude Code login") }
                LabeledContent("GitHub Copilot") { Text("Your Copilot account in Accounts, your editor, or gh") }
                LabeledContent("OpenCode Go") { Text("Your OpenCode Go key in Accounts") }
            } header: {
                Text("Where usage comes from")
            } footer: {
                Text("Usage providers are adapted from OpenUsage by Robin Ebers (MIT).")
            }
            Section {
                Toggle("Read logins from the Keychain", isOn: $readsKeychain)
                Text("Claude Code and some Codex and gh setups keep their login in the Keychain. macOS asks you once for each.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Renew expired logins", isOn: $renewsLogins)
                Text("When a Codex or Claude Code login has expired, renew it and save the new one where that tool keeps it, so limits stay current. Off, an expired login shows a note until you next use that tool.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width)
        .fixedSize()
        .onChange(of: [readsKeychain, renewsLogins]) { Task { await usage.refresh() } }
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
