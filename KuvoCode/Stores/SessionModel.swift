import Foundation
import OpenCodeKit

/// One session, live: its transcript, what's pending, and the actions on it.
@Observable
final class SessionModel {
    var session: Session
    private(set) var transcript: Transcript
    private(set) var isLoaded = false
    private(set) var changes: [FileDiff] = []
    var failure: String?

    private let api: OpenCodeAPI
    private var reloadTask: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?

    init(session: Session, api: OpenCodeAPI) {
        self.session = session
        self.api = api
        transcript = Transcript(sessionID: session.id)
    }

    var id: String { session.id }
    var isRunning: Bool { transcript.isRunning }

    /// The agent and model the next message goes to.
    var agent: String { session.agent ?? "build" }

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
    }

    // MARK: Actions

    /// Sends a message with `files`, as `model` can take them (see `Attachments`).
    func send(_ text: String, files: [URL] = [], for model: Model?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !files.isEmpty else { return }
        let id = Identifier.message()
        let delivery: InboxItem.Delivery = transcript.isRunning ? .queue : .steer
        transcript.addLocal(id: id, text: text, delivery: delivery, files: files)
        Task {
            do {
                // Converting a photo takes a moment; keep it off the main thread.
                let prepared = await Task.detached { Attachments.prepare(files, for: model) }.value
                let message = Attachments.text(text, adding: prepared.paths)
                try await api.prompt(session: self.id, id: id, text: message, files: prepared.files, delivery: delivery)
            } catch {
                transcript.removeLocal(id: id)
                failure = error.localizedDescription
            }
        }
    }

    func runCommand(_ name: String, arguments: String) {
        Task {
            do { try await api.runCommand(session: id, name: name, arguments: arguments) } catch { failure = error.localizedDescription }
        }
    }

    func stop() {
        Task { try? await api.interrupt(session: id) }
    }

    func cancelPending(_ item: Transcript.Pending) {
        if item.isLocal { transcript.removeLocal(id: item.id); return }
        Task { try? await api.cancelInbox(session: id, item: item.id) }
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
        session.permissions = approval.rules
        Task {
            do { try await api.setPermissions(session: id, rules: approval.rules) } catch { failure = error.localizedDescription }
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
