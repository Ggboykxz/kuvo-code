import Foundation
import OpenCodeKit
import os

private let log = Logger(subsystem: "run.kuvo.code", category: "catalog")

/// What the engine offers: providers to sign in to, models, agents, commands.
/// All of it comes from the engine, so new providers appear without an app update.
@Observable
final class Catalog {
    var api: OpenCodeAPI?
    /// This Mac's engine's, whose list of models says what every engine is started with
    /// (`ProviderCompatibility`); a machine's would make the two take turns, and the machine's
    /// engine look out of date each time.
    let isMac: Bool

    init(isMac: Bool = false) {
        self.isMac = isMac
    }

    /// The outside agents' bridge (Claude Code, Codex…), on this Mac's catalog: their accounts and
    /// models join the engine's.
    @ObservationIgnored var outsideAgents: OutsideAgents?

    /// The engine's integrations, and the outside agents' after them.
    private(set) var integrations: [Integration] = []
    /// The engine's models, and the outside agents' after them.
    private(set) var models: [Model] = []
    @ObservationIgnored private var engineIntegrations: [Integration] = []
    @ObservationIgnored private var engineModels: [Model] = []
    @ObservationIgnored private var agentIntegrations: [Integration] = []
    @ObservationIgnored private var agentModels: [Model] = []
    private(set) var defaultModel: Model?
    private(set) var agents: [Agent] = []
    private(set) var commands: [Command] = []
    /// Commands by project folder, with the project's own.
    private(set) var projectCommands: [String: [Command]] = [:]
    private(set) var isLoaded = false
    /// True while a refresh has been waiting more than a few seconds.
    private(set) var isSlow = false

    private var refreshTask: Task<Void, Never>?

    /// While the engine starts up it answers 503 ("Location plugins did not finish activating"),
    /// and the models come later: they're asked for again every few seconds, so they show once
    /// it's ready (after you answer a macOS prompt for folder access it was waiting on, say).
    /// Past `stallLimit` the engine is taken for stuck (a fetch of its own that never ends
    /// leaves it so for good), and the app starts it over.
    @ObservationIgnored var onStalled: (() -> Void)?
    @ObservationIgnored private var unavailableSince: ContinuousClock.Instant?
    private static let stallLimit: Duration = .seconds(60)

    /// AI providers only: no MCP servers or web-search services.
    var providers: [Integration] {
        integrations.filter { !$0.isMCP && !Self.searchServices.contains($0.id) }
    }

    var connectedProviders: [Integration] {
        providers.filter(\.isConnected)
    }

    /// The outside agents (Claude Code, Codex, Cursor, Grok, Antigravity), as the bridge lists them.
    var codingAgents: [Integration] {
        integrations.filter { OutsideAgents.isAgent($0.id) }
    }

    var primaryAgents: [Agent] {
        agents.filter(\.isPrimary)
    }

    /// The mode a new session starts in: the one chosen in Settings, if it's still a mode you
    /// can pick; otherwise Build, or the first mode there is when Build is turned off.
    func startingAgent(chosen: String?) -> String {
        let modes = primaryAgents.map(\.id)
        if let chosen, modes.contains(chosen) { return chosen }
        return modes.isEmpty || modes.contains("build") ? "build" : modes[0]
    }

    /// The models you can use now, offered in pickers: those of an account you connected,
    /// OpenCode Zen's free ones (they need no account), and those of a provider with nothing to
    /// sign in to (a local one). The engine lists every provider it knows, connected or not, and
    /// one that isn't only fails ("missing required Authorization header"); its models show once
    /// it's connected.
    var offered: [Model] {
        let byID = Dictionary(integrations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return models.filter { model in
            guard model.enabled else { return false }
            if model.providerID == "opencode", model.isFree { return true }
            guard let provider = byID[model.providerID] else { return true }
            return provider.isConnected || provider.methods.isEmpty
        }
    }

    /// Models grouped by provider, providers in the order people tend to look for them.
    var modelsByProvider: [(provider: String, models: [Model])] {
        let groups = Dictionary(grouping: offered.filter { !OutsideAgents.isAgent($0.providerID) }, by: \.providerID)
        return groups.keys
            .sorted { (Self.featuredOrder[$0] ?? 99, $0) < (Self.featuredOrder[$1] ?? 99, $1) }
            .map { id in (providerName(id), groups[id]!.sorted { $0.time.released > $1.time.released }) }
    }

    /// The models a picker offers, by provider: the engine's, an outside agent's, or both (a new
    /// session on this Mac), the agents' first.
    func modelGroups(_ scope: ModelScope) -> [(provider: String, models: [Model])] {
        let agents = OutsideAgents.order.compactMap { id -> (provider: String, models: [Model])? in
            guard scope.allows(id) else { return nil }
            let models = offered.filter { $0.providerID == id }
            return models.isEmpty ? nil : (providerName(id), models)
        }
        if case .agent = scope { return agents }
        return scope == .all ? agents + modelsByProvider : modelsByProvider
    }

    func model(_ ref: ModelRef?) -> Model? {
        guard let ref else { return nil }
        return models.first { $0.id == ref.id && $0.providerID == ref.providerID }
    }

    /// The model, if it's one you can use now (see `offered`).
    func offeredModel(_ ref: ModelRef?) -> Model? {
        guard let ref else { return nil }
        return offered.first { $0.id == ref.id && $0.providerID == ref.providerID }
    }

    /// A model picked that you can't use now (gone from its provider, or its account signed out
    /// of): it would only fail. Not before the models are known.
    func isUnavailable(_ ref: ModelRef?) -> Bool {
        isLoaded && ref != nil && offeredModel(ref) == nil
    }

    /// The model a new session or bot starts on: the first of `wanted` (the one picked, the one
    /// picked last) you can use now; else the engine's default, if you can; else the first model
    /// you can use. A model whose account you signed out of would only fail. Before the models are
    /// known (just after launch), the first of `wanted` as it is.
    func startingModel(_ wanted: ModelRef?..., scope: ModelScope = .all) -> ModelRef? {
        let wanted = wanted.compactMap(\.self).filter { scope.allows($0.providerID) }
        guard isLoaded else { return wanted.first ?? defaultModel?.ref }
        if let ref = wanted.first(where: { offeredModel($0) != nil }) { return ref }
        if let model = offeredModel(defaultModel?.ref) { return model.ref }
        return modelsByProvider.first?.models.first?.ref
    }

    func providerName(_ id: String) -> String {
        if id == "opencode" { return "OpenCode Zen" }
        return integrations.first { $0.id == id }?.name ?? id
    }

    func refresh() async {
        guard let api else { return }
        let slowness = Task {
            try await Task.sleep(for: .seconds(3))
            isSlow = true
        }
        defer {
            slowness.cancel()
            isSlow = false
        }
        async let integrations = api.integrations()
        async let models = api.models()
        async let defaultModel = api.defaultModel()
        async let agents = api.agents()
        async let commands = api.commands()
        do { engineIntegrations = try await integrations } catch { log.error("integrations: \(String(describing: error), privacy: .public)") }
        var starting = false
        do {
            engineModels = try await models
            if isMac { ProviderCompatibility.learn(from: engineModels) }
            LogoImages.shared.prefetch(engineModels.flatMap { [$0.makerLogoID, $0.providerID] })
        } catch {
            log.error("models: \(String(describing: error), privacy: .public)")
            starting = (error as? ServerError)?.status == 503
        }
        do { self.defaultModel = try await defaultModel } catch { log.error("default model: \(String(describing: error), privacy: .public)") }
        do { self.agents = try await agents } catch { log.error("agents: \(String(describing: error), privacy: .public)") }
        do { self.commands = try await commands } catch { log.error("commands: \(String(describing: error), privacy: .public)") }
        for directory in projectCommands.keys { await loadCommands(in: directory) }
        merge()
        isLoaded = true
        await refreshAgents()
        if starting { waitForEngine() } else { unavailableSince = nil }
    }

    /// The outside agents' accounts and models, from their bridge.
    func refreshAgents() async {
        guard let api = outsideAgents?.api else { return }
        async let integrations = api.integrations()
        async let models = api.models()
        do { agentIntegrations = try await integrations } catch { log.error("agents: \(String(describing: error), privacy: .public)") }
        do { agentModels = try await models } catch { log.error("agents' models: \(String(describing: error), privacy: .public)") }
        merge()
    }

    private func merge() {
        integrations = engineIntegrations + agentIntegrations
        models = engineModels + agentModels
    }

    /// Where an account signs in: the agents bridge for an outside agent's, else the engine.
    func api(forIntegration id: String) -> OpenCodeAPI? {
        OutsideAgents.isAgent(id) ? outsideAgents?.api : api
    }

    /// The engine is still starting: the models again in a moment, or, when it's been too long,
    /// the engine started over (once a launch, see AppModel), and the models asked for again, less
    /// often: one waiting on a macOS prompt finishes when it's answered.
    private func waitForEngine() {
        let since = unavailableSince ?? .now
        unavailableSince = since
        var wait = Duration.seconds(5)
        if ContinuousClock.now - since >= Self.stallLimit {
            log.error("the engine hasn't finished starting in \(Self.stallLimit, privacy: .public): starting it over")
            unavailableSince = nil
            onStalled?()
            wait = .seconds(15)
        }
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    /// The commands a session in `directory` can run.
    func commands(in directory: String) -> [Command] {
        projectCommands[directory] ?? commands
    }

    func loadCommands(in directory: String) async {
        guard let api else { return }
        do { projectCommands[directory] = try await api.commands(directory: directory) } catch { log.error("commands: \(String(describing: error), privacy: .public)") }
    }

    func handle(_ event: ServerEvent) {
        switch event.type {
        case "integration.updated", "credential.updated", "credential.switched", "provider.updated",
             "model.updated", "agent.updated", "command.updated", "config.updated":
            scheduleRefresh()
        default:
            break
        }
    }

    /// Catalog events come in bursts (a sign-in updates integrations, providers and
    /// models at once), so refresh once they settle.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    /// Shown first, in this order. Everything else follows alphabetically.
    /// (The outside agents have their own place, before these: `OutsideAgents.order`.)
    static let featured = ["openai", "github-copilot", "anthropic", "google", "xai", "openrouter", "opencode", "deepseek", "mistral", "groq"]
    static let featuredOrder = Dictionary(uniqueKeysWithValues: featured.enumerated().map { ($1, $0) })
    private static let searchServices: Set = ["exa", "firecrawl", "parallel", "tavily", "tinyfish"]
}

/// Which models a picker offers: the engine's (a session on it, a bot), one outside agent's (a
/// session with it: it can't change agents partway), or both (a new session on this Mac).
enum ModelScope: Equatable {
    case engine
    case agent(String)
    case all

    func allows(_ providerID: String) -> Bool {
        switch self {
        case .all: true
        case .engine: !OutsideAgents.isAgent(providerID)
        case .agent(let id): providerID == id
        }
    }
}
