import AppKit
import OpenCodeKit
import SwiftUI
import UsageKit

/// General: the window, where files open, and updates.
struct GeneralSettings: View {
    @AppStorage(TabBar.showsKey) private var showsTabBar = true
    @AppStorage(PairStyle.key) private var pairStyle = PairStyle.halves
    @AppStorage(OpenWith.editorKey) private var editor = ""
    @AppStorage(Awake.key) private var keepsAwake = true
    @Environment(Updates.self) private var updates
    @Environment(AppModel.self) private var app
    @Environment(Catalog.self) private var catalog
    /// What opencode has that could come over, once you asked.
    @State private var importing: ImportRequest?
    @State private var reading = false
    @State private var importNote: String?

    var body: some View {
        ScrollingSettingsForm {
            Section("Window") {
                Toggle(isOn: $showsTabBar) {
                    Text("Show the tab bar")
                    Text("The row at the top, with the project, its branch and your sessions as tabs. Without it, switch sessions in the sidebar or with ⌘K.")
                }
                Picker(selection: $pairStyle) {
                    Text("One tab in two halves").tag(PairStyle.halves)
                    Text("One tab with both names").tag(PairStyle.compact)
                    Text("Two tabs joined").tag(PairStyle.joined)
                } label: {
                    Text("Two sessions side by side")
                    Text("How they show in the tab bar.")
                }
                .disabled(!showsTabBar)
            }
            Section("While Agents Work") {
                Toggle(isOn: $keepsAwake) {
                    Text("Keep this Mac awake")
                    Text("It doesn’t go to sleep on its own while an agent or a bot works on it; the display still can. Sessions on your machines run there either way.")
                }
                .onChange(of: keepsAwake) { Awake.shared.update() }
            }
            Section("Files") {
                Picker(selection: $editor) {
                    Text("Each file’s default app").tag("")
                    Divider()
                    ForEach(OpenWith.installedEditors, id: \.id) { editor in
                        Text(OpenWith.name(of: editor.url)).tag(editor.id)
                    }
                } label: {
                    Text("Open code and text in")
                    Text("For Open in the panel’s files and Open in Editor in Changes. Pictures and other files open in their own apps.")
                }
            }
            if OpencodeImport.isAvailable {
                Section("opencode") {
                    LabeledContent {
                        Button("Bring Over…") { readOpencode() }
                            .disabled(reading || app.api == nil)
                    } label: {
                        Text("Bring over your opencode setup")
                        Text(importNote ?? "Its API keys, model, MCP servers, agents, commands, plugins and skills. opencode keeps its own; nothing here is replaced.")
                    }
                }
            }
            Section("Updates") {
                if updates.isAvailable {
                    @Bindable var updates = updates
                    Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                }
                LabeledContent {
                    if updates.isAvailable {
                        Button("Check Now") { updates.check() }
                            .disabled(!updates.canCheck)
                    }
                } label: {
                    Text("Version \(AppInfo.version)")
                    Text(updates.isAvailable ? "Updates are signed and come from Kuvo Code’s releases." : "This build doesn’t update itself.")
                }
            }
        }
        .sheet(item: $importing) { request in
            OpencodeImportSheet(plan: request.plan, names: catalog.providerName) { bring in
                importing = nil
                guard bring else { return }
                Task { await bringOver(request.plan) }
            }
        }
    }

    private struct ImportRequest: Identifiable {
        let id = UUID()
        let plan: OpencodeImport.Plan
    }

    private func readOpencode() {
        guard let engine = app.engineBinary, let api = app.api else { return }
        reading = true
        Task {
            defer { reading = false }
            let connected = Set(((try? await api.credentials()) ?? []).map(\.integrationID))
            do {
                let plan = try await OpencodeImport.plan(engine: engine, config: app.engineConfig.settings, connected: connected)
                if plan.isEmpty, plan.signIns.isEmpty {
                    importNote = "Everything in your opencode setup is here already."
                } else {
                    importing = ImportRequest(plan: plan)
                }
            } catch {
                importNote = "Couldn’t read your opencode setup: \(error.localizedDescription)"
            }
        }
    }

    private func bringOver(_ plan: OpencodeImport.Plan) async {
        guard let api = app.api else { return }
        let count = await OpencodeImport.apply(plan, to: app.engineConfig, api: api)
        importNote = count == 1 ? "Brought over 1 thing from opencode." : "Brought over \(count) things from opencode."
        // Accounts and servers take effect as the engines start again, each once it's not at work.
        app.renewEngines(mac: true)
    }
}

/// What would come over from opencode, to look over before it does.
private struct OpencodeImportSheet: View {
    let plan: OpencodeImport.Plan
    let names: (String) -> String
    let done: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(plan.lines(name: names), id: \.self) { line in
                        Text(line)
                            .lineLimit(3)
                    }
                } header: {
                    Text("Bring Over from opencode")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("These aren’t in Kuvo Code yet; what it has already stays as it is. API keys are copied into Kuvo Code’s engine, and skills are found where opencode keeps them. The engine starts again to use them.")
                        if !plan.signIns.isEmpty {
                            Text("Sign in to \(ListFormatter.localizedString(byJoining: plan.signIns.map(names))) again in Settings › Accounts: a sign-in copied over would be refreshed by both apps, which can sign both out.")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Bring Over") { done(true) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: SettingsView.sheetWidth, height: min(520, 220 + CGFloat(plan.lines(name: names).count) * 34))
    }
}

/// Notifications: when Kuvo Code tells you about a session, and how.
struct NotificationSettings: View {
    @AppStorage(Notifier.enabledKey) private var notifies = true
    @AppStorage(Notifier.soundKey) private var playsSound = true
    @AppStorage(Notifier.badgeKey) private var showsBadge = true

    var body: some View {
        ScrollingSettingsForm {
            Section {
                Toggle(isOn: $notifies) {
                    Text("Sessions")
                    Text("When a session finishes or needs your answer while you’re in another app. A permission request can be answered from its notification.")
                }
                Toggle(isOn: $playsSound) {
                    Text("Play a sound")
                    Text("With each notification.")
                }
                .disabled(!notifies)
                Toggle(isOn: $showsBadge) {
                    Text("Count on the Dock icon")
                    Text("The sessions that finished while you were away, or wait for you.")
                }
            } footer: {
                Text("macOS asks the first time there’s something to tell. To change how they look, or to allow them again, use System Settings › Notifications.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("System notification settings") {
                    Button("Open…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!)
                    }
                }
            }
        }
    }
}

/// Privacy: anonymous usage, and where your data is.
struct PrivacySettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollingSettingsForm {
            Section {
                @Bindable var analytics = Analytics.shared
                Toggle(isOn: $analytics.isEnabled) {
                    Text("Share anonymous usage")
                    Text("Which features you use and how often, with the app and macOS versions. Never your code, prompts, files or accounts.")
                }
                LabeledContent("What’s sent") {
                    Link("Privacy and Data", destination: URL(string: "https://www.kuvo.run/code/docs/privacy/")!)
                }
            }
            Section {
                LabeledContent {
                    Button("Storage…") { app.settingsTabs.show(.storage) }
                } label: {
                    Text("Sessions and accounts")
                    Text("Kept on this Mac, in Kuvo Code’s own folder. Messages go only to the model providers you choose.")
                }
                LabeledContent {
                    Button("Browser…") { app.settingsTabs.show(.browser) }
                } label: {
                    Text("The panel’s browser")
                    Text("Its sign-ins, cookies and history stay apart from your other browsers.")
                }
                LabeledContent {
                    Button("Passwords…") { app.settingsTabs.show(.passwords) }
                } label: {
                    Text("Saved passwords")
                    Text("In your Keychain, filled in only when you ask.")
                }
            } header: {
                Text("On This Mac")
            }
        }
    }
}

/// Usage has its own settings in the menu bar panel; this page points there.
struct UsageSettings: View {
    var body: some View {
        ScrollingSettingsForm {
            Section {
                LabeledContent {
                    Button("Open…") { UsageMenuBar.shared.open(.settings) }
                } label: {
                    Text("Usage settings")
                    Text("Plan limits, pace and spend for the accounts you connect, like GitHub Copilot, ChatGPT and OpenRouter, live in the menu bar. They count what you use anywhere, not only here.")
                }
                LabeledContent {
                    Button("Choose…") { UsageMenuBar.shared.open(.customize) }
                } label: {
                    Text("Providers")
                    Text("Which accounts the menu bar shows, and in what order.")
                }
            } footer: {
                Text("Usage tracking is a fork of OpenUsage by Robin Ebers (MIT). It isn’t affiliated with or endorsed by OpenUsage.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
