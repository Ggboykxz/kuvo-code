import Foundation
import OpenCodeKit
import os

/// Agents writing to each other. Any session or bot, on this Mac or a machine, can ask who else
/// there is (list_agents) and send one of them a message (send_message). The message reaches that
/// conversation as input that says who sent it, as a wake-up says what it is, and the agent there
/// takes it up; with `wait`, the sender gets its answer back. Machines get the list of everyone,
/// and leave messages for this Mac or other machines in an outbox it empties.
@MainActor
final class AgentMail {
    static let shared = AgentMail()

    struct Agent: Codable, Hashable {
        var session: String
        var name: String
        /// "bot" or "session".
        var kind: String
        /// Where it runs: nil for this Mac.
        var machine: String?
        var project: String?
        /// A bot's job.
        var about: String?
    }

    weak var app: AppModel?

    /// A message waiting for its agent's machine to be back, kept until then (across launches).
    struct Waiting: Codable, Equatable {
        var from: String?
        var name: String
        var to: String
        var machine: String
        var text: String
    }

    private static var waitingFile: URL { AppInfo.supportDirectory.appending(path: "agent-messages.json") }
    private var waiting: [Waiting] = JSONFile.read([Waiting].self, from: AgentMail.waitingFile) ?? []

    /// Delivers what waited for `engine`'s machine, now it's back, straight to its engine (its
    /// session needn't be among the latest the list names). Each leaves the list once it's there:
    /// one that doesn't get there (the machine went again) waits for the next time, unless its
    /// session is gone. It was counted against its sender's messages when it was sent.
    func deliverWaiting(to engine: MachineEngine) async {
        let machine = engine.machine.id
        for letter in waiting where letter.machine == machine {
            guard let api = engine.api else { return }
            do {
                try await api.prompt(session: letter.to, id: Identifier.message(),
                                     text: Self.compose(from: letter.name, session: letter.from ?? "unknown", text: letter.text, waits: false), delivery: .steer)
                Analytics.shared.track("agent_message_sent", ["waits": false, "bot": app?.bots.bot(forSession: letter.to) != nil])
            } catch {
                log.error("A message for \(machine, privacy: .public) didn't go: \(error.localizedDescription, privacy: .public)")
                guard (error as? ServerError)?.status == 404 else { continue }
            }
            if let index = waiting.firstIndex(of: letter) { waiting.remove(at: index) }
            save()
        }
    }

    private func save() {
        if waiting.isEmpty {
            try? FileManager.default.removeItem(at: Self.waitingFile)
        } else {
            JSONFile.write(waiting, to: Self.waitingFile)
        }
    }

    /// Messages sent lately, by the conversation that sent them, to keep two agents from
    /// writing back and forth for ever.
    private var sent: [String: [Date]] = [:]
    private let log = Logger(subsystem: "run.kuvo.code", category: "agents")

    // MARK: The message

    private static let opening = "[Message from "

    /// What the receiving agent reads: who it's from and how to answer, then the message.
    static func compose(from name: String, session: String, text: String, waits: Bool) -> String {
        let answer = waits ? "They're waiting for your reply: just answer, in your words." : "To answer, use send_message to \(session)."
        return opening + name + " · " + session + "] (\(answer))\n\n" + text
    }

    /// A message from another agent: who sent it, and what it says. Its first line is
    /// "[Message from <name> · <session>] (…)", read from the end, as a name can hold anything.
    static func parse(_ message: String) -> (name: String, session: String, text: String)? {
        guard message.hasPrefix(opening) else { return nil }
        let first = message.prefix { $0 != "\n" }
        guard let dot = first.range(of: " · ", options: .backwards) else { return nil }
        let after = first[dot.upperBound...]
        guard let close = after.firstIndex(of: "]") else { return nil }
        let session = after[..<close]
        guard session.hasPrefix("ses_") || session == "unknown", !session.contains(" ") else { return nil }
        // No name ("[Message from · ses_1]"): the " · " is the opening's own space, before where a
        // name would start.
        let nameStart = first.index(first.startIndex, offsetBy: opening.count)
        guard dot.lowerBound >= nameStart else { return nil }
        let name = first[nameStart..<dot.lowerBound]
        let rest = message[first.endIndex...]
        let text = rest.range(of: "\n\n").map { String(rest[$0.upperBound...]) } ?? String(rest.drop { $0 == "\n" })
        return (String(name), String(session), text)
    }

    // MARK: Who there is

    /// Every bot, and the sessions of the last while: not a sub-agent's, a group chat's seat,
    /// nor one put away.
    func directory() -> [Agent] {
        guard let app else { return [] }
        let workspace = app.workspace
        var agents = app.bots.list.map { bot in
            Agent(session: bot.sessionID, name: bot.name, kind: "bot", machine: bot.machine, project: nil, about: bot.job)
        }
        let bots = Set(agents.map(\.session))
        let recent = workspace.sessions
            .filter { $0.parentID == nil && !Workspace.isArchived($0) && !bots.contains($0.id) && !workspace.seats.contains($0.id) }
            .sorted { $0.time.updated > $1.time.updated }
            .prefix(40)
        for session in recent {
            let directory = session.location.directory
            agents.append(Agent(session: session.id, name: session.title ?? "New session", kind: "session",
                                machine: RemoteFolder.machine(of: directory), project: workspace.projectName(directory)))
        }
        return agents
    }

    /// The agent a conversation is, by its session.
    private func agent(_ session: String?) -> Agent? {
        directory().first { $0.session == session }
    }

    /// The list, for an agent to read.
    static func describe(_ agents: [Agent], caller: String?, here machine: String?) -> String {
        let others = agents.filter { $0.session != caller }
        guard !others.isEmpty else { return "No other agents yet." }
        func place(_ agent: Agent) -> String {
            switch agent.machine {
            case machine: machine == nil ? "on the Mac" : "here"
            case nil: "on the Mac"
            case let other?: "on \(other)"
            }
        }
        let lines = others.map { agent in
            var line = "- \(agent.name) (\(agent.kind), \(place(agent))"
            if let project = agent.project { line += ", in \(project)" }
            line += ") address: \(agent.session)"
            if let about = agent.about, !about.isEmpty { line += ": \(about)" }
            return line
        }
        return "Agents you can write to with send_message (by name or address):\n" + lines.joined(separator: "\n")
    }

    // MARK: Sending

    /// The tools' calls from this Mac's conversations.
    func call(_ name: String, arguments: [String: Any], caller: String?) async -> (text: String, isError: Bool) {
        switch name {
        case "list_agents":
            return (Self.describe(directory(), caller: caller, here: nil), false)
        case "send_message":
            guard let to = arguments["to"] as? String, !to.trimmingCharacters(in: .whitespaces).isEmpty else { return ("Say who to write to (to).", true) }
            guard let text = arguments["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ("Say what to write (text).", true) }
            let sender = agent(caller)
            return await send(from: caller, name: sender?.name ?? "another agent", to: to, text: text, waits: (arguments["wait"] as? NSNumber)?.boolValue ?? false)
        case "start_session":
            return await start(arguments, caller: caller)
        default:
            return ("Unknown tool \(name).", true)
        }
    }

    /// Delivers `text` from the conversation `caller` (named `name`) to the agent `to` (a name or
    /// an address), wherever it runs; with `waits`, waits for its answer and returns it.
    func send(from caller: String?, name: String, to: String, text: String, waits: Bool) async -> (text: String, isError: Bool) {
        switch await deliver(from: caller, name: name, to: to, text: text, waits: waits) {
        case .done(let text): (text, false)
        case .unknown(let text), .refused(let text), .limited(let text), .failed(let text): (text, true)
        }
    }

    /// How a message went: there (or waiting for its machine), to no agent this Mac knows (one
    /// another Mac does may take it), not one to send (too many), or not there now, and worth
    /// sending again.
    private enum Outcome {
        /// `limited`: too many lately; it can go in a while.
        case done(String), unknown(String), refused(String), limited(String), failed(String)
    }

    /// `limitKey`: what the few-at-a-time limit counts by, when not the caller (a machine's
    /// letters, whose sender anything there could claim).
    private func deliver(from caller: String?, name: String, to: String, text: String, waits: Bool, limitKey: String? = nil) async -> Outcome {
        let agents = directory()
        let wanted = to.trimmingCharacters(in: .whitespaces)
        let matches = agents.filter { $0.session == wanted } .nilIfEmpty
            ?? agents.filter { $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        guard let target = matches.first else {
            return .unknown("There's no agent called \(wanted). Use list_agents to see who there is.")
        }
        guard matches.count == 1 else {
            return .refused("More than one agent is called \(wanted): use one's address.\n" + Self.describe(matches, caller: caller, here: nil))
        }
        guard target.session != caller else { return .refused("That's you.") }
        // A few at a time: two agents shouldn't keep writing to each other unattended. (Counted
        // once it's sent, so one tried again isn't counted twice.)
        let key = limitKey ?? caller ?? "outside"
        let lately = (sent[key] ?? []).filter { $0.timeIntervalSinceNow > -600 }
        guard lately.count < 20 else {
            return .limited("You've sent a lot of messages in the last few minutes. Wait a while, or ask the user how to go on.")
        }
        guard let app, let api = app.workspace.api(forSession: target.session) else {
            // Its machine is away: it goes when it's back.
            guard let machine = target.machine else { return .failed("\(target.name) can't be reached now. Try again later.") }
            sent[key] = lately + [.now]
            waiting.append(Waiting(from: caller, name: name, to: target.session, machine: machine, text: text))
            save()
            return .done("\(target.name)'s machine (\(machine)) is away: the message goes to it as soon as it's back\(waits ? ", and its answer comes to you as a message" : "").")
        }
        let id = Identifier.message()
        // What it had said already, so its answer is what comes after. Unknown (it couldn't be
        // read), there's no telling its answer from those: it comes as a message instead.
        let known = waits ? await Self.replies(in: target.session, api: api) : []
        let waits = waits && known != nil
        do {
            try await api.prompt(session: target.session, id: id, text: Self.compose(from: name, session: caller ?? "unknown", text: text, waits: waits), delivery: .steer)
        } catch {
            return .failed("It didn't reach \(target.name): \(error.localizedDescription)")
        }
        sent[key] = lately + [.now]
        Analytics.shared.track("agent_message_sent", ["waits": waits, "bot": target.kind == "bot"])
        guard waits else { return .done("Sent to \(target.name). Its answer, if it writes one, comes to you as a message.") }
        if let reply = await reply(in: target.session, known: known ?? [], api: api) {
            return .done("\(target.name) answered:\n\n" + reply)
        }
        return .done("\(target.name) hasn't answered yet. It may still write back with send_message.")
    }

    // MARK: Starting another

    /// Sessions an agent started lately, by the conversation that started them.
    private var started: [String: [Date]] = [:]

    /// A new session from the conversation `caller`: an agent of its own, in the caller's folder
    /// (or the one given), on the caller's model, with the caller's approval (yours by default for
    /// one from outside a session), so Ask First isn't got around. It gets `task` as a
    /// message from the caller, so it knows who to report to, and its metadata says who started it,
    /// for the window to show it beside them.
    func start(_ arguments: [String: Any], caller: String?) async -> (text: String, isError: Bool) {
        guard let app else { return ("Kuvo Code isn't ready yet.", true) }
        guard let task = (arguments["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else {
            return ("Say what it's to do (task).", true)
        }
        let workspace = app.workspace
        let parent = caller.flatMap { workspace.session($0) }
        // A bot's own folder is its own: a session it starts there would be listed nowhere, so
        // it's a chat.
        var folder = parent.map { Workspace.isBotFolder($0.location.directory) ? Workspace.chatsFolder : $0.location.directory }
        if let given = (arguments["folder"] as? String)?.trimmingCharacters(in: .whitespaces), !given.isEmpty {
            let path = (given as NSString).expandingTildeInPath
            var isFolder: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
                return ("\(given) isn't a folder on this Mac. Give a full path to one.", true)
            }
            folder = path
        }
        guard let folder else { return ("Give the folder it works in (folder), as a full path.", true) }
        // A few at a time: an agent shouldn't fill the window with sessions unattended.
        let key = caller ?? "outside"
        let lately = (started[key] ?? []).filter { $0.timeIntervalSinceNow > -600 }
        guard lately.count < 6 else {
            return ("You've started several sessions in the last few minutes. Write to those (send_message), or ask the user before starting more.", true)
        }
        started[key] = lately + [.now]
        let approval = parent.map { ToolApproval(rules: $0.permissions) } ?? UserDefaults.standard.string(forKey: ToolApproval.key).flatMap(ToolApproval.init) ?? .approveAll
        let session: Session
        do {
            session = try await workspace.createSession(in: folder, model: parent?.model, agent: nil, approval: approval)
        } catch {
            return ("Couldn't start a session in \(folder): \(error.localizedDescription)", true)
        }
        guard let api = workspace.api(forSession: session.id) else { return ("Couldn't reach the new session.", true) }
        let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty { try? await api.renameSession(session.id, title: title) }
        let beside = (arguments["beside"] as? NSNumber)?.boolValue ?? true
        try? await api.setMetadata(session: session.id, .object(["kuvo": .object(["startedBy": .string(caller ?? ""), "beside": .bool(beside)])]))
        let waits = (arguments["wait"] as? NSNumber)?.boolValue ?? false
        let id = Identifier.message()
        do {
            try await api.prompt(session: session.id, id: id, text: Self.compose(from: agent(caller)?.name ?? "another agent", session: caller ?? "unknown", text: task, waits: waits), delivery: .steer)
        } catch {
            return ("Started a session (\(session.id)), but the task didn't reach it: \(error.localizedDescription)", true)
        }
        Analytics.shared.track("agent_started_session", ["waits": waits, "beside": beside])
        let name = title.flatMap { $0.isEmpty ? nil : "\"\($0)\"" } ?? "a new session"
        let place = Workspace.isChat(folder) ? "" : " in \(workspace.projectName(folder))"
        let shown = beside ? ", beside this conversation" : ", in a tab"
        guard waits else {
            return ("Started \(name)\(place)\(shown) (address \(session.id)). It's on it now. Write to it with send_message; it can write back to you the same way.", false)
        }
        // A new session: anything it says is its answer.
        if let reply = await reply(in: session.id, known: [], api: api) {
            return ("Started \(name)\(place) (address \(session.id)). It answered:\n\n" + reply, false)
        }
        return ("Started \(name)\(place) (address \(session.id)). It hasn't answered yet; it may still write back with send_message.", false)
    }

    /// The replies `session` has given so far, to tell its answer to a message sent now from them;
    /// nil when they can't be read (tried a few times, as the engine may be reconnecting).
    private static func replies(in session: String, api: OpenCodeAPI) async -> Set<String>? {
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            guard let messages = try? await api.messages(session: session, limit: 20).data else { continue }
            return Set(messages.compactMap { if case .assistant(let assistant) = $0 { assistant.id } else { nil } })
        }
        return nil
    }

    /// The answer in `session` to a message sent to it: its words once it's done, ten minutes at
    /// most; what it says that isn't among the replies `known` from before. (Not by comparing
    /// IDs, nor where they come in the list: a machine's are made from its own clock.)
    private func reply(in session: String, known: Set<String>, api: OpenCodeAPI) async -> String? {
        let began = Date.now
        var started = false
        while Date.now.timeIntervalSince(began) < 600 {
            try? await Task.sleep(for: .seconds(2))
            if app?.workspace.running.contains(session) == true {
                started = true
                continue
            }
            // Done; or not seen at work (a quick one, between looks): its words after ours.
            guard started || Date.now.timeIntervalSince(began) > 6 else { continue }
            guard let messages = try? await api.messages(session: session, limit: 20).data else { continue }
            let words = messages.compactMap { message -> String? in
                guard case .assistant(let assistant) = message, !known.contains(assistant.id) else { return nil }
                let text = assistant.content.compactMap { if case .text(let part) = $0 { part.text } else { nil } }.joined(separator: "\n")
                return text.isEmpty ? nil : text
            }
            if !words.isEmpty { return String(words.joined(separator: "\n\n").prefix(8000)) }
            if started { return nil }
        }
        return nil
    }

    // MARK: Machines

    /// The list as a machine's agents read it (`run/agents.json` there): which machine it is,
    /// and everyone.
    struct Directory: Codable {
        var machine: String
        var agents: [Agent]
    }

    /// Puts the list of everyone on `engine`'s machine, for its agents, when it's changed.
    func share(with engine: MachineEngine) async {
        let machine = engine.machine.id
        // Sorted: JSONEncoder writes a struct's keys in another order almost every time, and an
        // unchanged list would go again each minute.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(Directory(machine: machine, agents: directory())), shared[machine] != data else { return }
        let encoded = data.base64EncodedString()
        let file = "\"$HOME/\(RemoteEngineInstaller.root)/run/agents.json\""
        let script = "umask 077; mkdir -p \"$HOME/\(RemoteEngineInstaller.root)/run\" && printf %s '\(encoded)' | base64 -d >\(file).new && mv -f \(file).new \(file)"
        if await Task.detached(operation: { RemoteShell.run(script, on: machine) }).value != nil { shared[machine] = data }
    }

    /// What each machine was last given.
    private var shared: [String: Data] = [:]

    /// Delivers what `engine`'s machine's agents left for agents elsewhere. Each letter's file
    /// there goes once it's delivered, or can't ever be; one that can't go now (the engine it's
    /// for is starting over, or the machine sent many lately), or whose reading was cut off, goes
    /// next time. One for an agent this Mac doesn't know waits two days, for another Mac connected
    /// to the machine that may, and so does one held back that long.
    func collect(from engine: MachineEngine) async {
        // One at a time for a machine, or two would deliver the same letters; one asked for
        // meanwhile runs once after.
        let machine = engine.machine.id
        guard collecting.insert(machine).inserted else {
            collectAgain.insert(machine)
            return
        }
        defer { collecting.remove(machine) }
        repeat {
            collectAgain.remove(machine)
            await collectOnce(from: engine)
        } while collectAgain.contains(machine)
    }

    /// Machines whose letters are being collected, and those to collect again after.
    private var collecting: Set<String> = []
    private var collectAgain: Set<String> = []

    private func collectOnce(from engine: MachineEngine) async {
        let machine = engine.machine.id
        let folder = "\"$HOME/\(RemoteEngineInstaller.root)/run/outbox\""
        // Each as its file's name, when it was written and its letter (on one line, as it's
        // written), between tabs.
        let script = "cd \(folder) 2>/dev/null || exit 0; for f in *.json; do [ -f \"$f\" ] || continue; printf '%s\\t%s\\t' \"$f\" \"$(stat -c %Y \"$f\" 2>/dev/null || echo 0)\"; tr -d '\\n' <\"$f\"; printf '\\n'; done"
        guard let output = await Task.detached(operation: { RemoteShell.run(script, on: machine) }).value else { return }
        struct Letter: Decodable { var from: String?; var name: String?; var to: String; var text: String; var wait: Bool? }
        var done: [String] = []
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let file = String(fields[0])
            let written = Date(timeIntervalSince1970: Double(fields[1]) ?? 0)
            guard let letter = try? JSONDecoder().decode(Letter.self, from: Data(fields[2].utf8)) else {
                log.error("A message from \(machine, privacy: .public) couldn't be read")
                done.append(file)
                continue
            }
            // Anything on the machine can write a letter, so who it's from is taken only from an
            // agent that is there; else it's "an agent on" it. Counted by the machine.
            let sender = letter.from.flatMap { from in directory().first { $0.session == from && $0.machine == machine } }
            switch await deliver(from: sender?.session, name: sender?.name ?? "an agent on \(machine)", to: letter.to, text: letter.text, waits: false, limitKey: "machine:" + machine) {
            case .done:
                done.append(file)
            case .unknown(let why), .limited(let why):
                guard written.timeIntervalSinceNow < -2 * 86_400 else { continue }
                log.error("A message from \(machine, privacy: .public) didn't go: \(why, privacy: .public)")
                done.append(file)
            case .refused(let why):
                log.error("A message from \(machine, privacy: .public) didn't go: \(why, privacy: .public)")
                done.append(file)
            case .failed(let why):
                log.error("A message from \(machine, privacy: .public) didn't go yet: \(why, privacy: .public)")
            }
        }
        guard !done.isEmpty else { return }
        let names = done.map(SSHConnection.quoted).joined(separator: " ")
        _ = await Task.detached(operation: { RemoteShell.run("cd \(folder) && rm -f -- \(names)", on: machine) }).value
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
