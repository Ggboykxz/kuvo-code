import Foundation
import OpenCodeKit
import os

private let log = Logger(subsystem: "run.kuvo.code", category: "workspace")

/// Projects and their sessions, kept live from engine events.
@Observable
final class Workspace {
    var api: OpenCodeAPI?

    private(set) var sessions: [Session] = []
    private(set) var running: Set<String> = []
    /// Folders the user opened, even before they have sessions.
    private(set) var folders: [String] = UserDefaults.standard.stringArray(forKey: "projectFolders") ?? []
    /// Names and other folders of projects, by their primary folder.
    private(set) var settings: [String: ProjectSettings] = Workspace.loadSettings()
    /// Sessions' own git worktrees, by the folder their sessions run in.
    private(set) var worktrees: [String: Worktree] = Workspace.loadWorktrees()
    private(set) var isLoaded = false

    private var models: [String: SessionModel] = [:]
    /// Current git branch per project folder, when it has one.
    private(set) var branches: [String: String] = [:]
    /// The repository's main branch per project folder, when git knows it.
    private(set) var defaultBranches: [String: String] = [:]
    /// Open permission requests and questions, by ID, with the session they're for.
    private(set) var asking: [String: String] = [:]

    /// Sessions that finished while you were elsewhere, or wait for your answer: the
    /// number on the Dock icon.
    var waitingCount: Int {
        Set(sessions.filter { $0.isUnread && !Self.isArchived($0) }.map(\.id)).union(asking.values).count
    }

    struct Project: Identifiable, Hashable {
        /// The primary folder: sessions run here.
        var directory: String
        var sessions: [Session]
        var settings = ProjectSettings()

        var id: String { directory }
        var name: String { settings.name ?? (directory as NSString).lastPathComponent }
        /// Every folder, the primary one first.
        var allFolders: [String] { [directory] + settings.folders }
    }

    /// What a project has beyond its primary folder.
    struct ProjectSettings: Codable, Hashable {
        /// Shown instead of the folder's name.
        var name: String?
        /// Other folders the agent works with, besides the primary one.
        var folders: [String] = []
        /// What Run (⌘R) runs in a terminal: a dev server, say.
        var run: String?
    }

    /// A copy of a project for sessions to work in apart from the rest: a git worktree of its
    /// repository, on a branch of its own.
    struct Worktree: Codable, Hashable {
        /// The project's primary folder.
        var project: String
        /// The worktree's top folder. Sessions run in the same place in it as the project's
        /// folder is in its repository.
        var root: String
        var branch: String
        /// What the project's folder had checked out when it was made: what it merges back into.
        var base: String?
    }

    /// The project a folder sessions run in belongs to: its own, or a worktree's project.
    func projectDirectory(_ directory: String) -> String {
        worktrees[directory]?.project ?? directory
    }

    func projectDirectory(of session: Session) -> String {
        projectDirectory(session.location.directory)
    }

    /// The project's other folders, for a folder sessions run in.
    func extraFolders(_ directory: String) -> [String] {
        settings[projectDirectory(directory)]?.folders ?? []
    }

    /// Projects with their sessions, most recently active first.
    var projects: [Project] {
        let grouped = Dictionary(grouping: sessions.filter { !Self.isArchived($0) }, by: projectDirectory(of:))
        let directories = Set(grouped.keys).union(folders)
        return directories.map { directory in
            Project(directory: directory, sessions: (grouped[directory] ?? []).sorted { $0.time.updated > $1.time.updated }, settings: settings[directory] ?? ProjectSettings())
        }
        .sorted { lhs, rhs in
            let left = lhs.sessions.first?.time.updated ?? 0
            let right = rhs.sessions.first?.time.updated ?? 0
            return left != right ? left > right : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Put away: out of Projects and Recents, still found by searching. Archived here (a
    /// note in the session's metadata), or by an older opencode.
    static func isArchived(_ session: Session) -> Bool {
        session.time.archived != nil || session.metadata?[archivedKey]?.bool == true
    }

    private static let archivedKey = "kuvo.archived"

    /// Kept at the top of the sidebar, a note in the session's metadata.
    static func isPinned(_ session: Session) -> Bool {
        session.metadata?[pinnedKey]?.bool == true
    }

    private static let pinnedKey = "kuvo.pinned"

    /// Archives a session, or brings it back.
    func setArchived(_ id: String, _ archived: Bool) async {
        await setFlag(Self.archivedKey, archived, of: id)
    }

    /// Pins a session to the top of the sidebar, or takes it off.
    func setPinned(_ id: String, _ pinned: Bool) async {
        if pinned { Analytics.shared.track("session_pinned") }
        await setFlag(Self.pinnedKey, pinned, of: id)
    }

    private func setFlag(_ key: String, _ value: Bool, of id: String) async {
        guard let api, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var metadata = sessions[index].metadata?.object ?? [:]
        // Written either way: the engine may merge metadata rather than replace it.
        metadata[key] = .bool(value)
        sessions[index].metadata = .object(metadata)
        try? await api.setMetadata(session: id, .object(metadata))
    }

    func session(_ id: String?) -> Session? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    /// A subagent's session, to show its work inside the step that started it. It has no row
    /// or tab of its own; its model gets its events like any other.
    func subagentModel(for id: String) async -> SessionModel? {
        if let model = models[id] { return model }
        guard let api, let session = try? await api.session(id) else { return nil }
        if let model = models[id] { return model }
        let model = SessionModel(session: session, api: api)
        models[id] = model
        return model
    }

    /// A session's conversation as Markdown, to share.
    func markdown(of id: String) async throws -> String? {
        guard let api, let session = session(id) else { return nil }
        let messages = try await ConversationExport.messages(of: session, api: api)
        return ConversationExport.markdown(title: session.title ?? "New Session", messages: messages, directory: session.location.directory)
    }

    /// The live model behind a session view. Created on first use, then kept so
    /// switching back is instant.
    func model(for id: String) -> SessionModel? {
        if let model = models[id] { return model }
        guard let api, let session = session(id) else { return nil }
        let directory = session.location.directory
        let model = SessionModel(session: session, api: api) { [weak self] in self?.extraFolders(directory) ?? [] }
        models[id] = model
        return model
    }

    func loadBranch(for directory: String) async {
        guard let api, let info = try? await api.vcs(directory: directory) else { return }
        branches[directory] = info.branch?.current
        defaultBranches[directory] = info.branch?.default
    }

    func needsAttention(_ id: String) -> Bool {
        guard let model = models[id] else { return false }
        return !model.transcript.permissions.isEmpty || !model.transcript.forms.isEmpty
    }

    // MARK: Changes

    func addFolder(_ directory: String) {
        guard !folders.contains(directory) else { return }
        Analytics.shared.track("project_added", ["projects": folders.count + 1])
        folders.insert(directory, at: 0)
        UserDefaults.standard.set(folders, forKey: "projectFolders")
    }

    func removeFolder(_ directory: String) {
        folders.removeAll { $0 == directory }
        UserDefaults.standard.set(folders, forKey: "projectFolders")
        settings[directory] = nil
        saveSettings()
    }

    /// The project's name: its own, or its primary folder's. A worktree has its project's.
    func projectName(_ directory: String) -> String {
        let directory = projectDirectory(directory)
        return settings[directory]?.name ?? (directory as NSString).lastPathComponent
    }

    /// Adds a project, or updates one, and gives its open sessions the new folders.
    func saveProject(_ directory: String, settings project: ProjectSettings) {
        addFolder(directory)
        var project = project
        project.name = project.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if project.name?.isEmpty == true || project.name == (directory as NSString).lastPathComponent { project.name = nil }
        project.folders = project.folders.filter { $0 != directory }
        project.run = project.run?.trimmingCharacters(in: .whitespacesAndNewlines)
        if project.run?.isEmpty == true { project.run = nil }
        settings[directory] = project == ProjectSettings() ? nil : project
        saveSettings()
        // Sessions not open yet catch up when they open.
        for model in models.values where projectDirectory(of: model.session) == directory {
            Task { await model.syncFolders() }
        }
    }

    /// A new session in the project at `directory`, or with `worktree`, in a new worktree of it.
    func createSession(in directory: String, model: ModelRef?, agent: String?, approval: ToolApproval = .approveAll, worktree: Bool = false) async throws -> Session {
        guard let api else { throw CancellationError() }
        addFolder(directory)
        let folder = worktree ? try await makeWorktree(of: directory) : directory
        let extra = settings[directory]?.folders ?? []
        let rules = ProjectFolders.permissions(approval.rules, folders: extra)
        let session = try await api.createSession(directory: folder, agent: agent, model: model, permissions: rules.isEmpty ? nil : rules)
        if !extra.isEmpty {
            try? await api.setInstruction(session: session.id, key: ProjectFolders.instructionKey, text: ProjectFolders.instructions(primary: folder, folders: extra))
        }
        if let tree = worktrees[folder] {
            try? await api.setInstruction(session: session.id, key: Self.worktreeInstructionKey, text: Self.instructions(for: tree))
        }
        upsert(session)
        let used = model ?? session.model
        var props = Analytics.model(provider: used?.providerID, model: used?.id)
        props["mode"] = Analytics.mode(agent)
        props["approval"] = approval == .approveAll ? "all" : "ask"
        props["worktree"] = worktree
        Analytics.shared.track("session_created", props)
        return session
    }

    // MARK: Worktrees

    private static let worktreeInstructionKey = "kuvo.worktree"

    private static func instructions(for tree: Worktree) -> String {
        """
        You work in a git worktree of this project, on the branch \(tree.branch), so your changes stay apart from \
        the user's own checkout at \(tree.project) until they merge them. Make your changes here, not there.
        """
    }

    /// A new worktree of the project's repository on a branch of its own, set up by the
    /// project's setup command. Returns the folder for the session to run in.
    private func makeWorktree(of directory: String) async throws -> String {
        guard let api else { throw CancellationError() }
        let project = try await api.location(directory: directory).project
        let (base, subpath) = await Task.detached { (Git.currentBranch(in: directory), Git.pathInRepository(of: directory)) }.value
        let root = try await api.createWorktree(project: project.id)
        // The engine leaves it on no branch; one of its own makes the work easy to commit,
        // push and merge.
        let branch = try await Task.detached { try Git.newBranch(named: "kuvo/" + (root as NSString).lastPathComponent, in: root) }.value
        let folder = subpath.isEmpty ? root : (root as NSString).appendingPathComponent(subpath)
        worktrees[folder] = Worktree(project: directory, root: root, branch: branch, base: base)
        saveWorktrees()
        return folder
    }

    /// Whether another session still working in the worktree (not archived) would lose it.
    func worktreeIsShared(_ directory: String, besides id: String) -> Bool {
        guard let root = worktrees[directory]?.root else { return false }
        return sessions.contains { $0.id != id && !Self.isArchived($0) && worktrees[$0.location.directory]?.root == root }
    }

    /// Removes a worktree's folder, changes that aren't committed too. Its branch stays with its
    /// commits, unless it's merged already.
    func removeWorktree(_ directory: String) async throws {
        guard let api, let tree = worktrees[directory] else { return }
        let project = try await api.location(directory: tree.project).project
        try await api.removeWorktree(project: project.id, directory: tree.root, force: true)
        // Git deletes only a branch that's merged.
        _ = await Task.detached { Git.run(["branch", "-d", tree.branch], in: tree.project) }.value
        worktrees = worktrees.filter { $0.value.root != tree.root }
        saveWorktrees()
        Analytics.shared.track("worktree_removed")
    }

    private static func loadWorktrees() -> [String: Worktree] {
        guard let data = UserDefaults.standard.data(forKey: "worktrees") else { return [:] }
        return (try? JSONDecoder().decode([String: Worktree].self, from: data)) ?? [:]
    }

    private func saveWorktrees() {
        UserDefaults.standard.set(try? JSONEncoder().encode(worktrees), forKey: "worktrees")
    }

    private static func loadSettings() -> [String: ProjectSettings] {
        guard let data = UserDefaults.standard.data(forKey: "projectSettings") else { return [:] }
        return (try? JSONDecoder().decode([String: ProjectSettings].self, from: data)) ?? [:]
    }

    private func saveSettings() {
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: "projectSettings")
    }

    /// A session the window should open: a fork, say.
    var requestedTab: String?

    /// A new session with `id`'s conversation before `message`, opened in a tab with the
    /// message in its composer, ready to try another way.
    func fork(_ id: String, from message: Message.User) async throws {
        Analytics.shared.track("session_branched")
        guard let api else { return }
        let session = try await api.forkSession(id, before: message.id)
        upsert(session)
        let (withComments, paths) = Attachments.split(CommandMessages.shared.text(of: message))
        // The engine's copy carries the attachments; one seen arrive live doesn't.
        let recent = (try? await api.messages(session: id, limit: 100).data) ?? []
        var stored = message
        for case .user(let user) in recent where user.id == message.id { stored = user }
        Drafts.shared[session.id] = Drafts.Draft(text: ReviewComments.split(withComments).text, files: SessionModel.files(of: stored) + paths.map { URL(filePath: $0) })
        requestedTab = session.id
    }

    func delete(_ id: String) async {
        sessions.removeAll { $0.id == id }
        models[id] = nil
        Drafts.shared.remove(id)
        try? await api?.deleteSession(id)
    }

    func rename(_ id: String, to title: String) async {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].title = title
        try? await api?.renameSession(id, title: title)
    }

    // MARK: Sync

    func refresh() async {
        guard let api else { return }
        do { sessions = try await api.sessions().data } catch { log.error("sessions: \(String(describing: error), privacy: .public)") }
        do { running = try await api.activeSessions() } catch { log.error("active sessions: \(String(describing: error), privacy: .public)") }
        isLoaded = true
    }

    /// After a reconnect: re-read the list and every open session. Requests asked while
    /// disconnected are known again from the open sessions.
    func resync() async {
        await refresh()
        asking = [:]
        for model in models.values {
            await model.load()
            for request in model.transcript.permissions { asking[request.id] = request.sessionID }
            for form in model.transcript.forms { asking[form.id] = form.sessionID }
        }
    }

    func handle(_ event: ServerEvent) {
        if event.type == "vcs.branch.updated", let directory = event.location?.directory {
            struct Branch: Decodable { var branch: String? }
            branches[directory] = (try? event.payload(as: Branch.self))?.branch
        }
        if let id = event.sessionID ?? Self.formSessionID(event), let model = models[id] {
            model.apply(event)
        }
        noteQuestions(event)
        guard let id = event.sessionID else { return }

        switch event.type {
        case "session.created", "session.renamed", "session.moved", "session.metadata.updated", "session.revert.staged", "session.revert.cleared", "session.revert.committed":
            Task { await reload(id) }
        case "session.deleted":
            sessions.removeAll { $0.id == id }
            models[id] = nil
            asking = asking.filter { $0.value != id }
        case "session.execution.started":
            running.insert(id)
            runStarted[id] = .now
            touch(id)
        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted":
            running.remove(id)
            noteTurn(id, event)
            // Picks up the new idle time (unread state) and outcome.
            Task {
                await reload(id)
                // A run you stopped needs no news.
                if event.type != "session.execution.interrupted", let session = session(id) {
                    Notifier.shared.notify(
                        session: id,
                        title: session.title ?? "New Session",
                        subtitle: projectName(session.location.directory),
                        body: event.type == "session.execution.failed" ? "Stopped with an error." : "Finished."
                    )
                }
            }
        case "session.usage.updated":
            if let usage = try? event.payload(as: EventPayload.Usage.self), let index = sessions.firstIndex(where: { $0.id == id }) {
                sessions[index].cost = usage.cost
                sessions[index].tokens = usage.tokens
            }
        case "session.model.selected":
            if let selected = try? event.payload(as: EventPayload.ModelSelected.self), let index = sessions.firstIndex(where: { $0.id == id }) {
                sessions[index].model = selected.model
            }
        case "session.agent.selected":
            if let selected = try? event.payload(as: EventPayload.AgentSelected.self), let index = sessions.firstIndex(where: { $0.id == id }) {
                sessions[index].agent = selected.agent
            }
        default:
            break
        }
    }

    @ObservationIgnored private var runStarted: [String: Date] = [:]

    /// How a run ended, for anonymous usage: the outcome, how long it took, with which model, and
    /// for a failure the engine's error type and status, never its message.
    private func noteTurn(_ id: String, _ event: ServerEvent) {
        let ended = try? event.payload(as: EventPayload.ExecutionEnded.self)
        guard ended?.reason != "shutdown" else { return }
        let session = session(id)
        var props = Analytics.model(provider: session?.model?.providerID, model: session?.model?.id)
        props["outcome"] = switch event.type {
        case "session.execution.succeeded": "done"
        case "session.execution.failed": "failed"
        default: "stopped"
        }
        // A subagent's session has no row of its own.
        props["subagent"] = session == nil
        if let started = runStarted.removeValue(forKey: id) { props["seconds"] = Int(Date.now.timeIntervalSince(started)) }
        if event.type == "session.execution.failed", let error = ended?.error {
            props["error"] = String(error.type.lowercased().filter { $0.isLetter || $0 == "_" }.prefix(40))
            if let status = error.status { props["status"] = status }
        }
        Analytics.shared.track("turn_finished", props)
    }

    /// Keeps `asking` current, and tells you about a new request while you're elsewhere.
    private func noteQuestions(_ event: ServerEvent) {
        switch event.type {
        case "permission.asked":
            guard let request = try? event.payload(as: PermissionRequest.self) else { return }
            asking[request.id] = request.sessionID
            notifyAsk(request.sessionID, body: Self.describe(request))
        case "permission.replied":
            if let reply = try? event.payload(as: EventPayload.PermissionReplied.self) { asking[reply.requestID] = nil }
        case "form.created":
            guard let form = try? event.payload(as: EventPayload.FormCreated.self).form else { return }
            asking[form.id] = form.sessionID
            notifyAsk(form.sessionID, body: form.isQuestion ? "Has a question for you." : "Needs your answer.")
        case "form.replied", "form.cancelled":
            if let settled = try? event.payload(as: EventPayload.FormSettled.self) { asking[settled.id] = nil }
        default:
            break
        }
    }

    private func notifyAsk(_ id: String, body: String) {
        Task {
            // A subagent's session has no row or tab of its own; its request shows in the
            // session that started it.
            var session = session(id)
            var parent = session == nil ? (try? await api?.session(id))?.parentID : nil
            for _ in 0..<5 where session == nil {
                guard let next = parent else { break }
                session = self.session(next)
                parent = session == nil ? (try? await api?.session(next))?.parentID : nil
            }
            Notifier.shared.notify(session: session?.id ?? id, title: session?.title ?? AppInfo.name, subtitle: session.map { projectName($0.location.directory) }, body: body)
        }
    }

    /// "Wants to run a command: npm test".
    private static func describe(_ request: PermissionRequest) -> String {
        let what = switch request.action {
        case "edit", "write", "patch": "edit files"
        case "shell", "bash": "run a command"
        case "read": "read a file"
        case "external_directory": "work outside the project"
        case "webfetch": "open a web page"
        default: request.action
        }
        guard let resource = request.resources.first, resource != "*" else { return "Wants to \(what)." }
        return "Wants to \(what): \(resource)"
    }

    func markViewed(_ id: String) {
        Notifier.shared.clear(session: id)
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].isUnread, let idle = sessions[index].time.idle else { return }
        sessions[index].time.viewed = idle
        Task { try? await api?.markViewed(id, idle: idle) }
    }

    private func reload(_ id: String) async {
        guard let session = try? await api?.session(id) else { return }
        // Only root sessions get a row; subagent sessions show inside their parent.
        guard session.parentID == nil else { return }
        upsert(session)
    }

    private func upsert(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        models[session.id]?.session = session
    }

    private func touch(_ id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].time.updated = Date().timeIntervalSince1970 * 1000
    }

    /// `form.created` carries its session inside the form.
    private static func formSessionID(_ event: ServerEvent) -> String? {
        guard event.type == "form.created" else { return nil }
        return try? event.payload(as: EventPayload.FormCreated.self).form.sessionID
    }
}
