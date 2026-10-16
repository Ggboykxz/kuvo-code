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

    /// `text` as a Markdown quote, ahead of what you'd written (`draft`), with room under it.
    static func quoted(_ text: String, into draft: String) -> String {
        let quote = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
        let rest = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? quote + "\n\n" : rest + "\n\n" + quote + "\n\n"
    }
}
