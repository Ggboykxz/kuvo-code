import Foundation
import OpenCodeKit

/// One session, live: its transcript, what's pending, and the actions on it.
@Observable
final class SessionModel {
    var session: Session
    private(set) var transcript: Transcript
    private(set) var isLoaded = false
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

    /// Messages you sent here, oldest first, for going back through with ↑.
    var sentMessages: [String] {
        var texts: [String] = []
        for message in transcript.messages {
            guard case .user(let user) = message else { continue }
            let text = ReviewComments.split(Attachments.split(user.text).text).text
            if !text.isEmpty, text != texts.last { texts.append(text) }
        }
        return texts
    }
    /// Goes up to put the cursor in the composer (after a message comes back to it for editing).
    private(set) var composerFocus = 0
    /// Queued messages wait for Resume: after Stop, a failed run, or when the app finds them
    /// waiting at launch.
    private(set) var isQueuePaused = false
    var failure: String?

    private let api: OpenCodeAPI
    private var reloadTask: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    /// The last message on its way out; each waits for the one before, so the engine gets
    /// (and queues) them in the order they were written.
    private var sending: Task<Void, Never>?

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
    /// the queue. A message sent while it's idle goes straight to the transcript instead.
    var waiting: [Transcript.Pending] {
        let pending = transcript.pending
        return (isRunning ? pending.filter { $0.delivery == .steer } : []) + pending.filter { $0.delivery == .queue }
    }

    private var hasQueue: Bool { transcript.pending.contains { $0.delivery == .queue } }

    func load() async {
        async let messages = api.messages(session: id, limit: 200)
        async let inbox = api.inbox(session: id)
        async let permissions = api.permissions(session: id)
        async let forms = api.forms(session: id)
        async let active = api.activeSessions()
        do {
            transcript.load(
                messages: try await messages.data,
                inbox: (try? await inbox) ?? [],
                permissions: (try? await permissions) ?? [],
                forms: (try? await forms) ?? [],
                isRunning: (try? await active)?.contains(id) ?? false
            )
            // A queue left waiting (the app quit mid-run, say) waits for Resume rather than
            // starting on its own.
            if !isLoaded, !isRunning, hasQueue { isQueuePaused = true }
            if !isLoaded { await syncFolders() }
            isLoaded = true
        } catch {
            failure = error.localizedDescription
        }
        refreshChanges()
    }

    func apply(_ event: ServerEvent) {
        transcript.apply(event)
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
        case "session.execution.failed":
            // Don't run the rest of the queue into the same error.
            if hasQueue { isQueuePaused = true }
        default:
            break
        }
    }

    // MARK: Actions

    /// Sends a message with `files`, as `model` can take them (see `Attachments`). While the
    /// agent works, it gets the message at its next step, ahead of the queue. With `queue`, the
    /// message waits for the run, and everything queued before it, to finish.
    func send(_ text: String, files: [URL] = [], for model: Model?, queue: Bool = false) {
        let comments = reviewComments
        let text = ReviewComments.text(text.trimmingCharacters(in: .whitespacesAndNewlines), adding: comments)
        guard !text.isEmpty || !files.isEmpty else { return }
        reviewComments = []
        let id = Identifier.message()
        // With nothing running and nothing queued, there's nothing to wait for.
        let delivery: InboxItem.Delivery = queue && (transcript.isRunning || hasQueue) ? .queue : .steer
        if delivery == .steer { isQueuePaused = false }
        transcript.addLocal(id: id, text: text, delivery: delivery, files: files)
        let previous = sending
        sending = Task {
            await previous?.value
            do {
                // Converting a photo takes a moment; keep it off the main thread.
                let prepared = await Task.detached { Attachments.prepare(files, for: model) }.value
                let message = Attachments.text(text, adding: prepared.paths)
                try await api.prompt(session: self.id, id: id, text: message, files: prepared.files, delivery: delivery)
            } catch {
                transcript.removeLocal(id: id)
                reviewComments = comments + reviewComments
                failure = error.localizedDescription
            }
        }
    }

    func runCommand(_ name: String, arguments: String) {
        Task {
            do { try await api.runCommand(session: id, name: name, arguments: arguments) } catch { failure = error.localizedDescription }
        }
    }

    /// Stops the agent. Waiting messages stay, queued and paused until Resume.
    func stop() {
        let steering = transcript.pending.filter { $0.delivery == .steer && !$0.isLocal }
        if hasQueue || !steering.isEmpty { isQueuePaused = true }
        Task {
            // Moved to the queue first, so the end of the step doesn't hand them over.
            for item in steering { try? await api.setDelivery(session: id, item: item.id, delivery: .queue) }
            try? await api.interrupt(session: id)
        }
    }

    func cancelPending(_ item: Transcript.Pending) {
        if item.isLocal { transcript.removeLocal(id: item.id); return }
        Task { try? await api.cancelInbox(session: id, item: item.id) }
    }

    /// Gives a waiting message to the agent right away: its current step stops, and it carries
    /// on from there with this message.
    func sendNow(_ item: Transcript.Pending) {
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
        guard !item.isLocal else { return }
        Task {
            do {
                try await api.cancelInbox(session: id, item: item.id)
            } catch {
                failure = error.localizedDescription
                return
            }
            // The agent got it first: it's in the transcript now.
            guard !transcript.messages.contains(where: { $0.id == item.id }) else { return }
            transcript.removePending(id: item.id)
            restoreDraft(item.text, files: item.files)
        }
    }

    /// Puts a message back in the composer, ahead of anything already there: its text, its
    /// attached files and its comments on the changes.
    private func restoreDraft(_ message: String, files picked: [URL] = []) {
        let (withComments, paths) = Attachments.split(message)
        let (text, comments) = ReviewComments.split(withComments)
        draftText = [text, draftText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let files = picked + paths.map { URL(filePath: $0) }
        draftFiles = files + draftFiles.filter { !files.contains($0) }
        reviewComments = comments + reviewComments
        composerFocus += 1
    }

    /// The text an undo put back in the composer, taken out again by Redo if it's untouched.
    private var undoneDraft: String?

    /// Takes the session back to before `message`: the agent stops, the conversation and the
    /// files it changed since go back, and the message returns to the composer to edit or
    /// send again. Redo brings it all back, until the next message makes it final.
    func undo(from message: Message.User) {
        Task {
            do {
                if isRunning {
                    try await api.interrupt(session: id)
                    try await api.wait(session: id)
                }
                session.revert = try await api.stageRevert(session: id, messageID: message.id)
                let before = draftText
                restoreDraft(message.text)
                undoneDraft = draftText == before ? nil : draftText
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// Takes back an undo: the conversation and the files come back as they were.
    func redo() {
        Task {
            do {
                try await api.clearRevert(session: id)
                session.revert = nil
                if let undoneDraft, draftText == undoneDraft { draftText = "" }
                undoneDraft = nil
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// Edits the message that would go last, if there is one.
    @discardableResult
    func editLast() -> Bool {
        guard let item = waiting.last(where: { !$0.isLocal }) else { return false }
        edit(item)
        return true
    }

    /// Picks the queue up again after Stop or a failed run.
    func resumeQueue() {
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
        guard !model.sameModel(as: session.model) || model.variant != session.model?.variant else { return }
        session.model = model
        Task {
            do { try await api.selectModel(session: id, model: model) } catch { failure = error.localizedDescription }
        }
    }

    var approval: ToolApproval { ToolApproval(rules: session.permissions) }

    func setApproval(_ approval: ToolApproval) {
        // The project's folders stay allowed, after the approval rules.
        let rules = approval.rules + (session.permissions ?? []).filter(ProjectFolders.isFolderRule)
        session.permissions = rules
        Task {
            do { try await api.setPermissions(session: id, rules: rules) } catch { failure = error.localizedDescription }
        }
    }

    /// Gives the agent the project's folders as they're set now, if it doesn't have them yet:
    /// allowed in its permissions, and named in its instructions.
    func syncFolders() async {
        let folders = projectFolders()
        let current = session.permissions ?? []
        let rules = ProjectFolders.permissions(current, folders: folders)
        guard rules != current else { return }
        do {
            try await api.setPermissions(session: id, rules: rules)
            session.permissions = rules
            if folders.isEmpty {
                try await api.removeInstruction(session: id, key: ProjectFolders.instructionKey)
            } else {
                try await api.setInstruction(session: id, key: ProjectFolders.instructionKey, text: ProjectFolders.instructions(primary: session.location.directory, folders: folders))
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    func selectAgent(_ agent: String) {
        guard agent != session.agent else { return }
        session.agent = agent
        Task {
            do { try await api.selectAgent(session: id, agent: agent) } catch { failure = error.localizedDescription }
        }
    }

    func reply(to request: PermissionRequest, _ decision: PermissionRequest.Decision, message: String? = nil) {
        Task {
            do { try await api.reply(session: id, permission: request.id, decision: decision, message: message) } catch { failure = error.localizedDescription }
        }
    }

    func answer(_ form: FormRequest, with answer: FormAnswer) {
        Task {
            do { try await api.reply(session: id, form: form.id, answer: answer) } catch { failure = error.localizedDescription }
        }
    }

    func dismiss(_ form: FormRequest, message: String? = nil) {
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
        changesTask?.cancel()
        changesTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let diff = try? await api.diff(session: id) else { return }
            changes = diff
        }
    }
}
