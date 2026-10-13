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

    /// Hands the engine's active accounts to UsageKit. Secrets stay in memory.
    func sync() async {
        guard let api else { return }
        do {
            let credentials = try await api.credentialSecrets()
            HostAccounts.update(credentials.filter(\.active).compactMap { credential in
                guard let secret = credential.value.access ?? credential.value.key, !secret.isEmpty else { return nil }
                return HostCredential(integrationID: credential.integrationID, secret: secret)
            })
        } catch {
            log.error("credentials: \(String(describing: error), privacy: .public)")
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
