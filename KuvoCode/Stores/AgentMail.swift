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
    struct Waiting: Codable {
        var from: String?
        var name: String
        var to: String
        var machine: String
        var text: String
    }

    private static var waitingFile: URL { AppInfo.supportDirectory.appending(path: "agent-messages.json") }
    private var waiting: [Waiting] = JSONFile.read([Waiting].self, from: AgentMail.waitingFile) ?? []

    /// Delivers what waited for `engine`'s machine, now it's back.
    func deliverWaiting(to engine: MachineEngine) async {
        let machine = engine.machine.id
        let due = waiting.filter { $0.machine == machine }
        guard !due.isEmpty else { return }
        waiting.removeAll { $0.machine == machine }
        save()
        for letter in due {
            let result = await send(from: letter.from, name: letter.name, to: letter.to, text: letter.text, waits: false)
            if result.isError { log.error("A message for \(machine, privacy: .public) didn't go: \(result.text, privacy: .public)") }
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
        let name = first[first.index(first.startIndex, offsetBy: opening.count)..<dot.lowerBound]
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
            .filter { $0.parentID == nil && $0.time.archived == nil && !bots.contains($0.id) && !workspace.seats.contains($0.id) }
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
        let agents = directory()
        let wanted = to.trimmingCharacters(in: .whitespaces)
        let matches = agents.filter { $0.session == wanted } .nilIfEmpty
            ?? agents.filter { $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        guard let target = matches.first else {
            return ("There's no agent called \(wanted). Use list_agents to see who there is.", true)
        }
        guard matches.count == 1 else {
            return ("More than one agent is called \(wanted): use one's address.\n" + Self.describe(matches, caller: caller, here: nil), true)
        }
        guard target.session != caller else { return ("That's you.", true) }
        // A few at a time: two agents shouldn't keep writing to each other unattended.
        let key = caller ?? "outside"
        let lately = (sent[key] ?? []).filter { $0.timeIntervalSinceNow > -600 }
        guard lately.count < 20 else {
            return ("You've sent a lot of messages in the last few minutes. Wait a while, or ask the user how to go on.", true)
        }
        sent[key] = lately + [.now]
        guard let app, let api = app.workspace.api(forSession: target.session) else {
            // Its machine is away: it goes when it's back.
            guard let machine = target.machine else { return ("\(target.name) can't be reached now. Try again later.", true) }
            waiting.append(Waiting(from: caller, name: name, to: target.session, machine: machine, text: text))
            save()
            return ("\(target.name)'s machine (\(machine)) is away: the message goes to it as soon as it's back\(waits ? ", and its answer comes to you as a message" : "").", false)
        }
        let id = Identifier.message()
        do {
            try await api.prompt(session: target.session, id: id, text: Self.compose(from: name, session: caller ?? "unknown", text: text, waits: waits), delivery: .steer)
        } catch {
            return ("It didn't reach \(target.name): \(error.localizedDescription)", true)
        }
        Analytics.shared.track("agent_message_sent", ["waits": waits, "bot": target.kind == "bot"])
        guard waits else { return ("Sent to \(target.name). Its answer, if it writes one, comes to you as a message.", false) }
        if let reply = await reply(in: target.session, after: id, api: api) {
            return ("\(target.name) answered:\n\n" + reply, false)
        }
        return ("\(target.name) hasn't answered yet. It may still write back with send_message.", false)
    }

    // MARK: Starting another

    /// Sessions an agent started lately, by the conversation that started them.
    private var started: [String: [Date]] = [:]

    /// A new session from the conversation `caller`: an agent of its own, in the caller's folder
    /// (or the one given), on the caller's model, with your usual approval. It gets `task` as a
    /// message from the caller, so it knows who to report to, and its metadata says who started it,
    /// for the window to show it beside them.
    func start(_ arguments: [String: Any], caller: String?) async -> (text: String, isError: Bool) {
        guard let app else { return ("Kuvo Code isn't ready yet.", true) }
        guard let task = (arguments["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else {
            return ("Say what it's to do (task).", true)
        }
        let workspace = app.workspace
        let parent = caller.flatMap { workspace.session($0) }
        var folder = parent?.location.directory
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
        let approval = UserDefaults.standard.string(forKey: ToolApproval.key).flatMap(ToolApproval.init) ?? .approveAll
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
        if let reply = await reply(in: session.id, after: id, api: api) {
            return ("Started \(name)\(place) (address \(session.id)). It answered:\n\n" + reply, false)
        }
        return ("Started \(name)\(place) (address \(session.id)). It hasn't answered yet; it may still write back with send_message.", false)
    }

    /// The answer in `session` to the message `id`: its words once it's done, ten minutes at most.
    private func reply(in session: String, after id: String, api: OpenCodeAPI) async -> String? {
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
                guard case .assistant(let assistant) = message, assistant.id > id else { return nil }
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
        guard let data = try? JSONEncoder().encode(Directory(machine: machine, agents: directory())), shared[machine] != data else { return }
        let encoded = data.base64EncodedString()
        let file = "\"$HOME/\(RemoteEngineInstaller.root)/run/agents.json\""
        let script = "umask 077; mkdir -p \"$HOME/\(RemoteEngineInstaller.root)/run\" && printf %s '\(encoded)' | base64 -d >\(file).new && mv -f \(file).new \(file)"
        if await Task.detached(operation: { RemoteShell.run(script, on: machine) }).value != nil { shared[machine] = data }
    }

    /// What each machine was last given.
    private var shared: [String: Data] = [:]

    /// Delivers what `engine`'s machine's agents left for agents elsewhere.
    func collect(from engine: MachineEngine) async {
        let machine = engine.machine.id
        let folder = "\"$HOME/\(RemoteEngineInstaller.root)/run/outbox\""
        let script = "cd \(folder) 2>/dev/null || exit 0; for f in *.json; do [ -f \"$f\" ] || continue; cat \"$f\"; printf '\\n'; rm -f \"$f\"; done"
        let output = await Task.detached { RemoteShell.run(script, on: machine) }.value ?? Data()
        struct Letter: Decodable { var from: String?; var name: String?; var to: String; var text: String; var wait: Bool? }
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            guard let letter = try? JSONDecoder().decode(Letter.self, from: Data(line.utf8)) else { continue }
            let result = await send(from: letter.from, name: letter.name ?? "an agent on \(machine)", to: letter.to, text: letter.text, waits: false)
            if result.isError { log.error("A message from \(machine, privacy: .public) didn't go: \(result.text, privacy: .public)") }
        }
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
