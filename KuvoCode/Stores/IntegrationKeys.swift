import Foundation
import Security

/// Keys you bring for integrations that take one (a bot token, an API key), kept in your Keychain.
/// They reach the engines only in memory, as environment variables the engine's settings name
/// with `{env:…}`: never in its settings file, nor on a machine's disk.
nonisolated enum IntegrationKeys {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "run.kuvo.code") + ".integrations" }

    /// The variable an integration's key goes in: KUVO_KEY_<ID>_<NAME>.
    static func variable(_ integration: String, _ name: String) -> String {
        "KUVO_KEY_" + (integration + "_" + name).uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }.map(String.init).joined()
    }

    static func value(_ variable: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: variable,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves a key (or removes it, for nil or empty).
    @discardableResult
    static func set(_ value: String?, for variable: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: variable,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "Kuvo Code integration key"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// Every key you saved, as the environment the engines run with.
    static var environment: [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [:] }
        var found: [String: String] = [:]
        for item in items {
            if let name = item[kSecAttrAccount as String] as? String, let data = item[kSecValueData as String] as? Data,
               let value = String(data: data, encoding: .utf8) {
                found[name] = value
            }
        }
        return found
    }
}
