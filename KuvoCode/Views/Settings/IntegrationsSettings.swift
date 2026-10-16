import OpenCodeKit
import SwiftUI

/// Integrations: your mail and calendar, chats, socials, code and work tools, for the agent and
/// your bots. Each the best way it has: its maker's own server (connect, and sign in once), a key
/// you bring, or the site in the panel's browser.
struct IntegrationsSettings: View {
    @Environment(AppModel.self) private var app
    @State private var live: [MCPServer] = []
    @State private var signingIn: IntegrationRef?
    @State private var addingKey: KeyRequest?
    /// Saved keys reach the engine when it starts.
    @State private var needsRestart = false

    private var config: EngineConfig { app.engineConfig }

    var body: some View {
        ScrollingSettingsForm {
            if needsRestart {
                Section {
                    HStack {
                        Text("The engine uses new keys once it restarts.")
                        Spacer()
                        Button("Restart Engine") {
                            needsRestart = false
                            Task { await app.restart() }
                        }
                    }
                }
            }
            ForEach(Integrations.Kind.allCases, id: \.self) { kind in
                Section(kind.rawValue) {
                    ForEach(Integrations.all.filter { $0.kind == kind }) { service in
                        row(service)
                    }
                }
            }
            Section {
            } footer: {
                Text("Each works the best way it has: through its maker's own server, where you sign in once; with a key you bring, kept in your Keychain; or on its site, in the panel's browser, signed in as you. The agent and your bots use them on this Mac and your machines.")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: config.settings) { await refresh() }
        #if DEBUG
        // KUVO_DEMO_ADD_INTEGRATION=<id>: added, as Connect does.
        .onAppear {
            if let id = ProcessInfo.processInfo.environment["KUVO_DEMO_ADD_INTEGRATION"], let service = Integrations.service(id),
               config.value(at: MCPSettings.path + [id]) == nil { add(service) }
        }
        #endif
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                live = (try? await app.api?.mcpServers()) ?? live
            }
        }
        .sheet(item: $signingIn) { ref in
            ConnectSheet(integrationID: ref.id, note: "The agent can use it now.") {
                signingIn = nil
                Task {
                    for server in live where server.integrationID == ref.id { try? await app.api?.connectMCP(server.name) }
                    await refresh()
                }
            }
        }
        .sheet(item: $addingKey) { request in
            KeySheet(service: request.service) { saved in
                addingKey = nil
                guard saved else { return }
                add(request.service)
                // Nothing at work: restart now; otherwise when you say.
                if app.workspace.running.isEmpty { Task { await app.restart() } } else { needsRestart = true }
            }
        }
    }

    private func row(_ service: Integrations.Service) -> some View {
        let added = config.value(at: MCPSettings.path + [service.id]) != nil
        let server = live.first { $0.name == service.id }
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: service.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(service.title)
                    Text(Self.how(service.way))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(service.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                switch service.way {
                case .browser:
                    Button("Open") { open(service) }
                        .help("Open \(service.title) in the panel's browser, to sign in there")
                default:
                    if !added {
                        if case .officialApp = service.way {
                            Button("Add App…") { addingKey = KeyRequest(service: service) }
                        } else if !Integrations.keys(of: service.way).isEmpty {
                            Button("Add Key…") { addingKey = KeyRequest(service: service) }
                        } else {
                            Button("Connect") { add(service) }
                        }
                    } else {
                        status(server)
                        if let server, server.status.status == "needs_auth", let integrationID = server.integrationID {
                            Button("Sign In…") { signingIn = IntegrationRef(id: integrationID) }
                        } else if server?.status.status == "failed" {
                            Button("Try Again") {
                                Task {
                                    try? await app.api?.connectMCP(service.id)
                                    await refresh()
                                }
                            }
                        }
                        if !Integrations.keys(of: service.way).isEmpty {
                            Button(isApp(service) ? "Change App…" : "Change Key…") { addingKey = KeyRequest(service: service) }
                        }
                        Button("Remove") { remove(service) }
                            .help("The agent stops using \(service.title) (your sign-in or key goes with it)")
                    }
                }
            }
        }
    }

    @ViewBuilder private func status(_ server: MCPServer?) -> some View {
        let (title, color): (String, Color) = switch server?.status.status {
        case "connected": ("Connected", .green)
        case "pending": ("Connecting…", .secondary)
        case "needs_auth": ("Needs sign-in", .orange)
        case "failed": ("Couldn’t connect", .red)
        default: ("Starts with the engine", .secondary)
        }
        Text(title)
            .font(.subheadline)
            .foregroundStyle(color)
    }

    static func how(_ way: Integrations.Way) -> String {
        switch way {
        case .official: "Official"
        case .officialToken: "Official · your token"
        case .officialApp: "Official · your app"
        case .package(_, let keys, _, _, _, let macOnly): keys.isEmpty ? (macOnly ? "On this Mac" : "Open source") : "Open source · your key"
        case .browser: "In the browser"
        }
    }

    private func isApp(_ service: Integrations.Service) -> Bool {
        if case .officialApp = service.way { return true }
        return false
    }

    private func add(_ service: Integrations.Service) {
        guard let settings = Integrations.settings(for: service) else { return }
        config.set(settings, at: MCPSettings.path + [service.id])
        Analytics.shared.track("integration_added", ["integration": service.id])
    }

    private func remove(_ service: Integrations.Service) {
        config.set(nil, at: MCPSettings.path + [service.id])
        for key in Integrations.keys(of: service.way) { IntegrationKeys.set(nil, for: IntegrationKeys.variable(service.id, key.name)) }
    }

    /// The site in the panel's browser, for you to sign in there; the agent then uses it as you.
    private func open(_ service: Integrations.Service) {
        app.showsSettings = false
        app.utilities.newBrowser(service.site)
        app.utilities.reveal()
    }

    private func refresh() async {
        try? await Task.sleep(for: .milliseconds(400))
        live = (try? await app.api?.mcpServers()) ?? []
    }
}

private struct KeyRequest: Identifiable {
    let service: Integrations.Service
    var id: String { service.id }
}

/// The keys an integration needs, typed or pasted, for your Keychain.
private struct KeySheet: View {
    let service: Integrations.Service
    let done: (Bool) -> Void
    @State private var values: [String: String] = [:]

    private var keys: [Integrations.Key] { Integrations.keys(of: service.way) }

    private var help: String? {
        switch service.way {
        case .officialToken(_, _, let help), .officialApp(_, let help): help
        case .package(_, _, let help, _, _, _): help
        default: nil
        }
    }

    /// What the keys are for, under the fields.
    private var explanation: String {
        switch service.way {
        case .officialApp:
            "\(service.title)'s own server signs in only through an app registered with it. Make one in its developer console, with this redirect URL, then paste its ID and secret: \(Integrations.redirect). They stay in your Keychain; then you sign in."
        case .officialToken:
            "It goes to \(service.title)'s own server with your token, which stays in your Keychain and reaches the engine only while it runs."
        case .package(_, _, _, let by, _, _):
            "It runs \(by), an open-source MCP server, with your key. The key stays in your Keychain and reaches the engine only while it runs."
        default:
            ""
        }
    }

    private var isComplete: Bool {
        keys.allSatisfy { !(values[$0.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(keys, id: \.name) { key in
                        SecureField(key.label, text: Binding(get: { values[key.name] ?? "" }, set: { values[key.name] = $0 }), prompt: Text(key.prompt))
                    }
                } header: {
                    Text("Connect \(service.title)")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(explanation)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let help, let url = URL(string: help) {
                            Link("Where to get one", destination: url)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isComplete)
            }
            .padding(16)
        }
        .frame(width: SettingsView.sheetWidth, height: 230 + CGFloat(keys.count) * 30)
        .onAppear {
            for key in keys { values[key.name] = IntegrationKeys.value(IntegrationKeys.variable(service.id, key.name)) ?? "" }
        }
    }

    private func save() {
        for key in keys {
            IntegrationKeys.set(values[key.name]?.trimmingCharacters(in: .whitespacesAndNewlines), for: IntegrationKeys.variable(service.id, key.name))
        }
        done(true)
    }
}
