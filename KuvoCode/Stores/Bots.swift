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
    /// The model it uses unless you pick another in its conversation: in group chats, and for
    /// its conversation when it's made. Nil for one made before bots had one.
    var model: ModelRef?
    /// How it talks (a `Personality`'s ID); nil for the model's own way.
    var personality: String?

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
    /// Each bot's watches, as last read.
    private(set) var watches: [String: [Wakes.Watch]] = [:]
    /// Bots whose wake-ups you paused: they wait until you resume them.
    private(set) var paused: Set<String> = []
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var waking: Task<Void, Never>?
    /// Bots whose session has this version's instructions.
    @ObservationIgnored private var synced: Set<String> = []
    /// Machines given this copy's kuvo-wake since launch.
    @ObservationIgnored private var wakeInstalled: Set<String> = []
    private let log = Logger(subsystem: "run.kuvo.code", category: "bots")

    /// The key under which a bot's job goes to its session.
    static let instructionKey = "kuvo.bot"
    private static var file: URL { AppInfo.supportDirectory.appending(path: "bots.json") }
    /// This Mac's bots' folders.
    static var root: URL { AppInfo.supportDirectory.appending(path: "bots") }
    /// The wake-up command on this Mac.
    static var command: URL { AppInfo.supportDirectory.appending(path: "bin/kuvo-wake") }
    /// The wake-up command on a machine.
    static var machineCommand: String { "$HOME/\(RemoteEngineInstaller.root)/bin/kuvo-wake" }

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

    /// The bot a session acts for: its own conversation, or its seat in a group chat.
    func bot(actingAs id: String?) -> Bot? {
        guard let id else { return nil }
        if let bot = bot(forSession: id) { return bot }
        return bot(app?.groups.group(seat: id)?.seats.first { $0.value == id }?.key)
    }

    /// What the bot is up to, for how its avatar moves: waiting for you comes first, then working,
    /// then news you haven't seen, then asleep until a wake-up.
    func mood(of bot: Bot, in workspace: Workspace) -> BotMood {
        #if DEBUG
        // KUVO_DEMO_BOT_MOODS=<name>=<mood>,…: bots shown in a mood, for screenshots and videos.
        if let moods = ProcessInfo.processInfo.environment["KUVO_DEMO_BOT_MOODS"] {
            for pair in moods.split(separator: ",") {
                let parts = pair.split(separator: "=").map(String.init)
                if parts.count == 2, parts[0] == bot.name {
                    switch parts[1] {
                    case "working": return .working
                    case "waiting": return .waiting
                    case "news": return .news
                    case "sleeping": return .sleeping
                    case "watching": return .watching
                    default: return .idle
                    }
                }
            }
        }
        #endif
        if workspace.needsAttention(bot.sessionID) { return .waiting }
        if workspace.running.contains(bot.sessionID) { return .working }
        if workspace.session(bot.sessionID)?.isUnread == true { return .news }
        if wakes[bot.id]?.isEmpty == false { return .sleeping }
        if watches[bot.id]?.isEmpty == false { return .watching }
        return .idle
    }

    // MARK: Making, changing, deleting

    enum Failure: LocalizedError {
        case notConnected(String)
        case noFolder
        case tooSoon
        case tooMany
        case noWake
        var errorDescription: String? {
            switch self {
            case .notConnected(let machine): "\(machine) isn’t connected. Connect to it, then try again."
            case .noFolder: "Couldn’t make the bot’s folder."
            case .tooSoon: "Pick a time at least a minute from now."
            case .tooMany: "This bot has \(Wakes.limit) wake-ups waiting. Cancel some first."
            case .noWake: "Couldn’t add the wake-up. Check that the machine is connected, then try again."
            }
        }
    }

    /// Makes a bot: its folder where it lives, its session there with its job, and its place in
    /// the list.
    func create(name: String, job: String, instructions: String, look: BotLook, personality: String? = nil, model: ModelRef?, machine: String?, project: String?) async throws -> Bot {
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
        bot.personality = personality
        guard let api = app.workspace.api(forFolder: bot.directory) else { throw Failure.notConnected(machine ?? AppInfo.name) }
        let approval = UserDefaults.standard.string(forKey: ToolApproval.key).flatMap(ToolApproval.init) ?? .approveAll
        let rules = approval.rules + Self.ownRules(for: bot)
        let catalog = machine.flatMap { app.machines.engine($0)?.catalog } ?? app.catalog
        // The one picked, if the engine where it lives has it; otherwise the last one used.
        bot.model = [model, Self.lastModel].compactMap { $0 }.first { catalog.model($0) != nil }
        let session = try await api.createSession(directory: bot.directory, title: name, model: bot.model, permissions: rules)
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

    /// Saves a change to a bot, and tells its session about a new name, job or model; its group
    /// chats hear about them too.
    func update(_ bot: Bot) async {
        guard let index = list.firstIndex(where: { $0.id == bot.id }) else { return }
        let old = list[index]
        list[index] = bot
        save()
        guard let api = app?.workspace.api(forFolder: bot.directory) else { return }
        if old.name != bot.name || old.job != bot.job || old.instructions != bot.instructions || old.personality != bot.personality {
            try? await api.setInstruction(session: bot.sessionID, key: Self.instructionKey, text: Self.instructions(for: bot))
            if old.name != bot.name { try? await api.renameSession(bot.sessionID, title: bot.name) }
            await app?.groups.botChanged(bot)
        }
        // A new default model applies to its conversation too; you can still pick another there.
        if old.model != bot.model, let model = bot.model {
            try? await api.selectModel(session: bot.sessionID, model: model)
            await app?.groups.modelChanged(of: bot)
        }
    }

    /// Deletes a bot: its conversation, its folder and its wake-ups. A project it worked in stays.
    func delete(_ bot: Bot) async {
        await app?.groups.remove(bot)
        list.removeAll { $0.id == bot.id }
        save()
        wakes[bot.id] = nil
        app?.utilities.closeTabs(of: bot.id)
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

    /// A personality you changed or deleted: the bots with it hear the new words, or go back to
    /// their own way.
    func personalityChanged(_ id: String) async {
        for var bot in list where bot.personality == id {
            if Personalities.shared.personality(id) == nil { bot.personality = nil }
            // Saved even when unchanged, so its session hears the new wording.
            if let index = list.firstIndex(where: { $0.id == bot.id }) { list[index] = bot }
            save()
            guard let api = app?.workspace.api(forFolder: bot.directory) else { continue }
            try? await api.setInstruction(session: bot.sessionID, key: Self.instructionKey, text: Self.instructions(for: bot))
            await app?.groups.botChanged(bot)
        }
    }

    // MARK: Wake-ups

    /// Reads a bot's waiting wake-ups.
    func readWakes(_ bot: Bot) async {
        if bot.machine == nil {
            wakes[bot.id] = Self.localWakes(of: bot)
            let found = Self.localWatches(of: bot)
            if watches[bot.id] != found { watches[bot.id] = found }
            notePaused(bot, FileManager.default.fileExists(atPath: Self.pauseFile(of: bot)))
            return
        }
        guard let machine = bot.machine else { return }
        let folder = (bot.folder as NSString).appendingPathComponent("wakes")
        let watching = (bot.folder as NSString).appendingPathComponent("watches")
        // One line each: the file's name, a tab, the note on one line; "paused" first if it is;
        // then each watch, after "watch" and a tab: its letters, how often, its check and note.
        let one = "tr '\\t\\n' '  '"
        let script = "[ -e \(SSHConnection.quoted(Self.pauseFile(of: bot))) ] && echo paused; for f in \(SSHConnection.quoted(folder))/*; do [ -f \"$f\" ] && printf '%s\\t%s\\n' \"${f##*/}\" \"$(tr '\\n' ' ' <\"$f\" | head -c 400)\"; done; for w in \(SSHConnection.quoted(watching))/*/; do [ -f \"${w}check\" ] && l=${w%/} && printf 'watch\\t%s\\t%s\\t%s\\t%s\\n' \"${l##*/}\" \"$(cat \"${w}every\")\" \"$(\(one) <\"${w}check\" | head -c 300)\" \"$(\(one) <\"${w}note\" | head -c 400)\"; done; true"
        let output = await Task.detached { RemoteShell.run(script, on: machine) }.value
        var lines = output.map { String(decoding: $0, as: UTF8.self) }?.split(separator: "\n") ?? []
        guard output != nil else { return }
        notePaused(bot, lines.first == "paused")
        if lines.first == "paused" { lines.removeFirst() }
        let found = lines.filter { $0.hasPrefix("watch\t") }.compactMap { line -> Wakes.Watch? in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return parts.count >= 5 ? Wakes.Watch(letters: parts[1], every: parts[2], check: parts[3], note: parts[4]) : nil
        }
        if watches[bot.id] != found { watches[bot.id] = found }
        lines.removeAll { $0.hasPrefix("watch\t") }
        wakes[bot.id] = lines.compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.first.flatMap { Wakes.Pending(id: $0, note: parts.count > 1 ? parts[1] : "") }
        }
        .sorted { $0.due < $1.due }
    }

    /// A wake-up you add: at `due`, `note` arrives in the bot's conversation, and again at each
    /// repeat. One on weekdays starts on a weekday.
    func addWake(to bot: Bot, at due: Date, every: Wakes.Repeat?, note: String) async throws {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard due > .now.addingTimeInterval(60) else { throw Failure.tooSoon }
        guard (wakes[bot.id]?.count ?? 0) < Wakes.limit else { throw Failure.tooMany }
        let folder = (bot.folder as NSString).appendingPathComponent("wakes")
        if let machine = bot.machine {
            // Its own kuvo-wake, which knows the machine's clock and its weekends.
            let repeating = every.map { "--every \($0.text) " } ?? ""
            let script = "\"\(Self.machineCommand)\" \(SSHConnection.quoted(bot.folder)) add \(Int(due.timeIntervalSince1970)) \(repeating)\(SSHConnection.quoted(note))"
            guard await Task.detached(operation: { RemoteShell.run(script, on: machine) }).value != nil else { throw Failure.noWake }
            await readWakes(bot)
            return
        }
        var due = due
        let calendar = Calendar.current
        while every == .weekdays, calendar.isDateInWeekend(due), let next = calendar.date(byAdding: .day, value: 1, to: due) { due = next }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let file = (folder as NSString).appendingPathComponent(Wakes.name(due: due, every: every))
        guard FileManager.default.createFile(atPath: file, contents: Data(note.utf8)) else { throw Failure.noWake }
        wakes[bot.id] = Self.localWakes(of: bot)
        Analytics.shared.track("bot_wake_added", ["repeats": every != nil])
    }

    /// Cancels a wake-up by its letters, which a repeating one keeps as its time moves on (it may
    /// have come back since it was listed).
    func cancelWake(_ wake: Wakes.Pending, of bot: Bot) async {
        let folder = (bot.folder as NSString).appendingPathComponent("wakes")
        let letters = wake.letters
        // As kuvo-wake names them; anything else isn't one of its wake-ups (or safe in a command).
        guard !letters.isEmpty, letters.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return }
        if let machine = bot.machine {
            let base = SSHConnection.quoted(folder)
            _ = await Task.detached { RemoteShell.run("rm -f \(base)/*-\(letters) \(base)/*-\(letters)-*", on: machine) }.value
        } else {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where Wakes.Pending(id: name, note: "")?.letters == letters {
                try? FileManager.default.removeItem(atPath: (folder as NSString).appendingPathComponent(name))
            }
        }
        wakes[bot.id]?.removeAll { $0.letters == letters }
    }

    /// Stops a watch.
    func cancelWatch(_ watch: Wakes.Watch, of bot: Bot) async {
        let letters = watch.letters
        guard !letters.isEmpty, letters.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return }
        let folder = ((bot.folder as NSString).appendingPathComponent("watches") as NSString).appendingPathComponent(letters)
        if let machine = bot.machine {
            _ = await Task.detached { RemoteShell.run("rm -rf \(SSHConnection.quoted(folder))", on: machine) }.value
        } else {
            try? FileManager.default.removeItem(atPath: folder)
        }
        watches[bot.id]?.removeAll { $0.letters == letters }
    }

    /// Runs a watch's check now, as its own run would (in the bot's folder, for at most a minute),
    /// and returns what it prints, without counting it as a run.
    func tryCheck(_ watch: Wakes.Watch, of bot: Bot) async -> String {
        let folder = bot.machine.map { _ in RemoteFolder.parse(bot.directory)?.path ?? bot.directory } ?? bot.directory
        let script = "cd \(SSHConnection.quoted(folder)) 2>/dev/null || cd \(SSHConnection.quoted(bot.folder)); "
            + "if command -v timeout >/dev/null 2>&1; then timeout 60 sh -c \(SSHConnection.quoted(watch.check)); else sh -c \(SSHConnection.quoted(watch.check)); fi 2>&1 </dev/null | head -c 4000"
        if let machine = bot.machine {
            let output = await Task.detached { RemoteShell.run(script, on: machine) }.value
            return output.map { String(decoding: $0, as: UTF8.self) } ?? "Couldn’t reach \(machine)."
        }
        let environment = app?.shellEnvironment ?? ProcessInfo.processInfo.environment
        return await Task.detached { () -> String in
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = ["-c", script]
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            guard (try? process.run()) != nil else { return "" }
            let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: stop)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            stop.cancel()
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    private static func localWatches(of bot: Bot) -> [Wakes.Watch] {
        let folder = (bot.folder as NSString).appendingPathComponent("watches")
        let read = { (watch: String, file: String) in
            (try? String(contentsOfFile: ((folder as NSString).appendingPathComponent(watch) as NSString).appendingPathComponent(file), encoding: .utf8)) ?? ""
        }
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted().compactMap { letters in
            let check = read(letters, "check")
            return check.isEmpty ? nil : Wakes.Watch(letters: letters, every: read(letters, "every"), check: check, note: read(letters, "note"))
        }
    }

    /// This Mac's bots' watches, run while the app does, beside their wake-ups (so a slow check
    /// never holds one up): what changed wakes the bot, and one that can't go is tried again at its
    /// next check.
    @ObservationIgnored private var watching: Task<Void, Never>?

    private func watchDue() {
        guard watching == nil, let api = app?.api else { return }
        watching = Task { [weak self] in
            guard let self else { return }
            for bot in list where bot.machine == nil && !FileManager.default.fileExists(atPath: Self.pauseFile(of: bot)) {
                for letters in await dueWatches(of: bot) {
                    guard let message = Wakes.watchMessage(letters, inBot: bot.folder) else { continue }
                    await api.waitForTools(in: bot.directory)
                    do {
                        try await api.prompt(session: bot.sessionID, id: Identifier.message(), text: Wakes.marker + message, delivery: .queue)
                        Wakes.watchDelivered(letters, inBot: bot.folder)
                    } catch {
                        log.error("A watch's wake-up for \(bot.id, privacy: .public) didn't go: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            watching = nil
        }
    }

    /// Runs this Mac's bot's watches that are due (kuvo-wake does), in your shell's environment:
    /// the letters of those that saw a change.
    private func dueWatches(of bot: Bot) async -> [String] {
        guard FileManager.default.fileExists(atPath: (bot.folder as NSString).appendingPathComponent("watches")) else { return [] }
        let environment = app?.shellEnvironment ?? ProcessInfo.processInfo.environment
        let command = Self.command.path
        let folder = bot.folder
        let output = await Task.detached { () -> String in
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = [command, folder, "check"]
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            // Each check stops after a minute; the lot, after a few.
            let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: stop)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            stop.cancel()
            return String(decoding: data, as: UTF8.self)
        }.value
        return Wakes.changedWatches(in: output)
    }

    // MARK: Pausing

    /// A file in the bot's folder that, while it's there, holds its wake-ups: on this Mac, and on
    /// a machine, where the watchdog skips it.
    static func pauseFile(of bot: Bot) -> String {
        (bot.folder as NSString).appendingPathComponent("paused")
    }

    /// Holds a bot's wake-ups until you resume it; then those that came due meanwhile go.
    func setPaused(_ pause: Bool, _ bot: Bot) async {
        let file = Self.pauseFile(of: bot)
        if let machine = bot.machine {
            // A machine's kuvo-wake from before pausing would send them anyway.
            if pause, let engine = app?.machines.engine(machine) { try? await Wakes.install(on: engine.machine.connection) }
            let script = pause ? ": > \(SSHConnection.quoted(file))" : "rm -f \(SSHConnection.quoted(file))"
            guard await Task.detached(operation: { RemoteShell.run(script, on: machine) }).value != nil else { return }
        } else if pause {
            FileManager.default.createFile(atPath: file, contents: nil)
        } else {
            try? FileManager.default.removeItem(atPath: file)
        }
        notePaused(bot, pause)
    }

    private func notePaused(_ bot: Bot, _ isPaused: Bool) {
        if isPaused, !paused.contains(bot.id) { paused.insert(bot.id) }
        if !isPaused, paused.contains(bot.id) { paused.remove(bot.id) }
    }

    /// Sends a waiting wake-up now rather than at its time (to see the bot's job run), on this Mac
    /// or its machine, and takes it off the list.
    func wakeNow(_ wake: Wakes.Pending, of bot: Bot) async throws {
        guard let api = app?.workspace.api(forFolder: bot.directory) else { throw Failure.notConnected(bot.machine ?? "This Mac's engine") }
        await api.waitForTools(in: bot.directory)
        try await api.prompt(session: bot.sessionID, id: Identifier.message(), text: Wakes.marker + wake.note, delivery: .queue)
        // One that repeats keeps its time.
        if wake.every == nil { await cancelWake(wake, of: bot) }
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
                self?.watchDue()
                await self?.wakeDue()
                // On time: up to the next one due here, at most 20 seconds.
                let next = self?.nextLocalWake().map { $0.timeIntervalSinceNow } ?? 20
                try? await Task.sleep(for: .seconds(min(20, max(0.5, next))))
            }
        }
    }

    private func wakeDue() async {
        guard let api = app?.api else { return }
        for bot in list where bot.machine == nil && !FileManager.default.fileExists(atPath: Self.pauseFile(of: bot)) {
            let pending = Self.localWakes(of: bot)
            if pending.contains(where: { $0.due <= .now }) { await api.waitForTools(in: bot.directory) }
            for wake in pending where wake.due <= .now {
                do {
                    try await api.prompt(session: bot.sessionID, id: Identifier.message(), text: Wakes.marker + wake.note, delivery: .queue)
                    // Sent: one that repeats comes back at its next time; others are done.
                    let folder = (bot.folder as NSString).appendingPathComponent("wakes") as NSString
                    if let next = wake.nextID() {
                        try? FileManager.default.moveItem(atPath: folder.appendingPathComponent(wake.id), toPath: folder.appendingPathComponent(next))
                    } else {
                        try? FileManager.default.removeItem(atPath: folder.appendingPathComponent(wake.id))
                    }
                } catch {
                    log.error("A wake-up for \(bot.id, privacy: .public) didn't go: \(error.localizedDescription, privacy: .public)")
                }
            }
            let left = Self.localWakes(of: bot)
            if wakes[bot.id] != left { wakes[bot.id] = left }
        }
    }

    /// When the next wake-up on this Mac is due.
    private func nextLocalWake() -> Date? {
        list.filter { $0.machine == nil }.compactMap { wakes[$0.id]?.first?.due }.min()
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

    /// Writes the bot's session in its folder, and the folder it works in, where `kuvo-wake fire`
    /// reads them on a machine (it waits for the folder's tools before it wakes the bot).
    private func writeSession(of bot: Bot) async throws {
        let file = (bot.folder as NSString).appendingPathComponent("session")
        if let machine = bot.machine {
            let directory = (bot.folder as NSString).appendingPathComponent("directory")
            let timezone = (bot.folder as NSString).appendingPathComponent("timezone")
            let path = RemoteFolder.parse(bot.directory)?.path ?? bot.directory
            // Your time zone, which its wake-ups' times are in.
            let script = "printf '%s' \(SSHConnection.quoted(bot.sessionID)) >\(SSHConnection.quoted(file)) && printf '%s' \(SSHConnection.quoted(path)) >\(SSHConnection.quoted(directory)) && printf '%s' \(SSHConnection.quoted(TimeZone.current.identifier)) >\(SSHConnection.quoted(timezone))"
            guard await Task.detached(operation: { RemoteShell.run(script, on: machine) }).value != nil else { throw Failure.noFolder }
        } else {
            try Data(bot.sessionID.utf8).write(to: URL(filePath: file))
            // Where its watches' checks run.
            try Data(bot.directory.utf8).write(to: URL(filePath: (bot.folder as NSString).appendingPathComponent("directory")))
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
        \(Personalities.shared.personality(bot.personality).map { "\n\($0.instruction)\n" } ?? "")\(job.isEmpty ? "" : "\nYour job:\n\(job)\n")
        You can work on a schedule. Kuvo Code wakes you up at the times you choose, even while the user is away, so you can do \
        things later ("in 2 hours", "tomorrow at 9") or again and again ("every 5 minutes", "every morning"). Never say you can't \
        run in the background, on a timer or on a schedule: schedule a wake-up instead.

        To schedule a wake-up, run:
          kuvo-wake \(bot.id) add <when> "<note to yourself>"
        <when> is +5m, +2h, +1d, or a time like 2026-10-16T09:00 \(bot.machine == nil ? "on this Mac's clock" : "in the user's time zone, \(TimeZone.current.identifier)"), at least a minute from now. At that \
        time this conversation gets your note as a new message starting with "\(Wakes.marker.trimmingCharacters(in: .whitespaces))", \
        and you carry on. `kuvo-wake \(bot.id) list` shows what's scheduled; `kuvo-wake \(bot.id) cancel <id>` cancels one. \
        (If kuvo-wake isn't found, it's "\(full)".)

        To watch for a change (a status page, a build, a price, a file), don't wake up every time just to look: give \
        kuvo-wake a check, a shell command that prints what matters, and it runs it for you and wakes you only when what it \
        prints changes, with the new output:
          kuvo-wake \(bot.id) watch 30m "<check>" "<what to do when it changes>"
        How often is 5m or more, 2h or 1d. Make the check print just what you watch, like `curl -s <url> | grep -o '<the \
        part that matters>'` or `gh run list --limit 1 --json conclusion -q '.[0].conclusion'`, so a clock or an ad on the \
        page doesn't count as a change. It runs in your folder, for at most a minute. A page that needs a real browser to show \
        its content can't be watched this way; check it in the browser on a wake-up instead.

        For something that repeats, schedule it once with --every, and it keeps coming back until it's canceled:
          kuvo-wake \(bot.id) add 2026-10-17T09:00 --every 1d "<what to do each time>"
        The repeat is 30m, 2h, 1d, 1w (at least 5m), or weekdays; days, weeks and weekdays keep the same time of day. Don't \
        schedule the next run yourself each time. To change a schedule, cancel it and add the new one; check the list first so \
        you never keep two for the same thing. When it's due now too, also do the first round now. Keep reports short; the \
        user reads them later.

        Memory: the file "\(bot.memoryFile)" is yours. Read it when you start a piece of work. Keep in it what you'll need next \
        time: lasting preferences, how things are set up, where ongoing work stands, and any schedule you're keeping. Keep it short \
        and current; check facts at their source rather than trusting it.

        You have a web browser, through the browser tools: \(bot.machine == nil ? "tabs of your own in the user's browser on this Mac, signed in where they are" : "one on this machine, which keeps its sign-ins and keeps working while the user's Mac is off"). \
        When a page asks to sign in, for a one-time code, or for something only the user can do (a CAPTCHA, approving on \
        their phone), use browser_sign_in, browser_ask_code or browser_ask_user: they ask the user in Kuvo Code and wait for \
        the answer, which goes straight into the page. If no one answers, carry on with what you can and schedule a wake-up \
        to try again later. But for a service the user connected in Settings › Integrations (their mail or calendar, Notion, \
        GitHub…), use its tools, named after it, never its website.

        The user is usually away while you work. When you need a decision from them, say so plainly in a short message and \
        stop.

        \(identityNote)
        """
    }

    /// Who sets what about a bot, so it doesn't claim to have changed them.
    static let identityNote = """
        Your name, look, personality, job and model are set by the user in Kuvo Code, under Edit Bot. You can't change them, \
        and writing a new name or job into your memory doesn't change them either. If you're asked to, say so plainly and \
        suggest Edit Bot.
        """

    /// Gives each bot's session the current wording of its instructions, once a run of the app,
    /// as its engine comes up: bots made by an older version learn what this one can do.
    /// A bot's own rules: its folder is its to read and write, wherever it works, and scheduling,
    /// listing and canceling its wake-ups never ask. Anything else it runs, its watches too, goes
    /// by the conversation's approval.
    static func ownRules(for bot: Bot) -> [PermissionRule] {
        let full = bot.machine == nil ? command.path : machineCommand
        return [PermissionRule(action: "external_directory", resource: (bot.folder as NSString).appendingPathComponent("*"), effect: .allow)]
            + ["kuvo-wake \(bot.id)", "\"\(full)\" \(bot.id)"].flatMap { name in
                ["add *", "list*", "cancel *"].map { PermissionRule(action: "shell", resource: "\(name) \($0)", effect: .allow) }
            }
    }

    /// Whether a rule is one of a bot's own, as made now or by an earlier version.
    private static func isOwnRule(_ rule: PermissionRule, of bot: Bot) -> Bool {
        let full = bot.machine == nil ? command.path : machineCommand
        if rule.action == "external_directory" { return rule.resource == (bot.folder as NSString).appendingPathComponent("*") }
        return rule.action == "shell" && (rule.resource.hasPrefix("kuvo-wake \(bot.id) ") || rule.resource.hasPrefix("\"\(full)\" \(bot.id) "))
    }

    /// Puts a bot's own rules back as they're made now, after its approval and any others: an
    /// earlier version lost them when its conversation's approval changed, or its folder when the
    /// project's were synced, and allowed every kuvo-wake command.
    private func repairRules(of bot: Bot, api: OpenCodeAPI) async {
        guard let rules = app?.workspace.session(bot.sessionID)?.permissions else { return }
        let repaired = rules.filter { !Self.isOwnRule($0, of: bot) } + Self.ownRules(for: bot)
        guard repaired != rules else { return }
        try? await api.setPermissions(session: bot.sessionID, rules: repaired)
    }

    func syncInstructions() async {
        for bot in list where !synced.contains(bot.id) {
            guard let api = app?.workspace.api(forFolder: bot.directory) else { continue }
            if (try? await api.setInstruction(session: bot.sessionID, key: Self.instructionKey, text: Self.instructions(for: bot))) != nil {
                synced.insert(bot.id)
                await repairRules(of: bot, api: api)
                try? await writeSession(of: bot)
                if let machine = bot.machine {
                    // Its kuvo-wake as the instructions describe it, for an engine started before.
                    if wakeInstalled.insert(machine).inserted, let engine = app?.machines.engine(machine) {
                        try? await Wakes.install(on: engine.machine.connection)
                    }
                }
            }
        }
    }

    // MARK: Storage

    static var lastModel: ModelRef? {
        let parts = (UserDefaults.standard.string(forKey: "lastModel") ?? "").split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        return ModelRef(id: parts[1], providerID: parts[0], variant: parts.count > 2 ? parts[2] : nil)
    }

    private static func load() -> [Bot] {
        JSONFile.read([Bot].self, from: file, isoDates: true) ?? []
    }

    private func save() {
        JSONFile.write(list, to: Self.file, isoDates: true, readable: true)
    }
}

extension Wakes.Repeat {
    /// "every day", "every 2 hours", "on weekdays".
    var words: String {
        switch self {
        case .minutes(let n): "every \(n) min"
        case .hours(let n): n == 1 ? "every hour" : "every \(n) hours"
        case .days(let n): n == 1 ? "every day" : "every \(n) days"
        case .weeks(let n): n == 1 ? "every week" : "every \(n) weeks"
        case .weekdays: "on weekdays"
        }
    }
}
