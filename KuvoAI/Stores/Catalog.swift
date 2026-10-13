import Foundation
import OpenCodeKit
import os

private let log = Logger(subsystem: "run.kuvo.ai", category: "catalog")

/// What the engine offers: providers to sign in to, models, agents, commands.
/// All of it comes from the engine, so new providers appear without an app update.
@Observable
final class Catalog {
    var api: OpenCodeAPI?

    private(set) var integrations: [Integration] = []
    private(set) var models: [Model] = []
    private(set) var defaultModel: Model?
    private(set) var agents: [Agent] = []
    private(set) var commands: [Command] = []
    private(set) var isLoaded = false
    /// True while a refresh has been waiting more than a few seconds.
    private(set) var isSlow = false

    private var refreshTask: Task<Void, Never>?

    /// AI providers only: no MCP servers or web-search services.
    var providers: [Integration] {
        integrations.filter { !$0.isMCP && !Self.searchServices.contains($0.id) }
    }

    var connectedProviders: [Integration] {
        providers.filter(\.isConnected)
    }

    var primaryAgents: [Agent] {
        agents.filter(\.isPrimary)
    }

    /// Models grouped by provider, providers in the order people tend to look for them.
    var modelsByProvider: [(provider: String, models: [Model])] {
        let groups = Dictionary(grouping: models.filter(\.enabled), by: \.providerID)
        return groups.keys
            .sorted { (Self.featuredOrder[$0] ?? 99, $0) < (Self.featuredOrder[$1] ?? 99, $1) }
            .map { id in (providerName(id), groups[id]!.sorted { $0.time.released > $1.time.released }) }
    }

    func model(_ ref: ModelRef?) -> Model? {
        guard let ref else { return nil }
        return models.first { $0.id == ref.id && $0.providerID == ref.providerID }
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
        do { self.integrations = try await integrations } catch { log.error("integrations: \(String(describing: error), privacy: .public)") }
        do {
            self.models = try await models
            LogoImages.shared.prefetch(self.models.flatMap { [$0.makerLogoID, $0.providerID] })
        } catch { log.error("models: \(String(describing: error), privacy: .public)") }
        do { self.defaultModel = try await defaultModel } catch { log.error("default model: \(String(describing: error), privacy: .public)") }
        do { self.agents = try await agents } catch { log.error("agents: \(String(describing: error), privacy: .public)") }
        do { self.commands = try await commands } catch { log.error("commands: \(String(describing: error), privacy: .public)") }
        isLoaded = true
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
    static let featured = ["openai", "github-copilot", "anthropic", "google", "xai", "openrouter", "opencode", "deepseek", "mistral", "groq"]
    static let featuredOrder = Dictionary(uniqueKeysWithValues: featured.enumerated().map { ($1, $0) })
    private static let searchServices: Set = ["exa", "firecrawl", "parallel", "tavily", "tinyfish"]
}
