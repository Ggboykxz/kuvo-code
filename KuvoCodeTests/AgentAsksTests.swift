import Foundation
import OpenCodeKit
import Testing
@testable import KuvoCode

/// What the agent asks of you, and what it's told: its questions shown in their conversation and
/// answered there (B11); two sessions at work at once, each with its own asks, both counted on the
/// Dock until answered (B13); Plan mode's answer carried out with Build It (B9). The engine is
/// stubbed.
@MainActor
@Suite(.serialized) struct AgentAsksTests {
    let engine = StubEngine(port: 47982)
    let workspace = Workspace()
    let project = "/tmp/kuvo-tests-asks"

    init() {
        workspace.api = engine.api
    }

    private func start(_ ids: [String]) async {
        engine.list(ids.enumerated().map { StubEngine.session($1, title: $1, directory: project, created: Double(10 - $0)) }, running: Set(ids))
        for id in ids { engine.conversation(id, []) }
        engine.on("POST", "/api/session/*", json: [:])
        engine.on("DELETE", "/api/session/*", json: [:])
        await workspace.refresh()
    }

    private let question: [String: Any] = [
        "id": "frm_db", "sessionID": "ses_a", "title": "Questions", "metadata": ["kind": "question"],
        "fields": [["key": "q0", "title": "Database", "description": "Which database should I use?", "type": "string",
                    "options": [["value": "SQLite", "label": "SQLite"], ["value": "Postgres", "label": "Postgres"]], "custom": true]],
    ]

    /// Asked a question: it shows in its conversation; your answer goes to the engine as given,
    /// and the question goes once the engine has it.
    @Test func aQuestionAnsweredInItsCard() async throws {
        defer { engine.stop() }
        await start(["ses_a"])
        let model = try #require(workspace.model(for: "ses_a"))
        workspace.handle(try engine.event("form.created", session: "ses_a", ["form": question]))
        #expect(model.forms.map(\.id) == ["frm_db"])
        #expect(workspace.waitingCount == 1, "waiting on you, on the Dock")

        model.answer(try #require(model.forms.first), with: ["q0": .string("SQLite")])
        try await eventually { !engine.requests("POST", "/form/frm_db/reply").isEmpty }
        #expect(engine.requests("POST", "/api/session/ses_a/form/frm_db/reply").first?.body["answer"] as? [String: String] == ["q0": "SQLite"])
        workspace.handle(try engine.event("form.replied", session: "ses_a", ["id": "frm_db", "sessionID": "ses_a"]))
        #expect(model.forms.isEmpty)
        #expect(workspace.waitingCount == 0)
    }

    /// Two sessions at work at once, each asking: each conversation shows only its own, the Dock
    /// counts both, and answering one leaves the other waiting.
    @Test func twoSessionsEachWithItsOwnAsks() async throws {
        defer { engine.stop() }
        await start(["ses_a", "ses_b"])
        let a = try #require(workspace.model(for: "ses_a"))
        let b = try #require(workspace.model(for: "ses_b"))
        workspace.handle(try engine.event("permission.asked", ["id": "per_a", "sessionID": "ses_a", "action": "shell", "resources": ["npm test"]]))
        workspace.handle(try engine.event("permission.asked", ["id": "per_b", "sessionID": "ses_b", "action": "edit", "resources": ["README.md"]]))
        #expect(a.permissions.map(\.id) == ["per_a"])
        #expect(b.permissions.map(\.id) == ["per_b"])
        #expect(workspace.waitingCount == 2)
        #expect(workspace.needsAttention("ses_a") && workspace.needsAttention("ses_b"))

        workspace.answer("per_a", in: "ses_a", with: .once)
        try await eventually { !engine.requests("POST", "/api/session/ses_a/permission/per_a/reply").isEmpty }
        workspace.handle(try engine.event("permission.replied", ["sessionID": "ses_a", "requestID": "per_a"]))
        #expect(a.permissions.isEmpty)
        #expect(b.permissions.map(\.id) == ["per_b"])
        #expect(workspace.waitingCount == 1)
        #expect(!workspace.needsAttention("ses_a") && workspace.needsAttention("ses_b"))
    }

    /// Plan mode's answer, then Build It: the session switches to Build and is told to carry the
    /// plan out.
    @Test func buildItCarriesThePlanOut() async throws {
        defer { engine.stop() }
        await start(["ses_a"])
        let model = try #require(workspace.model(for: "ses_a"))
        model.buildPlan()
        try await eventually { !engine.requests("POST", "/api/session/ses_a/prompt").isEmpty }
        #expect(engine.requests("POST", "/api/session/ses_a/agent").first?.body["agent"] as? String == "build")
        #expect(model.agent == "build")
        let asked = engine.asked.filter { $0.hasSuffix("/agent") || $0.hasSuffix("/prompt") }
        #expect(asked == ["POST /api/session/ses_a/agent", "POST /api/session/ses_a/prompt"], "Build first, then the go-ahead")
        #expect((engine.requests("POST", "/api/session/ses_a/prompt").first?.body["text"] as? String)?.contains("build it, as planned") == true)
    }
}
