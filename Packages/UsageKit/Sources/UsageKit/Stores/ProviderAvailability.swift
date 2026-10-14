import Foundation
import Observation

/// Fork addition: which turned-on providers have nothing to show on this Mac, learned from their
/// refreshes: no login was found, or the account has no usage to read (an API-key login, no
/// subscription). The dashboard, the menu bar and Total Spend leave them out, so the panel only
/// shows providers the user really has; Customize says why. They keep being refreshed, and come
/// back on their own once a refresh succeeds (after the user signs in, say).
@MainActor
@Observable
final class ProviderAvailability {
    private static let storageKey = "kuvo.usage.unavailableProviders.v1"

    /// Why each unavailable provider is: `.notLoggedIn` or `.notAvailable`.
    private(set) var reasons: [String: ErrorCategory]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
        reasons = stored.compactMapValues(ErrorCategory.init(rawValue:))
    }

    func isAvailable(_ providerID: String) -> Bool {
        reasons[providerID] == nil
    }

    /// Why Customize's row for a turned-on provider isn't on the dashboard; nil when it is.
    func note(for providerID: String) -> String? {
        switch reasons[providerID] {
        case .notLoggedIn: "Not signed in on this Mac"
        case .notAvailable: "No usage to show for this account"
        default: nil
        }
    }

    /// A refresh's outcome: a success makes the provider available; a failure because there's no
    /// login or no usage to read makes it unavailable. Other failures (the network, an expired
    /// login) leave it as it was: those are worth seeing.
    func record(_ providerID: String, succeeded: Bool, category: ErrorCategory?) {
        var next = reasons
        if succeeded {
            next[providerID] = nil
        } else if let category, category == .notLoggedIn || category == .notAvailable {
            next[providerID] = category
        }
        guard next != reasons else { return }
        reasons = next
        defaults.set(next.mapValues(\.rawValue), forKey: Self.storageKey)
    }
}
