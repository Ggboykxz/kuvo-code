import Foundation
import OpenCodeKit
import os

/// A group chat: you and some of your bots, talking something through. Each bot takes part from
/// a seat of its own, a session where it lives with its job and memory, hidden from the lists.
/// Kuvo Code passes the floor around one bot at a time, so no two ever talk at once.
struct BotGroup: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    /// What it's for, in a few words: "Plan each week's release". Nil or empty for nothing in particular.
    var purpose: String?
    /// Its bots, in order; the first leads.
    var members: [String]
    /// Each member's seat: its session for this chat, made at its first turn.
    var seats: [String: String] = [:]
    /// The last message each member's seat has been given.
    var heard: [String: String] = [:]
    var created: Date
    /// When you last looked at it.
    var viewed: Date?
    /// Bots that heard messages you since took back, with the start of the first of them: they're
    /// told to set it aside at their next turn.
    var retracted: [String: String]?

    var lead: String? { members.first }
}

struct GroupMessage: Codable, Identifiable, Hashable {
    var id: String
    /// The bot that wrote it; nil for you.
    var author: String?
    var text: String
    var time: Date
    var kind: Kind = .message
    /// What the bot did on its turn before it wrote this: its searches, reads and commands.
    var steps: [Message.ToolCall]?

    enum Kind: String, Codable {
        /// Said in the chat.
        case message
        /// The lead's sum-up at the end of a discussion.
        case wrapUp
        /// From Kuvo Code: a bot that couldn't take part.
        case note
    }
}

/// Your group chats, in `groups.json`, their messages in `groups/<id>.json`, and the discussions
/// under way.
///
/// A discussion starts with each message of yours. The lead speaks first, unless you named
/// someone with @; then whoever the last message named, then the others in turn. A bot with
/// nothing new to add passes. It ends when everyone else has passed, or at a limit of turns
/// (Keep Going carries on), and the lead sums up one that went back and forth. A message you send
/// while a bot is talking goes to that bot straight away, and to the others at their turns.
/// Afterwards each bot remembers the chat in its own conversation, as you'd remember a meeting.
@Observable
final class BotGroups {
    private(set) var list: [BotGroup] = []
    /// Each chat's messages.
    private var logs: [String: [GroupMessage]] = [:]
    /// Whose turn it is, in each chat that's talking.
    private(set) var speaking: [String: String] = [:]
    /// Chats talking something through right now.
    private(set) var discussing: Set<String> = []
    /// Chats that stopped at their limit of turns with more to say.
    private(set) var paused: Set<String> = []
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var discussions: [String: Task<Void, Never>] = [:]
    /// Which run of each chat's discussion is the current one, so a stopped one ending late
    /// leaves the next alone.
    @ObservationIgnored private var runs: [String: UUID] = [:]
    /// Goes up with each message of yours, so a discussion under way starts its count again.
    @ObservationIgnored private var asked: [String: Int] = [:]
    /// Requests from seats already turned down.
    @ObservationIgnored private var declined: Set<String> = []
    @ObservationIgnored private var syncs: [String: Task<Void, Never>] = [:]
    private let log = Logger(subsystem: "run.kuvo.code", category: "groups")

    /// The key of a seat's instructions, and of the chats a bot's own conversation remembers.
    static let seatKey = "kuvo.seat"
    static let memoryKey = "kuvo.groups"
    private static var file: URL { AppInfo.supportDirectory.appending(path: "groups.json") }
    private static var folder: URL { AppInfo.supportDirectory.appending(path: "groups") }

    init() {
        list = Self.load()
        for group in list { logs[group.id] = Self.loadLog(group.id) }
    }

    func group(_ id: String?) -> BotGroup? {
        id.flatMap { id in list.first { $0.id == id } }
    }

    /// Every seat, so they stay out of the lists.
    var seatIDs: Set<String> { Set(list.flatMap(\.seats.values)) }

    /// The chat a seat is in.
    func group(seat: String) -> BotGroup? {
        list.first { $0.seats.values.contains(seat) }
    }

    func messages(in id: String) -> [GroupMessage] {
        logs[id] ?? []
    }

    /// A message from a bot since you last looked.
    func isUnread(_ group: BotGroup) -> Bool {
        guard let last = messages(in: group.id).last(where: { $0.author != nil && $0.kind != .note }) else { return false }
        return last.time > (group.viewed ?? .distantPast)
    }

    func markViewed(_ id: String) {
        guard let index = list.firstIndex(where: { $0.id == id }), isUnread(list[index]) else { return }
        list[index].viewed = .now
        save()
    }

    // MARK: Tabs

    static func tabKey(_ id: String) -> String { "group:" + id }

    static func groupID(fromTab key: String) -> String? {
        key.hasPrefix("group:") ? String(key.dropFirst("group:".count)) : nil
    }

    // MARK: Making, changing, deleting

    func create(name: String, purpose: String? = nil, members: [String]) -> BotGroup {
        let id = "grp_" + String((0..<10).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        let group = BotGroup(id: id, name: name, purpose: purpose, members: members, created: .now, viewed: .now)
        list.append(group)
        logs[id] = []
        save()
        Analytics.shared.track("group_created", ["members": members.count])
        return group
    }

    /// Saves a new name, members or lead. Bots that left lose their seat and stop remembering
    /// the chat; everyone's seat learns who's there now.
    func update(_ group: BotGroup) async {
        guard let index = list.firstIndex(where: { $0.id == group.id }) else { return }
        let old = list[index]
        var group = group
        let gone = old.members.filter { !group.members.contains($0) }
        for bot in gone {
            if let seat = group.seats.removeValue(forKey: bot) { await deleteSeat(seat, of: bot) }
            group.heard[bot] = nil
        }
        list[index] = group
        save()
        await refreshSeats(of: group)
        for bot in Set(old.members + group.members) { await remember(bot) }
    }

    /// Deletes a chat: its messages, and its seats where the bots live.
    func delete(_ group: BotGroup) async {
        stop(group.id)
        list.removeAll { $0.id == group.id }
        logs[group.id] = nil
        save()
        try? FileManager.default.removeItem(at: Self.folder.appending(path: "\(group.id).json"))
        for (bot, seat) in group.seats { await deleteSeat(seat, of: bot) }
        for bot in group.members { await remember(bot, changed: group.id, forgetting: group.id) }
        Analytics.shared.track("group_deleted")
    }

    /// A bot that's being deleted leaves its chats.
    func remove(_ bot: Bot) async {
        for var group in list where group.members.contains(bot.id) {
            group.members.removeAll { $0 == bot.id }
            await update(group)
        }
    }

    /// A bot's new name or job: the seats around it hear who they're talking with.
    func botChanged(_ bot: Bot) async {
        for group in list where group.members.contains(bot.id) {
            await refreshSeats(of: group)
        }
        await remember(bot.id)
    }

    /// A bot's new default model, for its seats.
    func modelChanged(of bot: Bot) async {
        guard let model = bot.model, let api = app?.workspace.api(forFolder: bot.directory) else { return }
        for group in list {
            if let seat = group.seats[bot.id] { try? await api.selectModel(session: seat, model: model) }
        }
    }

    // MARK: Talking

    /// Your message to the chat. It starts a discussion, or joins the one under way: the bot
    /// talking gets it straight away, the rest at their turns.
    func send(_ text: String, to id: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, group(id) != nil else { return }
        let message = append(GroupMessage(id: Self.newID(), author: nil, text: text, time: .now), to: id)
        asked[id, default: 0] += 1
        paused.remove(id)
        Analytics.shared.track("group_message", ["discussing": discussing.contains(id)])
        if let speaker = speaking[id] {
            Task { await steer(speaker, in: id, with: message) }
        }
        if discussions[id] == nil { start(id) }
    }

    /// Takes the chat back to before one of your messages: it and everything said after it leave
    /// the chat, the discussion stops, and bots that heard any of it are told at their next turn
    /// to set it aside. Returns the message's words, for the composer.
    @discardableResult
    func undo(from messageID: String, in id: String) -> String? {
        guard let index = list.firstIndex(where: { $0.id == id }), var messages = logs[id],
              let cut = messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        stop(id)
        let taken = messages[cut...]
        let text = messages[cut].text
        messages.removeSubrange(cut...)
        logs[id] = messages
        saveLog(id)
        var group = list[index]
        var retracted = group.retracted ?? [:]
        for bot in group.members {
            guard let heard = group.heard[bot], taken.contains(where: { $0.id == heard }) else { continue }
            group.heard[bot] = messages.last?.id
            if retracted[bot] == nil { retracted[bot] = String(text.prefix(120)) }
        }
        group.retracted = retracted.isEmpty ? nil : retracted
        list[index] = group
        save()
        rememberSoon(id)
        Analytics.shared.track("group_undo")
        return text
    }

    /// Stops the discussion; the bot talking stops mid-sentence.
    func stop(_ id: String) {
        discussions.removeValue(forKey: id)?.cancel()
        runs[id] = nil
        paused.remove(id)
        if let speaker = speaking.removeValue(forKey: id), let bot = app?.bots.bot(speaker), let seat = group(id)?.seats[speaker] {
            Task { try? await app?.workspace.api(forFolder: bot.directory)?.interrupt(session: seat) }
        }
        discussing.remove(id)
    }

    /// After the limit of turns: more of the same.
    func keepGoing(_ id: String) {
        guard discussions[id] == nil else { return }
        paused.remove(id)
        asked[id, default: 0] += 1
        start(id)
    }

    private func start(_ id: String) {
        let run = UUID()
        runs[id] = run
        discussing.insert(id)
        discussions[id] = Task { [weak self] in
            // A message of yours that came as it was ending (during the wrap-up) starts another.
            var epoch: Int
            repeat {
                epoch = await self?.discuss(id) ?? 0
            } while !Task.isCancelled && self.map { $0.asked[id, default: 0] != epoch } == true
            guard let self, self.runs[id] == run else { return }
            self.runs[id] = nil
            self.discussions[id] = nil
            self.discussing.remove(id)
            self.speaking[id] = nil
        }
    }

    /// How many turns a discussion gets for each message of yours.
    private static func limit(members: Int) -> Int {
        min(16, max(4, members * 3))
    }

    private enum Outcome { case said, passed, absent }

    /// Talks it through, until there's nothing left to add or it reaches its limit; then the
    /// wrap-up. Returns the count of your messages it went by.
    private func discuss(_ id: String) async -> Int {
        var epoch = asked[id, default: 0]
        var turns = 0
        /// Bots that passed since the last thing said.
        var quiet: Set<String> = []
        /// Bots that couldn't take part (not connected, an error): left out until you write again.
        var absent: Set<String> = []
        /// Bots' messages since yours.
        var said = 0
        while !Task.isCancelled {
            guard let group = group(id), let app else { return epoch }
            if asked[id, default: 0] != epoch {
                epoch = asked[id, default: 0]
                turns = 0
                quiet = []
                absent = []
                said = 0
            }
            let members = group.members.filter { app.bots.bot($0) != nil && !absent.contains($0) }
            if turns >= Self.limit(members: group.members.count) {
                paused.insert(id)
                break
            }
            guard let speaker = nextSpeaker(in: group, members: members, quiet: quiet) else { break }
            let outcome = await turn(of: speaker, in: id)
            guard !Task.isCancelled else { return epoch }
            turns += 1
            switch outcome {
            case .said:
                quiet = []
                said += 1
            case .passed:
                quiet.insert(speaker)
            case .absent:
                absent.insert(speaker)
            }
        }
        // The lead sums up a discussion that went back and forth, unless you've written since.
        guard !Task.isCancelled, said >= 3, asked[id, default: 0] == epoch, let group = group(id), group.members.count >= 2,
              let lead = group.lead, app?.bots.bot(lead) != nil else { return epoch }
        _ = await turn(of: lead, in: id, wrapUp: true)
        return epoch
    }

    /// Who talks next: someone the last message named with @, after one of yours the lead,
    /// otherwise the next in line after whoever spoke last. Nobody twice in a row, and nobody
    /// who passed since the last thing said. Nil once there's nobody left with something to add.
    private func nextSpeaker(in group: BotGroup, members: [String], quiet: Set<String>) -> String? {
        let last = messages(in: group.id).last { $0.kind != .note }
        let candidates = members.filter { $0 != last?.author && !quiet.contains($0) }
        guard !candidates.isEmpty else { return nil }
        if let last, let named = mentions(in: last.text, among: candidates).first {
            return named
        }
        guard let author = last?.author, let index = group.members.firstIndex(of: author) else {
            return candidates.first
        }
        let order = group.members[(index + 1)...] + group.members[..<index]
        return order.first { candidates.contains($0) }
    }

    /// The bots a message names with @, in the order it names them.
    func mentions(in text: String, among ids: [String]) -> [String] {
        let bots = ids.compactMap { app?.bots.bot($0) }
        return bots.compactMap { bot -> (String, String.Index)? in
            text.range(of: "@" + bot.name, options: [.caseInsensitive, .diacriticInsensitive]).map { (bot.id, $0.lowerBound) }
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    /// One bot's turn: what it hasn't heard yet goes to its seat, and its answer to the chat.
    private func turn(of botID: String, in id: String, wrapUp: Bool = false) async -> Outcome {
        guard let app, let bot = app.bots.bot(botID) else { return .absent }
        speaking[id] = botID
        defer { if speaking[id] == botID { speaking[id] = nil } }
        if let machine = bot.machine, app.machines.engine(machine)?.isReady != true {
            note("\(bot.name) is on \(machine), which isn’t connected, so it sat this out.", in: id)
            return .absent
        }
        guard let api = app.workspace.api(forFolder: bot.directory) else {
            note("\(bot.name) couldn’t answer: the engine isn’t running.", in: id)
            return .absent
        }
        do {
            let seat = try await seat(of: bot, in: id, api: api)
            guard let group = group(id) else { return .absent }
            let all = messages(in: id)
            let start = group.heard[botID].flatMap { heard in all.firstIndex { $0.id == heard } }.map { $0 + 1 } ?? 0
            let unheard = all[start...].filter { $0.author != botID && $0.kind != .note }
            let promptID = Identifier.message()
            let ended = app.workspace.endedRuns[seat, default: 0]
            try await api.prompt(session: seat, id: promptID, text: turnText(for: bot, in: group, unheard: Array(unheard), wrapUp: wrapUp), delivery: .queue)
            if let last = all.last { setHeard(last.id, by: botID, in: id) }
            if let index = list.firstIndex(where: { $0.id == id }), list[index].retracted?[botID] != nil {
                list[index].retracted?[botID] = nil
                if list[index].retracted?.isEmpty == true { list[index].retracted = nil }
                save()
            }
            let sent = Date.now
            try await waitForRun(of: seat, after: ended, since: sent, api: api)
            let (text, error, steps) = try await reply(in: seat, after: promptID, since: sent, api: api)
            if text.isEmpty {
                if let error {
                    note("\(bot.name) couldn’t answer: \(error)", in: id)
                    return .absent
                }
                return .passed
            }
            if !wrapUp, Self.isPass(text) { return .passed }
            append(GroupMessage(id: Self.newID(), author: botID, text: text, time: .now, kind: wrapUp ? .wrapUp : .message,
                                steps: steps.isEmpty ? nil : steps.map(Self.trimmed)), to: id)
            return .said
        } catch is CancellationError {
            return .absent
        } catch {
            guard !Task.isCancelled else { return .absent }
            log.error("\(bot.id, privacy: .public)'s turn in \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            note("\(bot.name) couldn’t answer: \(error.localizedDescription)", in: id)
            return .absent
        }
    }

    /// Your message, to the bot talking now: it hears it at its next step.
    private func steer(_ botID: String, in id: String, with message: GroupMessage) async {
        // Only into a run: one that hasn't started yet gets it with the rest at its turn.
        guard let bot = app?.bots.bot(botID), let seat = group(id)?.seats[botID], app?.workspace.running.contains(seat) == true,
              let api = app?.workspace.api(forFolder: bot.directory) else { return }
        if (try? await api.prompt(session: seat, id: Identifier.message(), text: "The user, just now: \(message.text)", delivery: .steer)) != nil {
            setHeard(message.id, by: botID, in: id)
        }
    }

    private enum Failure: LocalizedError {
        case tookTooLong
        var errorDescription: String? { "It took too long, so it was stopped." }
    }

    /// Until the seat's run ends. Questions and requests for permission are turned down on the
    /// way, since nobody's there to answer them.
    private func waitForRun(of seat: String, after ended: Int, since sent: Date, api: OpenCodeAPI) async throws {
        var checked = Date.now
        while app?.workspace.endedRuns[seat, default: 0] == ended {
            try await Task.sleep(for: .milliseconds(300))
            if app?.workspace.asking.values.contains(seat) == true { await decline(in: seat, api: api) }
            // The engine's word, now and then, in case an event went missing in a reconnect.
            if Date.now.timeIntervalSince(checked) > 8 {
                checked = .now
                if let active = try? await api.activeSessions(), !active.contains(seat) { return }
            }
            if Date.now.timeIntervalSince(sent) > 600 {
                try? await api.interrupt(session: seat)
                throw Failure.tookTooLong
            }
        }
    }

    private func decline(in seat: String, api: OpenCodeAPI) async {
        for request in (try? await api.permissions(session: seat)) ?? [] where declined.insert(request.id).inserted {
            try? await api.reply(session: seat, permission: request.id, decision: .reject, message: "Nobody can approve this in a group chat. Carry on without it, or say who should do it.")
        }
        for form in (try? await api.forms(session: seat)) ?? [] where declined.insert(form.id).inserted {
            try? await api.dismiss(session: seat, form: form.id, message: "Ask the group in your reply instead.")
        }
    }

    /// What the seat said since `promptID`, for the chat: its last words before each message it
    /// was given (yours, steered in while it talked, start a new part), so nothing it said to
    /// the group is lost, and none of the asides between its steps go in. An error, if that's
    /// all it has.
    private func reply(in seat: String, after promptID: String, since sent: Date, api: OpenCodeAPI) async throws -> (text: String, error: String?, steps: [Message.ToolCall]) {
        let messages = try await api.messages(session: seat, limit: 60).data
        let start = messages.firstIndex { $0.id == promptID }.map { $0 + 1 }
        let since = sent.timeIntervalSince1970 * 1000 - 2000
        var parts: [String] = []
        var part = ""
        var error: String?
        var steps: [Message.ToolCall] = []
        for (index, message) in messages.enumerated() {
            guard start.map({ index >= $0 }) ?? (message.created >= since) else { continue }
            switch message {
            case .user:
                if !part.isEmpty { parts.append(part) }
                part = ""
            case .assistant(let answer):
                for case .tool(let call) in answer.content { steps.append(call) }
                let words = answer.content.compactMap { block -> String? in
                    if case .text(let text) = block { text.text } else { nil }
                }
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                if !words.isEmpty { part = words }
                error = answer.error?.message
            default:
                break
            }
        }
        if !part.isEmpty { parts.append(part) }
        // A part that's only a pass, beside one that says something, is left out.
        let said = parts.filter { !Self.isPass($0) }
        return ((said.isEmpty ? parts.suffix(1) : said).joined(separator: "\n\n"), error, steps)
    }

    /// A step as it's kept with the chat: what it printed, cut short, so the log stays small.
    private static func trimmed(_ call: Message.ToolCall) -> Message.ToolCall {
        func cut(_ output: [Message.ToolOutput]) -> [Message.ToolOutput] {
            output.map { item in
                if case .text(let text) = item, text.count > 4000 { return .text(String(text.prefix(4000)) + "…") }
                return item
            }
        }
        var call = call
        switch call.state {
        case .completed(let input, let output, let metadata): call.state = .completed(input: input, output: cut(output), metadata: metadata)
        case .failed(let input, let error, let output, let metadata): call.state = .failed(input: input, error: error, output: output.map(cut), metadata: metadata)
        case .streaming, .running: break
        }
        return call
    }

    /// "PASS", "Pass.", "[pass] nothing to add": a bot with nothing to say.
    static func isPass(_ text: String) -> Bool {
        text.count < 80 && text.range(of: #"^\W*pass\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What a bot is told at its turn: what was said since it last spoke.
    private func turnText(for bot: Bot, in group: BotGroup, unheard: [GroupMessage], wrapUp: Bool) -> String {
        var text = ""
        if let taken = group.retracted?[bot.id] {
            text += "The user took back their message starting \"\(taken)\" and everything said after it. Set all of that aside: it no longer stands.\n\n"
        }
        if unheard.isEmpty {
            text = "Nothing new in \"\(group.name)\" since you last spoke.\n"
        } else {
            text = "New in \"\(group.name)\" since you last spoke:\n"
            if unheard.count > 40 { text += "\n(Earlier messages left out.)\n" }
            for message in unheard.suffix(40) {
                text += "\n\(name(of: message.author))\(message.kind == .wrapUp ? " (wrap-up)" : ""): \(message.text)\n"
            }
        }
        if wrapUp {
            text += "\nWrap up this discussion now, the one since the user last wrote: in a few short lines, what was decided, what's still open, and who does what next. Write to the user as \"you\". Don't reply PASS."
        } else {
            text += "\nYour turn, \(bot.name). Reply to the group, or just PASS if you have nothing new to add."
        }
        return text
    }

    private func name(of author: String?) -> String {
        author.map { app?.bots.bot($0)?.name ?? "A bot that left" } ?? "User"
    }

    // MARK: Seats

    /// The bot's seat in the chat, made the first time it's needed.
    private func seat(of bot: Bot, in id: String, api: OpenCodeAPI) async throws -> String {
        if let seat = group(id)?.seats[bot.id] { return seat }
        guard let group = group(id), let app else { throw CancellationError() }
        let model = bot.model ?? app.workspace.session(bot.sessionID)?.model
        let session = try await api.createSession(directory: bot.directory, title: "\(bot.name) in \(group.name)", model: model, permissions: Self.seatRules(for: bot))
        app.workspace.seats.insert(session.id)
        try? await api.setMetadata(session: session.id, .object(["kuvo": .object(["seat": .object(["group": .string(id), "bot": .string(bot.id)])])]))
        try await api.setInstruction(session: session.id, key: Self.seatKey, text: seatInstructions(for: bot, in: group))
        guard let index = list.firstIndex(where: { $0.id == id }) else { return session.id }
        list[index].seats[bot.id] = session.id
        save()
        return session.id
    }

    /// A seat talks and looks things up; it doesn't change anything, and never waits for answers.
    private static func seatRules(for bot: Bot) -> [PermissionRule] {
        let approval = UserDefaults.standard.string(forKey: ToolApproval.key).flatMap(ToolApproval.init) ?? .approveAll
        var rules = ["edit", "write", "patch", "question", "external_directory"].map { PermissionRule(action: $0, effect: .deny) }
        if approval == .askFirst {
            rules += ["shell", "webfetch"].map { PermissionRule(action: $0, effect: .deny) }
        }
        rules.append(PermissionRule(action: "external_directory", resource: (bot.folder as NSString).appendingPathComponent("*"), effect: .allow))
        return rules
    }

    private func seatInstructions(for bot: Bot, in group: BotGroup) -> String {
        let others = group.members.filter { $0 != bot.id }.compactMap { app?.bots.bot($0) }
        let who = others.map { other in other.name + (other.job.isEmpty ? "" : " (\(other.job))") }.joined(separator: ", ")
        let lead = group.lead.flatMap { app?.bots.bot($0) }
        let job = bot.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = """
        You are \(bot.name), one of the user's bots in Kuvo Code\(bot.job.isEmpty ? "" : ": \(bot.job)").\(Personalities.shared.personality(bot.personality).map { " \($0.instruction)" } ?? "")\(job.isEmpty ? "" : "\nYour job:\n\(job)\n")
        Your memory file is "\(bot.memoryFile)": read it for context on your work.

        This conversation is your seat in "\(group.name)", a group chat between the user and these bots: \(who.isEmpty ? "just you" : who), and you. \
        \(lead.map { $0.id == bot.id ? "You lead it." : "\($0.name) leads it." } ?? "")\(group.purpose.map { $0.isEmpty ? "" : " The chat is for: \($0)" } ?? "")

        Each message you get here holds what was said in the chat since you last spoke, and means it's your turn. Your reply is posted \
        to the chat as your message, so write it to the group: a few sentences, plain and to the point, like a colleague in a team \
        chat. Add something new: build on what others said instead of repeating it, disagree when you do, and ask someone directly \
        with @Name. Write to the user as "you". If you have nothing new to add, reply with just PASS.

        You can look things up before you answer (read files, search, run commands that don't change anything) when it helps. \
        Don't change files or start the work here: the chat is for talking it through. When something needs doing, say who should \
        do it; the user will ask them in their own conversation.

        \(Bots.identityNote)
        """
        if lead?.id == bot.id {
            text += """

            \nYou lead this chat. When the user brings something up, you go first: frame it in a line or two and say who should \
            weigh in on what. Keep it moving and short. When you're asked to wrap up, sum up what was decided, what's still open \
            and who does what.
            """
        }
        return text
    }

    /// Tells every seat in the chat who's there now.
    private func refreshSeats(of group: BotGroup) async {
        for (botID, seat) in group.seats {
            guard let bot = app?.bots.bot(botID), let api = app?.workspace.api(forFolder: bot.directory) else { continue }
            try? await api.setInstruction(session: seat, key: Self.seatKey, text: seatInstructions(for: bot, in: group))
        }
    }

    private func deleteSeat(_ seat: String, of botID: String) async {
        app?.workspace.seats.remove(seat)
        guard let bot = app?.bots.bot(botID) else { return }
        try? await app?.workspace.api(forFolder: bot.directory)?.deleteSession(seat)
    }

    // MARK: Remembering

    /// A bot's own conversation remembers its chats, as you'd remember a meeting: a recap of
    /// each in its instructions, and the whole of each in a file in its folder.
    /// `changed` is the one chat whose file needs writing again; nil writes them all.
    private func remember(_ botID: String, changed: String? = nil, forgetting gone: String? = nil) async {
        guard let app, let bot = app.bots.bot(botID), let api = app.workspace.api(forFolder: bot.directory) else { return }
        let folder = (bot.folder as NSString).appendingPathComponent("groups")
        if let gone { await removeFile((folder as NSString).appendingPathComponent("\(gone).md"), of: bot) }
        let chats = list.filter { $0.members.contains(botID) && !messages(in: $0.id).isEmpty }
            .sorted { (messages(in: $0.id).last?.time ?? $0.created) > (messages(in: $1.id).last?.time ?? $1.created) }
        guard !chats.isEmpty else {
            try? await api.removeInstruction(session: bot.sessionID, key: Self.memoryKey)
            return
        }
        var text = """
        You also take part in group chats in Kuvo Code, with the user and other bots. You remember them as you would a meeting: \
        a recap of each is below, newest first, and the whole of each is in a file in "\(folder)". When the user mentions one of \
        these chats, or something talked about there, go by this, and read the file when you need more. What's marked \
        "\(bot.name)" is what you said.
        """
        for (index, chat) in chats.enumerated() {
            let file = (folder as NSString).appendingPathComponent("\(chat.id).md")
            if changed == nil || changed == chat.id { await write(transcript(of: chat), to: file, of: bot) }
            guard index < 4 else { continue }
            let with = chat.members.filter { $0 != botID }.compactMap { app.bots.bot($0)?.name }
            text += "\n\n## \"\(chat.name)\"\(with.isEmpty ? "" : " with " + with.joined(separator: ", ")), in \(file)\n"
            text += recap(of: chat)
        }
        try? await api.setInstruction(session: bot.sessionID, key: Self.memoryKey, text: text)
    }

    /// The last few discussions: each one's start (what you asked), and its wrap-up or its last
    /// few messages, cut short.
    private func recap(of chat: BotGroup) -> String {
        // A discussion starts with a message of yours after the bots have spoken.
        var discussions: [[GroupMessage]] = []
        for message in messages(in: chat.id) where message.kind != .note {
            if discussions.isEmpty || (message.author == nil && discussions[discussions.count - 1].last?.author != nil) {
                discussions.append([message])
            } else {
                discussions[discussions.count - 1].append(message)
            }
        }
        let lines = discussions.suffix(3).flatMap { discussion -> [String] in
            let asked = discussion.prefix { $0.author == nil }
            let rest = discussion.dropFirst(asked.count)
            let shown = rest.last { $0.kind == .wrapUp }.map { [$0] } ?? Array(rest.suffix(4))
            return (asked + shown).map { message in
                let words = message.text.count > 500 ? message.text.prefix(500) + "…" : Substring(message.text)
                let when = message.time.formatted(date: .abbreviated, time: .shortened)
                return "\(name(of: message.author))\(message.kind == .wrapUp ? " (wrap-up)" : "") · \(when): \(words)"
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The whole chat, as Markdown.
    private func transcript(of chat: BotGroup) -> String {
        let names = chat.members.compactMap { app?.bots.bot($0)?.name }
        var text = "# \(chat.name)\n\nA group chat in Kuvo Code between the user and \(names.joined(separator: ", ")).\n"
        for message in messages(in: chat.id) {
            let when = message.time.formatted(date: .abbreviated, time: .shortened)
            switch message.kind {
            case .note: text += "\n_\(message.text)_\n"
            case .message, .wrapUp: text += "\n**\(name(of: message.author))**\(message.kind == .wrapUp ? " (wrap-up)" : "") · \(when)\n\n\(message.text)\n"
            }
        }
        return text
    }

    /// After a chat moves on, its bots remember it: once it's been quiet for a moment.
    private func rememberSoon(_ id: String) {
        syncs[id]?.cancel()
        syncs[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, let group = self.group(id) else { return }
            for bot in group.members { await self.remember(bot, changed: id) }
            self.syncs[id] = nil
        }
    }

    private func write(_ text: String, to path: String, of bot: Bot) async {
        if let machine = bot.machine {
            guard let connection = app?.machines.engine(machine)?.machine.connection else { return }
            let file = FileManager.default.temporaryDirectory.appending(path: "kuvo-group-\(UUID().uuidString).md")
            defer { try? FileManager.default.removeItem(at: file) }
            guard (try? Data(text.utf8).write(to: file)) != nil else { return }
            let quoted = SSHConnection.quoted(path)
            _ = try? await connection.run("mkdir -p \"$(dirname \(quoted))\" && cat >\(quoted)", input: file)
        } else {
            let url = URL(filePath: path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url, options: .atomic)
        }
    }

    private func removeFile(_ path: String, of bot: Bot) async {
        if let machine = bot.machine {
            _ = await Task.detached { RemoteShell.run("rm -f \(SSHConnection.quoted(path))", on: machine) }.value
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: Messages

    @discardableResult
    private func append(_ message: GroupMessage, to id: String) -> GroupMessage {
        var messages = messages(in: id)
        messages.append(message)
        logs[id] = messages
        saveLog(id)
        rememberSoon(id)
        return message
    }

    private func note(_ text: String, in id: String) {
        append(GroupMessage(id: Self.newID(), author: nil, text: text, time: .now, kind: .note), to: id)
    }

    private func setHeard(_ message: String, by botID: String, in id: String) {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        // Only ever forward: a later message may have reached it already.
        let all = messages(in: id)
        let current = list[index].heard[botID].flatMap { heard in all.firstIndex { $0.id == heard } } ?? -1
        guard let new = all.firstIndex(where: { $0.id == message }), new > current else { return }
        list[index].heard[botID] = message
        save()
    }

    private static func newID() -> String { "gm_" + UUID().uuidString.lowercased() }

    // MARK: Storage

    private static func load() -> [BotGroup] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? decoder.decode([BotGroup].self, from: data)) ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: AppInfo.supportDirectory, withIntermediateDirectories: true)
            try Self.encoder.encode(list).write(to: Self.file, options: .atomic)
        } catch {
            log.error("Group chats weren't saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadLog(_ id: String) -> [GroupMessage] {
        guard let data = try? Data(contentsOf: folder.appending(path: "\(id).json")) else { return [] }
        return (try? decoder.decode([GroupMessage].self, from: data)) ?? []
    }

    private func saveLog(_ id: String) {
        guard let messages = logs[id] else { return }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try Self.encoder.encode(messages).write(to: Self.folder.appending(path: "\(id).json"), options: .atomic)
        } catch {
            log.error("A group chat's messages weren't saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
