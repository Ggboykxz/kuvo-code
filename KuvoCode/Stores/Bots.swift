import AppKit
import OpenCodeKit
import os

/// A bot: a teammate with a name, a look and one job. It keeps one conversation (an engine
/// session) on this Mac or on one of your machines, remembers what it learns in a file of its own,
/// and can schedule its own wake-ups to carry on later. You start its work by writing to it.
struct Bot: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    /// What it does, in a few words, under its name: "Keeps CI green".
    var job: String
    /// How to do the job: what to watch, what to make, what never to do.
    var instructions: String
    var look: BotLook
    /// The machine it lives on; nil for this Mac.
    var machine: String?
    /// The project folder it works in, the app's way of writing it; nil for a folder of its own.
    var project: String?
    /// Its own folder, as the engine where it lives knows it: its memory, wake-ups and workspace.
    var folder: String
    /// Its conversation.
    var sessionID: String
    var created: Date

    /// Where its session runs, the app's way of writing it.
    var directory: String {
        project ?? app((folder as NSString).appendingPathComponent("workspace"))
    }

    var memoryFile: String { (folder as NSString).appendingPathComponent("MEMORY.md") }

    /// A path in its folder, the app's way: on its machine, or here.
    func app(_ path: String) -> String {
        machine.map { RemoteFolder.folder(path, on: $0) } ?? path
    }
}

/// Your bots, kept in `bots.json`, and the wake-ups of the ones on this Mac.
@Observable
final class Bots {
    private(set) var list: [Bot] = []
    /// Each bot's waiting wake-ups, as last read.
    private(set) var wakes: [String: [Wakes.Pending]] = [:]
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var waking: Task<Void, Never>?
    /// Bots whose session has this version's instructions.
    @ObservationIgnored private var synced: Set<String> = []
    private let log = Logger(subsystem: "run.kuvo.code", category: "bots")

    /// The key under which a bot's job goes to its session.
    static let instructionKey = "kuvo.bot"
    private static var file: URL { AppInfo.supportDirectory.appending(path: "bots.json") }
    /// This Mac's bots' folders.
    static var root: URL { AppInfo.supportDirectory.appending(path: "bots") }
    /// The wake-up command on this Mac.
    static var command: URL { AppInfo.supportDirectory.appending(path: "bin/kuvo-wake") }
    /// The wake-up command on a machine.
    static let machineCommand = "$HOME/\(RemoteEngineInstaller.root)/bin/kuvo-wake"

    init() {
        list = Self.load()
    }

    func bot(_ id: String?) -> Bot? {
        id.flatMap { id in list.first { $0.id == id } }
    }

    func bot(forSession id: String?) -> Bot? {
        id.flatMap { id in list.first { $0.sessionID == id } }
    }

    var sessionIDs: Set<String> { Set(list.map(\.sessionID)) }

    // MARK: Making, changing, deleting

    enum Failure: LocalizedError {
        case notConnected(String)
        case noFolder
        var errorDescription: String? {
            switch self {
            case .notConnected(let machine): "\(machine) isn’t connected. Connect to it, then try again."
            case .noFolder: "Couldn’t make the bot’s folder."
            }
        }
    }

    /// Makes a bot: its folder where it lives, its session there with its job, and its place in
    /// the list.
    func create(name: String, job: String, instructions: String, look: BotLook, machine: String?, project: String?) async throws -> Bot {
        guard let app else { throw CancellationError() }
        let id = "bot_" + String((0..<10).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        let folder: String
        if let machine {
            guard let engine = app.machines.engine(machine), engine.isReady else { throw Failure.notConnected(machine) }
            try await Wakes.install(on: engine.machine.connection)
            let made = try await engine.machine.connection.run("""
                B="$HOME/\(RemoteEngineInstaller.root)/bots/\(id)"
                mkdir -p "$B/workspace" "$B/wakes" && cd "$B" || exit 1
                [ -f MEMORY.md ] || printf '%s' \(SSHConnection.quoted(Self.blankMemory(name))) >MEMORY.md
                pwd
                """).trimmingCharacters(in: .whitespacesAndNewlines)
            guard made.hasPrefix("/") else { throw Failure.noFolder }
            folder = made
        } else {
            let url = Self.root.appending(path: id)
            try FileManager.default.createDirectory(at: url.appending(path: "workspace"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: url.appending(path: "wakes"), withIntermediateDirectories: true)
            try Self.installCommand()
            try Data(Self.blankMemory(name).utf8).write(to: url.appending(path: "MEMORY.md"))
            folder = url.path
        }

        var bot = Bot(id: id, name: name, job: job, instructions: instructions, look: look, machine: machine, project: project, folder: folder, sessionID: "", created: .now)
        guard let api = app.workspace.api(forFolder: bot.directory) else { throw Failure.notConnected(machine ?? AppInfo.name) }
        let approval = UserDefaults.standard.string(forKey: ToolApproval.key).flatMap(ToolApproval.init) ?? .approveAll
        // Its own folder is its to read and write, wherever it works, and its wake-ups never ask.
        let full = machine == nil ? Self.command.path : Self.machineCommand
        let rules = approval.rules + [
            PermissionRule(action: "external_directory", resource: (folder as NSString).appendingPathComponent("*"), effect: .allow),
            PermissionRule(action: "shell", resource: "kuvo-wake \(id) *", effect: .allow),
            PermissionRule(action: "shell", resource: "\"\(full)\" \(id) *", effect: .allow),
        ]
        let catalog = machine.flatMap { app.machines.engine($0)?.catalog } ?? app.catalog
        let model = Self.lastModel.flatMap { catalog.model($0) != nil ? $0 : nil }
        let session = try await api.createSession(directory: bot.directory, title: name, model: model, permissions: rules)
        bot.sessionID = session.id
        try? await api.setMetadata(session: session.id, .object(["kuvo": .object(["bot": .string(id)])]))
        try await api.setInstruction(session: session.id, key: Self.instructionKey, text: Self.instructions(for: bot))
        try await writeSession(of: bot)

        list.append(bot)
        save()
        app.workspace.add(session)
        app.workspace.botSessions = sessionIDs
        Analytics.shared.track("bot_created", ["machine": machine != nil, "project": project != nil])
        return bot
    }

    /// Saves a change to a bot, and tells its session about a new name or job.
    func update(_ bot: Bot) async {
        guard let index = list.firstIndex(where: { $0.id == bot.id }) else { return }
        let old = list[index]
        list[index] = bot
        save()
        guard old.name != bot.name || old.job != bot.job || old.instructions != bot.instructions,
              let api = app?.workspace.api(forFolder: bot.directory) else { return }
        try? await api.setInstruction(session: bot.sessionID, key: Self.instructionKey, text: Self.instructions(for: bot))
        if old.name != bot.name { try? await api.renameSession(bot.sessionID, title: bot.name) }
    }

    /// Deletes a bot: its conversation, its folder and its wake-ups. A project it worked in stays.
    func delete(_ bot: Bot) async {
        list.removeAll { $0.id == bot.id }
        save()
        wakes[bot.id] = nil
        app?.workspace.botSessions = sessionIDs
        await app?.workspace.delete(bot.sessionID)
        if let machine = bot.machine {
            let folder = bot.folder
            _ = await Task.detached { RemoteShell.run("rm -rf \(SSHConnection.quoted(folder))", on: machine) }.value
        } else {
            try? FileManager.default.removeItem(atPath: bot.folder)
        }
        Analytics.shared.track("bot_deleted")
    }

    // MARK: Wake-ups

    /// Reads a bot's waiting wake-ups.
    func readWakes(_ bot: Bot) async {
        if bot.machine == nil {
            wakes[bot.id] = Self.localWakes(of: bot)
            return
        }
        guard let machine = bot.machine else { return }
        let folder = (bot.folder as NSString).appendingPathComponent("wakes")
        // One line each: the file's name, a tab, the note on one line.
        let script = "for f in \(SSHConnection.quoted(folder))/*; do [ -f \"$f\" ] && printf '%s\\t%s\\n' \"${f##*/}\" \"$(tr '\\n' ' ' <\"$f\" | head -c 400)\"; done; true"
        let output = await Task.detached { RemoteShell.run(script, on: machine) }.value
        let lines = output.map { String(decoding: $0, as: UTF8.self) }?.split(separator: "\n") ?? []
        wakes[bot.id] = lines.compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.first.flatMap { Wakes.Pending(id: $0, note: parts.count > 1 ? parts[1] : "") }
        }
        .sorted { $0.due < $1.due }
    }

    func cancelWake(_ wake: Wakes.Pending, of bot: Bot) async {
        let file = ((bot.folder as NSString).appendingPathComponent("wakes") as NSString).appendingPathComponent(wake.id)
        if let machine = bot.machine {
            _ = await Task.detached { RemoteShell.run("rm -f \(SSHConnection.quoted(file))", on: machine) }.value
        } else {
            try? FileManager.default.removeItem(atPath: file)
        }
        wakes[bot.id]?.removeAll { $0.id == wake.id }
    }

    /// Sends this Mac's bots' wake-ups as they come due, while the app runs; ones missed while it
    /// wasn't running go as soon as it is. (A machine's engine sends its bots' own.)
    func startWaking() {
        guard waking == nil else { return }
        try? Self.installCommand()
        // Bots made before their memory file was made with them.
        for bot in list where bot.machine == nil && !FileManager.default.fileExists(atPath: bot.memoryFile) {
            try? Data(Self.blankMemory(bot.name).utf8).write(to: URL(filePath: bot.memoryFile))
        }
        waking = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncInstructions()
                await self?.wakeDue()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func wakeDue() async {
        guard let api = app?.api else { return }
        for bot in list where bot.machine == nil {
            let pending = Self.localWakes(of: bot)
            for wake in pending where wake.due <= .now {
                do {
                    try await api.prompt(session: bot.sessionID, id: Identifier.message(), text: Wakes.marker + wake.note, delivery: .queue)
                    try? FileManager.default.removeItem(atPath: ((bot.folder as NSString).appendingPathComponent("wakes") as NSString).appendingPathComponent(wake.id))
                } catch {
                    log.error("A wake-up for \(bot.id, privacy: .public) didn't go: \(error.localizedDescription, privacy: .public)")
                }
            }
            let left = Self.localWakes(of: bot)
            if wakes[bot.id] != left { wakes[bot.id] = left }
        }
    }

    private static func localWakes(of bot: Bot) -> [Wakes.Pending] {
        let folder = (bot.folder as NSString).appendingPathComponent("wakes")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.compactMap { name in
            let note = (try? String(contentsOfFile: (folder as NSString).appendingPathComponent(name), encoding: .utf8)) ?? ""
            return Wakes.Pending(id: name, note: note)
        }
        .sorted { $0.due < $1.due }
    }

    /// Puts `kuvo-wake` in the app's folder, as the engine on a machine has it.
    private static func installCommand() throws {
        let data = Data(Wakes.script.utf8)
        if (try? Data(contentsOf: command)) == data { return }
        try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: command, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
    }

    /// Writes the bot's session in its folder, where `kuvo-wake fire` reads it on a machine.
    private func writeSession(of bot: Bot) async throws {
        let file = (bot.folder as NSString).appendingPathComponent("session")
        if let machine = bot.machine {
            let script = "printf '%s' \(SSHConnection.quoted(bot.sessionID)) >\(SSHConnection.quoted(file))"
            guard await Task.detached(operation: { RemoteShell.run(script, on: machine) }).value != nil else { throw Failure.noFolder }
        } else {
            try Data(bot.sessionID.utf8).write(to: URL(filePath: file))
        }
    }

    // MARK: Its job, for the engine

    /// A new bot's memory file, so there's one to read from the start.
    static func blankMemory(_ name: String) -> String {
        "# \(name)'s memory\n\nWhat \(name) keeps for next time: preferences, how things are set up, where ongoing work stands. Nothing yet.\n"
    }

    /// Whether a path is a bot's memory file.
    static func isMemory(_ path: String) -> Bool {
        path.hasSuffix("/MEMORY.md") && path.contains("/bots/bot_")
    }

    /// What the bot's session knows about being a bot: who it is, its job, its memory and how to
    /// wake itself up.
    static func instructions(for bot: Bot) -> String {
        let full = bot.machine == nil ? Self.command.path : machineCommand
        let place = bot.machine.map { "the Linux machine \"\($0)\"" } ?? "this Mac"
        let job = bot.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You are \(bot.name), one of the user's bots in Kuvo Code\(bot.job.isEmpty ? "" : ": \(bot.job)"). A bot is a teammate with one job, \
        who keeps working on it over time in this one conversation. You run on \(place).
        \(job.isEmpty ? "" : "\nYour job:\n\(job)\n")
        You can work on a schedule. Kuvo Code wakes you up at the times you choose, even while the user is away, so you can do \
        things later ("in 2 hours", "tomorrow at 9") or again and again ("every 5 minutes", "every morning"). Never say you can't \
        run in the background, on a timer or on a schedule: schedule a wake-up instead.

        To schedule a wake-up, run:
          kuvo-wake \(bot.id) add <when> "<note to yourself>"
        <when> is +5m, +2h, +1d, or a time like 2026-10-16T09:00 on that computer's clock, at least a minute from now. At that \
        time this conversation gets your note as a new message starting with "\(Wakes.marker.trimmingCharacters(in: .whitespaces))", \
        and you carry on. `kuvo-wake \(bot.id) list` shows what's scheduled; `kuvo-wake \(bot.id) cancel <id>` cancels one. \
        (If kuvo-wake isn't found, it's "\(full)".)

        For something that repeats: do it now, report briefly, and schedule the next run, with a note that says what to do and \
        that it repeats. Each time you wake up, do the work, report briefly, and schedule the next run again, until the user says \
        to stop or the job is done. Keep reports short; the user reads them later.

        Memory: the file "\(bot.memoryFile)" is yours. Read it when you start a piece of work. Keep in it what you'll need next \
        time: lasting preferences, how things are set up, where ongoing work stands, and any schedule you're keeping. Keep it short \
        and current; check facts at their source rather than trusting it.

        The user is usually away while you work. When you need them (a sign-in, a decision, something only they can do), \
        say so plainly in a short message and stop.
        """
    }

    /// Gives each bot's session the current wording of its instructions, once a run of the app,
    /// as its engine comes up: bots made by an older version learn what this one can do.
    func syncInstructions() async {
        for bot in list where !synced.contains(bot.id) {
            guard let api = app?.workspace.api(forFolder: bot.directory) else { continue }
            if (try? await api.setInstruction(session: bot.sessionID, key: Self.instructionKey, text: Self.instructions(for: bot))) != nil {
                synced.insert(bot.id)
            }
        }
    }

    // MARK: Storage

    private static var lastModel: ModelRef? {
        let parts = (UserDefaults.standard.string(forKey: "lastModel") ?? "").split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        return ModelRef(id: parts[1], providerID: parts[0], variant: parts.count > 2 ? parts[2] : nil)
    }

    private static func load() -> [Bot] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Bot].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: AppInfo.supportDirectory, withIntermediateDirectories: true)
            try encoder.encode(list).write(to: Self.file, options: .atomic)
        } catch {
            log.error("Bots weren't saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
