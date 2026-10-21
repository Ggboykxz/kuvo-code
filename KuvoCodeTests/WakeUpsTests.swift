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

    /// The prompts the engine was sent for the session, each a wake-up's.
    nonisolated final class Prompts: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        func add(_ text: String) { lock.withLock { texts.append(text) } }
        var all: [String] { lock.withLock { texts } }
    }

    private func recordPrompts(holding gate: Gate? = nil) -> Prompts {
        let prompts = Prompts()
        StubWeb.handle(Self.engine + "/api/session/\(id)/prompt") { _, body in
            prompts.add((try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["text"] as? String ?? "")
            gate?.wait()
            return StubWeb.json([:])
        }
        return prompts
    }

    /// Wake Up Now, clicked again while the first is on its way (the folder's tools can take a
    /// while): the agent gets it once (L26). A one-off is then done; a repeating one comes back at
    /// its time.
    @Test(arguments: [false, true])
    func wakeUpNowSendsOnce(repeating: Bool) async throws {
        await start()
        defer { done() }
        let gate = Gate()
        defer { gate.open() }
        let prompts = recordPrompts(holding: gate)
        let owner = WakeUps.owner(of: try #require(app.workspace.session(id)))
        try await app.wakeUps.add(to: owner, at: .now.addingTimeInterval(86_400), every: repeating ? .days(1) : nil, note: "Check the nightly build")
        let wake = try #require(app.wakeUps.wakes[owner.key]?.first)

        let first = Task { try await app.wakeUps.wakeNow(wake, of: owner) }
        try await eventually { prompts.all.count == 1 }
        var secondDone = false
        let second = Task {
            defer { secondDone = true }
            try await app.wakeUps.wakeNow(wake, of: owner)
        }
        // The second click has done what it does: nothing, or sent it again.
        try await eventually { secondDone || prompts.all.count > 1 }
        gate.open()
        try await first.value
        try await second.value
        // And once more after it went: a one-off isn't there to send again.
        if !repeating { try await app.wakeUps.wakeNow(wake, of: owner) }

        #expect(prompts.all == [Wakes.marker + "Check the nightly build"], "sent \(prompts.all.count) times")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder(id, "wakes"))) ?? []
        #expect(left.count == (repeating ? 1 : 0))
    }

    /// Wake-ups you paused stay paused when the session is archived and brought back; ones paused
    /// only by archiving come back with it.
    @Test func aPauseYouSetOutlastsArchiving() async throws {
        await start()
        defer { done() }
        let session = try #require(app.workspace.session(id))
        let owner = WakeUps.owner(of: session)
        try await app.wakeUps.add(to: owner, at: .now.addingTimeInterval(86_400), every: nil, note: "Check the nightly build")
        try await app.wakeUps.setPaused(true, owner)

        await app.wakeUps.archived(session, true)
        await app.wakeUps.archived(session, false)
        #expect(app.wakeUps.paused.contains(id), "your pause should hold after the session comes back")
        #expect(FileManager.default.fileExists(atPath: folder(id, "paused")))

        try await app.wakeUps.setPaused(false, owner)
        await app.wakeUps.archived(session, true)
        #expect(app.wakeUps.paused.contains(id), "archived, its wake-ups wait")
        await app.wakeUps.archived(session, false)
        #expect(!app.wakeUps.paused.contains(id))
        #expect(!FileManager.default.fileExists(atPath: folder(id, "paused")))

        // Archived with an earlier Kuvo Code, whose hold said nothing: it comes back with it too.
        await app.wakeUps.archived(session, true)
        try Data().write(to: URL(filePath: folder(id, "paused")))
        await app.wakeUps.archived(session, false)
        #expect(!app.wakeUps.paused.contains(id), "archived before holds said whose they were: let go")
    }

    /// Archiving that the engine didn't take (it couldn't be reached): the session stays where it
    /// was, not archived, and nothing is told it was (which would hold its wake-ups). Taken, it is.
    @Test func anArchiveTheEngineDidntTakeHoldsNothing() async throws {
        await start()
        defer { done() }
        var told: [Bool] = []
        app.workspace.onArchived = { _, isArchived in told.append(isArchived) }
        let answer = StubWeb.json(["data": Self.session(id)])
        StubWeb.route(Self.engine + "/api/session/\(id)") { _ in StubWeb.json(["message": "Session is busy"], status: 500) }

        await app.workspace.setArchived(id, true)
        #expect(!Workspace.isArchived(try #require(app.workspace.session(id))), "the engine didn't archive it")
        #expect(told.isEmpty, "a session that wasn't archived holds nothing")

        StubWeb.route(Self.engine + "/api/session/\(id)") { _ in answer }
        await app.workspace.setArchived(id, true)
        #expect(Workspace.isArchived(try #require(app.workspace.session(id))))
        #expect(told == [true])
    }

    /// Wake-ups that came due while Kuvo Code was closed (L19): each goes once as it opens, a daily
    /// one once however many days it missed, then waits for its next time; a one-off is done.
    @Test func wakeUpsMissedWhileClosedGoOnceAsItOpens() async throws {
        await start()
        defer { done() }
        let prompts = recordPrompts()
        let owner = WakeUps.owner(of: try #require(app.workspace.session(id)))
        let wakes = folder(id, "wakes")
        try FileManager.default.createDirectory(atPath: wakes, withIntermediateDirectories: true)
        try Data(id.utf8).write(to: URL(filePath: folder(id, "session")))
        try Data(owner.directory.utf8).write(to: URL(filePath: folder(id, "directory")))
        let daily = Wakes.name(due: .now.addingTimeInterval(-3 * 86_400), every: .days(1))
        let once = Wakes.name(due: .now.addingTimeInterval(-3600), every: nil)
        try Data("Check the nightly build".utf8).write(to: URL(filePath: wakes + "/" + daily))
        try Data("Stand up and stretch".utf8).write(to: URL(filePath: wakes + "/" + once))

        app.wakeUps.start()
        try await eventually { prompts.all.count >= 2 && ((try? FileManager.default.contentsOfDirectory(atPath: wakes))?.count ?? 0) == 1 }
        #expect(prompts.all.sorted() == [Wakes.marker + "Check the nightly build", Wakes.marker + "Stand up and stretch"])
        let left = try FileManager.default.contentsOfDirectory(atPath: wakes)
        #expect(left.count == 1, "the one-off is done: \(left)")
        let next = try #require(left.first.flatMap { Wakes.Pending(id: $0, note: "") })
        #expect(next.due > .now && next.due < .now.addingTimeInterval(86_400 + 60), "the daily one waits for its next time")
    }
}
