import Foundation
import OpenCodeKit
import os

private let log = Logger(subsystem: "run.kuvo.code", category: "workspace")

/// Projects and their sessions, kept live from engine events.
@Observable
final class Workspace {
    /// This Mac's engine.
    var api: OpenCodeAPI?
    /// A machine's engine, by its name, for projects on it (folders written `ssh://machine/path`).
    @ObservationIgnored var machineAPI: (String) -> OpenCodeAPI? = { _ in nil }
    /// The machine each session's events came from, for sessions without a row (a subagent's).
    @ObservationIgnored private var sessionMachines: [String: String] = [:]
    /// Machines' sessions as last seen, kept across launches so their tabs wait for the machine
    /// to connect instead of closing.
    @ObservationIgnored private var remoteSessions: [String: RemoteSession] = Workspace.loadRemoteSessions()
    /// The machines whose sessions are in the lists.
    private(set) var connectedMachines: Set<String> = []
    /// The machines you've added. A removed machine's projects leave the sidebar but keep their
    /// settings, for when it's added again.
    var machines: Set<String> = []

    struct RemoteSession: Codable {
        var machine: String
        var title: String?
    }

    /// The machine a session is on, while that machine isn't connected; nil once it is (or
    /// for this Mac's sessions).
    func waitingMachine(for id: String) -> String? {
        guard session(id) == nil, let machine = remoteSessions[id]?.machine, !connectedMachines.contains(machine) else { return nil }
        return machine
    }

    /// A waiting session's title, as last seen.
    func remoteTitle(_ id: String) -> String? {
        remoteSessions[id]?.title
    }

    /// The engine a folder's sessions run on: its machine's, or this Mac's.
    func api(forFolder folder: String) -> OpenCodeAPI? {
        if let machine = RemoteFolder.machine(of: folder) { return machineAPI(machine) }
        return api
    }

    /// The engine a session runs on.
    func api(forSession id: String) -> OpenCodeAPI? {
        if let session = session(id) { return api(forFolder: session.location.directory) }
        if let machine = sessionMachines[id] { return machineAPI(machine) }
        return api
    }

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
    /// Sessions whose agent asks you for something in its browser (a sign-in, a code, a step).
    var askingInBrowser: Set<String> = []

    /// Sessions that finished while you were elsewhere, or wait for your answer: the
    /// number on the Dock icon.
    var waitingCount: Int {
        Set(sessions.filter { $0.isUnread && !Self.isArchived($0) }.map(\.id)).union(asking.values.filter { !seats.contains($0) }).union(askingInBrowser.subtracting(seats)).count
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

    /// Bots' sessions: each bot's conversation, shown with the bot rather than in its project.
    var botSessions: Set<String> = []
    /// Bots' seats in group chats: sessions that never get a row, a tab or a notification.
    var seats: Set<String> = [] {
        didSet { sessions.removeAll { seats.contains($0.id) } }
    }

    /// A bot's seat in a group chat, by its metadata, before it's in `seats`.
    static func isSeat(_ session: Session) -> Bool {
        session.metadata?["kuvo"]?["seat"] != nil
    }

    private func isHidden(_ session: Session) -> Bool {
        seats.contains(session.id) || Self.isSeat(session)
    }

    #if DEBUG
    private static let logsEvents = ProcessInfo.processInfo.environment["KUVO_DEMO_LOG_EVENTS"] != nil
    #endif

    /// How many runs of each session have ended since the app started: a run someone is
    /// waiting on has ended once its count goes up.
    @ObservationIgnored private(set) var endedRuns: [String: Int] = [:]

    // MARK: Chats

    /// Where chats run: conversations of no project, on this Mac, in a folder of their own.
    static let chatsFolder: String = {
        let url = AppInfo.supportDirectory.appending(path: "Chats")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }()

    static func isChat(_ directory: String) -> Bool {
        directory == chatsFolder
    }

    /// Chats, newest first.
    var chats: [Session] {
        sessions.filter { Self.isChat($0.location.directory) && !Self.isArchived($0) && !botSessions.contains($0.id) }
            .sorted { $0.time.updated > $1.time.updated }
    }

    /// Moves a chat into the project at `directory`: its conversation goes along, and from then on
    /// it works in that project's folders. If it's working, the move comes at its next step.
    func move(_ id: String, toProject directory: String) async throws {
        guard let session = session(id), let api = api(forFolder: directory) else { return }
        try await api.moveSession(id, to: directory)
        let extra = settings[directory]?.folders ?? []
        try? await api.setPermissions(session: id, rules: ProjectFolders.permissions(session.permissions ?? [], folders: extra))
        if extra.isEmpty {
            try? await api.removeInstruction(session: id, key: ProjectFolders.instructionKey)
        } else {
            try? await api.setInstruction(session: id, key: ProjectFolders.instructionKey, text: ProjectFolders.instructions(primary: directory, folders: extra))
        }
        // Its open conversation stays as it is, now in its new place.
        await reload(id)
        Analytics.shared.track("chat_moved")
    }

    /// Projects with their sessions, most recently active first.
    var projects: [Project] {
        let grouped = Dictionary(grouping: sessions.filter { !Self.isArchived($0) && !botSessions.contains($0.id) && !Self.isChat($0.location.directory) }, by: projectDirectory(of:))
        let directories = Set(grouped.keys).union(folders).filter { RemoteFolder.machine(of: $0).map(machines.contains) ?? true }
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
        guard let index = sessions.firstIndex(where: { $0.id == id }), let api = api(forFolder: sessions[index].location.directory) else { return }
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
    func subagentModel(for id: String, in folder: String) async -> SessionModel? {
        if let model = models[id] { return model }
        guard let api = api(forFolder: folder), let session = try? await api.session(id) else { return nil }
        if let model = models[id] { return model }
        let model = SessionModel(session: session, api: api)
        models[id] = model
        return model
    }

    /// Each session's conversation as text, for searching it, until the session changes.
    @ObservationIgnored private var conversationTexts: [String: (updated: Double, text: String)] = [:]

    /// Sessions whose conversation has `query` (archived ones too), the latest first, with the
    /// words around its first mention. Reads the conversations it hasn't yet, a few at a time.
    func searchConversations(_ query: String, limit: Int = 20) async -> [(session: Session, snippet: String)] {
        let candidates = sessions.sorted { $0.time.updated > $1.time.updated }
        // Each with its engine; a machine that isn't connected is skipped until it is.
        let missing = candidates.filter { conversationTexts[$0.id]?.updated != $0.time.updated }
            .compactMap { session in api(forFolder: session.location.directory).map { (session, $0) } }
        await withTaskGroup(of: (Session, [Message])?.self) { group in
            var queue = missing.makeIterator()
            func next() {
                guard let (session, api) = queue.next() else { return }
                group.addTask { (try? await ConversationExport.messages(of: session, api: api)).map { (session, $0) } }
            }
            for _ in 0..<4 { next() }
            for await result in group {
                if let (session, messages) = result {
                    let text = ConversationExport.markdown(title: session.title ?? "New Session", messages: messages, directory: session.location.directory)
                    conversationTexts[session.id] = (session.time.updated, text)
                }
                if Task.isCancelled { group.cancelAll() } else { next() }
            }
        }
        var found: [(session: Session, snippet: String)] = []
        for session in candidates where found.count < limit {
            guard let text = conversationTexts[session.id]?.text,
                  let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            found.append((session, Self.snippet(around: range, in: text)))
        }
        return found
    }

    /// A line's worth of text from just before `range`, without Markdown's marks, so the match
    /// shows in a narrow sidebar.
    private static func snippet(around range: Range<String.Index>, in text: String) -> String {
        let start = text.index(range.lowerBound, offsetBy: -16, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
        let words = text[start..<end].filter { !"*`#>".contains($0) }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + words + (end < text.endIndex ? "…" : "")
    }

    /// A session's conversation as Markdown, to share.
    func markdown(of id: String) async throws -> String? {
        guard let session = session(id), let api = api(forFolder: session.location.directory) else { return nil }
        let messages = try await ConversationExport.messages(of: session, api: api)
        return ConversationExport.markdown(title: session.title ?? "New Session", messages: messages, directory: session.location.directory)
    }

    /// The live model behind a session view. Created on first use, then kept so
    /// switching back is instant.
    func model(for id: String) -> SessionModel? {
        if let model = models[id] { return model }
        guard let session = session(id), let api = api(forFolder: session.location.directory) else { return nil }
        let directory = session.location.directory
        // The project's folders where the session is now: a chat moved into a project gets its folders.
        let model = SessionModel(session: session, api: api) { [weak self] in
            guard let self else { return [] }
            return self.extraFolders(self.session(id)?.location.directory ?? directory)
        }
        models[id] = model
        return model
    }

    func loadBranch(for directory: String) async {
        guard let api = api(forFolder: directory), let info = try? await api.vcs(directory: directory) else { return }
        branches[directory] = info.branch?.current
        defaultBranches[directory] = info.branch?.default
    }

    func needsAttention(_ id: String) -> Bool {
        if askingInBrowser.contains(id) { return true }
        guard let model = models[id] else { return false }
        return !model.transcript.permissions.isEmpty || !model.transcript.forms.isEmpty
    }

    // MARK: Changes

    func addFolder(_ directory: String) {
        // Chats aren't a project.
        guard !folders.contains(directory), !Self.isChat(directory) else { return }
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
        if Self.isChat(directory) { return "Chats" }
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
        guard let api = api(forFolder: directory) else { throw CancellationError() }
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
        guard let api = api(forFolder: directory) else { throw CancellationError() }
        let project = try await api.location(directory: directory).project
        let (base, subpath) = await Task.detached { (Git.currentBranch(in: directory), Git.pathInRepository(of: directory)) }.value
        let root = try await api.createWorktree(project: project.id)
        // The engine leaves it on no branch; one of its own makes the work easy to commit,
        // push and merge.
        let prefix = GitPreferences.branchPrefix
        let branch = try await Task.detached { try Git.newBranch(named: prefix + (root as NSString).lastPathComponent, in: root) }.value
        let folder = subpath.isEmpty ? root : (root as NSString).appendingPathComponent(subpath)
        worktrees[folder] = Worktree(project: directory, root: root, branch: branch, base: base)
        saveWorktrees()
        return folder
    }

    /// A worktree's branch starts with a made-up name; once its session has a title, the branch
    /// is named after it, unless it's been pushed (or renamed) already.
    private func nameBranch(of session: Session) {
        let folder = session.location.directory
        guard let tree = worktrees[folder], let title = session.title, !title.isEmpty,
              tree.branch == GitPreferences.branchPrefix + (tree.root as NSString).lastPathComponent else { return }
        let slug = Git.slug(title)
        guard !slug.isEmpty else { return }
        Task {
            let prefix = GitPreferences.branchPrefix
            guard let renamed = await Task.detached(operation: { Git.renameBranch(tree.branch, to: prefix + slug, in: tree.root) }).value else { return }
            for (key, value) in worktrees where value.root == tree.root { worktrees[key]?.branch = renamed }
            saveWorktrees()
            if let tree = worktrees[folder] {
                try? await api(forFolder: session.location.directory)?.setInstruction(session: session.id, key: Self.worktreeInstructionKey, text: Self.instructions(for: tree))
            }
            await loadBranch(for: folder)
        }
    }

    /// Whether another session still working in the worktree (not archived) would lose it.
    func worktreeIsShared(_ directory: String, besides id: String) -> Bool {
        guard let root = worktrees[directory]?.root else { return false }
        return sessions.contains { $0.id != id && !Self.isArchived($0) && worktrees[$0.location.directory]?.root == root }
    }

    /// Removes a worktree's folder, changes that aren't committed too. Its branch stays with its
    /// commits, unless it's merged already.
    func removeWorktree(_ directory: String) async throws {
        guard let api = api(forFolder: directory), let tree = worktrees[directory] else { return }
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
        guard let api = api(forSession: id) else { return }
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
        let api = api(forSession: id)
        sessions.removeAll { $0.id == id }
        models[id] = nil
        Drafts.shared.remove(id)
        try? await api?.deleteSession(id)
    }

    func rename(_ id: String, to title: String) async {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].title = title
        try? await api(forSession: id)?.renameSession(id, title: title)
    }

    // MARK: Sync

    func refresh() async {
        guard let api else { return }
        do {
            let local = try await api.sessions().data.filter { !isHidden($0) }
            sessions = local + sessions.filter { RemoteFolder.isRemote($0.location.directory) }
        } catch { log.error("sessions: \(String(describing: error), privacy: .public)") }
        do {
            let active = try await api.activeSessions()
            running = active.union(running.filter { id in session(id).map { RemoteFolder.isRemote($0.location.directory) } ?? false })
        } catch { log.error("active sessions: \(String(describing: error), privacy: .public)") }
        isLoaded = true
    }

    /// Whether a session on the machine is working (or waiting for an answer).
    func isRunning(on machine: String) -> Bool {
        running.contains { id in
            (session(id).map { RemoteFolder.machine(of: $0.location.directory) } ?? sessionMachines[id]) == machine
        } || asking.values.contains { RemoteFolder.machine(of: session($0)?.location.directory ?? "") == machine }
    }

    /// A machine's sessions, when it connects (or reconnects after a gap), in place of what was
    /// known of them.
    func refresh(_ engine: MachineEngine) async {
        guard let api = engine.api else { return }
        let machine = engine.machine.id
        do {
            let theirs = try await api.sessions().data.filter { !isHidden($0) }
            sessions = sessions.filter { RemoteFolder.machine(of: $0.location.directory) != machine } + theirs
            for session in theirs { sessionMachines[session.id] = machine }
            remoteSessions = remoteSessions.filter { $0.value.machine != machine }
            for session in theirs { remoteSessions[session.id] = RemoteSession(machine: machine, title: session.title) }
            Self.saveRemoteSessions(remoteSessions)
            connectedMachines.insert(machine)
            let active = try await api.activeSessions()
            running = running.filter { id in session(id).map { RemoteFolder.machine(of: $0.location.directory) != machine } ?? true }.union(active)
            for model in models.values where RemoteFolder.machine(of: model.session.location.directory) == machine {
                await model.load()
            }
        } catch {
            log.error("\(machine, privacy: .public) sessions: \(String(describing: error), privacy: .public)")
        }
    }

    /// A machine disconnected: its sessions leave the lists until it's back (their tabs wait).
    /// Removed for good, they're forgotten too.
    func forget(_ machine: String, forGood: Bool = false) {
        let gone = Set(sessions.filter { RemoteFolder.machine(of: $0.location.directory) == machine }.map(\.id))
        sessions.removeAll { gone.contains($0.id) }
        running.subtract(gone)
        for id in gone { models[id] = nil }
        connectedMachines.remove(machine)
        if forGood {
            remoteSessions = remoteSessions.filter { $0.value.machine != machine }
            Self.saveRemoteSessions(remoteSessions)
            sessionMachines = sessionMachines.filter { $0.value != machine }
        }
    }

    private static func loadRemoteSessions() -> [String: RemoteSession] {
        guard let data = UserDefaults.standard.data(forKey: "remoteSessions") else { return [:] }
        return (try? JSONDecoder().decode([String: RemoteSession].self, from: data)) ?? [:]
    }

    private static func saveRemoteSessions(_ sessions: [String: RemoteSession]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(sessions), forKey: "remoteSessions")
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

    /// An agent on a machine started using its browser.
    @ObservationIgnored var onMachineBrowsing: ((_ machine: String, _ session: String) -> Void)?
    /// A bot's name, by its session, for its notifications.
    @ObservationIgnored var botName: ((String) -> String?)?

    /// The text of a session's last reply, shortened for a notification.
    private func lastReply(of id: String) async -> String? {
        guard Notifier.isEnabled, let page = try? await api(forSession: id)?.messages(session: id, limit: 6) else { return nil }
        for message in page.data.reversed() {
            guard case .assistant(let reply) = message else { continue }
            let text = reply.content.compactMap { content -> String? in
                if case .text(let text) = content { text.text } else { nil }
            }.joined(separator: " ")
            let plain = text
                .replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !plain.isEmpty else { continue }
            return plain.count > 220 ? String(plain.prefix(219)) + "…" : plain
        }
        return nil
    }
    /// An agent (in a session, on a machine or this Mac) is asking you for something in its browser.
    @ObservationIgnored var onBrowserAsk: ((_ session: String, _ machine: String?) -> Void)?

    /// An event from this Mac's engine, or from `machine`'s.
    func handle(_ event: ServerEvent, machine: String? = nil) {
        #if DEBUG
        // KUVO_DEMO_LOG_EVENTS: each session event in the log, to see their order.
        if Self.logsEvents, event.sessionID != nil {
            log.notice("event \(event.type, privacy: .public) \(String(decoding: event.raw.prefix(300), as: UTF8.self), privacy: .public)")
        }
        #endif
        if let machine, let id = event.sessionID { sessionMachines[id] = machine }
        if event.type == "session.tool.input.started", let id = event.sessionID,
           let started = try? event.payload(as: EventPayload.ToolInputStarted.self), started.name.hasPrefix("kuvo-browser_") {
            if let machine { onMachineBrowsing?(machine, id) }
            if ["kuvo-browser_browser_sign_in", "kuvo-browser_browser_ask_code", "kuvo-browser_browser_ask_user"].contains(started.name) {
                onBrowserAsk?(id, machine)
            }
        }
        if event.type == "vcs.branch.updated", let directory = event.location?.directory {
            struct Branch: Decodable { var branch: String? }
            let folder = machine.map { RemoteFolder.folder(directory, on: $0) } ?? directory
            branches[folder] = (try? event.payload(as: Branch.self))?.branch
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
            if remoteSessions.removeValue(forKey: id) != nil { Self.saveRemoteSessions(remoteSessions) }
            models[id] = nil
            asking = asking.filter { $0.value != id }
        case "session.execution.started":
            running.insert(id)
            runStarted[id] = .now
            touch(id)
        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted":
            running.remove(id)
            endedRuns[id, default: 0] += 1
            noteTurn(id, event)
            // Picks up the new idle time (unread state) and outcome.
            Task {
                await reload(id)
                // A run you stopped needs no news.
                if event.type != "session.execution.interrupted", let session = session(id) {
                    let failed = event.type == "session.execution.failed"
                    // What it said last, as a chat app's notification shows the message.
                    let reply = failed ? nil : await lastReply(of: id)
                    Notifier.shared.notify(
                        session: id,
                        title: botName?(id) ?? session.title ?? "New Session",
                        subtitle: botName?(id) == nil ? projectName(session.location.directory) : nil,
                        body: failed ? "Stopped with an error." : reply ?? "Finished.",
                        replies: true
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
            notifyAsk(request.sessionID, body: Self.describe(request), permission: request.id)
        case "permission.replied":
            if let reply = try? event.payload(as: EventPayload.PermissionReplied.self) {
                asking[reply.requestID] = nil
                Notifier.shared.clear(request: reply.requestID)
            }
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

    /// Sends a message to a session from outside its conversation (a notification's Reply), with
    /// the model it last used. Says so in a notification if it didn't go.
    func send(_ text: String, to id: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let failure: String
        if let api = api(forSession: id) {
            do {
                try await api.prompt(session: id, id: Identifier.message(), text: text, delivery: .queue)
                Analytics.shared.track("notification_replied")
                return
            } catch {
                failure = error.localizedDescription
            }
        } else {
            failure = "Its engine isn’t connected."
        }
        Notifier.shared.notify(session: id, title: botName?(id) ?? session(id)?.title ?? AppInfo.name,
                               body: "Your reply didn’t go: \(failure) Open the conversation to send it again.")
    }

    /// `permission` is the request, for a notification whose buttons answer it.
    private func notifyAsk(_ id: String, body: String, permission: String? = nil) {
        // A seat's requests are answered by its group chat.
        guard !seats.contains(id) else { return }
        Task {
            // A subagent's session has no row or tab of its own; its request shows in the
            // session that started it.
            var session = session(id)
            let api = api(forSession: id)
            var parent = session == nil ? (try? await api?.session(id))?.parentID : nil
            for _ in 0..<5 where session == nil {
                guard let next = parent else { break }
                session = self.session(next)
                parent = session == nil ? (try? await api?.session(next))?.parentID : nil
            }
            Notifier.shared.notify(session: session?.id ?? id, title: session?.title ?? AppInfo.name, subtitle: session.map { projectName($0.location.directory) }, body: body,
                                   permission: permission.map { (session: id, request: $0) })
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

    /// A permission request answered from its notification.
    func answer(_ request: String, in session: String, with answer: Notifier.PermissionAnswer) {
        Analytics.shared.track("permission_answered", ["decision": answer.rawValue, "from": "notification"])
        guard let decision = PermissionRequest.Decision(rawValue: answer.rawValue) else { return }
        Task { try? await api(forSession: session)?.reply(session: session, permission: request, decision: decision) }
    }

    func markViewed(_ id: String) {
        Notifier.shared.clear(session: id)
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].isUnread, let idle = sessions[index].time.idle else { return }
        sessions[index].time.viewed = idle
        Task { try? await api(forSession: id)?.markViewed(id, idle: idle) }
    }

    private func reload(_ id: String) async {
        guard let session = try? await api(forSession: id)?.session(id) else { return }
        // Only root sessions get a row; subagent sessions show inside their parent.
        guard session.parentID == nil else { return }
        upsert(session)
    }

    /// A session made elsewhere (a bot's), so it can be opened right away.
    func add(_ session: Session) {
        upsert(session)
    }

    private func upsert(_ session: Session) {
        guard !isHidden(session) else {
            sessions.removeAll { $0.id == session.id }
            return
        }
        nameBranch(of: session)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        models[session.id]?.session = session
        if let machine = RemoteFolder.machine(of: session.location.directory) {
            sessionMachines[session.id] = machine
            remoteSessions[session.id] = RemoteSession(machine: machine, title: session.title)
            Self.saveRemoteSessions(remoteSessions)
        }
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
