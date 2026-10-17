import Foundation
import Testing
@testable import OpenCodeKit

/// Events that come after a read already has them (they came while it was made, or waited out a
/// reconnect), and events that never came.
struct TranscriptReplayTests {
    private static let session = "ses_ecb63eb0fffeLZyYgRmShX9IVf"

    /// A read made at any point, with the events since any point before it applied on top, ends as
    /// the events alone do: no message, block, tool call or turn's end twice.
    @Test func eventsAReadHasChangeNothingAgain() throws {
        let events = try Fixture.events()
        var all = Transcript(sessionID: Self.session)
        for event in events { all.apply(event) }

        for read in events.indices {
            // The engine's copy then: where blocks start and end, without the words streamed between.
            var engine = Transcript(sessionID: Self.session)
            for event in events[..<read] where !Transcript.isStreamed(event.type) { engine.apply(event) }
            let inbox = engine.pending.map {
                InboxItem(id: $0.id, sessionID: Self.session, type: "user", payload: .object(["text": .string($0.text)]), delivery: $0.delivery)
            }
            // From the start, half way, and just before (every point takes long, and passes too).
            for since in Set([0, read / 2, max(read - 2, 0), read]).sorted() {
                var transcript = Transcript(sessionID: Self.session)
                transcript.load(messages: engine.messages, inbox: inbox, permissions: engine.permissions, forms: engine.forms, isRunning: engine.isRunning)
                for event in events[since...] { transcript.apply(event) }
                let what = "read before event \(read), events from \(since)"
                #expect(transcript.messages == all.messages, "\(what)")
                #expect(transcript.pending == all.pending, "\(what)")
                #expect(transcript.forms == all.forms, "\(what)")
                #expect(transcript.isRunning == all.isRunning, "\(what)")
                #expect(!transcript.isStale, "\(what)")
            }
        }
    }

    /// Without the event that starts a block of words, thinking or a tool call, what comes after it
    /// finds nothing to change: the copy is stale, to be read again, instead of the block missing
    /// until then.
    @Test func aMissedStartMakesTheCopyStale() throws {
        let events = try Fixture.events()
        let starts = ["session.text.started", "session.reasoning.started", "session.tool.input.started"]
        for missed in events.indices where starts.contains(events[missed].type) {
            var transcript = Transcript(sessionID: Self.session)
            for (index, event) in events.enumerated() where index != missed {
                transcript.apply(event)
                if transcript.isStale { break }
            }
            #expect(transcript.isStale, "without \(events[missed].type) (event \(missed))")
        }
    }

    /// A step's words go to their own block: with the second one's start missed, its words don't
    /// replace the first's; read again, the events that come after the read change nothing twice.
    @Test func wordsGoToTheirOwnBlock() throws {
        func event(_ number: Int, _ type: String, _ fields: String) throws -> ServerEvent {
            try ServerEvent(json: Data(#"""
            {"id":"evt_\#(number)","created":\#(number),"type":"\#(type)","data":{"sessionID":"ses_1","assistantMessageID":"msg_1",\#(fields)}}
            """#.utf8))
        }
        func step(_ texts: [String]) -> [Message] {
            [.assistant(Message.Assistant(id: "msg_1", time: Message.Time(created: 1), agent: "build", model: ModelRef(id: "m", providerID: "p"),
                                          content: texts.map { .text(Message.Content.Text(text: $0)) }))]
        }
        func texts(_ transcript: Transcript) -> [String] {
            guard case .assistant(let step)? = transcript.messages.last else { return [] }
            return step.content.compactMap { if case .text(let block) = $0 { block.text } else { nil } }
        }
        let first = try [
            event(2, "session.text.started", #""ordinal":0"#),
            event(3, "session.text.delta", #""ordinal":0,"delta":"First""#),
            event(4, "session.text.ended", #""ordinal":0,"text":"First.""#),
        ]
        let second = try [
            event(5, "session.text.started", #""ordinal":1"#),
            event(6, "session.text.delta", #""ordinal":1,"delta":"Sec""#),
            event(7, "session.text.delta", #""ordinal":1,"delta":"ond""#),
            event(8, "session.text.ended", #""ordinal":1,"text":"Second.""#),
        ]

        var transcript = Transcript(sessionID: "ses_1")
        transcript.load(messages: step([]), inbox: [], permissions: [], forms: [], isRunning: true)
        for event in first + second.dropFirst() { transcript.apply(event) }
        #expect(texts(transcript) == ["First.", "Second."])
        #expect(transcript.isStale)

        // Read again (the engine had started the second block), then the events since the first
        // block started come too.
        transcript.load(messages: step(["First.", ""]), inbox: [], permissions: [], forms: [], isRunning: true)
        for event in first + second { transcript.apply(event) }
        #expect(texts(transcript) == ["First.", "Second."])
        #expect(!transcript.isStale)
    }
}
