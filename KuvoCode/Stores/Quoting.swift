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

    /// The message to send: the quote you're replying to, as Markdown, ahead of your words.
    static func message(quote: String?, text: String) -> String {
        guard let quote, !quote.isEmpty else { return text }
        let block = quote.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
        return block + "\n\n" + text
    }

    /// The message to send: each quote you're replying to, as Markdown, with your answer to it
    /// under it, then the rest of your words.
    static func message(quotes: [Drafts.Quote], text: String) -> String {
        let parts = quotes.flatMap { quote in
            [message(quote: quote.text, text: ""), quote.response.trimmingCharacters(in: .whitespacesAndNewlines)]
        } + [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// A message as what it quotes and what it says: each run of lines starting with ">" with the
    /// words after it, in order (the first part's quote is nil when it starts with words).
    static func segments(_ message: String) -> [(quote: String?, text: String)] {
        var segments: [(quote: String?, text: String)] = []
        var quote: [String] = []
        var words: [String] = []
        func close() {
            let text = words.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let quoted = quote.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !quoted.isEmpty || !text.isEmpty { segments.append((quoted.isEmpty ? nil : quoted, text)) }
            quote = []
            words = []
        }
        for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(">") {
                // A new quote after words: the part before is done.
                if !words.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { close() }
                var content = line.dropFirst()
                if content.first == " " { content = content.dropFirst() }
                quote.append(String(content))
            } else {
                words.append(String(line))
            }
        }
        close()
        return segments.isEmpty ? [(nil, message)] : segments
    }

    /// A message's own words, without what it quotes.
    static func words(of message: String) -> String {
        segments(message).map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
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
