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

/// A command you run yourself: it shows while it runs, then with what it printed. (The events as
/// engine 2.0.29 sends them.)
@Test func followsACommandYouRan() throws {
    func event(_ json: String) throws -> ServerEvent { try ServerEvent(json: Data(json.utf8)) }
    var transcript = Transcript(sessionID: "ses_1")
    transcript.apply(try event(#"""
    {"id":"evt_1","created":1,"type":"session.shell.started","data":{"sessionID":"ses_1","shell":{"id":"sh_1","status":"running","command":"uname -s","cwd":"/w","shell":"/bin/sh","file":"/f","metadata":{},"time":{"started":1},"pid":7}}}
    """#))
    guard case .shell(let running)? = transcript.messages.last else { Issue.record("no shell row"); return }
    #expect(running.command == "uname -s")
    #expect(running.isRunning)
    #expect(running.output == nil)

    transcript.apply(try event(#"""
    {"id":"evt_2","created":2,"type":"session.shell.ended","data":{"sessionID":"ses_1","shell":{"id":"sh_1","status":"exited","command":"uname -s","cwd":"/w","shell":"/bin/sh","file":"/f","metadata":{},"time":{"started":1,"completed":2},"pid":7,"exit":0},"output":{"output":"Linux\n","cursor":6,"size":6,"truncated":false}}}
    """#))
    guard case .shell(let ended)? = transcript.messages.last else { Issue.record("no shell row"); return }
    #expect(!ended.isRunning)
    #expect(ended.exit == 0)
    #expect(ended.output?.output == "Linux\n")
    #expect(transcript.messages.count == 1)

    // Read back from the session's messages, it has its output too.
    let stored = try JSONDecoder().decode(Message.self, from: Data(#"""
    {"id":"msg_1","metadata":{"background":true},"time":{"created":1,"completed":2},"type":"shell","shellID":"sh_1","command":"uname -s","status":"exited","exit":0,"output":{"output":"Linux\n","cursor":6,"size":6,"truncated":false}}
    """#.utf8))
    guard case .shell(let message) = stored else { Issue.record("not a shell message"); return }
    #expect(message.output?.output == "Linux\n")
}
