import Foundation
import Testing
@testable import KuvoCode

/// Replying to parts of a message: each part quoted, with your answer under it, sent as Markdown,
/// and back as the same quotes and answers when the message returns to the composer (an undo, a
/// send that didn't go). A quote-looking line in code, or ">>>", is words.
@Suite struct QuotingTests {
    @Test func quotesAndAnswersComeBackAsTheyWere() {
        let quotes = [Drafts.Quote(text: "Use Postgres for the queue?", response: "Yes, with SKIP LOCKED."),
                      Drafts.Quote(text: "Line one\n\nLine three", response: "Both fine.")]
        let message = Quoting.message(quotes: quotes, text: "")
        #expect(message == "> Use Postgres for the queue?\n\nYes, with SKIP LOCKED.\n\n> Line one\n>\n> Line three\n\nBoth fine.")
        let back = Quoting.draft(of: message)
        #expect(back.quotes.map(\.text) == quotes.map(\.text))
        #expect(back.quotes.map(\.response) == quotes.map(\.response))
        #expect(back.text == "")
    }

    /// Words before the first quote are the message's own; a message with no quote is all words.
    @Test func wordsBeforeAQuote() {
        let back = Quoting.draft(of: "Two things:\n\n> the cache\n\nDrop it.")
        #expect(back.text == "Two things:")
        #expect(back.quotes.map(\.text) == ["the cache"])
        #expect(back.quotes.map(\.response) == ["Drop it."])
        #expect(Quoting.draft(of: "Just a question").text == "Just a question")
    }

    /// What only looks like a quote is words: in a code block, ">>>", or a ">" inside a line.
    @Test(arguments: ["```\n> not a quote\n```", ">>> python prompt", "a > b and c", "text\n> right after words"])
    func whatOnlyLooksLikeAQuote(message: String) {
        let back = Quoting.draft(of: message)
        #expect(back.quotes.isEmpty)
        #expect(Quoting.words(of: message) == message)
    }

    /// The words a title or a preview takes: without the quotes.
    @Test func theMessagesOwnWords() {
        #expect(Quoting.words(of: "> long quoted text\n\nMy answer") == "My answer")
    }
}
