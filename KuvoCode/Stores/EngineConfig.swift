import Foundation
import OpenCodeKit

/// The engine's settings file, `opencode.json` in its own config folder: what it reads as its
/// global configuration, and reloads when the file changes. Settings edit it in place and keep
/// whatever they don't show, so a hand-edited file loses nothing.
@Observable
final class EngineConfig {
    let file: URL
    /// The file's settings; empty when there's no file yet.
    private(set) var settings: [String: JSONValue] = [:]
    /// Why the file couldn't be read. It's left alone until it's fixed.
    private(set) var problem: String?

    init(file: URL) {
        self.file = file
        reload()
        Self.current = self
    }

    /// This Mac's, for the places that make a session's rules.
    static weak var current: EngineConfig?

    /// What Kuvo Code gives every engine, unless the settings file sets it: web search through a
    /// free provider, moving to another when one is rate limited. The engine has none chosen, and
    /// every search the agent tried failed ("Web search provider is required").
    static func defaults(over settings: [String: Any]) -> [String: Any] {
        settings["websearch"] == nil ? ["websearch": ["provider": "random"]] : [:]
    }

    /// Settings › Permissions' rules, in their order: what every session and mode is held to.
    var permissionRules: [PermissionRule] {
        guard let value = settings["permissions"], let data = try? JSONEncoder().encode(value) else { return [] }
        return (try? JSONDecoder().decode([PermissionRule].self, from: data)) ?? []
    }

    /// Reads the file again, after it was changed elsewhere.
    func reload() {
        guard let data = try? Data(contentsOf: file) else {
            settings = [:]
            problem = nil
            return
        }
        do {
            settings = data.isEmpty ? [:] : try JSONDecoder().decode([String: JSONValue].self, from: data)
            problem = nil
        } catch {
            problem = "It isn't plain JSON, so Kuvo Code leaves it alone. (Comments aren't supported here.)"
        }
    }

    /// The value at a path of keys: `value(at: ["compaction", "auto"])`.
    func value(at path: [String]) -> JSONValue? {
        var current: JSONValue? = .object(settings)
        for key in path { current = current?[key] }
        return current
    }

    /// Sets the value at a path of keys, or removes it with nil (and any object it leaves
    /// empty), then saves.
    func set(_ value: JSONValue?, at path: [String]) {
        guard problem == nil, !path.isEmpty else { return }
        settings = Self.setting(value, at: path[...], in: settings)
        save()
    }

    /// Several changes at once, in one write: the engine reloads its settings once, not after
    /// each of them.
    func set(_ changes: [(path: [String], value: JSONValue?)]) {
        guard problem == nil else { return }
        for change in changes where !change.path.isEmpty {
            settings = Self.setting(change.value, at: change.path[...], in: settings)
        }
        save()
    }

    private static func setting(_ value: JSONValue?, at path: ArraySlice<String>, in object: [String: JSONValue]) -> [String: JSONValue] {
        var object = object
        let key = path.first!
        if path.count == 1 {
            object[key] = value
        } else {
            let inner = setting(value, at: path.dropFirst(), in: object[key]?.object ?? [:])
            object[key] = inner.isEmpty ? nil : .object(inner)
        }
        return object
    }

    private func save() {
        // No "$schema": opencode's published schema is still v1's, and would mark v2's keys
        // as errors in an editor.
        let document = settings
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(document).write(to: file, options: .atomic)
            settings = document
        } catch {
            problem = "It couldn't be saved: \(error.localizedDescription)"
        }
    }
}

// MARK: - Reading values

extension JSONValue {
    /// Whole numbers as `Int`: nil for one that isn't whole or doesn't fit.
    var int: Int? { number.flatMap { Int(exactly: $0) } }
}
