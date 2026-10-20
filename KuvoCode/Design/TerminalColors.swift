import SwiftUI

/// A command's output colored as a terminal shows it, in the code palette: a search's files, line
/// numbers and what it found; a diff's added and removed lines; errors and warnings. Everything
/// else stays as it was printed.
enum TerminalColors {
    static func colored(_ text: String, command: String, dark: Bool) -> AttributedString {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(command)
        hasher.combine(dark)
        let key = hasher.finalize()
        if let cached = cache[key] { return cached }
        let result = color(text, command: command, dark: dark)
        // A few outputs at a time are open; the oldest go.
        if cache.count >= 48 { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        return result
    }

    private static var cache: [Int: AttributedString] = [:]

    private static func color(_ text: String, command: String, dark: Bool) -> AttributedString {
        var result = AttributedString(text)
        let source = text as NSString
        func paint(_ range: NSRange, _ type: String, bold: Bool = false) {
            guard range.length > 0, let span = Range(range, in: result) else { return }
            if let color = CodeColors.color(for: type, dark: dark) { result[span].foregroundColor = color }
            if bold { result[span].inlinePresentationIntent = .stronglyEmphasized }
        }
        var lines: [NSRange] = []
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            lines.append(range)
        }
        let isDiff = command.range(of: #"(^|[\s|;&(])(git\s+(diff|show|log\s.*-p|stash\s+show)|diff)\s"#, options: .regularExpression) != nil
            || text.hasPrefix("diff --git ") || text.contains("\ndiff --git ")
        let isSearch = isSearch(command)
        let search = isSearch ? pattern(in: command) : nil
        var found = 0
        for (index, range) in lines.enumerated() {
            let line = source.substring(with: range)
            let whole = NSRange(location: 0, length: range.length)
            if isDiff {
                if line.hasPrefix("diff --git ") || line.hasPrefix("commit ") { paint(range, "keyword", bold: true); continue }
                if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("index ") { paint(range, "comment"); continue }
                if line.hasPrefix("@@") { paint(range, "class-name"); continue }
                if line.hasPrefix("+") { paint(range, "inserted"); continue }
                if line.hasPrefix("-") { paint(range, "deleted"); continue }
            }
            if isSearch {
                // "path:12:text" and "12:text" under a file; the file over its lines (rg's
                // headings); what it looked for, in what each line says.
                var textStart = 0
                if let match = located.firstMatch(in: line, range: whole) {
                    let file = match.range(at: 1), number = match.range(at: 2)
                    if file.location != NSNotFound { paint(NSRange(location: range.location + file.location, length: file.length), "keyword") }
                    paint(NSRange(location: range.location + number.location, length: number.length), "number")
                    textStart = match.range.length
                } else if !line.isEmpty, !line.hasPrefix(" "), index + 1 < lines.count,
                          numbered.firstMatch(in: source.substring(with: lines[index + 1]), range: NSRange(location: 0, length: lines[index + 1].length)) != nil {
                    paint(range, "keyword", bold: true)
                    continue
                }
                if let search, found < 2000 {
                    for hit in search.matches(in: line, range: NSRange(location: textStart, length: range.length - textStart)) where hit.range.length > 0 {
                        paint(NSRange(location: range.location + hit.range.location, length: hit.range.length), "string", bold: true)
                        found += 1
                    }
                }
                continue
            }
            if line.range(of: #"^(error|fatal|panic)\b|\berror(\[\w+\])?:"#, options: [.regularExpression, .caseInsensitive]) != nil {
                paint(range, "deleted")
            } else if line.range(of: #"^warning\b|\bwarning:"#, options: [.regularExpression, .caseInsensitive]) != nil {
                paint(range, "number")
            }
        }
        return result
    }

    /// "path:12:" or "path:12:3:" (and "path-12-" for a line around a match), or "12:" alone.
    private static let located = try! NSRegularExpression(pattern: #"^(?:([^\s:][^:\n]*?)[:-])?(\d+)[:-](?:\d+:)?"#)
    /// A line of a search's results under its file: "12:text" or "12-text".
    private static let numbered = try! NSRegularExpression(pattern: #"^\d+[:-]"#)

    private static func isSearch(_ command: String) -> Bool {
        command.range(of: #"(^|[\s|;&(])(rg|grep|egrep|fgrep|ag|git\s+grep)\s"#, options: .regularExpression) != nil
    }

    /// What a search looks for, from its command: `-e PATTERN` or its first word that isn't an
    /// option (nor an option's value), as a regular expression the way it reads it.
    static func pattern(in command: String) -> NSRegularExpression? {
        guard let start = command.range(of: #"(^|[\s|;&(])(rg|grep|egrep|fgrep|ag|git\s+grep)\s"#, options: .regularExpression) else { return nil }
        let words = shellWords(String(command[start.upperBound...]).prefix(while: { !"|;&)".contains($0) }))
        let takesValue: Set<String> = ["-g", "--glob", "-t", "--type", "-T", "--type-not", "-A", "-B", "-C", "-m", "--max-count", "-f", "--file", "--include", "--exclude", "-d", "--max-depth"]
        var found: String?
        var flags: Set<String> = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if word == "-e" || word == "--regexp", index + 1 < words.count { found = words[index + 1]; break }
            if word.hasPrefix("-") && word.count > 1 {
                flags.insert(word)
                if takesValue.contains(word) { index += 1 }
            } else if found == nil {
                found = word
                break
            }
            index += 1
        }
        guard let found, !found.isEmpty else { return nil }
        let fixed = flags.contains { $0 == "-F" || $0 == "--fixed-strings" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("F")) } || command.contains("fgrep")
        let caseless = flags.contains { $0 == "-i" || $0 == "--ignore-case" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("i")) }
            || (flags.contains { $0 == "-S" || $0 == "--smart-case" } && found == found.lowercased())
        let options: NSRegularExpression.Options = caseless ? [.caseInsensitive] : []
        if !fixed, let expression = try? NSRegularExpression(pattern: found, options: options) { return expression }
        return try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: found), options: options)
    }

    /// A command line's words, as a shell splits them: quotes kept together, backslashes taken.
    private static func shellWords(_ line: Substring) -> [String] {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var inWord = false
        var escaped = false
        for character in line {
            if escaped { word.append(character); escaped = false; continue }
            if character == "\\" && quote != "'" { escaped = true; inWord = true; continue }
            if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
                continue
            }
            if character == "'" || character == "\"" { quote = character; inWord = true; continue }
            if character.isWhitespace {
                if inWord { words.append(word); word = ""; inWord = false }
                continue
            }
            word.append(character)
            inWord = true
        }
        if inWord { words.append(word) }
        return words
    }
}
