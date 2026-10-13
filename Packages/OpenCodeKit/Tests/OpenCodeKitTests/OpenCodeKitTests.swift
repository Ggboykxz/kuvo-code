import Foundation
import Testing
@testable import OpenCodeKit

@Test func pinsAnEngineVersion() {
    #expect(!OpenCodeEngine.version.isEmpty)
}

/// The engine says "default" for a session with no effort chosen; it's not a level to send back.
@Test func readsTheDefaultEffortAsNone() throws {
    let reported = try JSONDecoder().decode(ModelRef.self, from: Data(#"{"id":"gpt-6-luna","providerID":"github-copilot","variant":"default"}"#.utf8))
    #expect(reported.variant == nil)
    let encoded = String(decoding: try JSONEncoder().encode(reported), as: UTF8.self)
    #expect(!encoded.contains("variant"))
    #expect(ModelRef(id: "m", providerID: "p", variant: "default").variant == nil)
    #expect(ModelRef(id: "m", providerID: "p", variant: "low").variant == "low")
}

/// Attachments keep their contents and where they came from, so the transcript can show them.
@Test func decodesUserAttachments() throws {
    let json = #"""
    {"id":"msg_1","time":{"created":1},"text":"look","files":[
      {"data":"aGk=","mime":"image/png","name":"shot.png","source":{"type":"inline"}},
      {"data":"aGk=","mime":"text/plain","name":"notes.md","source":{"type":"uri","uri":"file:///Users/me/notes.md"}}
    ]}
    """#
    let user = try JSONDecoder().decode(Message.User.self, from: Data(json.utf8))
    #expect(user.files?.count == 2)
    #expect(user.files?[0].source == .inline)
    #expect(user.files?[0].bytes == Data("hi".utf8))
    #expect(user.files?[1].fileURL?.path == "/Users/me/notes.md")
}
