import Foundation
import OpenCodeKit
import Testing
@testable import KuvoCode

/// A session's wake-ups follow the conversation: they move with it when it carries on with the
/// coding agents, and one made while it's archived waits, as those it had when archived do. The
/// engine and the agents' bridge are stubbed; the wake-ups' folders and kuvo-wake are real.
@MainActor
@Suite(.serialized) struct WakeUpsTests {
    static let engine = "http://127.0.0.1:47996"
    static let bridge = "http://127.0.0.1:47995"
    let app = AppModel()
    let id = "ses_wakeful"

    private static func session(_ id: String, archived: Bool = false, agent: Bool = false) -> [String: Any] {
        var metadata: [String: Any] = [:]
        if archived { metadata["kuvo.archived"] = true }
        if agent { metadata["kuvoAgent"] = "claude-code" }
        return [
            "id": id, "projectID": "p", "cost": 0, "title": "Nightly checks",
            "tokens": ["input": 0, "output": 0, "reasoning": 0, "cache": ["read": 0, "write": 0]],
            "time": ["created": 1, "updated": 2], "location": ["directory": "/tmp/kuvo-tests-project"],
            "model": ["id": "luna", "providerID": "openai"], "agent": "build", "metadata": metadata,
        ]
    }

    private func start(archived: Bool = false) async {
        TestEnvironment.prepare()
        try? FileManager.default.removeItem(at: WakeUps.root)
        StubWeb.start(hosts: ["127.0.0.1"])
        let listed = StubWeb.json(["data": [Self.session(id, archived: archived)]])
        StubWeb.route(Self.engine + "/api/session") { _ in listed }
        StubWeb.route(Self.engine + "/api/session/active") { _ in StubWeb.json(["data": [:]]) }
        let one = StubWeb.json(["data": Self.session(id, archived: archived)])
        StubWeb.route(Self.engine + "/api/session/\(id)") { _ in one }
        StubWeb.route(Self.engine + "/api/session/\(id)/message") { _ in StubWeb.json(["data": []]) }
        StubWeb.route(Self.engine + "/api/session/\(id)/inbox") { _ in StubWeb.json(["data": []]) }
        app.wakeUps.app = app
        app.workspace.api = OpenCodeAPI(endpoint: ServerEndpoint(url: URL(string: Self.engine)!, password: "test"))
        await app.workspace.refresh()
    }

    private func done() {
        StubWeb.stop()
        app.workspace.agents?.disconnect()
        try? FileManager.default.removeItem(at: WakeUps.root)
    }

    private func folder(_ session: String, _ parts: String...) -> String {
        parts.reduce(WakeUps.root.appending(path: session)) { $0.appending(path: $1) }.path
    }

    /// A session with a wake-up for tomorrow moves to Claude Code: the wake-up is the new
    /// session's, waiting, not left behind with the old one in Archived.
    @Test func wakeUpsMoveWithTheConversation() async throws {
        await start()
        defer { done() }
        let moved = "ses_onagents"
        let imported = StubWeb.json(["data": Self.session(moved, agent: true)])
        StubWeb.route(Self.bridge + "/api/session/import") { _ in imported }
        let agents = OutsideAgents()
        agents.connect(ServerEndpoint(url: URL(string: Self.bridge)!, password: "test"), folderPrefix: "")
        app.workspace.agents = agents

        let owner = WakeUps.owner(of: try #require(app.workspace.session(id)))
        try await app.wakeUps.add(to: owner, at: .now.addingTimeInterval(86_400), every: nil, note: "Check the nightly build")
        let wake = try #require(FileManager.default.contentsOfDirectory(atPath: folder(id, "wakes")).first)

        try await app.workspace.moveToAgents(id, model: ModelRef(id: "sonnet", providerID: "claude-code"))

        #expect(FileManager.default.fileExists(atPath: folder(moved, "wakes", wake)))
        #expect(try String(contentsOfFile: folder(moved, "session"), encoding: .utf8) == moved)
        #expect(try String(contentsOfFile: folder(moved, "via"), encoding: .utf8) == "bridge")
        #expect(!FileManager.default.fileExists(atPath: folder(moved, "paused")))
        #expect(!FileManager.default.fileExists(atPath: folder(id)))
    }

    /// An archived session's agent schedules a wake-up (it was still working): it waits with the
    /// session, and comes when you bring the session back.
    @Test func aWakeUpMadeWhileArchivedWaits() async throws {
        await start(archived: true)
        defer { done() }
        let made = await app.wakeUps.call("schedule_wake_up", arguments: ["when": "+2h", "note": "Look again"], caller: id)
        #expect(!made.isError, "\(made.text)")
        #expect(FileManager.default.fileExists(atPath: folder(id, "paused")))
        #expect(app.wakeUps.paused.contains(id))
        #expect(app.wakeUps.wakes[id]?.count == 1)

        await app.wakeUps.archived(try #require(app.workspace.session(id)), false)
        #expect(!FileManager.default.fileExists(atPath: folder(id, "paused")))
        #expect(!app.wakeUps.paused.contains(id))
    }
}
