import Foundation
import OpenCodeKit

/// One session, live: its transcript, what's pending, and the actions on it.
@Observable
final class SessionModel {
    var session: Session
    private(set) var transcript: Transcript {
        didSet {
            transcriptVersion &+= 1
            // Answers in progress go once their question has (answered, or dismissed).
            if !questionProgress.isEmpty {
                let open = Set(transcript.forms.map(\.id))
                questionProgress = questionProgress.filter { open.contains($0.key) }
            }
        }
    }
    /// Goes up with each change to the transcript, so what's made from it (the conversation's
    /// rows) is made again only then.
    private(set) var transcriptVersion = 0
    private(set) var isLoaded = false
    /// Your answers to the agent's questions so far, by form: kept while you look elsewhere.
    var questionProgress: [String: QuestionProgress] = [:]
    /// Goes up when the agent asks something while the composer is empty: it lets go of the
    /// keyboard, for the question.
    private(set) var composerBlur = 0
    /// Showing the conversation as last seen (its machine is connecting), not the engine's.
    private(set) var isCopy = false
    /// Made from a copy: no engine to read from until its machine is back.
    private var waitsForEngine = false
    /// Whether its engine can be reached (a machine's is connected); set by the workspace.
    @ObservationIgnored var isReachable: () -> Bool = { true }
    /// What's done here waits while its engine can't be reached: it would only fail.
    private var canReach: Bool { !waitsForEngine && isReachable() }
    private(set) var changes: [FileDiff] = []
    /// Comments on lines of the changes, sent with the next message.
    var reviewComments: [ReviewComment] = []
    /// What's in the composer, kept while you look at other sessions and across launches.
    var draftText: String {
        get { Drafts.shared[id].text }
        set { Drafts.shared[id].text = newValue }
    }

    var draftFiles: [URL] {
        get { Drafts.shared[id].files }
        set { Drafts.shared[id].files = newValue }
    }

    /// What you're replying to, over the composer, each with your answer to it.
    var draftQuotes: [Drafts.Quote] {
        get { Drafts.shared[id].quotes }
        set {
            Drafts.shared[id].quotes = newValue
            Drafts.shared[id].quote = nil
        }
    }

    /// The quote whose answer takes the keyboard: the one just added.
    private(set) var quoteFocus: UUID?

    /// Messages you sent here, oldest first, for going back through with ↑.
    var sentMessages: [String] {
        var texts: [String] = []
        for message in transcript.messages {
            let text: String
            switch message {
            case .user(let user): text = ReviewComments.split(Attachments.split(CommandMessages.shared.text(of: user)).text).text
            // Commands you ran come back as you typed them.
            case .shell(let shell): text = "!" + shell.command
            default: continue
            }
            if !text.isEmpty, text != texts.last { texts.append(text) }
        }
        return texts
    }
    /// Goes up to put the cursor in the composer (after a message comes back to it for editing).
    private(set) var composerFocus = 0
    /// Goes up to open the find bar on the conversation (⌘F).
    private(set) var findRequest = 0
    /// Goes up with each message you send, so the conversation goes back to its end.
    private(set) var sent = 0
    /// What the find bar should look for when it opens, from a search in the sidebar.
    var findPreset: String?

    func showFind(_ query: String? = nil) {
        findPreset = query
        findRequest += 1
    }

    /// Started by another session's agent to do part of its task.
    var isSubagent: Bool { session.parentID != nil }

    /// The project's folders as they're set now, the primary one first.
    func folders() -> [String] {
        [session.location.directory] + projectFolders()
    }

    func focusComposer() { composerFocus += 1 }

    /// A question came: the composer lets go of the keyboard for it, unless you're writing.
    func yieldComposer() {
        if draftText.isEmpty, draftQuotes.allSatisfy({ $0.response.isEmpty }) { composerBlur += 1 }
    }

    /// Replies to all of a message: it goes over the composer as a quote, to answer under.
    func reply(to text: String) {
        addQuote(text, how: "message")
    }

    /// Adds a quote to answer (all of a message, or a part you selected), after those there are,
    /// and its answer takes the keyboard.
    func addQuote(_ text: String, how: String) {
        let count = draftQuotes.count
        guard let id = Drafts.shared.addQuote(text, to: self.id) else { return }
        quoteFocus = id
        if draftQuotes.count > count { Analytics.shared.track("message_replied", ["how": how]) }
    }
    /// Queued messages wait for Resume: after Stop, a failed run, or when the app finds them
    /// waiting at launch.
    private(set) var isQueuePaused = false
    var failure: String?

    /// Its engine: a machine's changes with each connection to it.
    private var api: OpenCodeAPI
    private var reloadTask: Task<Void, Never>?
    /// Reads in a row that found nothing where the copy has a conversation.
    private var emptyReads = 0
    private var changesTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    /// The last message on its way out; each waits for the one before, so the engine gets
    /// (and queues) them in the order they were written.
    private var sending: Task<Void, Never>?
    /// Messages sent from here, so a command's message can be told from them.
    private var sentIDs: Set<String> = []
    /// Commands run from here whose messages haven't arrived yet, oldest first.
    private var runningCommands: [RunningCommand] = []

    private struct RunningCommand {
        var id = UUID()
        /// What its message shows: "/review main".
        var command: String
        var started: Date
        /// The messages there were already, sent or waiting.
        var before: Set<String>
    }

    /// The project's other folders, as they're set now.
    private let projectFolders: () -> [String]

    init(session: Session, api: OpenCodeAPI, projectFolders: @escaping () -> [String] = { [] }) {
        self.session = session
        self.api = api
        self.projectFolders = projectFolders
        transcript = Transcript(sessionID: session.id)
    }

    var id: String { session.id }
    var isRunning: Bool { transcript.isRunning }

    /// The agent and model the next message goes to.
    var agent: String { session.agent ?? "build" }

    /// Messages waiting for the agent, in the order it gets them: those for its next step, then
    /// the queue. A message sent while it's idle goes straight to the transcript instead, and
    /// stays there while the run it starts gets going.
    var waiting: [Transcript.Pending] {
        let pending = transcript.pending.filter { !starters.contains($0.id) }
        return (isRunning ? pending.filter { $0.delivery == .steer } : []) + pending.filter { $0.delivery == .queue }
    }

    /// Messages sent while the agent was idle, until it has them: each starts a run, and the run
    /// begins a moment before the agent takes it, which isn't waiting.
    private var starters: Set<String> = []

    private var hasQueue: Bool { transcript.pending.contains { $0.delivery == .queue } }

    /// Running, or about to: a message for the next step starts a run as soon as it lands.
    private var isBusy: Bool { transcript.isRunning || transcript.pending.contains { $0.delivery == .steer } }

    /// Waiting messages being taken back for editing, and what the engine said about each:
    /// true when the cancel won, false when the agent got it first.
    private var editing: Set<String> = []
    private var settledEdits: [String: Bool] = [:]
    private var isRetrying = false

    /// Shows the conversation as last seen, until `load` reads the engine's.
    func show(_ copy: [Message]) {
        transcript.load(messages: copy, inbox: [], permissions: [], forms: [], isRunning: false)
        isCopy = true
        waitsForEngine = true
    }

    /// A machine's session keeps its conversation as last seen, to show while the machine is
    /// out of reach (see `SessionCopies`).
    private func keepCopy() {
        guard api.folderPrefix != nil, !isSubagent, !transcript.messages.isEmpty else { return }
        // The latest, as opening it reads them: earlier ones are read again as you scroll up.
        SessionCopies.save(.init(session: session, messages: Array(transcript.messages.suffix(Self.pageSize))))
    }

    /// How many messages one read takes: the latest on opening, then as many earlier ones each
    /// time the conversation's top comes into view.
    static let pageSize = 200
    /// Where the messages not read yet end, while there are earlier ones.
    private(set) var earlierCursor: String?
    private(set) var isLoadingEarlier = false
    var hasEarlier: Bool { earlierCursor != nil }

    /// The page's way back to earlier messages, when it was full (so there may be more).
    private static func cursor(before page: Page<Message>) -> String? {
        page.data.count >= pageSize ? (page.cursor?.next ?? page.cursor?.previous) : nil
    }

    /// Reads every earlier message there is (to search them), up to a great many.
    func loadAllEarlier() async {
        while hasEarlier, transcript.messages.count < 20_000 {
            // After one already on its way (scrolling up).
            while isLoadingEarlier { try? await Task.sleep(for: .milliseconds(100)) }
            let before = transcript.messages.count
            await loadEarlier()
            if transcript.messages.count == before, !isLoadingEarlier { return }
        }
    }

    /// Reads the messages before those on screen, and puts them ahead of them.
    func loadEarlier() async {
        guard let cursor = earlierCursor, !isLoadingEarlier, !waitsForEngine else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        guard let page = try? await api.messages(session: id, limit: Self.pageSize, before: cursor) else { return }
        let known = Set(transcript.messages.map(\.id))
        let older = page.data.filter { !known.contains($0.id) }
        guard !older.isEmpty else {
            earlierCursor = nil
            return
        }
        transcript.messages = older + transcript.messages
        earlierCursor = Self.cursor(before: page)
    }

    /// Its machine connected again, through `api`.
    func reconnect(_ api: OpenCodeAPI) {
        self.api = api
        waitsForEngine = false
    }

    func load() async {
        guard !waitsForEngine else { return }
        async let messages = api.messages(session: id, limit: Self.pageSize)
        async let inbox = api.inbox(session: id)
        async let permissions = api.permissions(session: id)
        async let forms = api.forms(session: id)
        async let active = api.activeSessions()
        do {
            let page = try await messages
            // Nothing, where its copy has a conversation: an engine just started (a new version
            // setting itself up) can answer that for a moment. The copy stays; read again soon.
            if page.data.isEmpty, isCopy, !transcript.messages.isEmpty, emptyReads < 4 {
                emptyReads += 1
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    await load()
                }
                return
            }
            emptyReads = 0
            // Earlier messages read as you scrolled up stay, ahead of the latest: only those this
            // read, not a saved copy's (whose start it doesn't know), and only when they reach the
            // latest page; after a gap (many messages while it was away), it starts again from it.
            let earlier = transcript.messages
            let reaches = page.data.first.map { first in earlier.last.map { $0.id >= first.id } ?? false } ?? false
            let kept = !isCopy && reaches ? page.data.first.map { first in earlier.filter { $0.id < first.id } } ?? [] : []
            if kept.isEmpty { earlierCursor = Self.cursor(before: page) }
            transcript.load(
                messages: kept + page.data,
                inbox: (try? await inbox) ?? [],
                permissions: (try? await permissions) ?? [],
                forms: (try? await forms) ?? [],
                isRunning: (try? await active)?.contains(id) ?? false
            )
            // A queue left waiting (the app quit mid-run, say) waits for Resume rather than
            // starting on its own. Read again later (a reconnect), it carries on.
            if !isLoaded, !isRunning, hasQueue {
                isQueuePaused = true
            } else if isLoaded, !isRunning, hasQueue, !isQueuePaused {
                scheduleDrain()
            }
            // A subagent's session is the engine's to set up; it only gets shown.
            if !isLoaded, !isSubagent { await syncFolders() }
            isLoaded = true
            isCopy = false
            keepCopy()
        } catch {
            failure = error.localizedDescription
            // Its machine is back but this one couldn't be read: no longer waiting, so the
            // failure shows (and what you do goes to the engine, which may answer now).
            if !waitsForEngine { isCopy = false }
        }
        refreshChanges()
    }

    func apply(_ event: ServerEvent) {
        transcript.apply(event)
        if !runningCommands.isEmpty { noteCommandMessages() }
        if transcript.isStale { scheduleReload() }
        switch event.type {
        case "session.tool.success", "session.execution.succeeded", "session.execution.failed", "session.revert.committed":
            refreshChanges()
        default:
            break
        }
        switch event.type {
        case "session.execution.started":
            drainTask?.cancel()
        case "session.execution.succeeded", "session.execution.interrupted":
            scheduleDrain()
            keepCopy()
        case "session.execution.failed":
            // Don't run the rest of the queue into the same error.
            if hasQueue { isQueuePaused = true }
            keepCopy()
        case "session.inbox.enqueued":
            // Queued while nothing runs: the engine waits for a run to end, so nudge it.
            if !transcript.isRunning, !isQueuePaused, hasQueue { scheduleDrain() }
        case "session.inbox.cancelled", "session.inbox.delivered":
            if let id = try? event.payload(as: EventPayload.InboxChanged.self).inboxID {
                starters.remove(id)
                if editing.contains(id) { settledEdits[id] = event.type == "session.inbox.cancelled" }
            }
        case "session.revert.committed":
            // Final: there's nothing left to redo, and the conversation no longer ends at the undo.
            session.revert = nil
            undone = nil
        default:
            break
        }
        if transcript.pending.isEmpty { isQueuePaused = false }
    }

    // MARK: Actions

    /// Sends a message with `files`, as `model` can take them (see `Attachments`). While the
    /// agent works, it gets the message at its next step, ahead of the queue. With `queue`, the
    /// message waits for the run, and everything queued before it, to finish.
    /// The first message in a folder the engine has just opened can come before its tools (the
    /// browser's, the integrations') are connected, and the model would go without them, to the
    /// browser for a service it has an integration for: it waits for them, once.
    @ObservationIgnored private var toolsChecked = false

    private func waitForTools() async {
        guard !toolsChecked else { return }
        toolsChecked = true
        await api.waitForTools(in: session.location.directory)
    }

    func send(_ text: String, files: [URL] = [], for model: Model?, queue: Bool = false) {
        let written = text
        let comments = reviewComments
        let text = ReviewComments.text(text.trimmingCharacters(in: .whitespacesAndNewlines), adding: comments)
        guard !text.isEmpty || !files.isEmpty else { return }
        reviewComments = []
        let id = Identifier.message()
        sentIDs.insert(id)
        // With nothing running (or about to) and nothing queued, there's nothing to wait for.
        let delivery: InboxItem.Delivery = queue && (isBusy || hasQueue) ? .queue : .steer
        if delivery == .steer { isQueuePaused = false }
        if delivery == .steer, !isBusy { starters.insert(id) }
        commitUndo()
        transcript.addLocal(id: id, text: text, delivery: delivery, files: files)
        var props = Analytics.model(provider: model?.providerID ?? session.model?.providerID, model: model?.id ?? session.model?.id)
        props["mode"] = Analytics.mode(agent)
        props["queued"] = delivery == .queue
        props["files"] = !files.isEmpty
        props["comments"] = !comments.isEmpty
        Analytics.shared.track("message_sent", props)
        let previous = sending
        sending = Task {
            await previous?.value
            do {
                // Converting a photo takes a moment; keep it off the main thread. A machine's engine
                // can't read this Mac's files: they go to it inline, or copied there.
                let machine = RemoteFolder.machine(of: session.location.directory)
                let prepared = await Task.detached { machine.map { Attachments.prepare(files, for: model, machine: $0) } ?? Attachments.prepare(files, for: model) }.value
                let message = Attachments.text(text, adding: prepared.paths)
                await waitForTools()
                try await api.prompt(session: self.id, id: id, text: message, files: prepared.files, delivery: delivery)
            } catch {
                transcript.removeLocal(id: id)
                reviewComments = comments + reviewComments
                // It didn't go: back in the composer, ahead of anything written since.
                restoreDraft(written, files: files)
                failure = error.localizedDescription
            }
        }
    }

    /// Sends what's in the composer: a message, or a command for "/name arguments".
    func submit(_ text: String, files: [URL], for model: Model?, queue: Bool, commands: [Command]) {
        sent += 1
        if let command = Self.shellCommand(in: text) {
            runShell(command)
        } else if let (name, arguments) = SlashCommands.parse(text, commands: commands) {
            runCommand(name, arguments: arguments, files: files, for: model, queue: queue)
        } else {
            send(text, files: files, for: model, queue: queue)
        }
    }

    /// "!" at the start of a message: the rest is a command to run in the session's folder.
    static func shellCommand(in text: String) -> String? {
        guard text.hasPrefix("!") else { return nil }
        let command = text.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    /// Runs a command in the session's folder (on its machine, for a project on one) as you,
    /// right away, without waking the agent; it and its output join the conversation, and the
    /// agent gets them with your next message.
    func runShell(_ command: String) {
        guard canReach else { return }
        Analytics.shared.track("shell_run")
        let previous = sending
        sending = Task {
            await previous?.value
            do { try await api.runShell(session: id, command: command) } catch { failure = error.localizedDescription }
        }
    }

    /// Runs a command, with files as a message would carry them. With `queue`, it waits for the
    /// run, as a queued message does.
    func runCommand(_ name: String, arguments: String, files: [URL] = [], for model: Model? = nil, queue: Bool = false) {
        guard canReach else { return }
        let running = RunningCommand(
            command: arguments.isEmpty ? "/\(name)" : "/\(name) \(arguments)",
            started: Date(),
            before: Set(userMessageIDs + transcript.pending.map(\.id))
        )
        runningCommands.append(running)
        // The engine's own commands by name; yours (named by you) as "custom".
        Analytics.shared.track("command_run", ["command": ["init", "review"].contains(name) ? name : "custom"])
        let delivery: InboxItem.Delivery = queue && (isBusy || hasQueue) ? .queue : .steer
        let previous = sending
        sending = Task {
            await previous?.value
            do {
                let machine = RemoteFolder.machine(of: session.location.directory)
                let prepared = await Task.detached { machine.map { Attachments.prepare(files, for: model, machine: $0) } ?? Attachments.prepare(files, for: model) }.value
                try await api.runCommand(session: id, name: name, arguments: Attachments.text(arguments, adding: prepared.paths), files: prepared.files, delivery: delivery)
            } catch {
                runningCommands.removeAll { $0.id == running.id }
                failure = error.localizedDescription
            }
        }
    }

    private var userMessageIDs: [String] {
        transcript.messages.compactMap { if case .user(let user) = $0 { user.id } else { nil } }
    }

    /// Gives each command its message: the first new one, oldest command first, that wasn't
    /// sent from here or waiting already, and came after the command was run. A command that
    /// runs elsewhere (as a subagent's task) never gets one here, so it's let go after a while.
    private func noteCommandMessages() {
        runningCommands.removeAll { Date().timeIntervalSince($0.started) > 600 }
        while let running = runningCommands.first {
            let since = running.started.timeIntervalSince1970 * 1000 - 2000
            let message = transcript.messages.lazy.compactMap { if case .user(let user) = $0 { user } else { nil } }.first {
                !running.before.contains($0.id) && !sentIDs.contains($0.id) && CommandMessages.shared[$0.id] == nil && $0.time.created >= since
            }
            guard let message else { return }
            CommandMessages.shared.note(message.id, command: running.command)
            runningCommands.removeFirst()
        }
    }

    /// Stops the agent. Waiting messages stay, queued and paused until Resume.
    func stop() {
        Task {
            await holdWaiting()
            try? await api.interrupt(session: id)
        }
    }

    /// Before an interrupt: what's waiting stays where it is, paused, instead of being handed
    /// over as the step ends or started by the nudge after it.
    private func holdWaiting() async {
        drainTask?.cancel()
        let steering = transcript.pending.filter { $0.delivery == .steer && !$0.isLocal }
        if hasQueue || !steering.isEmpty { isQueuePaused = true }
        for item in steering { try? await api.setDelivery(session: id, item: item.id, delivery: .queue) }
    }

    func cancelPending(_ item: Transcript.Pending) {
        guard canReach else { return }
        if item.isLocal { transcript.removeLocal(id: item.id); return }
        Task { try? await api.cancelInbox(session: id, item: item.id) }
    }

    #if DEBUG
    /// KUVO_DEMO_WAITING: messages shown waiting, without sending them.
    func showWaiting(_ items: [Transcript.Pending]) {
        transcript.pending = items
    }
    #endif

    /// Steers a queued message in: the agent takes it at its next step, without waiting for the
    /// run to end (and without stopping the step it's on).
    func steer(_ item: Transcript.Pending) {
        guard canReach, !item.isLocal, item.delivery == .queue else { return }
        Analytics.shared.track("message_steered")
        Task {
            do {
                try await api.setDelivery(session: id, item: item.id, delivery: .steer)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// Gives a waiting message to the agent right away: its current step stops, and it carries
    /// on from there with this message.
    func sendNow(_ item: Transcript.Pending) {
        guard canReach else { return }
        Analytics.shared.track("message_sent_now")
        guard !item.isLocal else { return }
        isQueuePaused = false
        let running = transcript.isRunning
        Task {
            do {
                // Steering wakes an idle session; a running one gets it once the step stops.
                if item.delivery == .queue { try await api.setDelivery(session: id, item: item.id, delivery: .steer) }
                if running || item.delivery == .steer { try await api.interrupt(session: id, resume: true) }
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// Takes a waiting message back into the composer, with its files and comments, ahead of
    /// anything already there.
    func edit(_ item: Transcript.Pending) {
        guard canReach else { return }
        guard !item.isLocal, !editing.contains(item.id) else { return }
        editing.insert(item.id)
        Task {
            defer {
                editing.remove(item.id)
                settledEdits[item.id] = nil
            }
            do {
                try await api.cancelInbox(session: id, item: item.id)
            } catch {
                failure = error.localizedDescription
                return
            }
            // The engine says which won: the cancel, or the agent taking it first (a cancel
            // that comes too late changes nothing, and says nothing).
            for _ in 0..<40 where settledEdits[item.id] == nil { try? await Task.sleep(for: .milliseconds(50)) }
            let cancelled = settledEdits[item.id] ?? (!transcript.pending.contains { $0.id == item.id } && !transcript.messages.contains { $0.id == item.id })
            guard cancelled else { return }
            restoreDraft(item.text, files: item.files)
        }
    }

    /// Puts a message back in the composer, ahead of anything already there: its text, its
    /// attached files, its comments on the changes and what it replied to.
    private func restoreDraft(_ message: String, files picked: [URL] = []) {
        let (withComments, paths) = Attachments.split(message)
        let (quoted, comments) = ReviewComments.split(withComments)
        let (quotes, text) = Quoting.draft(of: quoted)
        draftQuotes = quotes + draftQuotes
        draftText = [text, draftText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let files = picked + paths.map { URL(filePath: $0) }
        draftFiles = files + draftFiles.filter { !files.contains($0) }
        reviewComments = comments + reviewComments
        composerFocus += 1
    }

    /// What was in the composer before an undo, and after it: Redo puts the first back if the
    /// second is still there untouched.
    private struct ComposerState: Equatable {
        var text: String
        var files: [URL]
        var comments: [ReviewComment]
    }

    private var composerState: ComposerState {
        get { ComposerState(text: draftText, files: draftFiles, comments: reviewComments) }
        set {
            draftText = newValue.text
            draftFiles = newValue.files
            reviewComments = newValue.comments
        }
    }

    private var undone: (before: ComposerState, after: ComposerState)?

    /// A sent message's attached files that are still on this Mac.
    static func files(of message: Message.User) -> [URL] {
        (message.files ?? []).compactMap { file in
            guard case .uri(let uri) = file.source, let url = URL(string: uri), url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }

    /// The engine's copy of a message, with its attachments (a message seen arrive live
    /// doesn't carry them).
    private func stored(_ message: Message.User) async -> Message.User {
        let recent = (try? await api.messages(session: id, limit: 100).data) ?? []
        for case .user(let user) in recent where user.id == message.id { return user }
        return message
    }

    /// Takes the session back to before `message`: the agent stops, the conversation and the
    /// files it changed since go back, and the message returns to the composer to edit or
    /// send again. Redo brings it all back, until the next message makes it final.
    func undo(from message: Message.User) {
        guard canReach else { return }
        Analytics.shared.track("undo_used")
        Task {
            do {
                if isRunning {
                    await holdWaiting()
                    try await api.interrupt(session: id)
                    try await api.wait(session: id)
                }
                let message = await stored(message)
                session.revert = try await api.stageRevert(session: id, messageID: message.id)
                let before = composerState
                restoreDraft(CommandMessages.shared.text(of: message), files: Self.files(of: message))
                undone = (before, composerState)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// Sends a message again after its run failed. Its turn is taken back first, so the
    /// conversation reads as if it had gone through the first time.
    func retry(_ message: Message.User) {
        guard canReach else { return }
        guard !isRunning, !isRetrying else { return }
        isRetrying = true
        Task {
            defer { isRetrying = false }
            do {
                let user = await stored(message)
                let files = (user.files ?? []).compactMap { file -> OpenCodeAPI.PromptFile? in
                    if case .uri(let uri) = file.source { .init(uri: uri, name: file.name) } else { nil }
                }
                _ = try await api.stageRevert(session: id, messageID: user.id)
                if let command = CommandMessages.shared[user.id], let (name, arguments) = SlashCommands.split(command) {
                    runCommand(name, arguments: arguments, files: Self.files(of: user))
                    return
                }
                let id = Identifier.message()
                sentIDs.insert(id)
                starters.insert(id)
                transcript.addLocal(id: id, text: user.text, delivery: .steer)
                try await api.prompt(session: self.id, id: id, text: user.text, files: files)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// A message after an undo makes it final: the undone part goes now, in the same moment the
    /// message appears, rather than as the engine's word of it comes in.
    private func commitUndo() {
        guard let revert = session.revert else { return }
        transcript.commitRevert(to: revert.messageID)
        session.revert = nil
        undone = nil
    }

    /// Takes back an undo: the conversation and the files come back as they were.
    func redo() {
        guard canReach else { return }
        Analytics.shared.track("redo_used")
        Task {
            do {
                try await api.clearRevert(session: id)
                session.revert = nil
                if let undone, composerState == undone.after { composerState = undone.before }
                undone = nil
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// Edits the message that would go last, if there is one.
    @discardableResult
    func editLast() -> Bool {
        guard canReach else { return false }
        guard let item = waiting.last(where: { !$0.isLocal && !editing.contains($0.id) }) else { return false }
        edit(item)
        return true
    }

    /// After Plan mode's answer: switches to Build, then has the agent carry the plan out.
    func buildPlan() {
        guard canReach else { return }
        session.agent = "build"
        Task {
            do { try await api.selectAgent(session: id, agent: "build") } catch {
                failure = error.localizedDescription
                return
            }
            send("Go ahead and build it, as planned.", for: nil)
        }
    }

    /// Summarizes the conversation so far, to make room in the context window.
    func compact() {
        guard canReach else { return }
        Task {
            do { try await api.compact(session: id) } catch { failure = error.localizedDescription }
        }
    }

    /// Picks the queue up again after Stop or a failed run.
    func resumeQueue() {
        guard canReach else { return }
        isQueuePaused = false
        scheduleDrain(after: .zero)
    }

    /// The engine starts each queued message after a run that ends normally, but not after an
    /// interrupt (Stop, or Send Now) or when its run is woken by steering. So once the agent has
    /// been idle a moment, the next waiting message gets a nudge.
    private func scheduleDrain(after delay: Duration = .seconds(1.5)) {
        drainTask?.cancel()
        drainTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, !isQueuePaused, !transcript.isRunning,
                  let next = waiting.first(where: { !$0.isLocal }) ?? transcript.pending.first(where: { !$0.isLocal }) else { return }
            if next.delivery == .queue {
                try? await api.setDelivery(session: id, item: next.id, delivery: .steer)
            } else {
                try? await api.interrupt(session: id, resume: true)
            }
        }
    }

    func selectModel(_ model: ModelRef) {
        guard canReach else { return }
        guard !model.sameModel(as: session.model) || model.variant != session.model?.variant else { return }
        session.model = model
        Task {
            do { try await api.selectModel(session: id, model: model) } catch { failure = error.localizedDescription }
        }
    }

    var approval: ToolApproval { ToolApproval(rules: session.permissions) }

    func setApproval(_ approval: ToolApproval) {
        guard canReach else { return }
        // The rules for particular things (the project's folders, a bot's folder and its
        // wake-ups) stay, after the approval rules.
        let rules = approval.rules + (session.permissions ?? []).filter { $0.resource != "*" }
        session.permissions = rules
        Task {
            do { try await api.setPermissions(session: id, rules: rules) } catch { failure = error.localizedDescription }
        }
    }

    /// Gives the agent the project's folders as they're set now, if it doesn't have them yet:
    /// allowed in its permissions, and named in its instructions.
    func syncFolders() async {
        // As the engine knows them: a machine's folders are plain paths there.
        let folders = projectFolders().map(api.enginePath)
        let current = session.permissions ?? []
        let rules = ProjectFolders.permissions(current, folders: folders)
        guard rules != current else { return }
        do {
            try await api.setPermissions(session: id, rules: rules)
            session.permissions = rules
            if folders.isEmpty {
                try await api.removeInstruction(session: id, key: ProjectFolders.instructionKey)
            } else {
                try await api.setInstruction(session: id, key: ProjectFolders.instructionKey, text: ProjectFolders.instructions(primary: api.enginePath(session.location.directory), folders: folders))
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    func selectAgent(_ agent: String) {
        guard canReach else { return }
        guard agent != session.agent else { return }
        session.agent = agent
        Task {
            do { try await api.selectAgent(session: id, agent: agent) } catch { failure = error.localizedDescription }
        }
    }

    func reply(to request: PermissionRequest, _ decision: PermissionRequest.Decision, message: String? = nil) {
        guard canReach else { return }
        Analytics.shared.track("permission_answered", ["action": Analytics.action(request.action), "decision": decision.rawValue])
        Task {
            do { try await api.reply(session: id, permission: request.id, decision: decision, message: message) } catch { failure = error.localizedDescription }
        }
    }

    func answer(_ form: FormRequest, with answer: FormAnswer) {
        guard canReach else { return }
        Analytics.shared.track("question_answered", ["kind": form.isQuestion ? "question" : "form"])
        Task {
            do { try await api.reply(session: id, form: form.id, answer: answer) } catch { failure = error.localizedDescription }
        }
    }

    func dismiss(_ form: FormRequest, message: String? = nil) {
        guard canReach else { return }
        Analytics.shared.track("question_dismissed", ["kind": form.isQuestion ? "question" : "form"])
        Task { try? await api.dismiss(session: id, form: form.id, message: message) }
    }

    // MARK: Background refreshes

    private func scheduleReload() {
        guard reloadTask == nil else { return }
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            await load()
            reloadTask = nil
        }
    }

    private func refreshChanges() {
        guard !isSubagent else { return }
        changesTask?.cancel()
        changesTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let diff = try? await api.diff(session: id) else { return }
            changes = diff
        }
    }
}

extension OpenCodeAPI {
    /// Until the MCP servers of `directory` are connected (the engine connects them after it
    /// opens a folder; an integration's server can take a while the first time, as it's
    /// fetched), twenty seconds at most, and a moment more if they only just did: a message sent
    /// sooner reaches a model without their tools.
    func waitForTools(in directory: String) async {
        let deadline = ContinuousClock.now + .seconds(20)
        var waited = false
        while ContinuousClock.now < deadline {
            guard let servers = try? await mcpServers(directory: directory) else { return }
            if !servers.contains(where: { $0.status.status == "pending" }) {
                // Connected only just now: the engine takes a moment more to hand its tools out.
                if waited { try? await Task.sleep(for: .milliseconds(1500)) }
                return
            }
            waited = true
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}
