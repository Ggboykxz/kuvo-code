import Foundation
import Synchronization

/// An account the host app already has: one connected in Kuvo Code's own Accounts screen, which its
/// opencode engine stores. (Fork addition.)
public struct HostCredential: Sendable, Hashable {
    /// The opencode integration ID: `github-copilot`, `openrouter`, `zai-coding-plan`, …
    public var integrationID: String
    /// The OAuth access token or API key.
    public var secret: String

    public init(integrationID: String, secret: String) {
        self.integrationID = integrationID
        self.secret = secret
    }
}

/// What the host app shares with the providers: its own accounts, which come before the logins other
/// tools leave on the Mac, and the folders where its private opencode engine keeps data, so the host's
/// own agent runs count toward spend. (Fork addition.)
public enum HostAccounts {
    private static let credentials = Mutex<[HostCredential]>([])
    private static let openCodeDirectories = Mutex<[String]>([])

    /// Replaces the host's accounts, then refreshes the providers that read them.
    @MainActor
    public static func update(_ newCredentials: [HostCredential]) {
        let changed = credentials.withLock { current in
            defer { current = newCredentials }
            return current != newCredentials
        }
        if changed { UsageMenuBar.shared.refresh(providerIDs: ["copilot", "openrouter", "zai", "opencode"]) }
    }

    /// Adds opencode data folders (each holding `opencode*.db`) to read alongside the user's own.
    public static func setOpenCodeDataDirectories(_ paths: [String]) {
        openCodeDirectories.withLock { $0 = paths }
    }

    /// The first account for any of `integrationIDs`, in that order.
    static func secret(for integrationIDs: [String]) -> String? {
        credentials.withLock { all in
            for id in integrationIDs {
                if let match = all.first(where: { $0.integrationID == id }),
                   let secret = match.secret.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                    return secret
                }
            }
            return nil
        }
    }

    static var openCodeDataDirectories: [String] {
        openCodeDirectories.withLock { $0 }
    }
}
