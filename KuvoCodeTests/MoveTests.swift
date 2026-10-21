import Foundation
import OpenCodeKit
import Testing
@testable import KuvoCode

/// Moving a bot or a chat to another computer: it goes whole (a bot's memory, files and wake-ups;
/// a chat's wake-ups) with its conversation, which carries on there under the same ID; the
/// original's conversation goes from its engine and its folder to the trash where it was, with
/// the conversation saved in it. One that fails part way leaves the original as it was, and
/// nothing behind where it was going. A bot in a project, one with a coding agent, or one at work
/// doesn't move. The machine is a folder of the test's own and a second engine, stubbed.
@MainActor
@Suite(.serialized) struct MoveTests {
    let mac = StubEngine(port: 47979)
    let box = StubEngine(port: 47978, alongside: true)
    /// The machine's `~/.kuvo-code`.
    let boxRoot = AppInfo.testRoot.appending(path: "box-home/.kuvo-code")
    var botsFile: URL { AppInfo.supportDirectory.appending(path: "bots.json") }

    init() {
        Self.clean()
    }

    private static func clean() {
        for name in ["bots.json", "bots", "wakes"] { try? FileManager.default.removeItem(at: AppInfo.supportDirectory.appending(path: name)) }
        try? FileManager.default.removeItem(at: AppInfo.testRoot.appending(path: "box-home"))
        try? FileManager.default.removeItem(at: AppInfo.testTrash)
    }

    /// The app, with this Mac's engine and the machine's.
    private func app() -> AppModel {
        let app = AppModel()
        app.bots.app = app
        app.wakeUps.app = app
        app.groups.app = app
        app.moves.app = app
        app.workspace.api = mac.api
        let boxAPI = OpenCodeAPI(endpoint: ServerEndpoint(url: URL(string: box.url)!, password: "test"), folderPrefix: RemoteFolder.prefix(for: "box"))
        app.workspace.machineAPI = { $0 == "box" ? boxAPI : nil }
        app.moves.transport = FolderMachine(root: boxRoot)
        for engine in [mac, box] {
            engine.on("PATCH", "/api/session/*", json: [:])
            engine.on("PUT", "/api/experimental/session/*", json: [:])
            engine.on("DELETE", "/api/session/*", json: [:])
        }
        return app
    }

    /// A bot's folder, with its memory, a file it made and a wake-up.
    private func botFolder(_ parent: URL, id: String, session: String) throws -> URL {
        let folder = parent.appending(path: id)
        try FileManager.default.createDirectory(at: folder.appending(path: "workspace"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "wakes"), withIntermediateDirectories: true)
        try Data("# Scout's memory\n\n## Job\nWatches the build\n".utf8).write(to: folder.appending(path: "MEMORY.md"))
        try Data("notes".utf8).write(to: folder.appending(path: "workspace/notes.txt"))
        try Data("check the build".utf8).write(to: folder.appending(path: "wakes/1792000500-AbC123"))
        try Data(session.utf8).write(to: folder.appending(path: "session"))
        return folder
    }

    private func saveBots(_ bots: [[String: Any]]) throws {
        try JSONSerialization.data(withJSONObject: bots).write(to: botsFile)
    }

    private func bot(_ id: String, folder: URL, session: String, machine: String? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var bot: [String: Any] = [
            "id": id, "name": "Scout", "job": "Watches the build", "instructions": "Watches the build", "jobInMemory": true,
            "look": ["color": "sky", "shape": "round", "face": "calm"], "folder": folder.path, "sessionID": session,
            "created": "2026-10-01T09:00:00Z",
        ]
        if let machine { bot["machine"] = machine }
        return bot.merging(extra) { $1 }
    }

    /// What an engine exports of a conversation: its session, with its metadata and rules, and
    /// its messages.
    private static func exported(_ id: String, directory: String, bot: String?) -> [String: Any] {
        var info = StubEngine.session(id, title: "Scout", directory: directory)
        if let bot { info["metadata"] = ["kuvo": ["bot": bot]] }
        info["permissions"] = [["action": "external_directory", "resource": "/old/place/*", "effect": "allow"]]
        return ["data": ["info": info, "messages": [["id": "msg_1", "type": "user", "text": "Remember the number 42.", "time": ["created": 1]]]]]
    }

    private func trashed(_ name: String, in trash: URL) -> URL? {
        let found = FileManager.default.enumerator(at: trash, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return found.first { $0.lastPathComponent == name }
    }

    @Test func aMacBotMovesToAMachineAndCarriesOn() async throws {
        defer { Self.clean(); mac.stop() }
        let id = "bot_scout00001", session = "ses_scout"
        let original = try botFolder(Bots.root, id: id, session: session)
        try saveBots([bot(id, folder: original, session: session)])
        let app = app()
        mac.list([StubEngine.session(session, title: "Scout", directory: original.appending(path: "workspace").path)])
        await app.workspace.refresh()
        mac.on("GET", "/api/experimental/session/\(session)/export", json: Self.exported(session, directory: original.appending(path: "workspace").path, bot: id))
        let there = boxRoot.appending(path: "bots/\(id)")
        box.on("POST", "/api/experimental/session/import") { request in
            StubWeb.json(["data": StubEngine.session(session, title: "Scout", directory: (request.body["location"] as? [String: Any])?["directory"] as? String ?? "")])
        }

        try await app.moves.move(bot: id, to: "box")

        // There: its memory, files and wake-ups, not held, and its conversation, under the same ID.
        #expect(FileManager.default.fileExists(atPath: there.appending(path: "MEMORY.md").path))
        #expect(try String(contentsOf: there.appending(path: "workspace/notes.txt"), encoding: .utf8) == "notes")
        #expect(FileManager.default.fileExists(atPath: there.appending(path: "wakes/1792000500-AbC123").path))
        #expect(!FileManager.default.fileExists(atPath: there.appending(path: "paused").path), "its wake-ups go on there")
        let imported = try #require(box.requests("POST", "/api/experimental/session/import").first)
        #expect((imported.body["location"] as? [String: Any])?["directory"] as? String == there.appending(path: "workspace").path)
        #expect((imported.body["info"] as? [String: Any])?["id"] as? String == session)
        #expect((imported.body["messages"] as? [Any])?.count == 1)
        // Its rules there, for its folder there, not where it was.
        let rules = box.requests("PATCH", "/api/session/\(session)").compactMap { $0.body["permissions"] as? [[String: Any]] }.last ?? []
        #expect(rules.contains { $0["resource"] as? String == there.path + "/*" })
        #expect(!rules.contains { ($0["resource"] as? String)?.hasPrefix("/old/place") == true })
        let told = box.requests("PUT", "/api/experimental/session/\(session)/instructions/entries/\(Bots.instructionKey)").last?.body["value"] as? String
        #expect(told?.contains("the Linux machine \"box\"") == true)
        // It lives there now.
        let moved = try #require(app.bots.bot(id))
        #expect(moved.machine == "box" && moved.folder == there.path && moved.sessionID == session)
        #expect(Bots().bot(id)?.machine == "box", "still there after a relaunch")
        #expect(app.workspace.session(session)?.location.directory == RemoteFolder.folder(there.appending(path: "workspace").path, on: "box"))

        // The original: its conversation gone from this Mac's engine, its folder in the Trash with
        // the conversation saved in it.
        #expect(mac.requests("DELETE", "/api/session/\(session)").count == 1)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        let kept = try #require(trashed(id, in: AppInfo.testTrash))
        let saved = try String(contentsOf: kept.appending(path: "conversation.json"), encoding: .utf8)
        #expect(saved.contains(session) && saved.contains("Remember the number 42."))
    }

    @Test func aBotOnAMachineComesBackToThisMac() async throws {
        defer { Self.clean(); mac.stop() }
        let id = "bot_scout00002", session = "ses_scout2"
        let original = try botFolder(boxRoot.appending(path: "bots"), id: id, session: session)
        try saveBots([bot(id, folder: original, session: session, machine: "box")])
        let app = app()
        box.on("GET", "/api/experimental/session/\(session)/export", json: Self.exported(session, directory: original.appending(path: "workspace").path, bot: id))
        mac.on("POST", "/api/experimental/session/import") { request in
            StubWeb.json(["data": StubEngine.session(session, title: "Scout", directory: (request.body["location"] as? [String: Any])?["directory"] as? String ?? "")])
        }

        try await app.moves.move(bot: id, to: nil)

        let here = Bots.root.appending(path: id)
        #expect(FileManager.default.fileExists(atPath: here.appending(path: "workspace/notes.txt").path))
        #expect(app.bots.bot(id)?.machine == nil && app.bots.bot(id)?.folder == here.path)
        // Described where it lives now, and its folder says its session and where it works.
        #expect(FileManager.default.fileExists(atPath: here.appending(path: Bot.Descriptor.file).path))
        #expect(try String(contentsOf: here.appending(path: "directory"), encoding: .utf8) == here.appending(path: "workspace").path)
        #expect(box.requests("DELETE", "/api/session/\(session)").count == 1)
        // The original in Kuvo Code's trash on the machine, with its conversation.
        #expect(!FileManager.default.fileExists(atPath: original.path))
        let kept = try #require(trashed(id, in: boxRoot.appending(path: "trash")))
        #expect(FileManager.default.fileExists(atPath: kept.appending(path: "conversation.json").path))
    }

    @Test func aChatMovesWithItsWakeUps() async throws {
        defer { Self.clean(); mac.stop() }
        let id = "ses_chat1"
        let wakes = WakeUps.root.appending(path: id)
        try FileManager.default.createDirectory(at: wakes.appending(path: "wakes"), withIntermediateDirectories: true)
        try Data(id.utf8).write(to: wakes.appending(path: "session"))
        try Data(Workspace.chatsFolder.utf8).write(to: wakes.appending(path: "directory"))
        try Data("ask how it went".utf8).write(to: wakes.appending(path: "wakes/1792000900-Chat01"))
        let app = app()
        mac.list([StubEngine.session(id, title: "Trip plans", directory: Workspace.chatsFolder)])
        await app.workspace.refresh()
        mac.on("GET", "/api/session/\(id)/inbox", json: ["data": []])
        mac.on("GET", "/api/experimental/session/\(id)/export", json: Self.exported(id, directory: Workspace.chatsFolder, bot: nil))
        box.on("POST", "/api/experimental/session/import") { request in
            StubWeb.json(["data": StubEngine.session(id, title: "Trip plans", directory: (request.body["location"] as? [String: Any])?["directory"] as? String ?? "")])
        }

        try await app.moves.move(chat: id, to: "box")

        let chats = boxRoot.appending(path: "chats").path
        let there = boxRoot.appending(path: "wakes/\(id)")
        #expect(FileManager.default.fileExists(atPath: there.appending(path: "wakes/1792000900-Chat01").path))
        #expect(try String(contentsOf: there.appending(path: "directory"), encoding: .utf8) == chats, "its checks run where it is now")
        #expect(!FileManager.default.fileExists(atPath: there.appending(path: "paused").path))
        let directory = RemoteFolder.folder(chats, on: "box")
        #expect(app.workspace.session(id)?.location.directory == directory)
        #expect(Workspace.isChat(directory) && app.workspace.chats.map(\.id) == [id], "with the chats, not a project")
        #expect(mac.requests("DELETE", "/api/session/\(id)").count == 1)
        #expect(!FileManager.default.fileExists(atPath: wakes.path))
        let kept = try #require(trashed(id, in: AppInfo.testTrash))
        #expect(FileManager.default.fileExists(atPath: kept.appending(path: "conversation.json").path))
    }

    /// The machine turned the conversation down: nothing of it stays there, and the original is as
    /// it was, its wake-ups going on.
    @Test func aMoveThatFailsLeavesTheOriginalAsItWas() async throws {
        defer { Self.clean(); mac.stop() }
        let id = "bot_scout00003", session = "ses_scout3"
        let original = try botFolder(Bots.root, id: id, session: session)
        try saveBots([bot(id, folder: original, session: session)])
        let before = try Data(contentsOf: botsFile)
        let app = app()
        mac.list([StubEngine.session(session, title: "Scout", directory: original.appending(path: "workspace").path)])
        await app.workspace.refresh()
        mac.on("GET", "/api/experimental/session/\(session)/export", json: Self.exported(session, directory: original.appending(path: "workspace").path, bot: id))
        box.on("POST", "/api/experimental/session/import", json: ["message": "Disk full"], status: 500)

        await #expect(throws: (any Error).self) { try await app.moves.move(bot: id, to: "box") }

        #expect(FileManager.default.fileExists(atPath: original.appending(path: "workspace/notes.txt").path))
        #expect(!FileManager.default.fileExists(atPath: original.appending(path: "paused").path), "its wake-ups go on")
        #expect(!FileManager.default.fileExists(atPath: boxRoot.appending(path: "bots/\(id)").path))
        #expect(mac.requests("DELETE", "/api/session/\(session)").isEmpty)
        #expect(try Data(contentsOf: botsFile) == before)
        #expect(app.bots.bot(id)?.machine == nil)
        #expect(!app.moves.isMoving(id))
    }

    @Test func someBotsDontMove() async throws {
        defer { Self.clean(); mac.stop() }
        let folders = try ["bot_project001", "bot_agents0001", "bot_working001"].map { try botFolder(Bots.root, id: $0, session: "ses_" + $0) }
        try saveBots([
            bot("bot_project001", folder: folders[0], session: "ses_bot_project001", extra: ["project": "/Users/me/app"]),
            bot("bot_agents0001", folder: folders[1], session: "ses_bot_agents0001", extra: ["agents": true]),
            bot("bot_working001", folder: folders[2], session: "ses_bot_working001"),
        ])
        let app = app()
        mac.list([StubEngine.session("ses_bot_working001", directory: folders[2].appending(path: "workspace").path)], running: ["ses_bot_working001"])
        await app.workspace.refresh()
        for (id, expected) in [("bot_project001", "projects"), ("bot_agents0001", "coding agent"), ("bot_working001", "working")] {
            do {
                try await app.moves.move(bot: id, to: "box")
                Issue.record("\(id) moved")
            } catch {
                #expect(error.localizedDescription.contains(expected), "\(id): \(error.localizedDescription)")
            }
            #expect(app.bots.bot(id)?.machine == nil)
            #expect(!FileManager.default.fileExists(atPath: boxRoot.appending(path: "bots/\(id)").path))
        }
        #expect(mac.requests("GET", "/export").isEmpty, "nothing was asked for")
    }
}

/// A machine whose `~/.kuvo-code` is a folder here: what goes there over SSH goes there.
private struct FolderMachine: MoveTransport {
    let root: URL
    let here = SSHMoveTransport()

    func home(on machine: String?) async throws -> MoveHome {
        guard machine != nil else { return try await here.home(on: nil) }
        for name in ["bots", "wakes", "chats", "trash"] {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        return MoveHome(root: root.path, bots: root.appending(path: "bots").path, wakes: root.appending(path: "wakes").path, chats: root.appending(path: "chats").path)
    }

    func exists(_ path: String, on machine: String?) async throws -> Bool { try await here.exists(path, on: nil) }
    func pack(_ path: String, on machine: String?, into archive: URL) async throws { try await here.pack(path, on: nil, into: archive) }
    func unpack(_ archive: URL, into parent: String, on machine: String?) async throws { try await here.unpack(archive, into: parent, on: nil) }
    func write(_ data: Data, to path: String, on machine: String?) async throws { try await here.write(data, to: path, on: nil) }
    func remove(_ path: String, on machine: String?) async throws { try await here.remove(path, on: nil) }

    func trash(_ path: String, on machine: String?) async throws {
        guard machine != nil else { return try await here.trash(path, on: nil) }
        guard FileManager.default.fileExists(atPath: path) else { return }
        let into = root.appending(path: "trash/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: path, toPath: into.appending(path: (path as NSString).lastPathComponent).path)
    }
}
