import Foundation

/// Claude Code's subagents (~/.claude/agents/*.md): a header with a name and a description,
/// then instructions. Kuvo Code brings them over as the engine's subagents.
nonisolated enum ClaudeAgents {
    struct Agent: Identifiable, Sendable {
        /// Its name in the engine's settings.
        var id: String
        var name: String
        var description: String
        var instructions: String
    }

    /// The engine's own agents, which an imported one mustn't replace.
    private static let reserved: Set = ["build", "plan", "general", "explore", "compaction", "title", "summary"]

    static func load(from folder: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/agents")) -> [Agent] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }
            .compactMap { file in (try? String(contentsOf: file, encoding: .utf8)).flatMap { parse($0, fallbackName: file.deletingPathExtension().lastPathComponent) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func parse(_ text: String, fallbackName: String) -> Agent? {
        var fields: [String: String] = [:]
        var body = text
        if text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            let lines = text[text.index(text.startIndex, offsetBy: 3)..<end.lowerBound].components(separatedBy: "\n")
            var index = 0
            while index < lines.count {
                let line = lines[index]
                index += 1
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                // A block (| or >): the indented lines after it.
                if value == "|" || value == ">" || value == "|-" || value == ">-" {
                    var block: [String] = []
                    while index < lines.count, lines[index].hasPrefix(" ") || lines[index].isEmpty {
                        block.append(lines[index].trimmingCharacters(in: .whitespaces))
                        index += 1
                    }
                    value = block.joined(separator: value.hasPrefix("|") ? "\n" : " ").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                fields[key] = unquote(value)
            }
            body = String(text[end.upperBound...])
            if let newline = body.firstIndex(of: "\n") { body = String(body[body.index(after: newline)...]) }
        }
        let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        var id = String(name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        guard !id.isEmpty else { return nil }
        if reserved.contains(id) { id += "-claude" }
        // Claude Code writes "\n" for line breaks in a one-line description.
        let description = (fields["description"] ?? "").replacingOccurrences(of: "\\n", with: "\n")
        return Agent(id: id, name: name, description: description, instructions: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" else { return text }
        let inner = String(text.dropFirst().dropLast())
        return first == "\"" ? inner.replacingOccurrences(of: "\\\"", with: "\"") : inner.replacingOccurrences(of: "''", with: "'")
    }
}
