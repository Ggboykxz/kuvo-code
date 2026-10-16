import AppKit

/// Replying to a message, or a part of one: what you selected (else the whole message) goes into
/// the composer as a quote, for you to answer under.
enum Quoting {
    /// The text selected in the window, copied as ⌘C would, with your clipboard put back as it
    /// was; nil when nothing's selected.
    static func selection() -> String? {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        let before = board.changeCount
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        guard board.changeCount != before else { return nil }
        let text = board.string(forType: .string)
        board.clearContents()
        if !saved.isEmpty { board.writeObjects(saved) }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What's selected, when it's part of `message` (not something selected elsewhere: in the
    /// panel's terminal, say, or another message).
    static func selection(in message: String) -> String? {
        guard let selected = selection() else { return nil }
        return plain(message).contains(plain(selected)) ? selected : nil
    }

    /// Text as it reads, for comparing what's shown with its Markdown: without the marks, its
    /// spaces and line breaks as single spaces.
    private static func plain(_ text: String) -> String {
        text.filter { !"*_`#>[]".contains($0) }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The message to send: the quote you're replying to, as Markdown, ahead of your words.
    static func message(quote: String?, text: String) -> String {
        guard let quote, !quote.isEmpty else { return text }
        let block = quote.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
        return block + "\n\n" + text
    }

    /// A message's quote (the lines starting with ">" that it opens with) and the rest.
    static func split(_ message: String) -> (quote: String?, text: String) {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        let quoted = lines.prefix { $0.hasPrefix(">") }
        guard !quoted.isEmpty, quoted.count < lines.count || !message.isEmpty else { return (nil, message) }
        let quote = quoted.map { line in
            var line = line.dropFirst()
            if line.first == " " { line = line.dropFirst() }
            return String(line)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = lines.dropFirst(quoted.count).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return quote.isEmpty ? (nil, message) : (quote, rest)
    }
}
