// Usage providers adapted from OpenUsage (https://github.com/robinebers/openusage),
// MIT License, Copyright (c) 2026 Robin Ebers. See THIRD_PARTY_NOTICES.md.

import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Lenient readers for the JSON other tools write and providers return.
enum UsageParse {
    static func json(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// A number, from a JSON number or a numeric string; never from a boolean.
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue.isFinite ? number.doubleValue : nil
        }
        if let string = value as? String, let double = Double(string.trimmingCharacters(in: .whitespaces)), double.isFinite {
            return double
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        switch (value as? String)?.lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }

    static func clampPercent(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 100) : 0
    }

    /// Some tools store their JSON hex-encoded in the Keychain; accept either.
    static func decodeWithHexFallback<T>(_ text: String, decode: (Data) -> T?) -> T? {
        if let decoded = decode(Data(text.utf8)) { return decoded }
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8) else { return nil }
        return decode(Data(decoded.utf8))
    }

    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while !payload.count.isMultiple(of: 4) { payload.append("=") }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return json(data)
    }

    /// `gh` keeps its token as `go-keyring-base64:<base64>` in the Keychain.
    static func unwrapGoKeyring(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            guard let data = Data(base64Encoded: String(text.dropFirst(prefix.count))), let decoded = String(data: data, encoding: .utf8) else { return nil }
            text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    /// An instant from an ISO-8601 string (with or without fractional seconds, or a
    /// space instead of the `T`) or epoch seconds (milliseconds when it's that large).
    static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) {
            return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds)
        }
        guard var text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.count > 10, text[text.index(text.startIndex, offsetBy: 10)] == " " {
            text.replaceSubrange(text.index(text.startIndex, offsetBy: 10)...text.index(text.startIndex, offsetBy: 10), with: "T")
        }
        if text.count == 10 { text += "T00:00:00Z" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// A value under `host:` in `gh`'s hosts.yml.
    static func yamlValue(_ text: String, key: String, host: String = "github.com") -> String? {
        var inHost = false
        for line in text.split(whereSeparator: \.isNewline) {
            if let first = line.first, !first.isWhitespace {
                inHost = line.trimmingCharacters(in: .whitespaces).hasPrefix(host + ":")
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard inHost, trimmed.hasPrefix(key + ":") else { continue }
            let value = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// Requests to usage endpoints.
struct UsageHTTP: Sendable {
    var session: URLSession = .shared

    struct Response: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String]

        func header(_ name: String) -> String? { headers[name.lowercased()] }
        var isSuccess: Bool { (200..<300).contains(status) }
        var isAuthFailure: Bool { status == 401 || status == 403 }
    }

    func send(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 15) async throws -> Response {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        var lowered: [String: String] = [:]
        for (name, value) in http?.allHeaderFields ?? [:] {
            if let name = name as? String, let value = value as? String { lowered[name.lowercased()] = value }
        }
        return Response(status: http?.statusCode ?? 0, body: data, headers: lowered)
    }
}

/// Login files other tools keep in the home folder.
enum LoginFiles {
    static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix("~") ? home + path.dropFirst() : path
    }

    static func read(_ path: String) -> String? {
        try? String(contentsOfFile: expand(path), encoding: .utf8)
    }

    /// Replaces the file atomically, keeping it private to the user (these hold tokens).
    static func write(_ path: String, _ text: String) throws {
        let url = URL(filePath: expand(path))
        try Data(text.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Keychain items other tools own.
///
/// Items a command-line tool created through `/usr/bin/security` (Claude Code, `gh`)
/// are read and written through that same tool, so the "Always Allow" a person grants
/// survives the tool's next save. Secrets go to `security` on stdin, never as arguments.
struct LoginKeychain: Sendable {
    enum Owner: Sendable {
        /// Created through the Security framework (Codex): read in-process.
        case app
        /// Created through `/usr/bin/security` (Claude Code, gh).
        case securityTool
    }

    /// Whether an item exists, without reading it (so never a prompt). Nil when it can't tell.
    func exists(service: String, account: String? = nil) -> Bool? {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        switch SecItemCopyMatching(query as CFDictionary, nil) {
        case errSecSuccess, errSecInteractionNotAllowed: return true
        case errSecItemNotFound: return false
        default: return nil
        }
    }

    /// Reads a password. May show the system's "allow access" prompt; blocks until answered,
    /// so call it off the main actor.
    func read(service: String, account: String?, owner: Owner) -> String? {
        switch owner {
        case .app:
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnData as String: true,
            ]
            if let account { query[kSecAttrAccount as String] = account }
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        case .securityTool:
            var arguments = ["find-generic-password", "-s", service, "-w"]
            if let account { arguments.insert(contentsOf: ["-a", account], at: 1) }
            guard let output = Self.runSecurity(arguments: arguments) else { return nil }
            let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    /// Updates a password in place (adding it if missing).
    func write(service: String, account: String?, value: String, owner: Owner) throws {
        switch owner {
        case .app:
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            if let account { query[kSecAttrAccount as String] = account }
            var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
            if status == errSecItemNotFound {
                query[kSecValueData as String] = Data(value.utf8)
                status = SecItemAdd(query as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw UsageLoginError.keychainWrite(status) }
        case .securityTool:
            // `security -i` reads commands from stdin; -X takes the secret as hex, so no quoting games.
            let hex = Data(value.utf8).map { String(format: "%02x", $0) }.joined()
            let command = "add-generic-password -U -a \(Self.quoted(account ?? "")) -s \(Self.quoted(service)) -X \(hex)\n"
            guard Self.runSecurity(arguments: ["-i"], input: command) != nil else { throw UsageLoginError.keychainWrite(errSecIO) }
        }
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Runs `/usr/bin/security`; nil when it fails. A permission prompt can take a while to be answered.
    private static func runSecurity(arguments: [String], input: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        do { try process.run() } catch { return nil }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The account most CLI tools file their item under.
    static var currentUser: String {
        ProcessInfo.processInfo.environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
    }

    /// Codex's Keychain account: `cli|` + the first 8 bytes of SHA-256 of the real path of its home.
    static func codexAccount(home: String) -> String {
        let expanded = LoginFiles.expand(home)
        let canonical = expanded.withCString { path -> String in
            guard let resolved = realpath(path, nil) else { return expanded }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return "cli|" + SHA256.hash(data: Data(canonical.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

enum UsageLoginError: Error {
    case keychainWrite(OSStatus)
    /// The login changed (the tool itself renewed it) while we were renewing; theirs wins.
    case changedMeanwhile
}
