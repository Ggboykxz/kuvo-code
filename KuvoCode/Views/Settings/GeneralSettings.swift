import AppKit
import SwiftUI
import UsageKit

/// General: the window, where files open, and updates.
struct GeneralSettings: View {
    @AppStorage(TabBar.showsKey) private var showsTabBar = true
    @AppStorage(OpenWith.editorKey) private var editor = ""
    @Environment(Updates.self) private var updates

    var body: some View {
        ScrollingSettingsForm {
            Section("Window") {
                Toggle(isOn: $showsTabBar) {
                    Text("Show the tab bar")
                    Text("The row at the top, with the project, its branch and your sessions as tabs. Without it, switch sessions in the sidebar or with ⌘K.")
                }
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
    @AppStorage(SettingsPage.storageKey) private var tab = SettingsPage.privacy.rawValue

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
                    Button("Storage…") { tab = SettingsPage.storage.rawValue }
                } label: {
                    Text("Sessions and accounts")
                    Text("Kept on this Mac, in Kuvo Code’s own folder. Messages go only to the model providers you choose.")
                }
                LabeledContent {
                    Button("Browser…") { tab = SettingsPage.browser.rawValue }
                } label: {
                    Text("The panel’s browser")
                    Text("Its sign-ins, cookies and history stay apart from your other browsers.")
                }
                LabeledContent {
                    Button("Passwords…") { tab = SettingsPage.passwords.rawValue }
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
