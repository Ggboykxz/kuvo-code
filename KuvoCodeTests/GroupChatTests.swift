import Foundation
import OpenCodeKit
import Testing
@testable import KuvoCode

/// A group chat talking something through (G1): after your message the lead speaks first, or the
/// bot you named with @; then the next in line, nobody twice in a row; it ends once everyone left
/// has nothing to add (they pass). Each bot speaks in a seat of its own, where it hears what was
/// said since its last turn. The engine is stubbed: each seat answers its turn with the next of
/// its bot's lines.
@MainActor
@Suite(.serialized) struct GroupChatTests {
    let engine = StubEngine(port: 47984)
    let root = AppInfo.testRoot.appending(path: "GroupChat-\(UUID().uuidString.prefix(6))")
    let botsFile = AppInfo.supportDirectory.appending(path: "bots.json")
    let groupsFile = AppInfo.supportDirectory.appending(path: "groups.json")

    /// Each seat's turns, as the engine runs them: who it is, what it was sent, what it answers.
    nonisolated final class Seats: @unchecked Sendable {
        private let lock = NSLock()
        private var bots: [String: String] = [:]
        private var lines: [String: [String]] = [:]
        private var answered: [String: (prompt: String, text: String)] = [:]
        private(set) var turns: [(bot: String, heard: String)] = []
        private var next = 1

        init(lines: [String: [String]]) { self.lines = lines }

        func seat(for title: String) -> String {
            lock.withLock {
                let bot = String(title.prefix { $0 != " " })
                let id = "ses_seat_\(next)"
                next += 1
                bots[id] = bot
                return id
            }
        }

        /// A turn given to `seat`: its bot's next line.
        func turn(_ seat: String, prompt: String, text: String) {
            lock.withLock {
                guard let bot = bots[seat] else { return }
                turns.append((bot, text))
                let line = lines[bot]?.isEmpty == false ? lines[bot]!.removeFirst() : "PASS"
                answered[seat] = (prompt, line)
            }
        }

        func conversation(_ seat: String) -> [[String: Any]] {
            lock.withLock {
                guard let (prompt, text) = answered[seat] else { return [] }
                return [
                    ["id": prompt, "type": "user", "time": ["created": 1], "text": "(turn)"],
                    ["id": prompt + "_reply", "type": "assistant", "agent": "build", "time": ["created": 2, "completed": 3],
                     "model": ["id": "m", "providerID": "p"], "content": [["type": "text", "text": text]]],
                ]
            }
        }

        /// The discussion's turns: not the lead's request, after it, to list who does what.
        var speakers: [String] { lock.withLock { turns.filter { !$0.heard.hasPrefix("For the app, not the chat") }.map(\.bot) } }
    }

    /// The workspace, for the engine's events from its own thread.
    nonisolated final class Events: @unchecked Sendable {
        let workspace: Workspace
        let engine: StubEngine
        init(_ workspace: Workspace, _ engine: StubEngine) {
            self.workspace = workspace
            self.engine = engine
        }

        func ran(_ seat: String) {
            let started = try? engine.event("session.execution.started", session: seat)
            let ended = try? engine.event("session.execution.succeeded", session: seat)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let started { self.workspace.handle(started) }
                    if let ended { self.workspace.handle(ended) }
                }
            }
        }
    }

    private func bot(_ id: String, _ name: String) -> [String: Any] {
        let folder = root.appending(path: id).path(percentEncoded: false)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return ["id": id, "name": name, "job": "Helps", "instructions": "Helps.", "jobInMemory": true,
                "look": ["color": "mint", "shape": "round", "face": "calm"], "folder": folder,
                "sessionID": "ses_" + id, "created": "2026-10-21T09:00:00Z"]
    }

    /// Ada (the lead) and Ben in a chat, with the lines they'll say; the app around them.
    private func start(lines: [String: [String]]) async throws -> (AppModel, BotGroup, Seats) {
        try FileManager.default.createDirectory(at: botsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [bot("bot_ada", "Ada"), bot("bot_ben", "Ben")]).write(to: botsFile)
        let app = AppModel()
        app.bots.app = app
        app.wakeUps.app = app
        app.groups.app = app
        app.workspace.api = engine.api
        engine.list([StubEngine.session("ses_bot_ada", title: "Ada", directory: root.appending(path: "bot_ada").path(percentEncoded: false)),
                     StubEngine.session("ses_bot_ben", title: "Ben", directory: root.appending(path: "bot_ben").path(percentEncoded: false))])
        let seats = Seats(lines: lines)
        let events = Events(app.workspace, engine)
        let directory = root.path(percentEncoded: false)
        engine.on("POST", "/api/session") { request in
            let id = seats.seat(for: request.body["title"] as? String ?? "")
            return StubWeb.json(["data": StubEngine.session(id, title: request.body["title"] as? String ?? "", directory: directory)])
        }
        engine.on("PATCH", "/api/session/*", json: [:])
        engine.on("PUT", "/api/experimental/session/*", json: [:])
        engine.on("POST", "/api/session/ses_seat_*") { request in
            let seat = request.path.split(separator: "/")[2]
            if request.path.hasSuffix("/prompt") {
                seats.turn(String(seat), prompt: request.body["id"] as? String ?? "", text: request.body["text"] as? String ?? "")
                events.ran(String(seat))
            }
            return StubWeb.json([:])
        }
        engine.on("GET", "/api/session/ses_seat_*") { request in
            let seat = String(request.path.split(separator: "/")[2])
            if request.path.hasSuffix("/message") { return StubWeb.json(["data": Array(seats.conversation(seat).reversed())]) }
            return StubWeb.json(["data": StubEngine.session(seat, title: "seat", directory: directory)])
        }
        await app.workspace.refresh()
        let group = app.groups.create(name: "Team", members: ["bot_ada", "bot_ben"])
        return (app, group, seats)
    }

    private func done() {
        engine.stop()
        try? FileManager.default.removeItem(at: botsFile)
        try? FileManager.default.removeItem(at: groupsFile)
        try? FileManager.default.removeItem(at: root)
    }

    /// What was said in the chat: who, in order (nil for you).
    private func said(_ app: AppModel, _ group: BotGroup) -> [String?] {
        app.groups.messages(in: group.id).filter { $0.kind == .message }.map(\.author)
    }

    private func talkedThrough(_ app: AppModel, _ group: BotGroup) async throws {
        for _ in 0..<300 where !app.groups.discussing.contains(group.id) { try await Task.sleep(for: .milliseconds(20)) }
        for _ in 0..<1500 where app.groups.discussing.contains(group.id) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!app.groups.discussing.contains(group.id), "the talk should end once everyone passes")
    }

    @Test func theLeadFirstNobodyTwiceInARowUntilEveryonePasses() async throws {
        defer { done() }
        let (app, group, seats) = try await start(lines: [
            "Ada": ["SQLite: one file, nothing to run.", "PASS"],
            "Ben": ["Agreed, and it's fast enough for notes.", "PASS"],
        ])
        app.groups.send("Which database for the notes app?", to: group.id)
        try await talkedThrough(app, group)
        #expect(said(app, group) == [nil, "bot_ada", "bot_ben"])
        let speakers = seats.speakers
        #expect(speakers.first == "Ada", "the lead speaks first")
        #expect(zip(speakers, speakers.dropFirst()).allSatisfy { $0 != $1 }, "nobody twice in a row: \(speakers)")
        // Each heard your message, and Ben what Ada said before him.
        #expect(seats.turns.first?.heard.contains("Which database for the notes app?") == true)
        #expect(seats.turns.first { $0.bot == "Ben" }?.heard.contains("SQLite: one file") == true)
    }

    /// Named with @, a bot speaks first, the lead after it.
    @Test func aBotYouNameSpeaksFirst() async throws {
        defer { done() }
        let (app, group, seats) = try await start(lines: [
            "Ada": ["I'd go with Postgres.", "PASS"],
            "Ben": ["SQLite, it's a notes app.", "PASS"],
        ])
        app.groups.send("@Ben which database?", to: group.id)
        try await talkedThrough(app, group)
        #expect(seats.speakers.first == "Ben")
        #expect(said(app, group) == [nil, "bot_ben", "bot_ada"])
    }

    /// A debate that goes on (G3): it pauses after its turns (three a bot, at least four), the lead
    /// sums up where it stands, and Keep Going carries it on from there until they've said all
    /// they had.
    @Test func aLongDebatePausesAndKeepGoingCarriesOn() async throws {
        defer { done() }
        let (app, group, seats) = try await start(lines: [
            "Ada": ["Tabs.", "Tabs are one key.", "Tabs let each choose a width.", "Still tabs.", "PASS"],
            "Ben": ["Spaces.", "Spaces look the same everywhere.", "Spaces in every style guide.", "Still spaces.", "PASS"],
        ])
        app.groups.send("Tabs or spaces?", to: group.id)
        try await talkedThrough(app, group)
        #expect(said(app, group).compactMap { $0 }.count == 6, "six turns for two bots")
        #expect(app.groups.paused.contains(group.id))
        // The lead sums up where it stands.
        #expect(app.groups.messages(in: group.id).last { $0.kind == .wrapUp }?.author == "bot_ada")

        app.groups.keepGoing(group.id)
        try await talkedThrough(app, group)
        #expect(!app.groups.paused.contains(group.id))
        let carriedOn = said(app, group).compactMap { $0 }
        #expect(carriedOn.count > 6, "it carries on: \(carriedOn)")
        #expect(seats.speakers.last != nil)
    }

    /// Undo From Here (G3): your message and what came after it go, its words come back to you,
    /// and the bots that heard it are told it was taken back at their next turn, once.
    @Test func undoFromYourMessage() async throws {
        defer { done() }
        let (app, group, seats) = try await start(lines: [
            "Ada": ["Postgres, then.", "PASS", "SQLite, for a small app.", "PASS"],
            "Ben": ["Fine by me.", "PASS", "Agreed.", "PASS"],
        ])
        app.groups.send("We need a big database server.", to: group.id)
        try await talkedThrough(app, group)
        let mine = try #require(app.groups.messages(in: group.id).first { $0.author == nil })
        #expect(app.groups.undo(from: mine.id, in: group.id) == "We need a big database server.")
        #expect(app.groups.messages(in: group.id).filter { $0.kind == .message }.isEmpty, "the message and what came after it go")

        app.groups.send("It's a small notes app.", to: group.id)
        try await talkedThrough(app, group)
        let after = seats.turns.filter { !$0.heard.hasPrefix("For the app, not the chat") }.suffix(2)
        // Told it was taken back, with what it said, and told so once.
        let ada = try #require(after.first { $0.bot == "Ada" })
        #expect(ada.heard.contains("We need a big database server."))
        #expect(ada.heard.contains("It's a small notes app."))
        #expect(app.groups.group(group.id)?.retracted == nil)
    }
}
