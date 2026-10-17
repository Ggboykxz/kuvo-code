import Foundation

/// A block the app adds to the end of a message for the agent (the review comments, the note of
/// attached files): its tag on a line of its own, its heading, what's in it, then its closing
/// tag, with nothing after. Only a block like that is read back, so a message can name the tags,
/// or quote one, and keep its words.
nonisolated struct MessageBlock: Sendable {
    let start: String
    let end: String
    /// What its first line can be.
    let headings: Set<String>

    /// The block that ends `text`: the words before it, and its lines from its heading on.
    func split(_ text: String) -> (before: Substring, lines: [Substring])? {
        guard let found = find(in: text) else { return nil }
        return (text[..<found.open.lowerBound], found.lines)
    }

    /// `text` as it can't be read as ending with a block (one copied from a message, say): its
    /// tag gets a space after it.
    func escaping(_ text: String) -> String {
        var text = text
        while let found = find(in: text) { text.insert(" ", at: text.index(found.open.lowerBound, offsetBy: start.count)) }
        return text
    }

    private func find(in text: String) -> (open: Range<String.Index>, lines: [Substring])? {
        let body = text[..<(text.lastIndex { !$0.isWhitespace && !$0.isNewline }.map(text.index(after:)) ?? text.startIndex)]
        guard body.hasSuffix("\n" + end) else { return nil }
        let close = body.index(body.endIndex, offsetBy: -end.count)
        var before = close
        // The last tag with its heading after it: one in what's before the block is the message's.
        while let open = text.range(of: start + "\n", options: .backwards, range: text.startIndex..<before) {
            before = open.lowerBound
            guard open.lowerBound == text.startIndex || text[text.index(before: open.lowerBound)] == "\n" else { continue }
            let lines = text[open.upperBound..<close].split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            guard let first = lines.first, headings.contains(String(first)) else { continue }
            return (open, Array(lines))
        }
        return nil
    }
}
