import Foundation
import OpenCodeKit
import Testing
@testable import KuvoCode

/// Making a bot from scratch (F1): it gets a folder of its own with a memory that names it, and a
/// conversation of its own in that folder, told who it is; it's listed, and still there when Kuvo
/// Code opens again; it writes first, asking what it's for. The job it then keeps in its memory is
/// what shows under its name. One the engine couldn't make leaves nothing behind. The engine is
/// stubbed.
@MainActor
@Suite(.serialized) struct BotCreationTests {
    let engine = StubEngine(port: 47997)
    let app = AppModel()
    let botsFile = AppInfo.supportDirectory.appending(path: "bots.json")

    init() {
        app.bots.app = app
        app.wakeUps.app = app
        app.workspace.api = engine.api
        engine.list([])
        engine.on("PATCH", "/api/session/*", json: [:])
        engine.on("PUT", "/api/experimental/session/*", json: [:])
        engine.on("POST", "/api/session/ses_inbox/*", json: [:])
    }

    private func done() {
        engine.stop()
        for bot in app.bots.list { try? FileManager.default.removeItem(atPath: bot.folder) }
        try? FileManager.default.removeItem(at: botsFile)
    }

    @Test func aBotFromScratch() async throws {
        defer { done() }
        engine.on("POST", "/api/session") { request in
            StubWeb.json(["data": StubEngine.session("ses_inbox", title: request.body["title"] as? String ?? "", directory: (request.body["location"] as? [String: Any])?["directory"] as? String ?? "")])
        }
        await app.workspace.refresh()
        let bot = try await app.bots.create(name: "Inbox Helper", look: BotLook(color: .mint, shape: .round, face: .calm), model: nil, machine: nil, project: nil)

        // Its own folder, with a memory that names it, and its conversation there.
        let memory = try String(contentsOfFile: bot.memoryFile, encoding: .utf8)
        #expect(memory.contains("Inbox Helper"))
        let made = try #require(engine.requests("POST", "/api/session").first)
        #expect((made.body["location"] as? [String: Any])?["directory"] as? String == bot.directory)
        #expect(bot.sessionID == "ses_inbox")
        #expect(app.workspace.session("ses_inbox") != nil)
        let told = engine.requests("PUT", "/api/experimental/session/ses_inbox/instructions/entries/\(Bots.instructionKey)").first?.body["value"] as? String
        #expect(told?.contains("Inbox Helper") == true, "it's told who it is")
        // Listed, and still there when Kuvo Code opens again.
        #expect(app.bots.list.map(\.name) == ["Inbox Helper"])
        #expect(Bots().list.map(\.id) == [bot.id])
        #expect(bot.job.isEmpty, "no job until you've told it")

        // It writes first.
        await app.bots.greet(bot)
        #expect(engine.requests("POST", "/api/session/ses_inbox/synthetic").count == 1)

        // You tell it; it keeps its job in its memory, and that's what shows under its name.
        try (memory + "\n## Job\nSorts my inbox every morning\n\nArchive newsletters; flag anything from my bank.\n").write(toFile: bot.memoryFile, atomically: true, encoding: .utf8)
        await app.bots.syncJob(of: bot.id)
        #expect(app.bots.bot(bot.id)?.job == "Sorts my inbox every morning")
        #expect(app.bots.bot(bot.id)?.instructions.contains("flag anything from my bank") == true)
    }

    /// The engine couldn't make its conversation: no bot, and no folder left of it.
    @Test func oneThatCouldntBeMadeLeavesNothing() async throws {
        defer { done() }
        engine.on("POST", "/api/session", json: ["message": "Engine busy"], status: 500)
        await app.workspace.refresh()
        let before = (try? FileManager.default.contentsOfDirectory(atPath: Bots.root.path(percentEncoded: false))) ?? []
        await #expect(throws: (any Error).self) {
            try await app.bots.create(name: "Inbox Helper", look: BotLook(color: .mint, shape: .round, face: .calm), model: nil, machine: nil, project: nil)
        }
        #expect(app.bots.list.isEmpty)
        let after = (try? FileManager.default.contentsOfDirectory(atPath: Bots.root.path(percentEncoded: false))) ?? []
        #expect(Set(after).subtracting(before).isEmpty, "a folder was left: \(Set(after).subtracting(before))")
    }
}
