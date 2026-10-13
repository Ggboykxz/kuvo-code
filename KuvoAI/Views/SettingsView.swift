import OpenCodeKit
import SwiftUI

struct SettingsView: View {
    /// Every tab is this wide, so switching tabs doesn't make the window jump sideways.
    static let width: CGFloat = 680

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Accounts", systemImage: "person.crop.circle") {
                ProvidersView(context: .settings)
                    .frame(width: SettingsView.width, height: 600)
            }
            Tab("Engine", systemImage: "cpu") {
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
