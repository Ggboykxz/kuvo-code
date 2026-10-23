import Foundation
import OpenCodeKit
import Testing
@testable import KuvoCode

/// What a permission card shows (B10): a command the agent wants to run as the one line it wrote,
/// pipes and && included, though the engine asks about each command in it on its own. The engine
/// is stubbed.
@MainActor
@Suite(.serialized) struct PermissionCardsTests {
    let engine = StubEngine(port: 47988)
    let workspace = Workspace()
    let id = "ses_permission"

    init() {
        workspace.api = engine.api
    }

    private func open(_ conversation: [[String: Any]]) async throws -> SessionModel {
        engine.list([StubEngine.session(id, title: "Permissions", directory: "/tmp/kuvo-tests-permissions")], running: [id])
        engine.conversation(id, conversation)
        await workspace.refresh()
        let model = try #require(workspace.model(for: id))
        await model.load()
        return model
    }

    private let ask: [String: Any] = [
        "id": "per_1", "sessionID": "ses_permission", "action": "shell", "resources": ["npm test", "tail -5"],
        "source": ["type": "tool", "messageID": "msg_step", "id": "call_1"],
    ]

    @Test func aPipedCommandIsAskedAsOneLine() async throws {
        defer { engine.stop() }
        let model = try await open([
            ["id": "msg_you", "type": "user", "time": ["created": 1], "text": "Run the tests"],
            ["id": "msg_step", "type": "assistant", "agent": "build", "time": ["created": 2], "model": ["id": "m", "providerID": "p"],
             "content": [["type": "tool", "id": "call_1", "name": "shell", "executed": true,
                          "state": ["status": "running", "input": ["command": "npm test | tail -5"]]]]],
        ])
        workspace.handle(try engine.event("permission.asked", ask))
        #expect(model.permissions.map(\.id) == ["per_1"])
        #expect(model.permissionCommands["per_1"] == "npm test | tail -5")
    }

    /// The ask can come before the step's own word of the command reaches the app (a step read
    /// again, events in another order): the card shows the whole line once it does.
    @Test func theLineShowsOnceTheStepHasIt() async throws {
        defer { engine.stop() }
        let model = try await open([
            ["id": "msg_you", "type": "user", "time": ["created": 1], "text": "Run the tests"],
            ["id": "msg_step", "type": "assistant", "agent": "build", "time": ["created": 2], "model": ["id": "m", "providerID": "p"], "content": []],
        ])
        workspace.handle(try engine.event("permission.asked", ask))
        workspace.handle(try engine.event("session.tool.input.started", session: id, ["assistantMessageID": "msg_step", "id": "call_1", "name": "shell"]))
        workspace.handle(try engine.event("session.tool.called", session: id, ["assistantMessageID": "msg_step", "id": "call_1", "input": ["command": "npm test | tail -5"]]))
        #expect(model.permissionCommands["per_1"] == "npm test | tail -5")
    }
}
