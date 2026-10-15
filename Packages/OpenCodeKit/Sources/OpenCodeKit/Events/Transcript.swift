import Foundation

/// Everything a session view shows, kept current by applying events.
///
/// Mirrors the engine's own projection (and opencode's official client): the
/// server stores the same messages, but streams them as fine-grained events.
public struct Transcript: Sendable, Equatable {
    public let sessionID: String
    public var messages: [Message] = []
    /// Inputs queued or sent but not yet handed to the agent.
    public var pending: [Pending] = []
    public var permissions: [PermissionRequest] = []
    public var forms: [FormRequest] = []
    public var isRunning = false
    /// Set when an event referred to something this copy doesn't have (it was
    /// loaded mid-step, say). The owner should reload from the server.
    public var isStale = false

    public struct Pending: Sendable, Hashable, Identifiable {
        public var id: String
        public var text: String
        public var delivery: InboxItem.Delivery
        /// Shown before the server confirmed it.
        public var isLocal: Bool
        /// What was attached, for showing a local message before the server has it.
        public var files: [URL]

        public init(id: String, text: String, delivery: InboxItem.Delivery, isLocal: Bool, files: [URL] = []) {
            self.id = id
            self.text = text
            self.delivery = delivery
            self.isLocal = isLocal
            self.files = files
        }
    }

    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// Replaces the state with a fresh read from the server.
    public mutating func load(messages: [Message], inbox: [InboxItem], permissions: [PermissionRequest], forms: [FormRequest], isRunning: Bool) {
        self.messages = messages
        let local = pending.filter { item in item.isLocal && !inbox.contains { $0.id == item.id } && !messages.contains { $0.id == item.id } }
        pending = inbox.filter { $0.type == "user" }.map { Pending(id: $0.id, text: $0.text ?? "", delivery: $0.delivery, isLocal: false, files: $0.files) } + local
        self.permissions = permissions
        self.forms = forms
        self.isRunning = isRunning
        isStale = false
    }

    /// Shows a message right away, before the server echoes it back.
    public mutating func addLocal(id: String, text: String, delivery: InboxItem.Delivery, files: [URL] = []) {
        pending.append(Pending(id: id, text: text, delivery: delivery, isLocal: true, files: files))
    }

    public mutating func removeLocal(id: String) {
        pending.removeAll { $0.id == id && $0.isLocal }
    }

    /// Drops waiting input the owner cancelled, ahead of the server's word.
    public mutating func removePending(id: String) {
        pending.removeAll { $0.id == id }
    }

    /// Applies one event. Events for other sessions are ignored.
    public mutating func apply(_ event: ServerEvent) {
        do {
            try reduce(event)
        } catch {
            // A payload this version can't read: the server's copy is the truth.
            isStale = true
        }
    }

    private mutating func reduce(_ event: ServerEvent) throws {
        let now = event.created ?? Date().timeIntervalSince1970 * 1000
        let messageID = "msg_" + event.id.dropFirst("evt_".count)

        switch event.type {
        case "permission.asked":
            let request = try event.payload(as: PermissionRequest.self)
            guard request.sessionID == sessionID else { return }
            permissions.removeAll { $0.id == request.id }
            permissions.append(request)
            return
        case "permission.replied":
            let reply = try event.payload(as: EventPayload.PermissionReplied.self)
            permissions.removeAll { $0.id == reply.requestID }
            return
        case "form.created":
            let form = try event.payload(as: EventPayload.FormCreated.self).form
            guard form.sessionID == sessionID else { return }
            forms.removeAll { $0.id == form.id }
            forms.append(form)
            return
        case "form.replied", "form.cancelled":
            let settled = try event.payload(as: EventPayload.FormSettled.self)
            forms.removeAll { $0.id == settled.id }
            return
        default:
            break
        }

        guard event.sessionID == sessionID else { return }

        switch event.type {
        // Inputs
        case "session.inbox.enqueued":
            let enqueued = try event.payload(as: EventPayload.InboxEnqueued.self)
            guard enqueued.item.type == "user" else { return }
            var item = Pending(id: enqueued.inboxID, text: enqueued.item.payload["text"]?.string ?? "", delivery: enqueued.item.delivery, isLocal: false, files: InboxItem.files(in: enqueued.item.payload))
            if let index = pending.firstIndex(where: { $0.id == item.id }) {
                // A local copy knows the files as they were picked, before any conversion.
                if !pending[index].files.isEmpty { item.files = pending[index].files }
                pending[index] = item
            } else {
                pending.append(item)
            }
        case "session.inbox.delivered":
            let id = try event.payload(as: EventPayload.InboxChanged.self).inboxID
            guard let index = pending.firstIndex(where: { $0.id == id }) else {
                // Not ours to show (a synthetic or compaction input), or we missed it.
                return
            }
            let item = pending.remove(at: index)
            messages.append(.user(Message.User(id: item.id, time: Message.Time(created: now), text: item.text)))
        case "session.inbox.cancelled":
            let id = try event.payload(as: EventPayload.InboxChanged.self).inboxID
            pending.removeAll { $0.id == id }
        case "session.inbox.delivery.changed":
            struct Changed: Decodable { var inboxID: String; var delivery: InboxItem.Delivery }
            let changed = try event.payload(as: Changed.self)
            if let index = pending.firstIndex(where: { $0.id == changed.inboxID }) {
                pending[index].delivery = changed.delivery
            }

        // Runs
        case "session.execution.started":
            isRunning = true
        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted":
            let ended = try event.payload(as: EventPayload.ExecutionEnded.self)
            isRunning = false
            closeOpenSteps(at: now)
            if messages.contains(where: Self.hasUnfinishedTool) { isStale = true }
            if ended.reason == "shutdown" { return }
            let outcome: Session.Outcome = switch event.type {
            case "session.execution.succeeded": .succeeded
            case "session.execution.failed": .failed
            default: .interrupted
            }
            messages.append(.idle(Message.Idle(id: messageID, time: Message.Time(created: now), outcome: outcome, error: ended.error)))

        // Steps
        case "session.step.started":
            let step = try event.payload(as: EventPayload.Step.self)
            if let index = assistantIndex(step.assistantMessageID), case .assistant(var message) = messages[index] {
                message.retry = nil
                message.error = nil
                message.finish = nil
                message.time.completed = nil
                messages[index] = .assistant(message)
            } else {
                closeOpenSteps(at: now)
                messages.append(.assistant(Message.Assistant(
                    id: step.assistantMessageID,
                    time: Message.Time(created: step.started ?? now),
                    agent: step.agent ?? "build",
                    model: step.model ?? ModelRef(id: "", providerID: "")
                )))
            }
        case "session.step.streamed":
            let step = try event.payload(as: EventPayload.BlockStarted.self)
            editAssistant(step.assistantMessageID) { $0.time.streamed = now }
        case "session.step.ended", "session.step.failed":
            let step = try event.payload(as: EventPayload.Step.self)
            editAssistant(step.assistantMessageID) { message in
                message.time.completed = now
                message.finish = step.finish ?? (step.error != nil ? "error" : message.finish)
                message.cost = step.cost ?? message.cost
                message.tokens = step.tokens ?? message.tokens
                message.error = step.error
                message.retry = nil
            }
        case "session.retry.scheduled":
            let retry = try event.payload(as: EventPayload.Retry.self)
            editAssistant(retry.assistantMessageID) { $0.retry = Message.Assistant.Retry(attempt: retry.attempt, at: retry.at, error: retry.error) }

        // Text and reasoning
        case "session.text.started":
            let block = try event.payload(as: EventPayload.BlockStarted.self)
            editAssistant(block.assistantMessageID) { $0.content.append(.text(Message.Content.Text(text: ""))) }
        case "session.text.delta":
            let delta = try event.payload(as: EventPayload.Delta.self)
            editAssistant(delta.assistantMessageID) { message in
                if let index = message.content.lastIndex(where: \.isText), case .text(var block) = message.content[index] {
                    block.text += delta.delta
                    message.content[index] = .text(block)
                }
            }
        case "session.text.ended":
            let ended = try event.payload(as: EventPayload.BlockEnded.self)
            editAssistant(ended.assistantMessageID) { message in
                if let index = message.content.lastIndex(where: \.isText) {
                    message.content[index] = .text(Message.Content.Text(text: ended.text))
                } else {
                    message.content.append(.text(Message.Content.Text(text: ended.text)))
                }
            }
        case "session.reasoning.started":
            let block = try event.payload(as: EventPayload.BlockStarted.self)
            editAssistant(block.assistantMessageID) { $0.content.append(.reasoning(Message.Content.Text(text: "", time: Message.Time(created: now)))) }
        case "session.reasoning.delta":
            let delta = try event.payload(as: EventPayload.Delta.self)
            editAssistant(delta.assistantMessageID) { message in
                if let index = message.content.lastIndex(where: \.isOpenReasoning), case .reasoning(var block) = message.content[index] {
                    block.text += delta.delta
                    message.content[index] = .reasoning(block)
                }
            }
        case "session.reasoning.ended":
            let ended = try event.payload(as: EventPayload.BlockEnded.self)
            editAssistant(ended.assistantMessageID) { message in
                if let index = message.content.lastIndex(where: \.isOpenReasoning), case .reasoning(var block) = message.content[index] {
                    block.text = ended.text
                    block.time?.completed = now
                    message.content[index] = .reasoning(block)
                }
            }

        // Tools
        case "session.tool.input.started":
            let started = try event.payload(as: EventPayload.ToolInputStarted.self)
            editAssistant(started.assistantMessageID) { message in
                let call = Message.ToolCall(id: started.id, name: started.name, state: .streaming(input: ""), time: .init(created: now))
                message.content.append(.tool(call))
            }
        case "session.tool.input.delta":
            let delta = try event.payload(as: EventPayload.ToolInputDelta.self)
            editTool(delta.assistantMessageID, delta.id) { call in
                if case .streaming(let input) = call.state { call.state = .streaming(input: input + delta.delta) }
            }
        case "session.tool.input.ended":
            let ended = try event.payload(as: EventPayload.ToolInputEnded.self)
            editTool(ended.assistantMessageID, ended.id) { call in
                if case .streaming = call.state { call.state = .streaming(input: ended.text) }
            }
        case "session.tool.called":
            let called = try event.payload(as: EventPayload.ToolCalled.self)
            editTool(called.assistantMessageID, called.id) { call in
                call.state = .running(input: called.input, metadata: nil)
                call.time?.ran = now
            }
        case "session.tool.progress":
            let progress = try event.payload(as: EventPayload.ToolProgress.self)
            editTool(progress.assistantMessageID, progress.id) { call in
                if case .running(let input, _) = call.state { call.state = .running(input: input, metadata: progress.metadata) }
            }
        case "session.tool.success":
            let success = try event.payload(as: EventPayload.ToolSucceeded.self)
            editTool(success.assistantMessageID, success.id) { call in
                guard case .running(let input, _) = call.state else { return }
                call.state = .completed(input: input, output: success.content, metadata: success.metadata)
                call.time?.completed = now
            }
        case "session.tool.failed":
            let failure = try event.payload(as: EventPayload.ToolFailed.self)
            editTool(failure.assistantMessageID, failure.id) { call in
                call.state = .failed(input: call.state.input ?? .object([:]), error: failure.error, output: failure.content, metadata: failure.metadata)
                call.time?.completed = now
            }

        // Notices
        case "session.agent.selected":
            let selected = try event.payload(as: EventPayload.AgentSelected.self)
            messages.append(.agentSwitched(Message.AgentSwitch(id: messageID, time: Message.Time(created: now), agent: selected.agent, previous: selected.previous)))
        case "session.model.selected":
            let selected = try event.payload(as: EventPayload.ModelSelected.self)
            messages.append(.modelSwitched(Message.ModelSwitch(id: messageID, time: Message.Time(created: now), model: selected.model, previous: selected.previous)))
        case "session.synthetic":
            struct Synthetic: Decodable { var text: String; var description: String? }
            let synthetic = try event.payload(as: Synthetic.self)
            messages.append(.synthetic(Message.Notice(id: messageID, time: Message.Time(created: now), text: synthetic.text, description: synthetic.description)))
        case "session.shell.started":
            struct Started: Decodable { var shell: ShellInfo }
            let shell = try event.payload(as: Started.self).shell
            messages.append(.shell(Message.Shell(id: messageID, time: Message.Time(created: now), shellID: shell.id, command: shell.command, status: shell.status, exit: shell.exit)))
        case "session.shell.ended":
            struct Ended: Decodable { var shell: ShellInfo; var output: Message.Shell.Output? }
            let ended = try event.payload(as: Ended.self)
            let shell = ended.shell
            if let index = messages.lastIndex(where: { if case .shell(let m) = $0 { m.shellID == shell.id } else { false } }),
               case .shell(var message) = messages[index] {
                message.status = shell.status
                message.exit = shell.exit
                message.output = ended.output
                message.time.completed = now
                messages[index] = .shell(message)
            }
        case "session.compaction.started":
            struct Started: Decodable { var reason: String? }
            let started = try event.payload(as: Started.self)
            messages.append(.compaction(Message.Compaction(id: messageID, time: Message.Time(created: now), status: "running", reason: started.reason, summary: nil)))
        case "session.compaction.ended", "session.compaction.failed":
            struct Ended: Decodable { var text: String? }
            let ended = try event.payload(as: Ended.self)
            if let index = messages.lastIndex(where: { if case .compaction = $0 { true } else { false } }), case .compaction(var message) = messages[index] {
                message.status = event.type.hasSuffix("ended") ? "completed" : "failed"
                message.summary = ended.text
                messages[index] = .compaction(message)
            }

        // History edits
        case "session.revert.committed":
            let to = try event.payload(as: EventPayload.RevertCommitted.self).to
            messages.removeAll { $0.id >= to }
            pending.removeAll { $0.id >= to }

        default:
            break
        }
    }

    // MARK: Helpers

    private func assistantIndex(_ id: String) -> Int? {
        messages.lastIndex { $0.id == id }
    }

    private mutating func editAssistant(_ id: String, _ edit: (inout Message.Assistant) -> Void) {
        guard let index = assistantIndex(id), case .assistant(var message) = messages[index] else {
            isStale = true
            return
        }
        edit(&message)
        messages[index] = .assistant(message)
    }

    private mutating func editTool(_ messageID: String, _ toolID: String, _ edit: (inout Message.ToolCall) -> Void) {
        editAssistant(messageID) { message in
            guard let index = message.content.lastIndex(where: { if case .tool(let call) = $0 { call.id == toolID } else { false } }),
                  case .tool(var call) = message.content[index] else { return }
            edit(&call)
            message.content[index] = .tool(call)
        }
    }

    /// A new step or the end of a run closes any step still marked open.
    private mutating func closeOpenSteps(at time: Milliseconds) {
        for index in messages.indices.reversed() {
            guard case .assistant(var message) = messages[index] else { continue }
            guard message.time.completed == nil else { break }
            message.time.completed = time
            messages[index] = .assistant(message)
        }
    }

    private static func hasUnfinishedTool(_ message: Message) -> Bool {
        guard case .assistant(let assistant) = message else { return false }
        return assistant.content.contains { if case .tool(let call) = $0 { !call.state.isFinished } else { false } }
    }
}

private struct ShellInfo: Decodable {
    var id: String
    var command: String
    var status: String
    var exit: Int?
}

extension Message.Content {
    var isText: Bool {
        if case .text = self { true } else { false }
    }

    var isOpenReasoning: Bool {
        if case .reasoning(let block) = self { !block.isComplete } else { false }
    }
}
