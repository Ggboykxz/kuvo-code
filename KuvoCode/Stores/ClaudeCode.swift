import Foundation

/// What Claude Code keeps in ~/.claude that the engine doesn't read on its own (it does read
/// skills): its subagents and slash commands, to bring over. Each is a Markdown file with a
/// header of fields (a name, a description) and its instructions or prompt.
nonisolated enum ClaudeCode {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")

    /// The header's fields and what comes after it.
    static func parse(_ text: String) -> (fields: [String: String], body: String) {
        guard text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else {
            return ([:], text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var fields: [String: String] = [:]
        let lines = text[text.index(text.startIndex, offsetBy: 3)..<end.lowerBound].components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // A block (| or >): the indented lines after it.
            if ["|", ">", "|-", ">-"].contains(value) {
                var block: [String] = []
                while index < lines.count, lines[index].hasPrefix(" ") || lines[index].isEmpty {
                    block.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                value = block.joined(separator: value.hasPrefix("|") ? "\n" : " ").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            fields[key] = unquote(value)
        }
        var body = String(text[end.upperBound...])
        if let newline = body.firstIndex(of: "\n") { body = String(body[body.index(after: newline)...]) }
        return (fields, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A name the engine takes: lowercase, with hyphens for anything else.
    static func id(_ name: String) -> String {
        String(name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
    }

    /// The Markdown files in a folder, read.
    static func files(in folder: URL) -> [(name: String, text: String)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "md" }
            .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { (url.deletingPathExtension().lastPathComponent, $0) } }
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" else { return text }
        let inner = String(text.dropFirst().dropLast())
        return first == "\"" ? inner.replacingOccurrences(of: "\\\"", with: "\"") : inner.replacingOccurrences(of: "''", with: "'")
    }
}

/// Claude Code's subagents (~/.claude/agents), to bring over as the engine's subagents.
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

    static func load(from folder: URL = ClaudeCode.folder.appending(path: "agents")) -> [Agent] {
        ClaudeCode.files(in: folder).compactMap { parse($0.text, fallbackName: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func parse(_ text: String, fallbackName: String) -> Agent? {
        let (fields, body) = ClaudeCode.parse(text)
        let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        var id = ClaudeCode.id(name)
        guard !id.isEmpty else { return nil }
        if reserved.contains(id) { id += "-claude" }
        // Claude Code writes "\n" for line breaks in a one-line description.
        let description = (fields["description"] ?? "").replacingOccurrences(of: "\\n", with: "\n")
        return Agent(id: id, name: name, description: description, instructions: body)
    }
}

/// Claude Code's slash commands (~/.claude/commands), to bring over as the engine's. Both fill
/// $ARGUMENTS with what's typed after the name.
nonisolated enum ClaudeCommands {
    struct Command: Identifiable, Sendable {
        var id: String
        var description: String
        var template: String
    }

    static func load(from folder: URL = ClaudeCode.folder.appending(path: "commands")) -> [Command] {
        ClaudeCode.files(in: folder).compactMap { file in
            let (fields, body) = ClaudeCode.parse(file.text)
            let id = ClaudeCode.id(file.name)
            guard !id.isEmpty, !body.isEmpty else { return nil }
            return Command(id: id, description: fields["description"] ?? "", template: body)
        }
        .sorted { $0.id < $1.id }
    }
}
