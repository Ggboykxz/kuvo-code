import Foundation
import OpenCodeKit
import UsageKit
import os

private let log = Logger(subsystem: "run.kuvo.code", category: "usage")

/// Connects the usage panel in the menu bar (UsageKit, our fork of OpenUsage) to this app: accounts
/// connected here (Copilot, OpenRouter, Z.ai, OpenCode Go) count there, and so do the engine's own
/// agent runs, which UsageKit reads from the engine's database like any OpenCode install.
@Observable
final class UsageAccounts {
    var api: OpenCodeAPI?
    private var pending: Task<Void, Never>?

    /// Puts the usage item in the menu bar. `engineData` is the engine's opencode data folder.
    func start(engineData: URL, openApp: @escaping @MainActor () -> Void) {
        HostAccounts.setOpenCodeDataDirectories([engineData.path])
        UsageMenuBar.shared.start(openHostApp: openApp)
    }

    /// Hands the engine's active accounts to UsageKit, and which of its providers they stand for:
    /// the panel follows only those. Secrets stay in memory.
    func sync() async {
        guard let api else { return }
        do {
            let credentials = try await api.credentialSecrets()
            HostAccounts.update(credentials.filter(\.active).compactMap { credential in
                guard let secret = credential.value.access ?? credential.value.key, !secret.isEmpty else { return nil }
                return HostCredential(integrationID: credential.integrationID, secret: secret)
            })
            HostAccounts.setConnectedProviders(Set(credentials.filter(\.active).compactMap {
                Self.usageProvider(for: $0.integrationID, signedIn: $0.value.type == "oauth" || $0.value.access != nil)
            }))
        } catch {
            log.error("credentials: \(String(describing: error), privacy: .public)")
        }
    }

    /// The usage panel's provider for an account connected here, if it has one: a plan with limits
    /// or spend to follow. ChatGPT's sign-in is Codex; an OpenAI API key has no plan. SuperGrok's
    /// sign-in is Grok's weekly limit; an xAI API key has none. Anthropic only takes API keys here,
    /// and an Ollama key isn't the plan its panel reads, so they don't count.
    static func usageProvider(for integrationID: String, signedIn: Bool) -> String? {
        switch integrationID {
        case "github-copilot": "copilot"
        case "openai": signedIn ? "codex" : nil
        case "xai": signedIn ? "grok" : nil
        case "opencode", "opencode-go": "opencode"
        case "openrouter": "openrouter"
        case "zai", "zai-coding-plan": "zai"
        default: nil
        }
    }

    /// Accounts change in bursts (a sign-in updates integrations and credentials at once).
    func handle(_ event: ServerEvent) {
        switch event.type {
        case "integration.updated", "credential.updated", "credential.switched":
            pending?.cancel()
            pending = Task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await sync()
            }
        default:
            break
        }
    }
}
