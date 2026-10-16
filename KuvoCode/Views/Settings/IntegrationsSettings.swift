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
    /// The sign-ins the engine keeps, by integration: a server can answer without one (Google's
    /// do), then turn every call down.
    @State private var signedIn: Set<String> = []
    /// Each connected machine's MCP servers, by machine.
    @State private var remote: [String: [MCPServer]] = [:]
    @State private var removing: Integrations.Service?

    private var config: EngineConfig { app.engineConfig }

    /// Each kind, in order. KUVO_DEMO_INTEGRATION_KINDS=<kinds>: only those, for screenshots.
    private static var kinds: [Integrations.Kind] {
        #if DEBUG
        if let only = ProcessInfo.processInfo.environment["KUVO_DEMO_INTEGRATION_KINDS"] {
            return Integrations.Kind.allCases.filter { kind in only.split(separator: ",").contains { kind.rawValue.lowercased().hasPrefix($0.lowercased()) } }
        }
        #endif
        return Integrations.Kind.allCases
    }

    var body: some View {
        list
        .modifier(LiveMCPServers(servers: $live, api: { app.api }, change: config.settings))
        .task(id: live) { await readSignIns() }
        .task {
            // The machines' servers, as their engines say.
            while !Task.isCancelled {
                var read: [String: [MCPServer]] = [:]
                for engine in app.machines.engines.values where engine.isReady {
                    if let servers = try? await engine.api?.mcpServers() { read[engine.machine.id] = servers }
                }
                remote = read
                await SiteSignIns.shared.refresh(app)
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .confirmationDialog("Remove \(removing?.title ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { service in
            Button("Remove", role: .destructive) { remove(service) }
        } message: { _ in
            Text("The agent and your bots stop using it, and your sign-in or key goes with it.")
        }
        #if DEBUG
        // KUVO_DEMO_ADD_INTEGRATION=<id>: added, as Connect does.
        .onAppear {
            if let id = ProcessInfo.processInfo.environment["KUVO_DEMO_ADD_INTEGRATION"], let service = Integrations.service(id),
               config.value(at: MCPSettings.path + [id]) == nil { add(service) }
            // KUVO_DEMO_SIGN_IN_SITE=<id>: signing in to that service on its site, in the sheet.
            if let id = ProcessInfo.processInfo.environment["KUVO_DEMO_SIGN_IN_SITE"], let service = Integrations.service(id) {
                app.settingsTabs.open(service)
            }
            // KUVO_DEMO_CONNECTED=<id>: its sign-in sheet, on its last step.
            if let id = ProcessInfo.processInfo.environment["KUVO_DEMO_CONNECTED"], let service = Integrations.service(id) {
                signingIn = IntegrationRef(id: "mcp_demo", service: service)
            }
        }
        #endif
        .sheet(item: $signingIn) { ref in
            ConnectSheet(integrationID: ref.id, name: ref.service?.title, symbol: ref.service?.symbol, note: ref.service == nil ? "The agent can use it now." : "", highlights: highlights(ref.service)) {
                signingIn = nil
                Task {
                    if let api = app.api { for server in live where server.integrationID == ref.id { await app.reconnect(server.name, api: api, machine: nil) } }
                    await refresh()
                    await readSignIns()
                    app.syncSignIns()
                }
            }
        }
        .sheet(item: $addingKey) { request in
            KeySheet(service: request.service) { saved in
                addingKey = nil
                guard saved else { return }
                add(request.service)
                // Keys reach engines when they start: each starts again once nothing's at work in it.
                app.renewEngines(mac: true)
            }
        }
    }

    private var list: some View {
        ScrollingSettingsForm {
            ForEach(Self.kinds, id: \.self) { kind in
                Section(kind.rawValue) {
                    ForEach(Integrations.all.filter { $0.kind == kind }) { service in
                        row(service)
                    }
                }
            }
        }
    }

    private func row(_ service: Integrations.Service) -> some View {
        let added = config.value(at: MCPSettings.path + [service.id]) != nil
        let places = added ? self.places(service) : siteSignIns(service)
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
                if !places.isEmpty {
                    PlacesLine(places: places, waitsForCodeHelp: "Ask the agent to use \(service.title): the first time, it gives you a code to enter on Microsoft's page.")
                        .padding(.top, 2)
                }
            }
            Spacer()
            HStack {
                switch service.way {
                case .browser:
                    Button(SiteSignIns.shared.isSignedIn(service.id, on: nil) == true ? "Open…" : "Sign In…") { withAnimation(.ui) { app.settingsTabs.open(service) } }
                        .help("Sign in to \(service.title) in the browser the agent and your bots use, on this Mac or one of your machines")
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
                        let server = live.first { $0.name == service.id }
                        // What needs you, first.
                        if places.first?.state == .needsSignIn, let integrationID = server?.integrationID {
                            Button("Sign In…") { signingIn = IntegrationRef(id: integrationID, service: service) }
                        } else if places.contains(where: { $0.state == .failed }) {
                            Button("Try Again") { reconnect(service, where: places.filter { $0.state == .failed }) }
                        }
                        Menu {
                            if let integrationID = server?.integrationID {
                                Button("Sign In Again…") { signingIn = IntegrationRef(id: integrationID, service: service) }
                            }
                            if !Integrations.keys(of: service.way).isEmpty {
                                Button(isApp(service) ? "Change App…" : "Change Key…") { addingKey = KeyRequest(service: service) }
                            }
                            Button("Reconnect") { reconnect(service, where: places) }
                            Divider()
                            Button("Remove…", role: .destructive) { removing = service }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More")
                    }
                }
            }
        }
    }

    /// How it's doing on this Mac, then on each machine connected now that runs it.
    private func places(_ service: Integrations.Service) -> [Place] {
        let server = live.first { $0.name == service.id }
        var here = Place.state(server)
        if here == .connected, needsSignIn(service, server) { here = .needsSignIn }
        // Microsoft 365's sign-in is one for all, copied between this Mac and the machines.
        let waits = waitsForCode(service)
        if here == .connected, waits { here = .waitsForCode }
        var places = [Place(name: "this Mac", machine: nil, state: here)]
        guard !Integrations.macOnly.contains(service.id) else { return places }
        for engine in app.machines.list.compactMap({ app.machines.engine($0.id) }) where engine.isReady {
            guard let servers = remote[engine.machine.id] else { continue }
            var there = Place.state(servers.first { $0.name == service.id })
            if there == .connected, waits { there = .waitsForCode }
            places.append(Place(name: engine.machine.name, machine: engine.machine.id, state: there))
        }
        return places
    }

    /// Where a service the agent uses on its site is signed in, as far as its cookies tell.
    private func siteSignIns(_ service: Integrations.Service) -> [Place] {
        guard case .browser = service.way else { return [] }
        let signIns = SiteSignIns.shared
        var places: [Place] = []
        if let here = signIns.isSignedIn(service.id, on: nil) {
            places.append(Place(name: "this Mac", machine: nil, state: here ? .signedIn : .signedOut))
        }
        for engine in app.machines.list.compactMap({ app.machines.engine($0.id) }) {
            if let there = signIns.isSignedIn(service.id, on: engine.machine.id) {
                places.append(Place(name: engine.machine.name, machine: engine.machine.id, state: there ? .signedIn : .signedOut))
            }
        }
        // Only here known, with machines: say it's here.
        if places.count == 1, places[0].machine == nil, !app.machines.list.isEmpty { places[0].namesPlace = true }
        return places
    }

    /// Connects it again, on this Mac and the machines among `places`.
    private func reconnect(_ service: Integrations.Service, where places: [Place]) {
        Task {
            for place in places {
                if let machine = place.machine {
                    if let api = app.machines.engine(machine)?.api { await app.reconnect(service.id, api: api, machine: machine) }
                } else if let api = app.api {
                    await app.reconnect(service.id, api: api, machine: nil)
                }
            }
            await refresh()
        }
    }

    /// What signing in to it gives you, for the sheet's last step.
    private func highlights(_ service: Integrations.Service?) -> [ConnectView.Highlight] {
        guard let service else { return [] }
        var lines = [ConnectView.Highlight(symbol: "text.bubble", title: "Just ask", detail: "The agent and your bots use \(service.title)'s own tools when you mention it, not its website.")]
        if !app.machines.list.isEmpty {
            lines.append(.init(symbol: "server.rack", title: "On your machines too", detail: "Sessions and bots there use this sign-in, kept in step with this Mac."))
        }
        return lines
    }

    /// Whether it waits for you to sign in: as its server says, or, answering without a sign-in,
    /// as there's none kept. Microsoft 365's server signs in by itself, with a code, when the
    /// agent first uses it, and keeps the sign-in in its folder.
    private func needsSignIn(_ service: Integrations.Service, _ server: MCPServer?) -> Bool {
        guard let server else { return false }
        if server.status.status == "needs_auth" { return true }
        guard server.status.status == "connected", let integration = server.integrationID else { return false }
        switch service.way {
        case .official, .officialApp: return !signedIn.contains(integration)
        default: return false
        }
    }

    private func readSignIns() async {
        guard let entries = try? await app.api?.credentialEntries() else { return }
        signedIn = Set(entries.filter { $0.active && $0.isOAuth }.map(\.integrationID))
    }

    /// Microsoft 365, without its sign-in yet.
    private func waitsForCode(_ service: Integrations.Service) -> Bool {
        guard let files = Integrations.signInFiles[service.id], let first = files.first else { return false }
        return !FileManager.default.fileExists(atPath: AppInfo.supportDirectory.appending(path: "integrations/\(service.id)/\(first)").path)
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
        // One that needs a key waits for it (saving it renews them).
        // Machines' engines take their settings when they start (this Mac's reads the file).
        if Integrations.keys(of: service.way).isEmpty, !Integrations.macOnly.contains(service.id) { app.renewEngines(mac: false) }
    }

    /// Out of the engine's settings, with its keys, its sign-in and what its server kept.
    private func remove(_ service: Integrations.Service) {
        let signIn = live.first { $0.name == service.id }?.integrationID
        config.set(nil, at: MCPSettings.path + [service.id])
        for key in Integrations.keys(of: service.way) { IntegrationKeys.set(nil, for: IntegrationKeys.variable(service.id, key.name)) }
        // What its server kept: its own folder (and the file it once kept), here and on the
        // machines that are connected.
        for name in [service.id, "\(service.id).json"] { try? FileManager.default.removeItem(at: AppInfo.supportDirectory.appending(path: "integrations/\(name)")) }
        let kept = "\"$HOME/\(RemoteEngineInstaller.root)/integrations/\(service.id)\""
        for engine in app.machines.engines.values where engine.isReady {
            let machine = engine.machine.id
            Task.detached { _ = RemoteShell.run("rm -rf \(kept)", on: machine) }
        }
        if let signIn { app.forgetSignIn(signIn) }
        if !Integrations.macOnly.contains(service.id) { app.renewEngines(mac: false) }
    }

    private func refresh() async {
        live = await MCPStatus.read(app.api) ?? []
    }
}

/// Where an integration runs, and how it's doing there.
private struct Place: Identifiable {
    let name: String
    /// nil for this Mac.
    let machine: String?
    let state: State
    /// Alone in its line, it still says where ("Signed in on this Mac").
    var namesPlace = false
    var id: String { machine ?? "" }

    /// Worst last.
    enum State: Int, Comparable {
        case connected, signedIn, starting, signedOut, waitsForCode, needsSignIn, failed

        static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .connected: "Connected"
            case .signedIn: "Signed in"
            case .signedOut: "Not signed in"
            case .starting: "Starting"
            case .waitsForCode: "Not signed in yet"
            case .needsSignIn: "Needs sign-in"
            case .failed: "Couldn’t connect"
            }
        }

        var color: Color {
            switch self {
            case .connected, .signedIn: .green
            case .starting, .signedOut: .secondary
            case .waitsForCode, .needsSignIn: .orange
            case .failed: .red
            }
        }
    }

    /// As an engine reports its server (none yet: it starts with the engine).
    static func state(_ server: MCPServer?) -> State {
        switch server?.status.status {
        case "connected": .connected
        case "needs_auth": .needsSignIn
        case "failed": .failed
        default: .starting
        }
    }
}

/// An integration's state in a line: a dot in the color of the worst, and each state with where
/// ("Connected on this Mac · Needs sign-in on my-server"); with no machines, just the state.
private struct PlacesLine: View {
    let places: [Place]
    let waitsForCodeHelp: String

    private var text: String {
        guard places.count > 1 else {
            guard let place = places.first else { return "" }
            return place.state.title + (place.namesPlace ? " on " + place.name : "")
        }
        let states = Set(places.map(\.state)).sorted()
        if states.count == 1, let state = states.first, [.connected, .signedIn].contains(state) { return state.title + " on " + Self.list(places.map(\.name)) }
        return states.reversed().map { state in
            state.title + " on " + Self.list(places.filter { $0.state == state }.map(\.name))
        }.joined(separator: " · ")
    }

    static func list(_ names: [String]) -> String {
        names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    var body: some View {
        let worst = places.map(\.state).max() ?? .connected
        HStack(spacing: 6) {
            Circle()
                .fill(worst.color)
                .frame(width: 7, height: 7)
            Text(text)
                .lineLimit(1)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .help(places.contains { $0.state == .waitsForCode } ? waitsForCodeHelp : "")
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
    @State private var failed = false

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
                        if failed {
                            Text("Couldn’t save it in your Keychain. Try again, or check Keychain Access.")
                                .foregroundStyle(.red)
                        }
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
        let saved = keys.allSatisfy { key in
            IntegrationKeys.set(values[key.name]?.trimmingCharacters(in: .whitespacesAndNewlines), for: IntegrationKeys.variable(service.id, key.name))
        }
        guard saved else {
            failed = true
            return
        }
        done(true)
    }
}
