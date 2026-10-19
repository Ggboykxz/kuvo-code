import Foundation
import OpenCodeKit
import os

private let log = Logger(subsystem: "run.kuvo.code", category: "agents")

/// The coding agents you already have, beside the engine: Claude Code, Codex, Cursor, Grok and
/// Antigravity, each signed in as you (your plan or key with its maker), as T3 Code runs them.
///
/// A small server of Kuvo Code's own, the agents bridge (`kuvo-agents.js`, run by the engine's
/// Bun), drives each agent through its maker's SDK or CLI and answers in the engine's own API, so
/// their sessions, models and sign-ins show where the engine's do. Its sessions run on this Mac;
/// what it keeps is in `agents` beside the engine's folder.
@Observable
final class OutsideAgents {
    /// The bridge, once it has started.
    private(set) var api: OpenCodeAPI? {
        didSet { address.endpoint = api?.client.endpoint }
    }
    /// Its address, for the phone link's own threads.
    @ObservationIgnored let address = Address()

    nonisolated final class Address: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ServerEndpoint?

        var endpoint: ServerEndpoint? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
    /// It couldn't start, and why.
    private(set) var failure: String?

    @ObservationIgnored private var server: ServerProcess?
    /// Starting: a second start meanwhile (the engine restarted) waits for this one.
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var restarts: [Date] = []
    @ObservationIgnored private var engine: URL?
    @ObservationIgnored private var environment: [String: String] = [:]
    /// Each event it sends (to the catalog and the sessions, as the engine's go).
    @ObservationIgnored var onEvent: ((ServerEvent) -> Void)?
    /// Its feed is connected (again): what it has is read anew.
    @ObservationIgnored var onConnected: (() -> Void)?

    /// Where this Mac's engine is, for the engine's own models in the bridge's sessions (Auto's,
    /// or one you pick in a session with an agent). Told to the bridge each time either starts.
    @ObservationIgnored var engineEndpoint: ServerEndpoint? {
        didSet { if engineEndpoint != oldValue { tellEngine() } }
    }

    /// Auto: your list of models, and those held back at a limit until it resets.
    private(set) var auto = AutoList()

    /// The agents' providers (their models' and accounts' IDs), as the bridge names them: an
    /// account you added is `<agent's>@<id>` ("claude-code@1f2e3d4c").
    static let order = ["claude-code", "codex-cli", "cursor", "grok-cli", "antigravity"]
    static let providers = Set(order)
    /// Auto's provider: a session on it runs down your list.
    static let autoProvider = "auto"

    /// The agent's own provider, without the account: "claude-code" for "claude-code@1f2e3d4c".
    static func base(_ providerID: String) -> String {
        providerID.split(separator: "@", maxSplits: 1).first.map(String.init) ?? providerID
    }

    /// The account part of an added account's provider, if it is one.
    static func account(_ providerID: String) -> String? {
        let parts = providerID.split(separator: "@", maxSplits: 1)
        return parts.count == 2 && providers.contains(String(parts[0])) ? String(parts[1]) : nil
    }

    /// An agent's name, by its provider.
    static func name(_ providerID: String?) -> String {
        switch providerID.map(base) {
        case "claude-code": "Claude Code"
        case "codex-cli": "Codex"
        case "cursor": "Cursor"
        case "grok-cli": "Grok"
        case "antigravity": "Antigravity"
        default: "That agent"
        }
    }

    /// The mark an agent goes by: its maker's.
    static func logo(_ providerID: String) -> String {
        switch base(providerID) {
        case "claude-code": "anthropic"
        case "codex-cli": "openai"
        case "grok-cli": "xai"
        case "antigravity": "google"
        default: providerID
        }
    }

    /// One of your accounts with a coding agent.
    static func isAgent(_ providerID: String?) -> Bool {
        providerID.map { providers.contains(base($0)) } ?? false
    }

    /// A model the bridge runs a session on: an agent's, or Auto.
    static func runsInBridge(_ providerID: String?) -> Bool {
        providerID == autoProvider || isAgent(providerID)
    }

    /// A session one of these agents runs: the bridge marks its own.
    static func isAgentSession(_ session: Session) -> Bool {
        session.metadata?["kuvoAgent"]?.string != nil
    }

    /// Where the bridge keeps its sessions, the agents' SDKs and its cache.
    static var home: URL { AppInfo.supportDirectory.appending(path: "agents") }

    /// The bridge's script: KUVO_AGENTS_SCRIPT's (a checkout's `Agents/src/main.ts`) in a debug
    /// build, else the app's own.
    private static var script: URL? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["KUVO_AGENTS_SCRIPT"] { return URL(filePath: path) }
        #endif
        return Bundle.main.url(forResource: "kuvo-agents", withExtension: "js")
    }

    /// Starts the bridge with the engine's Bun, in your login shell's environment (so it finds
    /// `claude`, `codex` and `grok` where your terminal does).
    func start(engine: URL, environment: [String: String]) async {
        guard server == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        self.engine = engine
        self.environment = environment
        guard let script = Self.script else {
            failure = "The agents bridge is missing from the app."
            return
        }
        var env = environment
        env["BUN_BE_BUN"] = "1"
        env["KUVO_AGENTS_HOME"] = Self.home.path
        // Its temporary files (and the agents'), in the app's own temporary folder.
        let temporary = FileManager.default.temporaryDirectory.appending(path: Bundle.main.bundleIdentifier ?? "run.kuvo.code").appending(path: "agents")
        env["TMPDIR"] = temporary.path + "/"
        do {
            try FileManager.default.createDirectory(at: Self.home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let server = try await ServerProcess.start(
                executable: engine,
                arguments: ["run", script.path],
                environment: env,
                directory: Self.home,
                onExit: { [weak self] status in Task { @MainActor in self?.exited(status: status) } }
            )
            self.server = server
            let api = OpenCodeAPI(endpoint: server.endpoint)
            self.api = api
            failure = nil
            listen(to: api)
            tellEngine()
            await loadAuto()
        } catch {
            log.error("The agents bridge didn't start: \(error.localizedDescription, privacy: .public)")
            failure = error.localizedDescription
        }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        server?.stop()
        server = nil
        api = nil
    }

    private func listen(to api: OpenCodeAPI) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await update in api.events.updates() {
                guard let self else { return }
                switch update {
                case .connected:
                    onConnected?()
                    await loadAuto()
                case .disconnected: break
                case .event(let event):
                    if event.type == "kuvo.auto.updated" { await loadAuto() }
                    onEvent?(event)
                }
            }
        }
    }

    /// It stopped by itself: started again, unless it keeps stopping.
    private func exited(status: Int32) {
        guard server != nil else { return }
        let output = server?.recentOutput.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        log.error("The agents bridge stopped (\(status)): \(output, privacy: .public)")
        stop()
        restarts.removeAll { $0 < .now.addingTimeInterval(-300) }
        guard restarts.count < 3, let engine else {
            failure = "It stopped unexpectedly (exit code \(status)).\(output.isEmpty ? "" : "\n\n" + String(output.suffix(600)))"
            return
        }
        restarts.append(.now)
        let environment = environment
        Task { await start(engine: engine, environment: environment) }
    }

    /// Tells the bridge where the engine is.
    private func tellEngine() {
        guard let api, let engineEndpoint else { return }
        Task { try? await api.setAgentsEngine(engineEndpoint) }
    }

    // MARK: Auto

    func loadAuto() async {
        guard let api, let list = try? await api.autoList() else { return }
        if list != auto { auto = list }
    }

    /// Your list as you arranged it.
    func saveAuto(_ entries: [AutoEntry]) async throws {
        guard let api else { throw Failure.unavailable("Auto") }
        auto = AutoList(entries: entries, limits: auto.limits)
        auto = try await api.saveAutoList(entries)
    }

    /// Every model at a limit tried again.
    func clearAutoLimits() async throws {
        guard let api else { throw Failure.unavailable("Auto") }
        try await api.clearAutoLimits()
        await loadAuto()
    }

    // MARK: Accounts

    /// Another account with an agent: its provider, to sign in to.
    func addAccount(agent: String, label: String) async throws -> String {
        guard let api else { throw Failure.unavailable("Adding an account") }
        return try await api.addAgentAccount(agent: agent, label: label)
    }

    func renameAccount(_ providerID: String, label: String) async throws {
        guard let api else { throw Failure.unavailable("Renaming an account") }
        try await api.renameAgentAccount(providerID, label: label)
    }

    func removeAccount(_ providerID: String) async throws {
        guard let api else { throw Failure.unavailable("Removing an account") }
        try await api.removeAgentAccount(providerID)
    }

    /// Signs out of an agent, where the agent lets an app do that (Cursor's browser sign-in).
    func signOut(_ providerID: String) async throws {
        guard let api else { return }
        try await api.disconnectAgent(providerID)
    }

    enum Failure: LocalizedError {
        case onlyOnThisMac(String)
        case unavailable(String)
        /// The bridge isn't up (yet): why, if it couldn't start.
        case notRunning(String?)

        var errorDescription: String? {
            switch self {
            case .onlyOnThisMac(let agent): "\(agent) runs on this Mac: start its sessions in a project here."
            case .unavailable(let what): "\(what) isn't available in sessions with this agent."
            case .notRunning(let why): why.map { "The coding agents couldn't start: \($0)" } ?? "The coding agents are still starting. Try again in a moment."
            }
        }
    }
}

/// One model in your Auto list, with its effort.
nonisolated struct AutoEntry: Codable, Hashable, Identifiable, Sendable {
    var providerID: String
    var modelID: String
    var variant: String?

    var id: String { "\(providerID)/\(modelID)/\(variant ?? "")" }
    var ref: ModelRef { ModelRef(id: modelID, providerID: providerID, variant: variant) }

    init(_ ref: ModelRef) {
        providerID = ref.providerID
        modelID = ref.id
        variant = ref.variant
    }
}

/// A model, or an account's every model, held back at a limit until it resets.
nonisolated struct AutoLimit: Codable, Hashable, Sendable {
    /// `<provider>` for an account's limit, `<provider>/<model>` for a model's.
    var key: String
    /// Milliseconds since 1970.
    var until: Double
    var scope: String
    /// Its reset is the agent's word, rather than a guess.
    var known: Bool

    var resets: Date { Date(timeIntervalSince1970: until / 1000) }
    var isWholeAccount: Bool { scope == "provider" }

    /// It holds back this entry.
    func holds(_ entry: AutoEntry) -> Bool {
        key == entry.providerID || key == "\(entry.providerID)/\(entry.modelID)"
    }
}

nonisolated struct AutoList: Codable, Hashable, Sendable {
    var entries: [AutoEntry] = []
    var limits: [AutoLimit] = []
}

extension OpenCodeAPI {
    /// The agents' accounts; `fresh` asks each agent anew (with your shell's PATH read again).
    func agentIntegrations(fresh: Bool) async throws -> [Integration] {
        let request = try client.request("GET", "api/integration", query: ["fresh": fresh ? "1" : nil])
        return try await client.send(request, as: LocatedEnvelope<[Integration]>.self).data
    }

    /// The agents bridge's own: where the engine is, for its models in the bridge's sessions.
    func setAgentsEngine(_ endpoint: ServerEndpoint) async throws {
        struct Body: Encodable { var url: String; var password: String? }
        _ = try await client.send(try client.request("PUT", "api/kuvo/engine", body: Body(url: endpoint.url.absoluteString, password: endpoint.password)), as: Empty.self)
    }

    func autoList() async throws -> AutoList {
        try await client.send(try client.request("GET", "api/kuvo/auto"), as: DataEnvelope<AutoList>.self).data
    }

    func saveAutoList(_ entries: [AutoEntry]) async throws -> AutoList {
        struct Body: Encodable { var entries: [AutoEntry] }
        return try await client.send(try client.request("PUT", "api/kuvo/auto", body: Body(entries: entries)), as: DataEnvelope<AutoList>.self).data
    }

    func clearAutoLimits() async throws {
        _ = try await client.send(try client.request("DELETE", "api/kuvo/auto/limits"), as: Empty.self)
    }

    /// Another account with an agent (`claude`, `codex`…): its provider ID.
    func addAgentAccount(agent: String, label: String) async throws -> String {
        struct Body: Encodable { var agent: String; var label: String }
        return try await client.send(try client.request("POST", "api/kuvo/accounts", body: Body(agent: agent, label: label)), as: DataEnvelope<AddedAccount>.self).data.providerID
    }

    func renameAgentAccount(_ providerID: String, label: String) async throws {
        struct Body: Encodable { var label: String }
        _ = try await client.send(try client.request("PATCH", "api/kuvo/accounts/\(providerID.pathComponentEscaped)", body: Body(label: label)), as: Empty.self)
    }

    func removeAgentAccount(_ providerID: String) async throws {
        _ = try await client.send(try client.request("DELETE", "api/kuvo/accounts/\(providerID.pathComponentEscaped)"), as: Empty.self)
    }

    /// The agents bridge's own: signs out of an agent it signed in to itself.
    func disconnectAgent(_ providerID: String) async throws {
        _ = try await client.send(try client.request("POST", "api/integration/\(providerID.pathComponentEscaped)/disconnect"), as: Empty.self)
    }
}

nonisolated private struct AddedAccount: Decodable, Sendable {
    var providerID: String
}

nonisolated private extension String {
    /// As one part of a path: "claude-code@1f2e" stays readable, anything else is escaped.
    var pathComponentEscaped: String {
        addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~@"))) ?? self
    }
}
