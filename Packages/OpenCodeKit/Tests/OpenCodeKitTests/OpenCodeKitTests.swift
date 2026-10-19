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

/// Sending a message after an undo makes the undo final: the undone part goes, and the message just
/// sent stays, though it's newer than where the conversation was taken back to. (The events in
/// the order engine 2.0.29 sends them.)
@Test func keepsTheMessageThatMakesAnUndoFinal() throws {
    func event(_ json: String) throws -> ServerEvent { try ServerEvent(json: Data(json.utf8)) }
    var transcript = Transcript(sessionID: "ses_1")
    transcript.load(messages: [
        .user(Message.User(id: "msg_1", time: Message.Time(created: 1), text: "first")),
        .user(Message.User(id: "msg_2", time: Message.Time(created: 2), text: "undone")),
    ], inbox: [], permissions: [], forms: [], isRunning: false)
    transcript.addLocal(id: "msg_3", text: "again", delivery: .steer)

    transcript.apply(try event(#"""
    {"id":"evt_1","created":3,"type":"session.revert.committed","data":{"sessionID":"ses_1","to":"msg_2"}}
    """#))
    #expect(transcript.messages.map(\.id) == ["msg_1"])
    #expect(transcript.pending.map(\.id) == ["msg_3"])

    transcript.apply(try event(#"""
    {"id":"evt_2","created":4,"type":"session.inbox.enqueued","data":{"sessionID":"ses_1","inboxID":"msg_3","item":{"type":"user","payload":{"text":"again"},"delivery":"steer"}}}
    """#))
    transcript.apply(try event(#"""
    {"id":"evt_3","created":5,"type":"session.inbox.delivered","data":{"sessionID":"ses_1","inboxID":"msg_3"}}
    """#))
    #expect(transcript.messages.map(\.id) == ["msg_1", "msg_3"])
    #expect(transcript.pending.isEmpty)
}

/// Read while it worked, a run can look stopped (the engine didn't say it was active); the next step
/// it starts shows it at work again, so its thinking isn't folded away as if done.
@Test func aStepStartingMeansItsRunning() throws {
    func event(_ json: String) throws -> ServerEvent { try ServerEvent(json: Data(json.utf8)) }
    var transcript = Transcript(sessionID: "ses_1")
    transcript.load(messages: [], inbox: [], permissions: [], forms: [], isRunning: false)
    transcript.apply(try event(#"""
    {"id":"evt_1","created":1,"type":"session.step.started","data":{"sessionID":"ses_1","assistantMessageID":"msg_2","agent":"build","model":{"providerID":"opencode","id":"glm"}}}
    """#))
    #expect(transcript.isRunning)
}

/// A message you send keeps the files you attached once the engine takes it: the event that
/// delivers it names only the message, and they used to vanish until the session was reloaded.
@Test func keepsAMessagesFilesWhenItsDelivered() throws {
    func event(_ json: String) throws -> ServerEvent { try ServerEvent(json: Data(json.utf8)) }
    var transcript = Transcript(sessionID: "ses_1")
    transcript.load(messages: [], inbox: [], permissions: [], forms: [], isRunning: false)
    let report = URL(filePath: "/Users/me/Desktop/research/Report.md")
    transcript.addLocal(id: "msg_1", text: "Read my reports", delivery: .steer, files: [report])
    transcript.apply(try event(#"""
    {"id":"evt_1","created":1,"type":"session.inbox.enqueued","data":{"sessionID":"ses_1","inboxID":"msg_1","item":{"type":"user","payload":{"text":"Read my reports","files":[{"uri":"file:///Users/me/Desktop/research/Report.md","name":"Report.md"}]},"delivery":"steer"}}}
    """#))
    transcript.apply(try event(#"""
    {"id":"evt_2","created":2,"type":"session.inbox.delivered","data":{"sessionID":"ses_1","inboxID":"msg_1"}}
    """#))
    guard case .user(let message) = transcript.messages.first else { Issue.record("no message"); return }
    #expect(message.files?.map(\.name) == ["Report.md"])
    #expect(message.files?.first?.fileURL == report)
    #expect(message.files?.first?.mime == "text/markdown")
}

/// A photo sent from a phone comes in the message itself, as a `data:` URL: it stays on the message,
/// with its type from the URL's header.
@Test func keepsAFileSentInTheMessageItself() throws {
    func event(_ json: String) throws -> ServerEvent { try ServerEvent(json: Data(json.utf8)) }
    var transcript = Transcript(sessionID: "ses_1")
    transcript.load(messages: [], inbox: [], permissions: [], forms: [], isRunning: false)
    transcript.apply(try event(#"""
    {"id":"evt_1","created":1,"type":"session.inbox.enqueued","data":{"sessionID":"ses_1","inboxID":"msg_1","item":{"type":"user","payload":{"text":"Look","files":[{"uri":"data:image/jpeg;base64,/9j/4AAQ","name":"IMG_0001.jpeg"}]},"delivery":"steer"}}}
    """#))
    transcript.apply(try event(#"""
    {"id":"evt_2","created":2,"type":"session.inbox.delivered","data":{"sessionID":"ses_1","inboxID":"msg_1"}}
    """#))
    guard case .user(let message) = transcript.messages.first else { Issue.record("no message"); return }
    #expect(message.files?.count == 1)
    #expect(message.files?.first?.mime == "image/jpeg")
    #expect(message.files?.first?.name == "IMG_0001.jpeg")
    // Its picture is there to show and open.
    #expect(message.files?.first?.bytes == Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]))
    // Not among the files a queued message shows or gives back to the composer.
    transcript.apply(try event(#"""
    {"id":"evt_3","created":3,"type":"session.inbox.enqueued","data":{"sessionID":"ses_1","inboxID":"msg_2","item":{"type":"user","payload":{"text":"Again","files":[{"uri":"data:image/png;base64,AAAA"}]},"delivery":"queue"}}}
    """#))
    #expect(transcript.pending.first?.files == [])
    #expect(transcript.pending.first?.inlineFiles.map(\.mime) == ["image/png"])

    // Sent from a phone, its local copy has the photo as a data: URL: the type comes from that,
    // and the name it was sent with stays.
    transcript.addLocal(id: "msg_3", text: "Photo", delivery: .steer, files: [URL(string: "data:image/heic;base64,AAAA")!])
    transcript.apply(try event(#"""
    {"id":"evt_4","created":4,"type":"session.inbox.enqueued","data":{"sessionID":"ses_1","inboxID":"msg_3","item":{"type":"user","payload":{"text":"Photo","files":[{"uri":"data:image/heic;base64,AAAA","name":"IMG_0002.heic"}]},"delivery":"steer"}}}
    """#))
    transcript.apply(try event(#"""
    {"id":"evt_5","created":5,"type":"session.inbox.delivered","data":{"sessionID":"ses_1","inboxID":"msg_3"}}
    """#))
    guard case .user(let photo) = transcript.messages.last else { Issue.record("no message"); return }
    #expect(photo.files?.map(\.mime) == ["image/heic"])
    #expect(photo.files?.first?.name == "IMG_0002.heic")
    #expect(photo.files?.first?.bytes == Data([0, 0, 0]))
}

/// A file that comes as a `data:` URL has its bytes from it, base64 or percent-encoded; a
/// malformed one has none.
@Test func decodesDataURLs() {
    func bytes(_ uri: String) -> Data? { Message.User.Attachment(mime: "image/png", source: .uri(uri)).bytes }
    #expect(bytes("data:image/png;base64,aGk=") == Data("hi".utf8))
    #expect(bytes("DATA:image/png;BASE64,aGk=") == Data("hi".utf8))
    #expect(bytes("data:text/plain;charset=utf-8;base64,aGk=") == Data("hi".utf8))
    #expect(bytes("data:;base64,aGk%3D") == Data("hi".utf8))
    #expect(bytes("data:,Hello%2C%20there") == Data("Hello, there".utf8))
    #expect(bytes("data:text/plain,%FF%00a") == Data([0xFF, 0x00, 0x61]))
    #expect(bytes("data:,") == Data())
    // Without `;` before it, "base64" is the type, and the payload is as it is.
    #expect(bytes("data:base64,aGk=") == Data("aGk=".utf8))

    #expect(bytes("data:image/png;base64") == nil)
    #expect(bytes("data:image/png;base64,!!!!") == nil)
    #expect(bytes("data:image/png;base64,aGk%") == nil)
    #expect(bytes("data:,100%") == nil)
    #expect(bytes("data:,%G0") == nil)
    #expect(bytes("file:///Users/me/a.png") == nil)
    #expect(bytes("https://example.com/a.png") == nil)

    // The engine's copy comes first; neither is taken for a file.
    let both = Message.User.Attachment(mime: "image/png", data: "aGk=", source: .uri("data:,other"))
    #expect(both.bytes == Data("hi".utf8))
    #expect(both.fileURL == nil)
    #expect(Message.User.Attachment(mime: "image/png", source: .uri("data:image/png;base64,aGk=")).size == 3)
    #expect(Message.User.Attachment(mime: "text/plain", source: .uri("data:,abc")).size == 3)
}

/// What an MCP server asks belongs to no session in the engine; it shows in the conversation whose
/// tool of that server is running, and goes once that tool is done.
@Test func takesAnMCPServersFormWhileItsToolRuns() throws {
    func event(_ json: String) throws -> ServerEvent { try ServerEvent(json: Data(json.utf8)) }
    func step(_ state: String) throws -> Message {
        try HTTPClient.decoder.decode(Message.self, from: Data(#"""
        {"type":"assistant","id":"msg_2","time":{"created":2},"agent":"build","model":{"providerID":"opencode","id":"glm"},
         "content":[{"type":"tool","id":"call_1","name":"apple-events_reminders_tasks","state":\#(state)}]}
        """#.utf8))
    }
    func form(_ id: String, server: String) -> String {
        #"{"id":"\#(id)","sessionID":"global","title":"\#(server) is requesting input","metadata":{"kind":"mcp-elicitation","server":"\#(server)","message":"Which list?"},"fields":[{"key":"list","type":"string"}]}"#
    }
    var transcript = Transcript(sessionID: "ses_1")
    transcript.load(messages: [try step(#"{"status":"running","input":{}}"#)], inbox: [], permissions: [], forms: [], isRunning: true)
    #expect(transcript.isWaiting(on: "apple-events"))

    transcript.apply(try event(#"{"id":"evt_1","created":3,"type":"form.created","data":{"form":\#(form("frm_1", server: "apple-events"))}}"#))
    transcript.apply(try event(#"{"id":"evt_2","created":4,"type":"form.created","data":{"form":\#(form("frm_2", server: "notion"))}}"#))
    #expect(transcript.forms.map(\.id) == ["frm_1"])
    #expect(transcript.forms.first?.server == "apple-events")
    #expect(transcript.forms.first?.message == "Which list?")

    // Read again once the tool is done: the form isn't this conversation's any more.
    let open = try HTTPClient.decoder.decode([FormRequest].self, from: Data("[\(form("frm_1", server: "apple-events"))]".utf8))
    transcript.load(messages: [try step(#"{"status":"completed","input":{},"content":[]}"#)], inbox: [], permissions: [], forms: open, isRunning: false)
    #expect(transcript.forms.isEmpty)
}
