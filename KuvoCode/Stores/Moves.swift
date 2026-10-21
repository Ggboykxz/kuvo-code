import Foundation
import OpenCodeKit
import os

/// Moving a bot or a chat to another computer: this Mac, or one of your machines, say a new one
/// you've set up. It goes whole (a bot with its memory, workspace, wake-ups and watches; a chat
/// with its wake-ups), with its conversation and its subagents', which carry on there under the
/// same IDs.
///
/// While it moves, nothing goes to it (`isFrozen`): what you send stays in the composer, agents'
/// messages wait, its wake-ups are held. Its conversation is copied once it's settled, and read
/// again right before it switches: what reached it meanwhile (a wake-up on its way) goes along.
/// Nothing of the original is touched until the copy is set up where it's going. Then the app
/// switches to the copy, and the original goes: its conversation from its engine, its folder to
/// the trash where it was (the Mac's Trash, or Kuvo Code's trash folder on its machine), with
/// its conversation saved in it as `conversation.json`. A move is noted as it goes (`Record`), so
/// one cut short (the app quit, a machine away) is taken back, or finished once it had switched,
/// the next time both computers are there (`recover`).
@MainActor @Observable
final class Moves {
    /// What's moving now, a bot's ID or a chat's session ID, and where to (nil: this Mac): its
    /// row says so.
    private(set) var underWay: [String: String?] = [:]
    @ObservationIgnored weak var app: AppModel?
    /// How files get where they're going: over SSH, or (in tests) a folder standing in for a machine.
    @ObservationIgnored var transport: any MoveTransport = SSHMoveTransport()
    private let log = Logger(subsystem: "run.kuvo.code", category: "moves")

    /// Conversations moving now (a bot's, a chat's, their subagents') and the bots moving: nothing
    /// goes to them until they're where they're going.
    private(set) static var frozen: Set<String> = []

    static func isFrozen(_ id: String) -> Bool { frozen.contains(id) }

    enum Failure: LocalizedError {
        case notConnected(String)
        case working(String)
        case inProject(String)
        case withAgents(String)
        case waiting(String)
        case busy(String)
        /// Something sent to one that's moving.
        case moving
        var errorDescription: String? {
            switch self {
            case .notConnected(let place): "\(place) isn’t connected. Connect to it, then try again."
            case .working(let name): "\(name) is working. Move it once it’s done."
            case .inProject(let name): "\(name) works in one of your projects, which stays where it is. Only a bot with a folder of its own can move."
            case .withAgents(let name): "\(name) talks with a coding agent, which keeps its conversation on this computer, so it can’t move yet."
            case .waiting(let name): "\(name) still has messages on their way. Try again in a moment."
            case .busy(let name): "\(name) kept getting messages while it moved, so it stayed where it is. Try again in a moment."
            case .moving: "It’s moving to another computer. Try again once it’s there."
            }
        }
    }

    /// A move as it goes, kept in the app's settings until it's done.
    struct Record: Codable, Equatable {
        enum Kind: String, Codable { case bot, chat }
        /// Copying, with the original as it was: taken back if cut short. Switched: the app goes
        /// by the copy; the original is to go.
        enum Stage: String, Codable { case copying, switched }
        var kind: Kind
        /// The bot's ID, or the chat's session.
        var id: String
        /// Its conversation, and its subagents', root first.
        var sessions: [String]
        var from: String?
        var to: String?
        /// Its folder where it was, and where it's going: a bot's own, a chat's wake-ups' (nil
        /// for a chat that keeps none).
        var original: String?
        var copy: String?
        var wasPaused: Bool
        var stage: Stage
    }

    private static let key = "movesUnderWay"

    private var records: [Record] {
        get { UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? [] }
        set {
            UserDefaults.standard.set(newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue), forKey: Self.key)
            noteMovedAway(newValue)
        }
    }

    private func save(_ record: Record) {
        records = records.filter { $0.id != record.id } + [record]
    }

    private func forget(_ record: Record) {
        records = records.filter { $0.id != record.id }
    }

    /// What's listed from where a conversation was leaves out its original once it switched, until
    /// it's gone.
    private func noteMovedAway(_ records: [Record]) {
        var away: [String: String?] = [:]
        for record in records where record.stage == .switched {
            for session in record.sessions { away[session] = .some(record.from) }
        }
        app?.workspace.movedAway = away
    }

    func isMoving(_ id: String) -> Bool { underWay[id] != nil }

    /// Where something can move: this Mac, and each machine you've added, but where it is.
    func destinations(from machine: String?) -> [String?] {
        ([nil] + (app?.machines.list.map(\.id) ?? []).map(Optional.some)).filter { $0 != machine }
    }

    // MARK: Bots

    /// Moves a bot to `machine` (nil: this Mac): its folder and conversation go there, and from
    /// then on it lives there. Its group chats get a seat for it there at its next turn.
    func move(bot id: String, to machine: String?) async throws {
        guard let app, let bot = app.bots.bot(id), bot.machine != machine, underWay[id] == nil else { return }
        if bot.project != nil { throw Failure.inProject(bot.name) }
        if bot.agents == true { throw Failure.withAgents(bot.name) }
        if app.workspace.isWorking(bot.sessionID) || app.groups.speaking.values.contains(bot.id) { throw Failure.working(bot.name) }
        guard let source = app.workspace.api(forFolder: bot.directory) else { throw Failure.notConnected(bot.machine ?? AppInfo.name) }
        guard let target = api(on: machine) else { throw Failure.notConnected(machine ?? AppInfo.name) }
        var record = Record(kind: .bot, id: id, sessions: [bot.sessionID], from: bot.machine, to: machine, original: bot.folder, copy: nil, wasPaused: true, stage: .copying)
        underWay[id] = .some(machine)
        Self.frozen.formUnion([bot.id, bot.sessionID])
        defer {
            underWay[id] = nil
            Self.frozen.subtract(record.sessions + [bot.id, bot.sessionID])
        }
        let copied: (exports: [JSONValue], sessions: [Session])
        let folder: String
        do {
            let home = try await transport.home(on: machine)
            var moved = bot
            moved.machine = machine
            moved.folder = home.bots + "/" + bot.id
            folder = moved.folder
            record.copy = folder
            record.wasPaused = try await transport.exists(bot.folder + "/paused", on: bot.machine)
            save(record)
            // Its wake-ups wait while it moves (as Pause does), so none goes on the way, and none twice.
            if !record.wasPaused { try await transport.write(Data("paused".utf8), to: bot.folder + "/paused", on: bot.machine) }
            try await settle(bot.sessionID, on: source, name: bot.name)
            copied = try await carry(bot.sessionID, from: source, to: target, directory: moved.directory, name: bot.name, record: &record) {
                // One left there by a move cut short goes first.
                if try await self.transport.exists(folder, on: machine) { try await self.transport.trash(folder, on: machine) }
                try await self.copy(bot.folder, from: bot.machine, into: home.bots, on: machine)
            }
        } catch {
            await takeBack(record, target: target)
            log.error("A bot didn't move: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        // The switch: from here on it lives there.
        record.stage = .switched
        save(record)
        await app.groups.botMoving(bot)
        app.workspace.moved(copied.sessions, api: target)
        await app.bots.moved(id, to: machine, folder: folder, session: copied.sessions[0], api: target)
        if !record.wasPaused { try? await transport.remove(folder + "/paused", on: machine) }
        if let now = app.bots.bot(id) { await BotKeys.apply(to: now, app: app) }
        if bot.machine == nil { app.utilities.closeTabs(of: bot.id) }
        // The original goes.
        await finish(record, exports: copied.exports, source: source, leaving: bot)
        app.wakeUps.forget(key: id)
        if let now = app.bots.bot(id) { await app.wakeUps.read(now.wakeOwner) }
        Analytics.shared.track("bot_moved", ["to": machine == nil ? "mac" : "machine"])
    }

    // MARK: Chats

    /// Moves a chat to `machine` (nil: this Mac): its conversation and wake-ups go there, into
    /// that computer's chats.
    func move(chat id: String, to machine: String?) async throws {
        guard let app, let chat = app.workspace.session(id), Workspace.isChat(chat.location.directory) else { return }
        let from = RemoteFolder.machine(of: chat.location.directory)
        guard from != machine, underWay[id] == nil else { return }
        let name = (chat.title ?? "").isEmpty ? "This chat" : "“\(chat.title ?? "")”"
        if OutsideAgents.isAgentSession(chat) { throw Failure.withAgents(name) }
        if app.workspace.isWorking(id) { throw Failure.working(name) }
        guard let source = app.workspace.api(forSession: id) else { throw Failure.notConnected(from ?? AppInfo.name) }
        guard let target = api(on: machine) else { throw Failure.notConnected(machine ?? AppInfo.name) }
        var record = Record(kind: .chat, id: id, sessions: [id], from: from, to: machine, original: nil, copy: nil, wasPaused: true, stage: .copying)
        underWay[id] = .some(machine)
        Self.frozen.insert(id)
        defer {
            underWay[id] = nil
            Self.frozen.subtract(record.sessions + [id])
        }
        let copied: (exports: [JSONValue], sessions: [Session])
        let hasWakes: Bool
        do {
            let there = try await transport.home(on: machine)
            let here = try await transport.home(on: from)
            let directory = machine.map { RemoteFolder.folder(there.chats, on: $0) } ?? there.chats
            let wakes = here.wakes + "/" + id
            let copy = there.wakes + "/" + id
            hasWakes = try await transport.exists(wakes, on: from)
            if hasWakes {
                record.original = wakes
                record.copy = copy
                record.wasPaused = try await transport.exists(wakes + "/paused", on: from)
            }
            save(record)
            if hasWakes, !record.wasPaused { try await transport.write(Data("paused".utf8), to: wakes + "/paused", on: from) }
            try await settle(id, on: source, name: name)
            copied = try await carry(id, from: source, to: target, directory: directory, name: name, record: &record) {
                guard hasWakes else { return }
                if try await self.transport.exists(copy, on: machine) { try await self.transport.trash(copy, on: machine) }
                try await self.copy(wakes, from: from, into: there.wakes, on: machine)
                // Where its watches' checks run there.
                try await self.transport.write(Data(there.chats.utf8), to: copy + "/directory", on: machine)
            }
        } catch {
            await takeBack(record, target: target)
            log.error("A chat didn't move: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        record.stage = .switched
        save(record)
        app.workspace.moved(copied.sessions, api: target)
        if hasWakes, !record.wasPaused, let copy = record.copy { try? await transport.remove(copy + "/paused", on: machine) }
        await finish(record, exports: copied.exports, source: source, leaving: nil)
        app.wakeUps.forget(key: id)
        if let now = app.workspace.session(id) { await app.wakeUps.read(WakeUps.owner(of: now)) }
        Analytics.shared.track("chat_moved_computer", ["to": machine == nil ? "mac" : "machine"])
    }

    // MARK: The conversation

    /// Until the conversation has nothing at work or waiting to go (a wake-up on its way, a
    /// message that went just before it froze): a minute at most.
    private func settle(_ session: String, on api: OpenCodeAPI, name: String) async throws {
        for _ in 0..<60 {
            let working = app?.workspace.isWorking(session) ?? false
            let waiting = try await !api.inbox(session: session).isEmpty
            if !working, !waiting { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw Failure.waiting(name)
    }

    /// Copies the conversation (and its subagents') to `target`, at `directory`, once `files` (its
    /// folder) are there; then, right before it switches, reads the original again: what reached
    /// it meanwhile goes along, by copying it again. One there already (an earlier copy, from a
    /// move cut short) gives way.
    private func carry(_ session: String, from source: OpenCodeAPI, to target: OpenCodeAPI, directory: String, name: String, record: inout Record,
                       files: () async throws -> Void) async throws -> (exports: [JSONValue], sessions: [Session]) {
        var exports = try await exportAll(session, from: source)
        record.sessions = Self.ids(exports)
        save(record)
        Self.frozen.formUnion(record.sessions)
        try await files()
        var sessions = try await importAll(exports, into: target, directory: directory)
        for attempt in 0..<3 {
            let again = try await exportAll(session, from: source)
            if Self.same(again, exports) { return (exports, sessions) }
            guard attempt < 2 else { break }
            for id in record.sessions.reversed() { try? await target.deleteSession(id) }
            exports = again
            record.sessions = Self.ids(exports)
            save(record)
            Self.frozen.formUnion(record.sessions)
            sessions = try await importAll(exports, into: target, directory: directory)
        }
        throw Failure.busy(name)
    }

    /// The conversation and every subagent's under it, root first, as the engine exports them.
    private func exportAll(_ session: String, from api: OpenCodeAPI) async throws -> [JSONValue] {
        var exports = [try await api.exportSession(session)]
        var next = [session]
        while let parent = next.popLast() {
            for child in try await api.children(of: parent, limit: 200) {
                exports.append(try await api.exportSession(child.id))
                next.append(child.id)
            }
        }
        return exports
    }

    /// Each into `api` at `directory`, under its own ID; one there already (an earlier copy, from
    /// a move cut short, while the original is still where it was) gives way.
    private func importAll(_ exports: [JSONValue], into api: OpenCodeAPI, directory: String) async throws -> [Session] {
        var sessions: [Session] = []
        for exported in exports {
            do {
                sessions.append(try await api.importSession(exported: exported, directory: directory))
            } catch let error as ServerError where error.status == 409 {
                guard let id = exported["info"]?["id"]?.string else { throw error }
                try await api.deleteSession(id)
                sessions.append(try await api.importSession(exported: exported, directory: directory))
            }
        }
        return sessions
    }

    private static func ids(_ exports: [JSONValue]) -> [String] {
        exports.compactMap { $0["info"]?["id"]?.string }
    }

    /// Whether two reads of a conversation hold the same sessions and messages.
    private static func same(_ one: [JSONValue], _ other: [JSONValue]) -> Bool {
        func messages(_ exports: [JSONValue]) -> [String] {
            exports.flatMap { export in [export["info"]?["id"]?.string ?? ""] + (export["messages"]?.array ?? []).map { $0["id"]?.string ?? "" } }
        }
        return messages(one) == messages(other)
    }

    // MARK: Ending

    /// A move that didn't get as far as switching: what it made where it was going goes, and the
    /// original's wake-ups go on, as it was.
    private func takeBack(_ record: Record, target: OpenCodeAPI?) async {
        if let target { for id in record.sessions.reversed() { try? await target.deleteSession(id) } }
        if let copy = record.copy { try? await transport.trash(copy, on: record.to) }
        if !record.wasPaused, let original = record.original { try? await transport.remove(original + "/paused", on: record.from) }
        forget(record)
    }

    /// After it switched: the original goes, its conversation saved in its folder (or one of its
    /// own, for a chat that kept none), which goes to the trash where it was. Kept to try again
    /// (`recover`) if its engine couldn't be told.
    private func finish(_ record: Record, exports: [JSONValue]?, source: OpenCodeAPI, leaving bot: Bot?) async {
        var place = record.original
        if place == nil, let home = try? await transport.home(on: record.from) { place = home.root + "/moved-" + record.id }
        if let place, let exports, let data = Self.data(.array(exports)) {
            try? await transport.write(data, to: place + "/conversation.json", on: record.from)
        }
        var gone = true
        for id in record.sessions.reversed() {
            do {
                try await source.deleteSession(id)
            } catch let error as ServerError where error.status == 404 {
                // Gone already.
            } catch {
                gone = false
                log.error("A moved conversation's original stayed where it was: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard gone else { return }
        if let place { try? await transport.trash(place, on: record.from) }
        if let bot { await BotKeys.leave(bot, app: app) }
        forget(record)
    }

    /// Moves cut short (the app quit, a computer away): those that switched finish, the rest are
    /// taken back, once both computers are there. At launch, and as a machine connects.
    func recover() async {
        noteMovedAway(records)
        for record in records where underWay[record.id] == nil {
            guard let source = api(on: record.from), let target = api(on: record.to) else { continue }
            switch record.stage {
            case .copying:
                await takeBack(record, target: target)
            case .switched:
                let exports = try? await exportAll(record.sessions[0], from: source)
                await finish(record, exports: exports, source: source, leaving: nil)
            }
        }
    }

    // MARK: Plumbing

    /// The engine on `machine` (nil: this Mac's), while it's up.
    private func api(on machine: String?) -> OpenCodeAPI? {
        guard let machine else { return app?.workspace.api }
        if let engine = app?.machines.engine(machine) { return engine.isReady ? engine.api : nil }
        return app?.workspace.machineAPI(machine)
    }

    /// Copies `path` (a folder) from where it is into `parent` on `machine`, through an archive in
    /// Kuvo Code's temporary folder, gone once it's there.
    private func copy(_ path: String, from source: String?, into parent: String, on machine: String?) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: AppInfo.bundleID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appending(path: "move-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: archive) }
        try await transport.pack(path, on: source, into: archive)
        try await transport.unpack(archive, into: parent, on: machine)
    }

    private static func data(_ exported: JSONValue) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(exported)
    }
}

/// Kuvo Code's folders on a computer, as that computer writes them: where bots, sessions' wake-ups
/// and chats are kept.
struct MoveHome: Equatable {
    var root: String
    var bots: String
    var wakes: String
    var chats: String
}

/// How a move's files get from one computer to another (`Moves`).
protocol MoveTransport {
    /// Kuvo Code's folders on `machine` (nil: this Mac), made if they aren't there.
    func home(on machine: String?) async throws -> MoveHome
    func exists(_ path: String, on machine: String?) async throws -> Bool
    /// `path` (a folder) as an archive at `archive`, named by its last part.
    func pack(_ path: String, on machine: String?, into archive: URL) async throws
    /// What `archive` holds, unpacked in `parent`.
    func unpack(_ archive: URL, into parent: String, on machine: String?) async throws
    /// `path` to the trash: this Mac's, or Kuvo Code's trash folder on `machine`.
    func trash(_ path: String, on machine: String?) async throws
    func write(_ data: Data, to path: String, on machine: String?) async throws
    /// A file, if it's there.
    func remove(_ path: String, on machine: String?) async throws
}

/// This Mac's folders, and a machine's over SSH, in `~/.kuvo-code`.
nonisolated struct SSHMoveTransport: MoveTransport {
    private var root: String { RemoteEngineInstaller.root }

    func home(on machine: String?) async throws -> MoveHome {
        guard let machine else {
            return MoveHome(root: AppInfo.supportDirectory.path, bots: Bots.root.path, wakes: WakeUps.root.path, chats: Workspace.chatsFolder)
        }
        let output = try await SSHConnection(destination: machine).run("""
            K="$HOME/\(root)"; mkdir -p "$K/bots" "$K/wakes" "$K/chats" "$K/trash" && chmod 700 "$K" && cd "$K" && pwd
            """)
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { throw URLError(.cannotOpenFile) }
        return MoveHome(root: path, bots: path + "/bots", wakes: path + "/wakes", chats: path + "/chats")
    }

    func exists(_ path: String, on machine: String?) async throws -> Bool {
        guard let machine else { return FileManager.default.fileExists(atPath: path) }
        let output = try await SSHConnection(destination: machine).run("[ -e \(SSHConnection.quoted(path)) ] && echo yes || echo no")
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
    }

    func pack(_ path: String, on machine: String?, into archive: URL) async throws {
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        guard let machine else {
            // Without this Mac's own metadata (extended attributes, ACLs), which Linux's tar
            // doesn't know.
            try await Self.tar(["--no-xattrs", "--no-mac-metadata", "--no-acls", "--no-fflags", "--format", "gnutar", "-C", parent, "-cf", archive.path, name])
            return
        }
        try await SSHConnection(destination: machine).run("cd \(SSHConnection.quoted(parent)) && tar -cf - \(SSHConnection.quoted(name))", output: archive)
    }

    func unpack(_ archive: URL, into parent: String, on machine: String?) async throws {
        guard let machine else {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try await Self.tar(["-C", parent, "-xf", archive.path])
            return
        }
        try await SSHConnection(destination: machine).run("mkdir -p \(SSHConnection.quoted(parent)) && tar -xf - -C \(SSHConnection.quoted(parent))", input: archive)
    }

    func trash(_ path: String, on machine: String?) async throws {
        guard let machine else {
            guard FileManager.default.fileExists(atPath: path) else { return }
            try FileManager.default.moveToTrash(URL(filePath: path))
            return
        }
        try await SSHConnection(destination: machine).run("""
            P=\(SSHConnection.quoted(path)); T="$HOME/\(root)/trash/$(date +%Y%m%d-%H%M%S)-$$"
            [ ! -e "$P" ] || { mkdir -p "$T" && mv -- "$P" "$T/"; }
            """)
    }

    func write(_ data: Data, to path: String, on machine: String?) async throws {
        guard let machine else {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(filePath: path), options: .atomic)
            return
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: AppInfo.bundleID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appending(path: "move-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: input) }
        FileManager.default.createFile(atPath: input.path, contents: data, attributes: [.posixPermissions: 0o600])
        let quoted = SSHConnection.quoted(path)
        try await SSHConnection(destination: machine).run("mkdir -p \"$(dirname \(quoted))\" && (umask 077; cat >\(quoted).new) && mv -f \(quoted).new \(quoted)", input: input)
    }

    func remove(_ path: String, on machine: String?) async throws {
        guard let machine else {
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
            return
        }
        try await SSHConnection(destination: machine).run("rm -f \(SSHConnection.quoted(path))")
    }

    /// This Mac's tar, as it is.
    private static func tar(_ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tar")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["COPYFILE_DISABLE"] = "1"
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "tar", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "tar failed (\(status))" : message])
        }
    }
}
