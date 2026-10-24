import SwiftUI

/// Edit Bot's keys: for each integration you bring a key for, whether the bot uses one of its
/// own, your shared one or none, and the way to give it its own (see `BotKeys`).
struct BotKeysSection: View {
    let bot: Bot
    /// Opens the key entry for an integration, in the editor's place.
    let edit: (Integrations.Service) -> Void
    @Environment(AppModel.self) private var app
    @State private var own: Set<String> = []
    @State private var shared: Set<String> = []
    @State private var removing: Set<String> = []

    var body: some View {
        WellGroup {
            ForEach(Array(BotKeys.services.enumerated()), id: \.element.id) { index, service in
                if index > 0 { WellDivider() }
                row(service)
            }
        }
        .task(id: bot.id) { await reload() }
    }

    private func row(_ service: Integrations.Service) -> some View {
        WellRow(height: 52) {
            Image(systemName: service.symbol)
        } content: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.title)
                    Text(own.contains(service.id) ? "Its own key" : shared.contains(service.id) ? "Your shared key, from Settings › Integrations" : "No key")
                        .font(.caption)
                        .foregroundStyle(own.contains(service.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 8)
                if removing.contains(service.id) {
                    Spinner(size: 14)
                } else if own.contains(service.id) {
                    Menu {
                        Button("Change Key…") { edit(service) }
                        Button("Remove Its Key", role: .destructive) { remove(service) }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Its Key")
                            MenuChevron()
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()
                } else {
                    Button("Add Its Own Key…") { edit(service) }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    private func reload() async {
        let status = await BotKeys.status(of: bot.id)
        own = status.own
        shared = status.shared
    }

    private func remove(_ service: Integrations.Service) {
        removing.insert(service.id)
        Task {
            await BotKeys.remove(service, bot: bot, app: app)
            await reload()
            removing.remove(service.id)
        }
    }
}

/// A key of a bot's own for an integration, typed or pasted, for your Keychain: in Edit Bot's place.
struct BotKeyEntry: View {
    let service: Integrations.Service
    let bot: Bot
    let done: () -> Void
    @Environment(AppModel.self) private var app
    @State private var values: [String: String] = [:]
    @State private var isSaving = false
    @State private var failed = false

    private var keys: [Integrations.Key] { Integrations.keys(of: service.way) }

    private var isComplete: Bool {
        keys.allSatisfy { !(values[$0.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var help: URL? {
        switch service.way {
        case .officialToken(_, _, let help): URL(string: help)
        case .package(_, _, let help, _, _, _): help.flatMap(URL.init(string:))
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WellGroup {
                ForEach(Array(keys.enumerated()), id: \.element.name) { index, key in
                    if index > 0 { WellDivider() }
                    WellRow {
                        Image(systemName: "key")
                    } content: {
                        SecureField(key.label, text: Binding(get: { values[key.name] ?? "" }, set: { values[key.name] = $0 }), prompt: Text(key.label + ": " + key.prompt))
                            .textFieldStyle(.plain)
                            .labelsHidden()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Only \(bot.name)’s conversation uses it: its \(service.title) tools take this key in place of the shared one, and no other bot’s or session’s do. It stays in your Keychain\(bot.machine == nil ? "" : ", and reaches its machine only while the engine there runs").")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let help {
                    Link("Where to get one", destination: help)
                }
                if failed {
                    Text("Couldn’t save it in your Keychain. Try again, or check Keychain Access.")
                        .foregroundStyle(.red)
                }
            }
            .font(.callout)
            EditorFooter(primary: "Save", canDoPrimary: isComplete, onPrimary: save, onCancel: done, cancelsOnEscape: true, working: isSaving ? "Saving…" : nil)
                .padding(.top, 8)
        }
    }

    private func save() {
        isSaving = true
        failed = false
        Task {
            let saved = await BotKeys.save(values, for: service, bot: bot, app: app)
            isSaving = false
            if saved { done() } else { failed = true }
        }
    }
}
