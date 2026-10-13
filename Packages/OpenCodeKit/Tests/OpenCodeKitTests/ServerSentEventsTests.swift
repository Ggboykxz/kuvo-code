import Testing
@testable import OpenCodeKit

struct ServerSentEventsTests {
    private func parse(_ text: String) -> [ServerSentEvent] {
        var parser = ServerSentEventParser()
        return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { parser.feed(line: $0) }
    }

    @Test func joinsDataLinesAndDispatchesOnBlankLine() {
        let events = parse("event: message\nid: 7\ndata: {\"a\":\ndata: 1}\n\n")
        #expect(events == [ServerSentEvent(id: "7", event: "message", data: "{\"a\":\n1}")])
    }

    @Test func ignoresCommentsAndEventsWithoutData() {
        let events = parse(": heartbeat\n\nevent: ping\n\ndata: x\n\n")
        #expect(events == [ServerSentEvent(data: "x")])
    }

    @Test func keepsLastEventIDAcrossEvents() {
        let events = parse("id: 1\ndata: a\n\ndata: b\n\n")
        #expect(events.map(\.id) == ["1", "1"])
    }

    @Test func stripsOnlyOneLeadingSpace() {
        #expect(parse("data:  two\n\n").first?.data == " two")
        #expect(parse("data:none\n\n").first?.data == "none")
    }
}
