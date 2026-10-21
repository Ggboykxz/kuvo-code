import Foundation
import OpenCodeKit
import Testing
@testable import KuvoCode

/// The first launch after an update brings what you keep up to date, once: the window says
/// it's updating, a backup of your lists and settings is made first, and each bot gets its
/// description beside its memory, while its list stays as an older version wrote it. A new install
/// has nothing to back up or say. Edits reach a bot's description; a bot whose folder has gone
/// gets none. A list of machines that won't read is set aside, not written over.
@MainActor
@Suite(.serialized) struct CalibrationTests {
    var botsFile: URL { AppInfo.supportDirectory.appending(path: "bots.json") }

    init() {
        TestEnvironment.prepare()
        Self.clean()
    }

    private static func clean() {
        for key in [Calibration.key, Calibration.backedUpKey, "calibrationTestMarker"] + Backups.settings {
            UserDefaults.standard.removeObject(forKey: key)
        }
        for name in Backups.files + ["Backups", "bots"] {
            try? FileManager.default.removeItem(at: AppInfo.supportDirectory.appending(path: name))
        }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(Machines.unreadableKey) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// A bot's folder on this Mac, with its memory.
    private func folder(_ id: String, memory: String) throws -> URL {
        let folder = Bots.root.appending(path: id)
        try FileManager.default.createDirectory(at: folder.appending(path: "workspace"), withIntermediateDirectories: true)
        try Data(memory.utf8).write(to: folder.appending(path: "MEMORY.md"))
        return folder
    }

    /// `bots.json` as Kuvo Code wrote it before descriptions: one bot on this Mac, one on a machine.
    private func savedBefore(macFolder: URL) -> Data {
        Data("""
            [
              {
                "agents" : null, "created" : "2026-10-01T09:00:00Z", "folder" : "\(macFolder.path)",
                "id" : "bot_scout00001", "instructions" : "Watches the build", "job" : "Watches the build",
                "jobInMemory" : true, "look" : { "color" : "sky", "face" : "calm", "shape" : "round" },
                "model" : { "id" : "big-pickle", "providerID" : "opencode" }, "name" : "Scout",
                "personality" : null, "sessionID" : "ses_scout"
              },
              {
                "created" : "2026-10-02T09:00:00Z", "folder" : "/home/me/.kuvo-code/bots/bot_away000001",
                "id" : "bot_away000001", "instructions" : "", "job" : "", "jobInMemory" : true,
                "look" : { "color" : "mint", "face" : "happy", "shape" : "gem" }, "machine" : "my-server",
                "name" : "Away", "sessionID" : "ses_away"
              }
            ]
            """.utf8)
    }

    private static func descriptor(in folder: URL) throws -> Bot.Descriptor {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Bot.Descriptor.self, from: Data(contentsOf: folder.appending(path: Bot.Descriptor.file)))
    }

    @Test func theFirstLaunchAfterAnUpdateBacksUpThenUpdates() async throws {
        defer { Self.clean() }
        let scout = try folder("bot_scout00001", memory: "# Scout's memory\n\n## Job\nWatches the build\n")
        let saved = savedBefore(macFolder: scout)
        try saved.write(to: botsFile)
        UserDefaults.standard.set("kept", forKey: "calibrationTestMarker")

        let app = AppModel()
        #expect(app.calibration.isRunning, "the window says it's updating from its first moment")
        await app.calibration.run(app)
        #expect(!app.calibration.isRunning)
        #expect(UserDefaults.standard.integer(forKey: Calibration.key) == Calibration.current)

        // A backup first: the list as it was, and the settings.
        let backups = try FileManager.default.contentsOfDirectory(at: Backups.folder, includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(try Data(contentsOf: backup.appending(path: "bots.json")) == saved)
        let settings = try PropertyListSerialization.propertyList(from: Data(contentsOf: backup.appending(path: "settings.plist")), format: nil) as? [String: Any]
        #expect(settings?["calibrationTestMarker"] as? String == "kept")

        // The Mac bot's description beside its memory; the list as an older version wrote it.
        let described = try Self.descriptor(in: scout)
        #expect(described.kuvo == 1)
        #expect(described.id == "bot_scout00001" && described.name == "Scout" && described.job == "Watches the build")
        #expect(described.look == BotLook(color: .sky, shape: .round, face: .calm))
        #expect(described.model == ModelRef(id: "big-pickle", providerID: "opencode"))
        #expect(described.project == nil)
        #expect(described.updated == described.created, "not changed since it was made")
        #expect(try Data(contentsOf: botsFile) == saved)

        // Once: the next launch has nothing to do.
        let next = AppModel()
        #expect(!next.calibration.isRunning)
        await next.calibration.run(next)
        #expect(try FileManager.default.contentsOfDirectory(atPath: Backups.folder.path).count == 1)
    }

    @Test func aNewInstallHasNothingToBackUpOrSay() async {
        defer { Self.clean() }
        #expect(!Backups.hasData)
        let app = AppModel()
        #expect(!app.calibration.isRunning)
        await app.calibration.run(app)
        #expect(!FileManager.default.fileExists(atPath: Backups.folder.path))
        #expect(UserDefaults.standard.integer(forKey: Calibration.key) == Calibration.current)
    }

    @Test func onlyTheNewestBackupsStay() throws {
        defer { Self.clean() }
        try Data("[]".utf8).write(to: botsFile)
        // Noon, so the day is the same in any time zone.
        for day in 0..<5 { #expect(Backups.make(now: Date(timeIntervalSince1970: Double(day) * 86_400 + 43_200)) != nil) }
        let names = try FileManager.default.contentsOfDirectory(atPath: Backups.folder.path).sorted()
        #expect(names.count == Backups.kept)
        #expect(names.first?.hasPrefix("1970-01-03") == true)
        #expect(names.last?.hasPrefix("1970-01-05") == true)
    }

    /// One left half made (the app quit while it copied) never counts, and goes with the next.
    @Test func aBackupCutShortDoesntCount() throws {
        defer { Self.clean() }
        try Data("[]".utf8).write(to: botsFile)
        let cut = Backups.folder.appending(path: ".partial-left-from-before")
        try FileManager.default.createDirectory(at: cut, withIntermediateDirectories: true)
        #expect(Backups.make() != nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: Backups.folder.path)
        #expect(names.count == 1 && names.first?.hasPrefix(".") == false)
    }

    /// An update's steps tried again at a later launch (one failed, or the app quit) make no
    /// second backup, which could push the one from before the update out; two starts of the
    /// engine at once run the steps once, the second waiting for the first.
    @Test func oneBackupForAnUpdateAndOneRunAtATime() async throws {
        defer { Self.clean() }
        let scout = try folder("bot_scout00001", memory: "# Scout's memory\n")
        try savedBefore(macFolder: scout).write(to: botsFile)

        let app = AppModel()
        async let first: Void = app.calibration.run(app)
        async let second: Void = app.calibration.run(app)
        _ = await (first, second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: Backups.folder.path).count == 1)
        #expect(FileManager.default.fileExists(atPath: scout.appending(path: Bot.Descriptor.file).path))

        // Its steps not marked done (as if one had failed): tried again, without a new backup.
        UserDefaults.standard.removeObject(forKey: Calibration.key)
        let again = AppModel()
        #expect(again.calibration.isRunning)
        await again.calibration.run(again)
        #expect(try FileManager.default.contentsOfDirectory(atPath: Backups.folder.path).count == 1)
        #expect(UserDefaults.standard.integer(forKey: Calibration.key) == Calibration.current)
    }

    /// Made, edited, given a job: its description follows. One whose folder has gone gets none,
    /// and no folder is made for it.
    @Test func editsReachTheDescription() async throws {
        defer { Self.clean() }
        let engine = StubEngine(port: 47981)
        defer { engine.stop() }
        let app = AppModel()
        app.bots.app = app
        app.wakeUps.app = app
        app.workspace.api = engine.api
        engine.list([])
        engine.on("PATCH", "/api/session/*", json: [:])
        engine.on("PUT", "/api/experimental/session/*", json: [:])
        engine.on("POST", "/api/session/ses_inbox/*", json: [:])
        engine.on("POST", "/api/session") { request in
            StubWeb.json(["data": StubEngine.session("ses_inbox", title: request.body["title"] as? String ?? "", directory: (request.body["location"] as? [String: Any])?["directory"] as? String ?? "")])
        }
        await app.workspace.refresh()
        let bot = try await app.bots.create(name: "Inbox Helper", look: BotLook(color: .mint, shape: .round, face: .calm), model: nil, machine: nil, project: nil)
        let folder = URL(filePath: bot.folder)
        #expect(try Self.descriptor(in: folder).name == "Inbox Helper")

        var edited = bot
        edited.name = "Inbox Keeper"
        edited.look = BotLook(color: .coral, shape: .gem, face: .wink)
        await app.bots.update(edited)
        let renamed = try Self.descriptor(in: folder)
        #expect(renamed.name == "Inbox Keeper" && renamed.look.color == .coral)
        #expect(app.bots.bot(bot.id)?.updated != nil, "noted as changed")

        try "# Inbox Keeper's memory\n\n## Job\nSorts my inbox every morning\n".write(toFile: bot.memoryFile, atomically: true, encoding: .utf8)
        await app.bots.syncJob(of: bot.id)
        #expect(try Self.descriptor(in: folder).job == "Sorts my inbox every morning")

        // Its folder gone (deleted by hand): no description, and no folder made for it.
        try FileManager.default.removeItem(at: folder)
        await app.bots.describeAll(on: nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        try? FileManager.default.removeItem(at: botsFile)
    }

    @Test func machinesThatWontReadAreSetAsideNotOverwritten() {
        defer { Self.clean() }
        let damaged = Data("[{\"destination\": 42}]".utf8)
        UserDefaults.standard.set(damaged, forKey: "machines")
        let machines = Machines()
        #expect(machines.list.isEmpty)
        let aside = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix(Machines.unreadableKey) }
        #expect(aside.count == 1)
        #expect(aside.first?.value as? Data == damaged)
        // Once, however many launches find it there.
        _ = Machines()
        #expect(UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix(Machines.unreadableKey) }.count == 1)
        UserDefaults.standard.removeObject(forKey: "machines")
    }
}
