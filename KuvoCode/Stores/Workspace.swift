import Foundation
import OpenCodeKit
import os

private let log = Logger(subsystem: "run.kuvo.code", category: "workspace")

/// Projects and their sessions, kept live from engine events.
@Observable
final class Workspace {
    /// This Mac's engine.
    var api: OpenCodeAPI? {
        // The engine started again (it stopped, or you restarted it): this Mac's open
        // conversations go on through the new one, as a machine's do when it reconnects, and
        // read it again once it's live.
        didSet {
            guard let api, let oldValue, oldValue.client.endpoint != api.client.endpoint else { return }
            for model in models.values where !RemoteFolder.isRemote(model.session.location.directory) { model.reconnect(api) }
        }
    }
    /// A session an agent started (its start_session tool), to show beside the conversation that
    /// started it or in a tab of its own, as its metadata says (`kuvo.startedBy`, `kuvo.beside`):
    /// asked once, as it's first seen, wherever it runs.
    struct BesideRequest: Equatable {
        var session: String
        var startedBy: String
        /// Beside the conversation that started it (the default); false: in a tab.
        var beside = true
    }
    var besideRequest: BesideRequest?
    @ObservationIgnored private var askedBeside: Set<String> = []

    /// A machine's engine, by its name, for projects on it (folders written `ssh://machine/path`).
    @ObservationIgnored var machineAPI: (String) -> OpenCodeAPI? = { _ in nil }
    /// The machine each session's events came from, for sessions without a row (a subagent's).
    @ObservationIgnored private var sessionMachines: [String: String] = [:]
    /// Machines' sessions as last seen, kept across launches so their tabs wait for the machine
    /// to connect instead of closing.
    @ObservationIgnored private var remoteSessions: [String: RemoteSession] = {
        let sessions = Workspace.loadRemoteSessions()
        // Their conversations as last seen, for those tabs meanwhile; the rest are gone.
        SessionCopies.keep(Set(sessions.keys))
        return sessions
    }()
    /// The machines whose sessions are in the lists.
    private(set) var connectedMachines: Set<String> = []
    /// The machines you've added. A removed machine's projects leave the sidebar but keep their
    /// settings, for when it's added again.
    var machines: Set<String> = [] {
        didSet { for machine in machines.subtracting(oldValue) { showLastSeen(machine) } }
    }

    struct RemoteSession: Codable {
        var machine: String
        var title: String?
    }

    /// The machine a session is on, while that machine isn't connected; nil once it is (or
    /// for this Mac's sessions).
    func waitingMachine(for id: String) -> String? {
        guard let machine = session(id).flatMap({ RemoteFolder.machine(of: $0.location.directory) }) ?? remoteSessions[id]?.machine,
              !connectedMachines.contains(machine) else { return nil }
        return machine
    }

    /// A machine's sessions as last seen, in the lists until it connects.
    private func showLastSeen(_ machine: String) {
        guard !connectedMachines.contains(machine), !sessions.contains(where: { RemoteFolder.machine(of: $0.location.directory) == machine }) else { return }
        let seen = SessionCopies.sessions(of: machine).filter { !isHidden($0) }
        for session in seen { sessionMachines[session.id] = machine }
        sessions += seen
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
    private(set) var running: Set<String> = [] {
        // While one runs on this Mac, it stays awake (unless you turned that off).
        didSet { Awake.shared.agentsWork(running.contains { id in sessionMachines[id] == nil && !(session(id).map { RemoteFolder.isRemote($0.location.directory) } ?? false) }) }
    }
    /// Folders the user opened, even before they have sessions.
    /// A bot's own folder was kept as one by mistake once: it isn't one.
    private(set) var folders: [String] = (UserDefaults.standard.stringArray(forKey: "projectFolders") ?? []).filter { !Workspace.isBotFolder($0) }
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
    /// What MCP servers ask (in `asking` with the session waiting on it), by form: the folder
    /// the engine files each under, which answering it takes.
    @ObservationIgnored private(set) var sharedForms: [String: String] = [:]
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

    /// A bot's own folder, on this Mac or a machine: what's there is the bot's, even before the
    /// bot is listed (while it's being made), so it never shows as a project.
    static func isBotFolder(_ directory: String) -> Bool {
        directory.hasPrefix(Bots.root.path + "/") || directory.contains("/\(RemoteEngineInstaller.root)/bots/")
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
        let grouped = Dictionary(grouping: sessions.filter { !Self.isArchived($0) && !botSessions.contains($0.id) && !Self.isChat($0.location.directory) && !Self.isBotFolder($0.location.directory) }, by: projectDirectory(of:))
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
        if let machine = RemoteFolder.machine(of: sessions[index].location.directory) { keepList(of: machine) }
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
        model.isReachable = reachable(folder)
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
        guard let session = session(id), let api = api(forFolder: session.location.directory) else { return copyModel(for: id) }
        let directory = session.location.directory
        // The project's folders where the session is now: a chat moved into a project gets its folders.
        let model = SessionModel(session: session, api: api) { [weak self] in
            guard let self else { return [] }
            return self.extraFolders(self.session(id)?.location.directory ?? directory)
        }
        model.isReachable = reachable(directory)
        models[id] = model
        return model
    }

    /// A machine's sessions as they are now, kept for when it's away (see `showLastSeen`): a
    /// moment after they change, as several often change together.
    @ObservationIgnored private var listSaves: [String: Task<Void, Never>] = [:]

    private func keepList(of machine: String) {
        guard connectedMachines.contains(machine) else { return }
        listSaves[machine]?.cancel()
        listSaves[machine] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            saveList(of: machine)
        }
    }

    private func saveList(of machine: String) {
        listSaves[machine]?.cancel()
        listSaves[machine] = nil
        SessionCopies.saveSessions(sessions.filter { RemoteFolder.machine(of: $0.location.directory) == machine }, of: machine)
    }

    /// Whether a folder's engine can be reached: a machine's, while it's connected.
    private func reachable(_ folder: String) -> () -> Bool {
        guard let machine = RemoteFolder.machine(of: folder) else { return { true } }
        return { [weak self] in self?.connectedMachines.contains(machine) ?? false }
    }

    /// Whether the machine's sessions are live (it's connected and they've been read).
    func isConnected(_ machine: String) -> Bool { connectedMachines.contains(machine) }

    /// A session on a machine that's connecting, from its conversation as last seen, to read
    /// meanwhile. It takes the machine's engine once it's back (see `refresh`).
    private func copyModel(for id: String) -> SessionModel? {
        guard let machine = waitingMachine(for: id), let copy = SessionCopies.load(id) else { return nil }
        // Nothing answers here; nothing's asked of it before the machine is back.
        let offline = OpenCodeAPI(endpoint: ServerEndpoint(url: URL(string: "http://127.0.0.1:9")!, username: "", password: nil), folderPrefix: RemoteFolder.prefix(for: machine))
        let directory = copy.session.location.directory
        let model = SessionModel(session: copy.session, api: offline) { [weak self] in
            guard let self else { return [] }
            return self.extraFolders(self.session(id)?.location.directory ?? directory)
        }
        model.isReachable = reachable(directory)
        model.show(copy.messages)
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
        return !model.permissions.isEmpty || !model.forms.isEmpty
    }

    // MARK: Changes

    /// Adds a project folder; the folder as it's kept (see `folderPath`).
    @discardableResult
    func addFolder(_ directory: String) -> String {
        let directory = folderPath(directory)
        // Chats aren't a project, nor is a bot's own folder.
        guard !folders.contains(directory), !Self.isChat(directory), !Self.isBotFolder(directory) else { return directory }
        Analytics.shared.track("project_added", ["projects": folders.count + 1])
        folders.insert(directory, at: 0)
        UserDefaults.standard.set(folders, forKey: "projectFolders")
        return directory
    }

    /// A project's folder as it's kept: one already a project as it is; a new one on this Mac by its
    /// real path, links followed (/var/… is /private/var/…, a Dropbox folder is in
    /// ~/Library/CloudStorage). The engine takes a session for outside its project when the two
    /// paths differ, and keeps no snapshots of its changes then, so Undo couldn't bring files back.
    func folderPath(_ directory: String) -> String {
        guard !folders.contains(directory), !RemoteFolder.isRemote(directory), let resolved = realpath(directory, nil) else { return directory }
        defer { free(resolved) }
        return String(cString: resolved)
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
    @discardableResult
    func saveProject(_ directory: String, settings project: ProjectSettings) -> String {
        let directory = addFolder(directory)
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
        return directory
    }

    /// Settings › Permissions changed: open sessions' rules follow (the others' when they open).
    func syncPermissions() {
        for model in models.values {
            Task { await model.syncFolders() }
        }
    }

    /// A new session in the project at `directory`, or with `worktree`, in a new worktree of it.
    func createSession(in directory: String, model: ModelRef?, agent: String?, approval: ToolApproval = .approveAll, worktree: Bool = false) async throws -> Session {
        guard let api = api(forFolder: directory) else { throw CancellationError() }
        let directory = addFolder(directory)
        let folder = worktree ? try await makeWorktree(of: directory) : directory
        let extra = settings[directory]?.folders ?? []
        let rules = ProjectFolders.permissions(approval.rules(settings: EngineConfig.current?.permissionRules ?? []), folders: extra)
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
        if let since = Analytics.shared.sinceInstall { props["since_install"] = since }
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
        // What it replied to comes back over the composer, as you wrote it.
        let (quotes, text) = Quoting.draft(of: ReviewComments.split(withComments).text)
        Drafts.shared[session.id] = Drafts.Draft(text: text, files: SessionModel.files(of: stored) + paths.map { URL(filePath: $0) }, quotes: quotes)
        requestedTab = session.id
    }

    /// Deleted on its engine; one on a machine that's away waits for it (it would come back).
    func delete(_ id: String) async {
        guard let api = api(forSession: id) else { return }
        if let machine = session(id).flatMap({ RemoteFolder.machine(of: $0.location.directory) }) { keepList(of: machine) }
        sessions.removeAll { $0.id == id }
        models[id] = nil
        Drafts.shared.remove(id)
        try? await api.deleteSession(id)
    }

    func rename(_ id: String, to title: String) async {
        guard let index = sessions.firstIndex(where: { $0.id == id }), api(forSession: id) != nil else { return }
        sessions[index].title = title
        if let machine = RemoteFolder.machine(of: sessions[index].location.directory) { keepList(of: machine) }
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

    /// The folders of the sessions open or at work on `machine` (nil: this Mac): folders its
    /// engine has open, each with its own MCP servers.
    func openFolders(on machine: String?) -> Set<String> {
        let ids = Set(models.keys).union(running)
        return Set(ids.compactMap { session($0)?.location.directory }.filter { RemoteFolder.machine(of: $0) == machine })
    }

    /// Whether a session on the machine is working (or waiting for an answer).
    func isRunning(on machine: String) -> Bool {
        running.contains { id in
            (session(id).map { RemoteFolder.machine(of: $0.location.directory) } ?? sessionMachines[id]) == machine
        } || asking.values.contains { RemoteFolder.machine(of: session($0)?.location.directory ?? "") == machine }
    }

    /// The run end each bot's session was last told about (as its idle time), so news that came
    /// while a machine was out of reach is told once it's back, and only once.
    @ObservationIgnored private var toldIdle: [String: Double] = [:]
    /// Machines connected since launch: a later connection is a reconnection.
    @ObservationIgnored private var connectedOnce: Set<String> = []

    /// Bots on the machine that finished while it was out of reach (your Mac asleep, say): their
    /// news, in notifications, as if you'd been connected.
    private func tellMissedNews(in sessions: [Session], machine: String) {
        let reconnected = !connectedOnce.insert(machine).inserted
        for session in sessions where botName?(session.id) != nil {
            guard let idle = session.time.idle else { continue }
            let told = toldIdle[session.id]
            toldIdle[session.id] = max(idle, told ?? 0)
            guard reconnected, session.isUnread, idle > (told ?? 0) else { continue }
            Task {
                let reply = await lastReply(of: session.id)
                if let reply { replyPreviews[session.id] = reply }
                Notifier.shared.notify(session: session.id, title: botName?(session.id) ?? session.title ?? "New Session",
                                       body: session.outcome == .failed ? "Stopped with an error." : reply ?? "Finished.", replies: true)
            }
        }
    }

    /// A machine's sessions, when it connects (or reconnects after a gap), in place of what was
    /// known of them.
    /// False when the machine couldn't list its sessions (to try again).
    @discardableResult
    func refresh(_ engine: MachineEngine) async -> Bool {
        guard let api = engine.api else { return true }
        let machine = engine.machine.id
        // Still the connection it started with: a newer one (or none) takes over from here.
        let isCurrent = { engine.isReady && engine.api?.client.endpoint == api.client.endpoint }
        do {
            let listed = try await api.sessions().data
            guard isCurrent() else { return true }
            // Its open conversations take this connection first, so nothing sent from them goes
            // to the old one.
            for model in models.values where RemoteFolder.machine(of: model.session.location.directory) == machine { model.reconnect(api) }
            let theirs = listed.filter { !isHidden($0) }
            tellMissedNews(in: theirs, machine: machine)
            sessions = sessions.filter { RemoteFolder.machine(of: $0.location.directory) != machine } + theirs
            for session in theirs { sessionMachines[session.id] = machine }
            remoteSessions = remoteSessions.filter { $0.value.machine != machine }
            for session in theirs { remoteSessions[session.id] = RemoteSession(machine: machine, title: session.title) }
            Self.saveRemoteSessions(remoteSessions)
            SessionCopies.saveSessions(theirs, of: machine)
            connectedMachines.insert(machine)
            if let active = try? await api.activeSessions(), isCurrent() {
                running = running.filter { id in session(id).map { RemoteFolder.machine(of: $0.location.directory) != machine } ?? true }.union(active)
            }
            // Its open conversations, kept while it was away, are read again; one deleted there
            // meanwhile goes. (The list has only the newest, so one missing from it is asked about.)
            let known = Set(listed.map(\.id))
            for (id, model) in models where RemoteFolder.machine(of: model.session.location.directory) == machine {
                guard isCurrent() else { return true }
                if !model.isSubagent, !known.contains(id) {
                    guard let session = try? await api.session(id) else {
                        models[id] = nil
                        continue
                    }
                    model.session = session
                } else if let session = listed.first(where: { $0.id == id }) {
                    model.session = session
                }
                await model.load()
            }
        } catch {
            log.error("\(machine, privacy: .public) sessions: \(String(describing: error), privacy: .public)")
            return false
        }
        return true
    }

    /// A machine disconnected: its sessions stay as last seen until it's back, their
    /// conversations to read. Removed for good, they're forgotten.
    func forget(_ machine: String, forGood: Bool = false) {
        let gone = Set(sessions.filter { RemoteFolder.machine(of: $0.location.directory) == machine }.map(\.id))
        if !forGood, connectedMachines.contains(machine) { saveList(of: machine) }
        running.subtract(gone)
        connectedMachines.remove(machine)
        if forGood {
            listSaves[machine]?.cancel()
            listSaves[machine] = nil
            sessions.removeAll { gone.contains($0.id) }
            for id in gone { models[id] = nil }
            for (id, session) in remoteSessions where session.machine == machine { SessionCopies.remove(id) }
            SessionCopies.removeSessions(of: machine)
            models = models.filter { RemoteFolder.machine(of: $0.value.session.location.directory) != machine }
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
            // A machine's are read when it's connected (see `refresh(_ engine:)`).
            if RemoteFolder.machine(of: model.session.location.directory).map(connectedMachines.contains) ?? true { await model.load() }
            for request in model.permissions { asking[request.id] = request.sessionID }
            for form in model.forms { note(form, in: model) }
        }
    }

    /// An agent on a machine started using its browser.
    @ObservationIgnored var onMachineBrowsing: ((_ machine: String, _ session: String) -> Void)?

    /// An agent showed you a file or folder (its show_in_panel tool), at a path on its machine
    /// (nil: this Mac): the window opens it in the panel.
    @ObservationIgnored var onShowInPanel: ((_ session: String, _ machine: String?, _ path: String, _ isFolder: Bool) -> Void)?
    /// An agent on `machine` wrote to one elsewhere (see `AgentMail`): its message waits there.
    @ObservationIgnored var onAgentMessage: ((_ machine: String) -> Void)?
    /// send_message's calls under way on machines, by ID.
    @ObservationIgnored private var mailCalls: Set<String> = []
    /// Those calls under way, by ID, with their paths once they're known.
    @ObservationIgnored private var panelCalls: [String: String] = [:]

    /// Follows show_in_panel's calls: what they're for when they're made, and once the tool says
    /// the path is there, it's shown.
    private func noteShowInPanel(_ event: ServerEvent, machine: String?) {
        guard let session = event.sessionID else { return }
        switch event.type {
        case "session.tool.input.started":
            if let started = try? event.payload(as: EventPayload.ToolInputStarted.self), started.name == "kuvo-browser_" + BrowserTools.showInPanel {
                panelCalls[started.id] = ""
            }
            if machine != nil, let started = try? event.payload(as: EventPayload.ToolInputStarted.self), started.name == "kuvo-browser_send_message" {
                mailCalls.insert(started.id)
            }
        case "session.tool.called":
            if let called = try? event.payload(as: EventPayload.ToolCalled.self), panelCalls[called.id] != nil {
                panelCalls[called.id] = called.input["path"]?.string ?? ""
            }
        case "session.tool.success":
            if let machine, let done = try? event.payload(as: EventPayload.ToolSucceeded.self), mailCalls.remove(done.id) != nil {
                onAgentMessage?(machine)
            }
            guard let done = try? event.payload(as: EventPayload.ToolSucceeded.self), let path = panelCalls.removeValue(forKey: done.id), !path.isEmpty else { return }
            let said = done.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
            guard let isFolder = BrowserTools.shownFolder(in: said) else { return }
            onShowInPanel?(session, machine, path, isFolder)
        case "session.tool.failed":
            if let failed = try? event.payload(as: EventPayload.ToolFailed.self) {
                panelCalls[failed.id] = nil
                mailCalls.remove(failed.id)
            }
        default:
            break
        }
    }
    /// A bot's name, by its session, for its notifications.
    @ObservationIgnored var botName: ((String) -> String?)?
    /// A session's run ended (a bot's memory may have changed).
    @ObservationIgnored var onRunEnded: ((String) -> Void)?

    /// The start of a bot's last reply, for its row in the sidebar while it's unread, as a chat
    /// list shows a message.
    private(set) var replyPreviews: [String: String] = [:]

    /// Reads a bot's last reply for its row, unless it's known.
    func loadReplyPreview(_ id: String) async {
        guard replyPreviews[id] == nil, let reply = await lastReply(of: id) else { return }
        replyPreviews[id] = reply
    }

    /// The text of a session's last reply, shortened for a notification.
    private func lastReply(of id: String) async -> String? {
        guard let page = try? await api(forSession: id)?.messages(session: id, limit: 6) else { return nil }
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
        // What an MCP server asks (and its answer): for the conversations of its folder there.
        if (event.sessionID ?? Self.formSessionID(event)) == FormRequest.anySession {
            handleShared(event, machine: machine)
            return
        }
        if let machine, let id = event.sessionID { sessionMachines[id] = machine }
        noteShowInPanel(event, machine: machine)
        if event.type == "session.tool.input.started", let id = event.sessionID,
           let started = try? event.payload(as: EventPayload.ToolInputStarted.self), started.name.hasPrefix("kuvo-browser_browser_") {
            if let machine {
                onMachineBrowsing?(machine, id)
                Analytics.shared.trackOnce("browser_used", key: "agent.machine", ["by": "agent", "place": "machine"])
            }
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
        // A run's first words, thought or tool: how long the model took to start.
        if runStarted[id] != nil, firstOutput[id] == nil, ["session.text.started", "session.reasoning.started", "session.tool.input.started"].contains(event.type) {
            firstOutput[id] = .now
        }

        switch event.type {
        case "session.created", "session.renamed", "session.moved", "session.metadata.updated", "session.revert.staged", "session.revert.cleared", "session.revert.committed":
            Task { await reload(id) }
        case "session.deleted":
            sessions.removeAll { $0.id == id }
            if let machine { keepList(of: machine) }
            if remoteSessions.removeValue(forKey: id) != nil {
                Self.saveRemoteSessions(remoteSessions)
                SessionCopies.remove(id)
            }
            models[id] = nil
            asking = asking.filter { $0.value != id }
        case "session.execution.started":
            running.insert(id)
            runStarted[id] = .now
            firstOutput[id] = nil
            if let session = session(id) { usageAtStart[id] = (Self.tokenCount(session.tokens), session.cost) }
            touch(id)
        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted":
            running.remove(id)
            endedRuns[id, default: 0] += 1
            noteTurn(id, event)
            onRunEnded?(id)
            if session(id)?.title?.isEmpty != false { nameIfUntitled(id) }
            // Picks up the new idle time (unread state) and outcome.
            Task {
                await reload(id)
                // A run you stopped needs no news.
                if event.type != "session.execution.interrupted", let session = session(id) {
                    let failed = event.type == "session.execution.failed"
                    // What it said last, as a chat app's notification shows the message, and a
                    // bot's row.
                    let isBot = botName?(id) != nil
                    let reply = failed || !(Notifier.isEnabled || isBot) ? nil : await lastReply(of: id)
                    if isBot { replyPreviews[id] = reply }
                    // Told: a reconnection won't tell it again.
                    if let idle = self.session(id)?.time.idle { toldIdle[id] = max(idle, toldIdle[id] ?? 0) }
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
    @ObservationIgnored private var firstOutput: [String: Date] = [:]
    /// A session's tokens and cost as a run began, to tell what the run used.
    @ObservationIgnored private var usageAtStart: [String: (tokens: Int, cost: Double)] = [:]

    private static func tokenCount(_ tokens: TokenUsage) -> Int {
        tokens.input + tokens.output + tokens.reasoning
    }

    /// A session the engine didn't name after its run (its title model gave nothing back, as
    /// GLM-5.3 Flash's does): the start of its first message, as a chat app names one, so the
    /// sidebar isn't a column of "New Session". Saved in the engine, for every place that shows it.
    private func nameIfUntitled(_ id: String) {
        guard !seats.contains(id), !namingUntitled.contains(id) else { return }
        namingUntitled.insert(id)
        Task {
            defer { namingUntitled.remove(id) }
            // The engine names it a few seconds after the run, when it can.
            try? await Task.sleep(for: .seconds(15))
            guard session(id)?.title?.isEmpty != false, let api = api(forSession: id),
                  let page = try? await api.messages(session: id, limit: 40) else { return }
            let first = page.data.lazy.compactMap { message -> String? in
                if case .user(let user) = message { return user.text }
                return nil
            }.first
            guard let first, let title = Self.title(from: first) else { return }
            try? await api.renameSession(id, title: title)
            await reload(id)
        }
    }
    @ObservationIgnored private var namingUntitled: Set<String> = []

    /// A title from a message: its words without review comments or line breaks, up to the end
    /// of its first sentence or about 48 characters, at a word.
    nonisolated static func title(from message: String) -> String? {
        let split = ReviewComments.split(message)
        let words = (split.text.isEmpty ? split.comments.first?.text ?? "" : split.text)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        var title = words
        if let end = title.firstIndex(where: { ".?!".contains($0) }), title.distance(from: title.startIndex, to: end) >= 12 {
            title = String(title[...end])
        }
        if title.count > 48 {
            let cut = title.prefix(48)
            title = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
        }
        return title.hasSuffix(".") ? String(title.dropLast()) : title
    }

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
        if let started = runStarted.removeValue(forKey: id) {
            props["seconds"] = Int(Date.now.timeIntervalSince(started))
            if let first = firstOutput.removeValue(forKey: id) { props["first_token_seconds"] = Int(first.timeIntervalSince(started)) }
        }
        if let start = usageAtStart.removeValue(forKey: id), let session {
            props["tokens"] = Analytics.tokens(Double(max(0, Self.tokenCount(session.tokens) - start.tokens)))
            props["cost"] = Analytics.cost(max(0, session.cost - start.cost))
        }
        if event.type == "session.execution.failed", let error = ended?.error {
            props["error"] = String(error.type.lowercased().filter { $0.isLetter || $0 == "_" }.prefix(40))
            if let status = error.status { props["status"] = status }
            // What kind of trouble, from its words, which stay here.
            props["error_type"] = Analytics.trouble(status: error.status, error.type + " " + error.message)
        }
        Analytics.shared.track("turn_finished", props)
        Analytics.shared.noteTurn(in: id)
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
            let question = Self.question(in: form)
            notifyAsk(form.sessionID, body: question?.text ?? (form.isQuestion ? "Has a question for you." : "Needs your answer."), question: question)
        case "form.replied", "form.cancelled":
            if let settled = try? event.payload(as: EventPayload.FormSettled.self) {
                asking[settled.id] = nil
                Notifier.shared.clear(request: settled.id)
            }
        default:
            break
        }
    }

    /// The agent's question as its notification asks it, with its choices; nil for anything
    /// more (the notification opens the conversation).
    private static func question(in form: FormRequest) -> Notifier.Question? {
        form.single.map { single in
            Notifier.Question(session: form.sessionID, form: form.id, key: single.key, text: single.text,
                              choices: single.choices.map { (value: $0.value, label: $0.label) }, allowsText: single.allowsText)
        }
    }

    /// Answers a question from its notification.
    func answerQuestion(_ form: String, in session: String, field: String, with answer: String) {
        Analytics.shared.track("question_answered", ["kind": "question", "from": "notification"])
        Task {
            do {
                guard let api = api(forSession: session) else { throw CancellationError() }
                try await api.reply(session: session, form: form, answer: [field: .string(answer)])
            } catch {
                // The agent still waits: say so, rather than lose the answer.
                Notifier.shared.notify(session: session, title: botName?(session) ?? self.session(session)?.title ?? AppInfo.name,
                                       body: "Your answer didn’t go. Open the conversation to answer there.")
            }
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
    private func notifyAsk(_ id: String, body: String, permission: String? = nil, question: Notifier.Question? = nil) {
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
            Notifier.shared.notify(session: session?.id ?? id, title: session.flatMap { botName?($0.id) } ?? session?.title ?? AppInfo.name,
                                   subtitle: session.flatMap { botName?($0.id) == nil ? projectName($0.location.directory) : nil }, body: body,
                                   permission: permission.map { (session: id, request: $0) }, question: question)
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
        // Read: its next news is read afresh.
        if replyPreviews[id] != nil { replyPreviews[id] = nil }
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].isUnread, let idle = sessions[index].time.idle,
              api(forSession: id) != nil else { return }
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

    /// Asks for an agent's new session to show beside the one that started it, or in a tab, the
    /// first time it's seen, while it's new.
    private func noteBeside(_ session: Session) {
        guard let kuvo = session.metadata?["kuvo"], let starter = kuvo["startedBy"]?.string,
              Date.now.timeIntervalSince1970 * 1000 - session.time.created < 120_000,
              askedBeside.insert(session.id).inserted else { return }
        besideRequest = BesideRequest(session: session.id, startedBy: starter, beside: kuvo["beside"]?.bool != false)
    }

    private func upsert(_ session: Session) {
        guard !isHidden(session) else {
            sessions.removeAll { $0.id == session.id }
            return
        }
        nameBranch(of: session)
        noteBeside(session)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        models[session.id]?.session = session
        if let machine = RemoteFolder.machine(of: session.location.directory) {
            keepList(of: machine)
            sessionMachines[session.id] = machine
            remoteSessions[session.id] = RemoteSession(machine: machine, title: session.title)
            Self.saveRemoteSessions(remoteSessions)
        }
    }

    private func touch(_ id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].time.updated = Date().timeIntervalSince1970 * 1000
    }

    /// What an MCP server asks belongs to no session: each conversation of its folder on that
    /// engine sees it, and takes it if a tool of that server is running there. Asked, it's noted
    /// for the conversation waiting on it, open or not.
    private func handleShared(_ event: ServerEvent, machine: String?) {
        let folder = event.location.map { location in machine.map { RemoteFolder.folder(location.directory, on: $0) } ?? location.directory }
        for model in models.values where RemoteFolder.machine(of: model.session.location.directory) == machine
            && (folder == nil || model.session.location.directory == folder) {
            model.apply(event)
        }
        switch event.type {
        case "form.created":
            guard let form = try? event.payload(as: EventPayload.FormCreated.self).form, let server = form.server else { return }
            if let model = models.values.first(where: { $0.forms.contains { $0.id == form.id } }) {
                note(form, in: model)
                return
            }
            // A conversation that isn't open: the running one of that folder with that server's
            // tool going.
            Task {
                for id in running where sessionMachines[id] == machine {
                    guard let directory = session(id)?.location.directory ?? folder, folder == nil || directory == folder,
                          let api = api(forSession: id), let page = try? await api.messages(session: id, limit: 8),
                          Transcript.isWaiting(on: server, in: page.data) else { continue }
                    sharedForms[form.id] = directory
                    asking[form.id] = id
                    notifyAsk(id, body: form.message ?? "Needs your answer.", question: nil)
                    return
                }
            }
        case "form.replied", "form.cancelled":
            guard let settled = try? event.payload(as: EventPayload.FormSettled.self) else { return }
            asking[settled.id] = nil
            sharedForms[settled.id] = nil
            Notifier.shared.clear(request: settled.id)
        default:
            break
        }
    }

    /// A form `model`'s conversation shows, as one it's asking.
    private func note(_ form: FormRequest, in model: SessionModel) {
        // Told once, not again with each read after a reconnect.
        let isNew = sharedForms[form.id] == nil
        asking[form.id] = model.id
        guard form.sessionID == FormRequest.anySession else { return }
        sharedForms[form.id] = model.session.location.directory
        if isNew { notifyAsk(model.id, body: form.message ?? "Needs your answer.", question: nil) }
    }

    /// `form.created` carries its session inside the form.
    private static func formSessionID(_ event: ServerEvent) -> String? {
        guard event.type == "form.created" else { return nil }
        return try? event.payload(as: EventPayload.FormCreated.self).form.sessionID
    }
}
