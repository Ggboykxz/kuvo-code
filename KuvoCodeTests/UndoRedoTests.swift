import Foundation
import OpenCodeKit
import Testing
@testable import KuvoCode

/// Undo and Redo and the composer (B6): each undone message comes back to the composer, ahead of
/// what you'd written; Redo takes them out again while the composer is as the undo left it, and
/// never takes away what you typed meanwhile. The engine is stubbed.
@MainActor
@Suite(.serialized) struct UndoRedoTests {
    let engine = StubEngine(port: 47992)
    let workspace = Workspace()
    let id = "ses_undo_\(UUID().uuidString.prefix(8))"
    let older: [String: Any] = ["id": "msg_01", "type": "user", "time": ["created": 1], "text": "Add a settings page"]
    let newer: [String: Any] = ["id": "msg_03", "type": "user", "time": ["created": 3], "text": "Make it dark"]

    init() {
        workspace.api = engine.api
    }

    private func open() async throws -> SessionModel {
        engine.list([StubEngine.session(id, title: "Undo", directory: "/tmp/kuvo-tests-undo")])
        engine.on("GET", "/api/session/\(id)/message", json: ["data": [older, newer]])
        engine.on("POST", "/api/session/\(id)/revert/stage") { request in
            StubWeb.json(["data": ["messageID": request.body["messageID"] as? String ?? ""]])
        }
        engine.on("DELETE", "/api/session/\(id)/revert", json: [:])
        await workspace.refresh()
        return try #require(workspace.model(for: id))
    }

    private func user(_ json: [String: Any]) throws -> Message.User {
        guard case .user(let message) = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: json)) else {
            throw TestFailure("not a user message")
        }
        return message
    }

    private func done() {
        engine.stop()
        Drafts.shared.remove(id)
    }

    /// Undo to the last message, then further back to the one before: both come back to the
    /// composer, oldest first. Redo takes them both out, back to what you'd written.
    @Test func undoTwiceThenRedo() async throws {
        defer { done() }
        let model = try await open()
        model.draftText = "half a thought"
        model.undo(from: try user(newer))
        try await eventually { model.draftText.contains("Make it dark") }
        model.undo(from: try user(older))
        try await eventually { model.draftText.contains("Add a settings page") }
        #expect(model.draftText == "Add a settings page\n\nMake it dark\n\nhalf a thought")
        model.redo()
        try await eventually { model.session.revert == nil }
        #expect(model.draftText == "half a thought")
    }

    /// Text you typed after an undo is yours: Redo leaves the composer as it is.
    @Test func redoKeepsWhatYouTypedAfterTheUndo() async throws {
        defer { done() }
        let model = try await open()
        model.undo(from: try user(newer))
        try await eventually { model.draftText == "Make it dark" }
        model.draftText += ", with a toggle"
        model.redo()
        try await eventually { model.session.revert == nil }
        #expect(model.draftText == "Make it dark, with a toggle")
    }

    /// Typing between two undos, then Redo: what you typed stays (it used to go with the undone
    /// messages' text, back to the composer as it was before the first undo).
    @Test func redoKeepsWhatYouTypedBetweenTwoUndos() async throws {
        defer { done() }
        let model = try await open()
        model.draftText = "half a thought"
        model.undo(from: try user(newer))
        try await eventually { model.draftText.contains("Make it dark") }
        model.draftText += " about colors"
        model.undo(from: try user(older))
        try await eventually { model.draftText.contains("Add a settings page") }
        model.redo()
        try await eventually { model.session.revert == nil }
        #expect(model.draftText.contains("half a thought about colors"), "typed text was lost: \(model.draftText)")
        #expect(!model.draftText.contains("Add a settings page"), "the message Redo brought back shouldn't stay in the composer to be sent again")
    }
}
