import Foundation
import OpenCodeKit
import os

/// Moving a bot or a chat to another computer: this Mac, or one of your machines, say a new one
/// you've set up. It goes whole (a bot with its memory, workspace, wake-ups and watches; a chat
/// with its wake-ups), with its conversation, which carries on there under the same ID. Nothing of
/// the original is touched until the copy is set up where it's going; then the original stops
/// (its wake-ups too) and goes to the trash where it was (the Mac's Trash, or Kuvo Code's trash
/// folder on its machine), with its conversation saved beside it as `conversation.json`, so
/// nothing runs twice and it can still be brought back. A move that fails part way takes back
/// what it made and leaves the original as it was.
@MainActor @Observable
final class Moves {
    /// What's moving now, a bot's ID or a chat's session ID, and where to (nil: this Mac): its
    /// row says so.
    private(set) var underWay: [String: String?] = [:]
    @ObservationIgnored weak var app: AppModel?
    /// How files get where they're going: over SSH, or (in tests) a folder standing in for a machine.
    @ObservationIgnored var transport: any MoveTransport = SSHMoveTransport()
    private let log = Logger(subsystem: "run.kuvo.code", category: "moves")

    enum Failure: LocalizedError {
        case notConnected(String)
        case working(String)
        case inProject(String)
        case withAgents(String)
        case waiting(String)
        var errorDescription: String? {
            switch self {
            case .notConnected(let place): "\(place) isn’t connected. Connect to it, then try again."
            case .working(let name): "\(name) is working. Move it once it’s done."
            case .inProject(let name): "\(name) works in one of your projects, which stays where it is. Only a bot with a folder of its own can move."
            case .withAgents(let name): "\(name) talks with a coding agent, which keeps its conversation on this computer, so it can’t move yet."
            case .waiting(let name): "Messages are waiting to go to \(name). Send or remove them first."
            }
        }
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
        underWay[id] = .some(machine)
        defer { underWay[id] = nil }

        let home = try await transport.home(on: machine)
        let folder = home.bots + "/" + bot.id
        // Its wake-ups wait while it moves (as Pause does), so none goes on the way, and none twice.
        let pause = bot.folder + "/paused"
        let wasPaused = try await transport.exists(pause, on: bot.machine)
        if !wasPaused { try await transport.write(Data("paused".utf8), to: pause, on: bot.machine) }
        var made: (folder: Bool, session: Bool) = (false, false)
        let exported: JSONValue
        let session: Session
        do {
            exported = try await source.exportSession(bot.sessionID)
            // One left there by a move that didn't finish is put away first.
            if try await transport.exists(folder, on: machine) { try await transport.trash(folder, on: machine) }
            try await copy(bot.folder, from: bot.machine, into: home.bots, on: machine)
            made.folder = true
            var moved = bot
            moved.machine = machine
            moved.folder = folder
            session = try await target.importSession(exported: exported, directory: moved.directory)
            made.session = true
            if !wasPaused { try await transport.remove(folder + "/paused", on: machine) }
        } catch {
            if made.session { try? await target.deleteSession(bot.sessionID) }
            if made.folder { try? await transport.trash(folder, on: machine) }
            if !wasPaused { try? await transport.remove(pause, on: bot.machine) }
            log.error("A bot didn't move: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        // It's there: the original stops. Its seats in group chats go (new ones are made where it
        // is now), its conversation goes from its engine, and its folder, with the conversation
        // saved in it, to the trash where it was.
        await app.groups.botMoving(bot)
        if let data = Self.data(exported) { try? await transport.write(data, to: bot.folder + "/conversation.json", on: bot.machine) }
        do { try await source.deleteSession(bot.sessionID) } catch { log.error("A moved bot's conversation stayed where it was: \(error.localizedDescription, privacy: .public)") }
        do { try await transport.trash(bot.folder, on: bot.machine) } catch { log.error("A moved bot's folder stayed where it was: \(error.localizedDescription, privacy: .public)") }
        await BotKeys.leave(bot, app: app)
        if bot.machine == nil { app.utilities.closeTabs(of: bot.id) }
        app.wakeUps.forget(key: bot.id)
        await app.bots.moved(id, to: machine, folder: folder, session: session, api: target)
        if let moved = app.bots.bot(id) {
            await BotKeys.apply(to: moved, app: app)
            await app.wakeUps.read(moved.wakeOwner)
        }
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
        if let waiting = try? await source.inbox(session: id), !waiting.isEmpty { throw Failure.waiting(name) }
        underWay[id] = .some(machine)
        defer { underWay[id] = nil }

        let there = try await transport.home(on: machine)
        let here = try await transport.home(on: from)
        let directory = machine.map { RemoteFolder.folder(there.chats, on: $0) } ?? there.chats
        let wakes = here.wakes + "/" + id
        let hasWakes = try await transport.exists(wakes, on: from)
        let pause = wakes + "/paused"
        let wasPaused = hasWakes ? try await transport.exists(pause, on: from) : false
        if hasWakes, !wasPaused { try await transport.write(Data("paused".utf8), to: pause, on: from) }
        var made: (wakes: Bool, session: Bool) = (false, false)
        let exported: JSONValue
        let session: Session
        do {
            exported = try await source.exportSession(id)
            if hasWakes {
                let moved = there.wakes + "/" + id
                if try await transport.exists(moved, on: machine) { try await transport.trash(moved, on: machine) }
                try await copy(wakes, from: from, into: there.wakes, on: machine)
                made.wakes = true
                // Where its watches' checks run there.
                try await transport.write(Data(there.chats.utf8), to: moved + "/directory", on: machine)
                if !wasPaused { try await transport.remove(moved + "/paused", on: machine) }
            }
            session = try await target.importSession(exported: exported, directory: directory)
            made.session = true
        } catch {
            if made.session { try? await target.deleteSession(id) }
            if made.wakes { try? await transport.trash(there.wakes + "/" + id, on: machine) }
            if hasWakes, !wasPaused { try? await transport.remove(pause, on: from) }
            log.error("A chat didn't move: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        // It's there: the original goes, its conversation saved in the trash where it was.
        if let data = Self.data(exported) {
            let kept = hasWakes ? wakes : here.root + "/moved-" + id
            try? await transport.write(data, to: kept + "/conversation.json", on: from)
            try? await transport.trash(kept, on: from)
        }
        do { try await source.deleteSession(id) } catch { log.error("A moved chat stayed where it was too: \(error.localizedDescription, privacy: .public)") }
        app.wakeUps.forget(key: id)
        app.workspace.add(session)
        await app.wakeUps.read(WakeUps.owner(of: session))
        Analytics.shared.track("chat_moved_computer", ["to": machine == nil ? "mac" : "machine"])
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
