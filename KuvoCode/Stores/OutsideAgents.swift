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
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var restarts: [Date] = []
    @ObservationIgnored private var engine: URL?
    @ObservationIgnored private var environment: [String: String] = [:]
    /// Each event it sends (to the catalog and the sessions, as the engine's go).
    @ObservationIgnored var onEvent: ((ServerEvent) -> Void)?
    /// Its feed is connected (again): what it has is read anew.
    @ObservationIgnored var onConnected: (() -> Void)?

    /// The agents' providers (their models' and accounts' IDs), as the bridge names them.
    static let order = ["claude-code", "codex-cli", "cursor", "grok-cli", "antigravity"]
    static let providers = Set(order)

    /// An agent's name, by its provider.
    static func name(_ providerID: String?) -> String {
        switch providerID {
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
        switch providerID {
        case "claude-code": "anthropic"
        case "codex-cli": "openai"
        case "grok-cli": "xai"
        case "antigravity": "google"
        default: providerID
        }
    }

    static func isAgent(_ providerID: String?) -> Bool {
        providerID.map(providers.contains) ?? false
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
        guard server == nil else { return }
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
                case .connected: onConnected?()
                case .disconnected: break
                case .event(let event): onEvent?(event)
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

    /// Signs out of an agent, where the agent lets an app do that (Cursor's browser sign-in).
    func signOut(_ providerID: String) async throws {
        guard let api else { return }
        try await api.disconnectAgent(providerID)
    }

    enum Failure: LocalizedError {
        case onlyOnThisMac(String)
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .onlyOnThisMac(let agent): "\(agent) runs on this Mac: start its sessions in a project here."
            case .unavailable(let what): "\(what) isn't available in sessions with this agent."
            }
        }
    }
}

extension OpenCodeAPI {
    /// The agents bridge's own: signs out of an agent it signed in to itself.
    func disconnectAgent(_ providerID: String) async throws {
        var request = try client.request("POST", "api/integration/\(providerID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? providerID)/disconnect")
        request.httpMethod = "POST"
        _ = try await client.send(request, as: Empty.self)
    }
}
