import Foundation
import Security

/// Keys you bring for integrations that take one (a bot token, an API key), kept in your Keychain.
/// This Mac's engine reads them from files only you can read, in Kuvo Code's temporary folder,
/// which its settings name with `{file:…}`: written each time it starts, and gone when Kuvo Code
/// quits. So they're never in its settings file, nor in its environment, where the agent's own
/// commands (`env`, say) would print them. Machines get them in memory, as environment variables
/// their settings name with `{env:…}`, never on their disk.
nonisolated enum IntegrationKeys {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "run.kuvo.code") + ".integrations" }

    /// The variable an integration's key goes in: KUVO_KEY_<ID>_<NAME>.
    static func variable(_ integration: String, _ name: String) -> String {
        "KUVO_KEY_" + (integration + "_" + name).uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }.map(String.init).joined()
    }

    /// Where this Mac's engine reads the keys.
    static var folder: URL {
        FileManager.default.temporaryDirectory.appending(path: Bundle.main.bundleIdentifier ?? "run.kuvo.code").appending(path: "integration-keys")
    }

    /// How this Mac's engine settings name a key: the file it's read from.
    static func reference(_ variable: String) -> String {
        "{file:\(folder.path)/\(variable)}"
    }

    /// Every key you saved, each in its file for the engine to read as it starts, and no others.
    static func writeFiles() {
        let keys = environment
        let manager = FileManager.default
        try? manager.removeItem(at: folder)
        guard !keys.isEmpty else { return }
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (name, value) in keys {
            manager.createFile(atPath: folder.appending(path: name).path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600])
        }
    }

    /// When Kuvo Code quits: the keys' files go.
    static func removeFiles() {
        try? FileManager.default.removeItem(at: folder)
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

    /// Saves a key, in place of the one before (or removes it, for nil or empty).
    @discardableResult
    static func set(_ value: String?, for variable: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: variable,
        ]
        guard let value, !value.isEmpty else {
            // Its file too, for an engine that's running.
            try? FileManager.default.removeItem(at: folder.appending(path: variable))
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let updated = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated != errSecItemNotFound { return updated == errSecSuccess }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Kuvo Code integration key"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// Every key you saved, as the environment the engines run with. (The keychain lists them
    /// without their values, so each is read on its own.)
    static var environment: [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [:] }
        var found: [String: String] = [:]
        for case let name as String in items.map({ $0[kSecAttrAccount as String] }) {
            if let value = value(name) { found[name] = value }
        }
        return found
    }
}
