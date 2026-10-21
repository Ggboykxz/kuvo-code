import Foundation
import OpenCodeKit
import Testing
@testable import KuvoCode

/// What goes back to the composer: a message the engine didn't take (with its comments, ahead of
/// what you wrote meanwhile, and why it didn't go), and one you undo, which Redo takes back out.
/// The engine is stubbed.
@MainActor
@Suite(.serialized) struct ComposerReturnsTests {
    static let engine = "http://127.0.0.1:47994"
    let workspace = Workspace()
    let id = "ses_composer_\(UUID().uuidString.prefix(8))"

    init() async {
        TestEnvironment.prepare()
        StubWeb.start(hosts: ["127.0.0.1"])
        let session: [String: Any] = [
            "id": id, "projectID": "p", "cost": 0, "title": "Composer",
            "tokens": ["input": 0, "output": 0, "reasoning": 0, "cache": ["read": 0, "write": 0]],
            "time": ["created": 1, "updated": 2], "location": ["directory": "/tmp/kuvo-tests-composer"],
        ]
        let listed = StubWeb.json(["data": [session]])
        StubWeb.route(Self.engine + "/api/session") { _ in listed }
        StubWeb.route(Self.engine + "/api/session/active") { _ in StubWeb.json(["data": [:]]) }
        workspace.api = OpenCodeAPI(endpoint: ServerEndpoint(url: URL(string: Self.engine)!, password: "test"))
        await workspace.refresh()
    }

    private func done() {
        StubWeb.stop()
        Drafts.shared.remove(id)
    }

    /// Until `condition` holds (the work goes on off the main thread), a few seconds at most.
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aMessageTheEngineDidntTakeComesBackWhole() async throws {
        defer { done() }
        StubWeb.handle(Self.engine + "/api/session/\(id)/prompt") { _, _ in StubWeb.json(["message": "Model is overloaded"], status: 400) }
        let model = try #require(workspace.model(for: id))
        model.reviewComments = [ReviewComment(file: "a.swift", line: 2, side: .new, snippet: "x", text: "Rename x")]
        model.send("Fix the build", for: nil)
        #expect(model.draftText.isEmpty)
        model.draftText = "and the tests"
        try await until { model.failure != nil }
        #expect(model.draftText == "Fix the build\n\nand the tests")
        #expect(model.reviewComments.map(\.text) == ["Rename x"])
        #expect(model.failure != nil)
    }

    @Test func undoPutsItBackAndRedoTakesItOut() async throws {
        defer { done() }
        let sent: [String: Any] = ["id": "msg_sent", "type": "user", "time": ["created": 1], "text": "Refactor the parser"]
        let page = StubWeb.json(["data": [sent]])
        StubWeb.route(Self.engine + "/api/session/\(id)/message") { _ in page }
        StubWeb.handle(Self.engine + "/api/session/\(id)/revert") { request, _ in
            request.httpMethod == "DELETE" ? StubWeb.json([:]) : StubWeb.json(["data": ["messageID": "msg_sent"]])
        }
        let model = try #require(workspace.model(for: id))
        model.draftText = "half a thought"
        guard case .user(let message) = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: sent)) else { return }
        model.undo(from: message)
        try await until { model.draftText.contains("Refactor") }
        #expect(model.draftText == "Refactor the parser\n\nhalf a thought")
        #expect(model.session.revert?.messageID == "msg_sent")
        model.redo()
        try await until { model.session.revert == nil }
        #expect(model.draftText == "half a thought")
    }

    /// Sent while the agent works, with Queue: it waits its turn. With nothing running: now.
    @Test func whileItWorksAMessageWaitsItsTurn() async throws {
        defer { done() }
        let bodies = Bodies()
        StubWeb.handle(Self.engine + "/api/session/\(id)/prompt") { _, body in
            bodies.add((try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["delivery"] as? String ?? "")
            return StubWeb.json(["data": ["id": "x"]])
        }
        let model = try #require(workspace.model(for: id))
        model.send("first", for: nil, queue: true)
        try await until { bodies.all.count == 1 }
        #expect(bodies.all == ["steer"])
        let started = try ServerEvent(json: JSONSerialization.data(withJSONObject: ["id": "e1", "type": "session.execution.started", "created": 1, "data": ["sessionID": id]]))
        workspace.handle(started)
        model.send("second", for: nil, queue: true)
        try await until { bodies.all.count == 2 }
        #expect(bodies.all.last == "queue")
    }

    nonisolated final class Bodies: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ delivery: String) { lock.withLock { list.append(delivery) } }
        var all: [String] { lock.withLock { list } }
    }
}
