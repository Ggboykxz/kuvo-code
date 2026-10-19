import Foundation
import KuvoLink
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
            for model in models.values where !RemoteFolder.isRemote(model.session.location.directory) && !OutsideAgents.isAgentSession(model.session) { model.reconnect(api) }
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

    /// The agents bridge: sessions with Claude Code, Codex, Cursor, Grok and Antigravity go to it,
    /// whatever their folder (on this Mac).
    @ObservationIgnored var agents: OutsideAgents?

    /// A machine's engine, by its name, for projects on it (folders written `ssh://machine/path`).
    @ObservationIgnored var machineAPI: (String) -> OpenCodeAPI? = { _ in nil }
    /// The machine each session's events came from, for sessions without a row (a subagent's).
    @ObservationIgnored private var sessionMachines: [String: String] = [:]
    /// Machines' sessions as last seen, kept across launches so their tabs wait for the machine
    /// to connect instead of closing.
    @ObservationIgnored private var remoteSessions: [String: RemoteSession] = {
        let sessions = Workspace.loadRemoteSessions()
        // Their conversations as last seen, for those tabs meanwhile, and this Mac's sessions';
        // the rest are gone.
        SessionCopies.keep(Set(sessions.keys).union(SessionCopies.localSessions().map(\.id)))
        return sessions
    }()
    /// The machines whose sessions are in the lists.
    private(set) var connectedMachines: Set<String> = []
    /// The machines you've added. A removed machine's projects leave the sidebar but keep their
    /// settings, for when it's added again.
    var machines: Set<String> = [] {
        didSet {
            projectsChanged()
            for machine in machines.subtracting(oldValue) { showLastSeen(machine) }
        }
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
        if let session = session(id) { return api(for: session) }
        if let machine = sessionMachines[id] { return machineAPI(machine) }
        // One the agents bridge told of before it has a row (made on your phone, say).
        if bridgeSessions.contains(id) { return agents?.api }
        return api
    }

    /// Sessions the agents bridge has told of: theirs, wherever they were made.
    @ObservationIgnored private var bridgeSessions: Set<String> = []

    /// An event from the agents bridge: its session is the bridge's.
    func handleAgents(_ event: ServerEvent) {
        if let id = event.sessionID ?? Self.formSessionID(event) { bridgeSessions.insert(id) }
        handle(event)
    }

    /// What a session runs on: the agents bridge for an outside agent's, else its folder's engine.
    func api(for session: Session) -> OpenCodeAPI? {
        OutsideAgents.isAgentSession(session) ? agents?.api : api(forFolder: session.location.directory)
    }

    /// This Mac's as last listed until its engine lists them (it takes a moment to start), so the
    /// sidebar and the conversation open at launch show at once.
    private(set) var sessions: [Session] = SessionCopies.localSessions() {
        didSet {
            projectsChanged()
            if isLoaded { keepLocalList() }
        }
    }
    private(set) var running: Set<String> = [] {
        // While one runs on this Mac, it stays awake (unless you turned that off).
        didSet { Awake.shared.agentsWork(running.contains { id in sessionMachines[id] == nil && !(session(id).map { RemoteFolder.isRemote($0.location.directory) } ?? false) }) }
    }
    /// Folders the user opened, even before they have sessions.
    /// A bot's own folder was kept as one by mistake once: it isn't one.
    private(set) var folders: [String] = (UserDefaults.standard.stringArray(forKey: "projectFolders") ?? []).filter { !Workspace.isBotFolder($0) } {
        didSet { projectsChanged() }
    }
    /// Names and other folders of projects, by their primary folder.
    private(set) var settings: [String: ProjectSettings] = Workspace.loadSettings() {
        didSet { projectsChanged() }
    }
    /// Sessions' own git worktrees, by the folder their sessions run in.
    private(set) var worktrees: [String: Worktree] = Workspace.loadWorktrees() {
        didSet { projectsChanged() }
    }
    /// The projects of worktrees removed since, by the folder their sessions ran in: an archived
    /// session there still belongs to its project, and comes back to it if you restore it.
    private var removedWorktrees: [String: String] = UserDefaults.standard.dictionary(forKey: "removedWorktrees") as? [String: String] ?? [:] {
        didSet { projectsChanged() }
    }
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
        worktrees[directory]?.project ?? removedWorktrees[directory] ?? directory
    }

    func projectDirectory(of session: Session) -> String {
        projectDirectory(session.location.directory)
    }

    /// The project's other folders, for a folder sessions run in.
    func extraFolders(_ directory: String) -> [String] {
        settings[projectDirectory(directory)]?.folders ?? []
    }

    /// Bots' sessions: each bot's conversation, shown with the bot rather than in its project.
    var botSessions: Set<String> = [] {
        didSet { projectsChanged() }
    }
    /// Bots' seats in group chats: sessions that never get a row, a tab or a notification.
    var seats: Set<String> = [] {
        didSet { sessions.removeAll { seats.contains($0.id) } }
    }

    /// A bot's seat in a group chat, by its metadata, before it's in `seats`.
    static func isSeat(_ session: Session) -> Bool {
        session.metadata?["kuvo"]?["seat"] != nil
    }

    private func isHidden(_ session: Session) -> Bool {
        seats.contains(session.id) || Self.isSeat(session) || Self.isEngineRun(session)
    }

    /// The engine's session for a model of the engine's run in a session with the agents (Auto's,
    /// say): that session shows what it does, so it never gets a row of its own.
    static func isEngineRun(_ session: Session) -> Bool {
        session.metadata?["kuvo"]?["engineFor"] != nil
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
        guard let session = session(id) else { return }
        if OutsideAgents.isAgentSession(session) { throw OutsideAgents.Failure.unavailable("Moving a chat into a project") }
        guard let api = api(forFolder: directory) else { return }
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
        // What they're made of, read here so views showing them are updated as it changes.
        _ = (sessions.count, folders.count, settings.count, worktrees.count, removedWorktrees.count, botSessions.count, machines.count)
        if let madeProjects { return madeProjects }
        let projects = makeProjects()
        madeProjects = projects
        return projects
    }

    /// The projects as last made, until what they're made of changes: views showing them (the
    /// sidebar, every time the window is resized) read them often, and making them groups and
    /// sorts every session.
    @ObservationIgnored private var madeProjects: [Project]?

    private func projectsChanged() {
        madeProjects = nil
    }

    private func makeProjects() -> [Project] {
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
        guard let index = sessions.firstIndex(where: { $0.id == id }), let api = api(for: sessions[index]) else { return }
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

    /// The subagent a step handed its task to, as the conversation it's in knows it (with the
    /// session the step started, when the engine didn't say), and that conversation.
    func subagent(forStep call: String) -> (subagent: SessionModel.Subagent, conversation: String)? {
        for (id, model) in models {
            if let subagent = model.subagents.first(where: { $0.call == call }) { return (subagent, id) }
        }
        return nil
    }

    /// A subagent's task, as its session is called, once it's been read.
    func subagentTitle(_ id: String) -> String? {
        models[id]?.session.title
    }

    /// Each session's conversation as text, for searching it, until the session changes.
    @ObservationIgnored private var conversationTexts: [String: (updated: Double, text: String)] = [:]

    /// Sessions whose conversation has `query` (archived ones too), the latest first, with the
    /// words around its first mention. Reads the conversations it hasn't yet, a few at a time.
    func searchConversations(_ query: String, limit: Int = 20) async -> [(session: Session, snippet: String)] {
        let candidates = sessions.sorted { $0.time.updated > $1.time.updated }
        // Each with its engine; a machine that isn't connected is skipped until it is.
        let missing = candidates.filter { conversationTexts[$0.id]?.updated != $0.time.updated }
            .compactMap { session in api(for: session).map { (session, $0) } }
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
        guard let session = session(id), let api = api(for: session) else { return nil }
        let messages = try await ConversationExport.messages(of: session, api: api)
        return ConversationExport.markdown(title: session.title ?? "New Session", messages: messages, directory: session.location.directory)
    }

    /// The live model behind a session view. Created on first use, then kept so
    /// switching back is instant.
    func model(for id: String) -> SessionModel? {
        if let model = models[id] { return model }
        guard let session = session(id), let api = api(for: session) else { return copyModel(for: id) }
        let directory = session.location.directory
        // The project's folders where the session is now: a chat moved into a project gets its folders.
        let model = SessionModel(session: session, api: api) { [weak self] in
            guard let self else { return [] }
            return self.extraFolders(self.session(id)?.location.directory ?? directory)
        }
        model.isReachable = reachable(directory)
        models[id] = model
        // This Mac's conversation as last seen, in its first frame, while the engine's is read
        // (which takes a moment, longer while it starts): read in place, the same messages,
        // nothing moves. Reading a copy takes a few milliseconds.
        if !RemoteFolder.isRemote(directory), let copy = SessionCopies.load(id) { model.preview(copy.messages) }
        Task { await readShellJobs(in: directory) }
        return model
    }

    /// A machine's sessions as they are now, kept for when it's away (see `showLastSeen`): a
    /// moment after they change, as several often change together.
    @ObservationIgnored private var listSaves: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var localListSave: Task<Void, Never>?
    /// This Mac's sessions shown as last seen before its engine was there at all (see `copyModel`).
    @ObservationIgnored private var beforeEngine: Set<String> = []

    /// This Mac's sessions as they are now, kept for the next launch (see `sessions`), a moment
    /// after they change.
    private func keepLocalList() {
        localListSave?.cancel()
        localListSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            SessionCopies.saveLocalSessions(sessions.filter { !RemoteFolder.isRemote($0.location.directory) })
        }
    }

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

    /// A session on a machine that's connecting, or on this Mac while its engine starts, from its
    /// conversation as last seen, to read meanwhile. It takes the engine once it's there (see
    /// `refresh`).
    private func copyModel(for id: String) -> SessionModel? {
        // An agent's session waits for the bridge as this Mac's do for the engine.
        let isAgents = session(id).map(OutsideAgents.isAgentSession) ?? false
        if isAgents ? agents?.api == nil : api == nil, let session = session(id), !RemoteFolder.isRemote(session.location.directory), let copy = SessionCopies.load(id) {
            // Nothing answers here; nothing's asked of it before the engine is there.
            let offline = OpenCodeAPI(endpoint: ServerEndpoint(url: URL(string: "http://127.0.0.1:9")!, username: "", password: nil))
            let directory = session.location.directory
            let model = SessionModel(session: session, api: offline) { [weak self] in
                guard let self else { return [] }
                return self.extraFolders(self.session(id)?.location.directory ?? directory)
            }
            model.isReachable = { [weak self] in isAgents ? self?.agents?.api != nil : self?.api != nil }
            model.show(copy.messages)
            models[id] = model
            beforeEngine.insert(id)
            return model
        }
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

    /// Waiting on you: a permission, a question or a sign-in, in a conversation you have open or
    /// not (a bot's work in a session of its own, say).
    func needsAttention(_ id: String) -> Bool {
        if askingInBrowser.contains(id) || asking.values.contains(where: { $0 == id || root(of: $0) == id }) { return true }
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
        // A model of an outside agent (Claude Code, Codex…), or Auto: the session is the agents
        // bridge's, here.
        let isAgents = OutsideAgents.runsInBridge(model?.providerID)
        if isAgents, RemoteFolder.isRemote(directory) {
            throw OutsideAgents.Failure.onlyOnThisMac(model?.providerID == OutsideAgents.autoProvider ? "Auto" : OutsideAgents.name(model?.providerID))
        }
        if isAgents, agents?.api == nil { throw OutsideAgents.Failure.notRunning(agents?.failure) }
        guard let api = isAgents ? agents?.api : api(forFolder: directory) else { throw CancellationError() }
        let directory = addFolder(directory)
        let folder = worktree ? try await makeWorktree(of: directory) : directory
        let extra = settings[directory]?.folders ?? []
        let rules = ProjectFolders.permissions(approval.rules(settings: EngineConfig.current?.permissionRules ?? []), folders: extra)
        let session: Session
        do {
            session = try await api.createSession(directory: folder, agent: agent, model: model, permissions: rules.isEmpty ? nil : rules)
        } catch {
            // A worktree made for it goes too, with its branch (nothing's on it yet).
            if worktree { await discardWorktree(folder) }
            throw error
        }
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

    static let worktreeInstructionKey = "kuvo.worktree"

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
        let branch: String
        do {
            branch = try await Task.detached { try Git.newBranch(named: prefix + (root as NSString).lastPathComponent, in: root) }.value
        } catch {
            // Not kept without its branch: nothing would list it, to remove it.
            try? await api.removeWorktree(project: project.id, directory: root, force: true)
            throw error
        }
        let folder = subpath.isEmpty ? root : (root as NSString).appendingPathComponent(subpath)
        worktrees[folder] = Worktree(project: directory, root: root, branch: branch, base: base)
        saveWorktrees()
        return folder
    }

    /// A worktree made for a session that wasn't: removed, with its branch, and not recorded as
    /// one you removed.
    func discardWorktree(_ folder: String) async {
        guard let tree = worktrees[folder], let api = api(forFolder: tree.project),
              let project = try? await api.location(directory: tree.project).project else { return }
        try? await api.removeWorktree(project: project.id, directory: tree.root, force: true)
        _ = await Task.detached { Git.run(["branch", "-D", tree.branch], in: tree.project) }.value
        worktrees = worktrees.filter { $0.value.root != tree.root }
        saveWorktrees()
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
                try? await api(for: session)?.setInstruction(session: session.id, key: Self.worktreeInstructionKey, text: Self.instructions(for: tree))
            }
            await loadBranch(for: folder)
        }
    }

    /// Whether another session still working in the worktree (not archived) would lose it.
    func worktreeIsShared(_ directory: String, besides id: String) -> Bool {
        guard let root = worktrees[directory]?.root else { return false }
        return sessions.contains { $0.id != id && !Self.isArchived($0) && worktrees[$0.location.directory]?.root == root }
    }

    /// Removes a worktree's folder, and changes that aren't committed with it when
    /// `discardingChanges` (you were told they go); without, one that has some stays. Its branch
    /// stays with its commits, unless it's merged already. Never while an agent works in it.
    func removeWorktree(_ directory: String, discardingChanges: Bool = true) async throws {
        guard let api = api(forFolder: directory), let tree = worktrees[directory] else { return }
        // Looked at again now: an agent may have written more since you were asked.
        // Any session there, opened or not, with its subagents and background commands.
        if sessions.contains(where: { worktrees[$0.location.directory]?.root == tree.root && isWorking($0.id) }) {
            throw GitFailure(message: "An agent is still working in the worktree of \(tree.branch), so it stays. Stop it first, then remove the worktree.")
        }
        if !discardingChanges, await Task.detached(operation: { Git.hasUncommittedChanges(in: tree.root) }).value {
            throw GitFailure(message: "The worktree of \(tree.branch) has changes that aren’t committed, so it stays. Commit them, or remove it in Settings › Worktrees, which throws them away.")
        }
        let project = try await api.location(directory: tree.project).project
        // Forced only when you were told its changes go: otherwise git itself keeps one that has some.
        try await api.removeWorktree(project: project.id, directory: tree.root, force: discardingChanges)
        // Git deletes only a branch that's merged.
        _ = await Task.detached { Git.run(["branch", "-d", tree.branch], in: tree.project) }.value
        for (folder, removed) in worktrees where removed.root == tree.root { removedWorktrees[folder] = removed.project }
        UserDefaults.standard.set(removedWorktrees, forKey: "removedWorktrees")
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
        // The engine's copy carries the attachments; one seen arrive live has them as picked.
        let recent = (try? await api.messages(session: id, limit: 100).data) ?? []
        var stored = message
        for case .user(let user) in recent where user.id == message.id { stored = user }
        // What it replied to comes back over the composer, as you wrote it.
        let (quotes, text) = Quoting.draft(of: ReviewComments.split(withComments).text)
        let files = Attachments.restored(SessionModel.files(of: message, stored: stored), noting: paths)
        Drafts.shared[session.id] = Drafts.Draft(text: text, files: files, quotes: quotes)
        requestedTab = session.id
    }

    /// A session was deleted: its panel goes with it. The app sets it.
    @ObservationIgnored var onDeleted: ((String) -> Void)?

    /// Deleted on its engine; one on a machine that's away waits for it (it would come back).
    func delete(_ id: String) async {
        guard let api = api(forSession: id) else { return }
        onDeleted?(id)
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
            let local = try await api.allSessions().filter { !isHidden($0) }
            let theAgents = sessions.filter(OutsideAgents.isAgentSession)
            sessions = local + theAgents + sessions.filter { RemoteFolder.isRemote($0.location.directory) }
            SessionCopies.saveLocalSessions(local + theAgents)
            // Conversations shown as last seen while the engine started take it now, and are read
            // in place (the same messages, so nothing on screen moves); one deleted meanwhile goes.
            for id in beforeEngine {
                guard let model = models[id], !OutsideAgents.isAgentSession(model.session) else { continue }
                guard let session = local.first(where: { $0.id == id }) else {
                    models[id] = nil
                    continue
                }
                model.reconnect(api)
                model.session = session
                Task { await model.load() }
            }
            beforeEngine = beforeEngine.filter { models[$0].map { OutsideAgents.isAgentSession($0.session) } ?? false }
        } catch { log.error("sessions: \(String(describing: error), privacy: .public)") }
        do {
            let active = try await api.activeSessions()
            running = active.union(running.filter { id in session(id).map { RemoteFolder.isRemote($0.location.directory) || OutsideAgents.isAgentSession($0) } ?? false })
        } catch { log.error("active sessions: \(String(describing: error), privacy: .public)") }
        isLoaded = true
    }

    /// The outside agents' sessions, from the bridge (when it starts, or its feed comes back), in
    /// place of what was known of them. Conversations open meanwhile take it and are read again.
    func refreshAgents() async {
        guard let api = agents?.api else { return }
        do {
            let listed = try await api.allSessions().filter { !isHidden($0) }
            sessions = sessions.filter { !OutsideAgents.isAgentSession($0) } + listed
            for (id, model) in models where OutsideAgents.isAgentSession(model.session) {
                guard let session = listed.first(where: { $0.id == id }) else {
                    models[id] = nil
                    continue
                }
                model.reconnect(api)
                model.session = session
                Task { await model.load() }
            }
            beforeEngine = beforeEngine.filter { id in !listed.contains { $0.id == id } }
            if let active = try? await api.activeSessions() {
                running = running.filter { id in !(session(id).map(OutsideAgents.isAgentSession) ?? false) }.union(active)
            }
            // Questions it asked before starting over went with it (it keeps them in memory): only
            // those it still asks stay.
            for (request, id) in asking where session(id).map(OutsideAgents.isAgentSession) ?? false {
                let permissions = (try? await api.permissions(session: id)) ?? []
                let forms = (try? await api.forms(session: id)) ?? []
                if !permissions.contains(where: { $0.id == request }) && !forms.contains(where: { $0.id == request }) {
                    asking[request] = nil
                    Notifier.shared.clear(request: request)
                }
            }
        } catch {
            log.error("agents' sessions: \(String(describing: error), privacy: .public)")
        }
    }

    /// The agents bridge stopped for good: its sessions aren't at work, nor asking anything.
    func agentsStopped() {
        for (request, id) in asking where session(id).map(OutsideAgents.isAgentSession) ?? false {
            asking[request] = nil
            Notifier.shared.clear(request: request)
        }
        running = running.filter { id in !(session(id).map(OutsideAgents.isAgentSession) ?? false) }
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
            let listed = try await api.allSessions()
            guard isCurrent() else { return true }
            // Its open conversations take this connection first, so nothing sent from them goes
            // to the old one.
            for model in models.values where RemoteFolder.machine(of: model.session.location.directory) == machine { model.reconnect(api) }
            let theirs = listed.filter { !isHidden($0) }
            let reconnected = connectedOnce.contains(machine)
            tellMissedNews(in: theirs, machine: machine)
            sessions = sessions.filter { RemoteFolder.machine(of: $0.location.directory) != machine } + theirs
            for session in theirs { sessionMachines[session.id] = machine }
            remoteSessions = remoteSessions.filter { $0.value.machine != machine }
            for session in theirs { remoteSessions[session.id] = RemoteSession(machine: machine, title: session.title) }
            Self.saveRemoteSessions(remoteSessions)
            SessionCopies.saveSessions(theirs, of: machine)
            connectedMachines.insert(machine)
            if let active = try? await api.activeSessions(), isCurrent() {
                // A subagent's session has no row: its machine is the one its events came from.
                running = running.filter { id in (session(id).map { RemoteFolder.machine(of: $0.location.directory) } ?? sessionMachines[id]) != machine }.union(active)
                await noteAsks(on: machine, in: active, api: api, tell: reconnected)
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

    /// What a machine's sessions at work ask you, once it's back: `asking` as it is there now and,
    /// when it `tell`s (connected again since launch, as for bots' news), each request made while
    /// it was out of reach (a bot's wake-up while your Mac slept) told then, as it would have
    /// been, since no event brings it. One told before isn't told again.
    private func noteAsks(on machine: String, in active: Set<String>, api: OpenCodeAPI, tell: Bool) async {
        var found: [String: String] = [:]
        var complete = true
        for id in active {
            async let permissions = api.permissions(session: id)
            async let forms = api.forms(session: id)
            // Couldn't read them: its own are left as they were.
            guard let permissions = try? await permissions, let forms = try? await forms else {
                complete = false
                continue
            }
            for request in permissions {
                found[request.id] = request.sessionID
                if tell, asking[request.id] == nil { notifyAsk(request.sessionID, body: Self.describe(request), request: request.id, isPermission: true) }
            }
            for form in forms where form.sessionID != FormRequest.anySession {
                found[form.id] = form.sessionID
                guard tell, asking[form.id] == nil else { continue }
                let question = Self.question(in: form)
                notifyAsk(form.sessionID, body: question?.text ?? (form.isQuestion ? "Has a question for you." : "Needs your answer."), request: form.id, question: question)
            }
        }
        // Answered meanwhile (on your phone, say): no longer asking.
        let isTheirs = { (id: String) in (self.session(id).map { RemoteFolder.machine(of: $0.location.directory) } ?? self.sessionMachines[id]) == machine }
        let kept = complete ? asking.filter { !isTheirs($0.value) || sharedForms[$0.key] != nil } : asking
        // Answered elsewhere meanwhile (on the phone): its notification goes too, rather than
        // offering an answer to a request that's gone.
        for request in asking.keys where kept[request] == nil && found[request] == nil { Notifier.shared.clear(request: request) }
        asking = kept.merging(found) { $1 }
    }

    /// A machine disconnected: its sessions stay as last seen until it's back, their
    /// conversations to read. Removed for good, they're forgotten.
    func forget(_ machine: String, forGood: Bool = false) {
        let gone = Set(sessions.filter { RemoteFolder.machine(of: $0.location.directory) == machine }.map(\.id))
        if !forGood, connectedMachines.contains(machine) { saveList(of: machine) }
        running.subtract(gone)
        // And its subagents', which have no row.
        running = running.filter { sessionMachines[$0] != machine || session($0) != nil }
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
            // What its sessions asked goes with them, from the Dock's count and the notifications.
            for (request, session) in asking where gone.contains(session) || sessionMachines[session] == machine {
                asking[request] = nil
                Notifier.shared.clear(request: request)
            }
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
        let before = asking
        asking = [:]
        for directory in Set(models.values.map(\.session.location.directory)) { await readShellJobs(in: directory) }
        for model in models.values {
            // A machine's are read when it's connected (see `refresh(_ engine:)`).
            if RemoteFolder.machine(of: model.session.location.directory).map(connectedMachines.contains) ?? true { await model.load() }
            for request in model.permissions { asking[request.id] = request.sessionID }
            for form in model.forms { note(form, in: model) }
        }
        for (request, session) in before where asking[request] == nil {
            // The coding agents' are the bridge's, which an engine's reconnect doesn't touch.
            if self.session(session).map(OutsideAgents.isAgentSession) ?? false {
                asking[request] = session
                continue
            }
            // On a machine not connected now: read again when it is.
            guard sessionMachines[session].map(connectedMachines.contains) ?? true else { continue }
            // A closed session's: still asked (or not known), it stays; its notification goes otherwise.
            if sharedForms[request] == nil, let api = api(forSession: session) {
                guard let permissions = try? await api.permissions(session: session), let forms = try? await api.forms(session: session),
                      !permissions.contains(where: { $0.id == request }), !forms.contains(where: { $0.id == request }) else {
                    asking[request] = session
                    continue
                }
            }
            Notifier.shared.clear(request: request)
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
            let plain = ReplyPreview.line(text)
            guard !plain.isEmpty else { continue }
            return plain
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
        noteShellJob(event)
        if let id = event.sessionID ?? Self.formSessionID(event), let model = models[id] {
            model.apply(event)
        }
        // A subagent's asks: shown in the conversation it works for.
        if Self.asksEvents.contains(event.type), let id = event.sessionID ?? Self.formSessionID(event), case let parent = root(of: id), parent != id, let model = models[parent] {
            model.applyHelper(event, from: id)
        }
        noteQuestions(event)
        guard let id = event.sessionID else { return }
        // A run's first words, thought or tool: how long the model took to start.
        if runStarted[id] != nil, firstOutput[id] == nil, ["session.text.started", "session.reasoning.started", "session.tool.input.started"].contains(event.type) {
            firstOutput[id] = RunInstant(onMachine: machine != nil)
        }

        switch event.type {
        case "session.created", "session.renamed", "session.moved", "session.metadata.updated", "session.revert.staged", "session.revert.cleared", "session.revert.committed":
            Task { await reload(id) }
        case "session.deleted":
            sessions.removeAll { $0.id == id }
            if let machine { keepList(of: machine) }
            if remoteSessions.removeValue(forKey: id) != nil { Self.saveRemoteSessions(remoteSessions) }
            SessionCopies.remove(id)
            models[id] = nil
            asking = asking.filter { $0.value != id }
        case "session.execution.started":
            running.insert(id)
            // A session with no row may be a subagent's: whose it is, so the one that started it
            // shows working while it does (in the background, after its own turn has ended).
            if session(id) == nil, parents[id] == nil { Task { await reload(id) } }
            runStarted[id] = RunInstant(onMachine: machine != nil)
            firstOutput[id] = nil
            if let session = session(id) { usageAtStart[id] = (Self.tokenCount(session.tokens), session.cost) }
            touch(id)
        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted":
            running.remove(id)
            endedRuns[id, default: 0] += 1
            noteTurn(id, event)
            onRunEnded?(id)
            // A subagent's session has no row: the engine names those, and it's not to be renamed.
            if let session = session(id), session.title?.isEmpty != false { nameIfUntitled(id) }
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
                        replies: true,
                        push: .init(failed ? .failed : isBot ? .report : .finished, machine: sessionMachines[id])
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

    /// When a run began and first had something to show: never less than nothing when the clock
    /// is set back.
    @ObservationIgnored private var runStarted: [String: RunInstant] = [:]
    @ObservationIgnored private var firstOutput: [String: RunInstant] = [:]

    /// A moment in a run. One here counts while the Mac is awake, as it stops while it sleeps;
    /// one on a machine counts the time the Mac slept too, as it carries on there.
    private struct RunInstant {
        let onMachine: Bool
        let awake = SuspendingClock.now
        let always = ContinuousClock.now

        func seconds(since start: RunInstant) -> Int {
            Int((start.onMachine ? always - start.always : awake - start.awake).components.seconds)
        }
    }
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
            guard let session = session(id), session.parentID == nil, session.title?.isEmpty != false, let api = api(forSession: id),
                  let page = try? await api.firstMessages(session: id, limit: 10) else { return }
            // What you wrote first, as it shows in the conversation: a command as you typed it,
            // without the note on attached files, and another agent's message without its header.
            let first = page.data.lazy.compactMap { message -> String? in
                guard case .user(let user) = message else { return nil }
                let text = Attachments.split(CommandMessages.shared.text(of: user)).text
                let words = AgentMail.parse(text)?.text ?? text
                return words.isEmpty ? nil : words
            }.first
            guard let first, let title = Self.title(from: first) else { return }
            try? await api.renameSession(id, title: title)
            await reload(id)
        }
    }
    @ObservationIgnored private var namingUntitled: Set<String> = []

    /// A title from a message: its words without review comments, the note of attached files or
    /// line breaks, up to the end of its first sentence or about 48 characters, at a word. A dot in
    /// a word (README.md, a web address) doesn't end a sentence.
    nonisolated static func title(from message: String) -> String? {
        let split = ReviewComments.split(Attachments.split(message).text)
        let words = (split.text.isEmpty ? split.comments.first?.text ?? "" : split.text)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        var title = words
        let end = title.indices.first { index in
            ".?!".contains(title[index]) && (title.index(after: index) == title.endIndex || title[title.index(after: index)] == " ")
        }
        if let end, title.distance(from: title.startIndex, to: end) >= 12 {
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
            props["seconds"] = RunInstant(onMachine: started.onMachine).seconds(since: started)
            if let first = firstOutput.removeValue(forKey: id) { props["first_token_seconds"] = first.seconds(since: started) }
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

    private static let asksEvents: Set<String> = ["permission.asked", "permission.replied", "form.created", "form.replied", "form.cancelled"]

    /// Keeps `asking` current, and tells you about a new request while you're elsewhere.
    private func noteQuestions(_ event: ServerEvent) {
        switch event.type {
        case "permission.asked":
            guard let request = try? event.payload(as: PermissionRequest.self) else { return }
            asking[request.id] = request.sessionID
            notifyAsk(request.sessionID, body: Self.describe(request), request: request.id, isPermission: true)
        case "permission.replied":
            if let reply = try? event.payload(as: EventPayload.PermissionReplied.self) {
                asking[reply.requestID] = nil
                Notifier.shared.clear(request: reply.requestID)
            }
        case "form.created":
            guard let form = try? event.payload(as: EventPayload.FormCreated.self).form else { return }
            asking[form.id] = form.sessionID
            let question = Self.question(in: form)
            notifyAsk(form.sessionID, body: question?.text ?? (form.isQuestion ? "Has a question for you." : "Needs your answer."), request: form.id, question: question)
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

    /// `request` is the permission or the form, for a notification whose buttons answer it.
    private func notifyAsk(_ id: String, body: String, request: String, isPermission: Bool = false, question: Notifier.Question? = nil) {
        // A seat's requests are answered by its group chat.
        guard !seats.contains(id) else { return }
        Task {
            // A subagent's session has no row or tab of its own; its request shows in the
            // session that started it.
            var session = session(id)
            let api = api(forSession: id)
            let unlisted = session == nil ? try? await api?.session(id) : nil
            var isEngineRun = unlisted.map(Self.isEngineRun) ?? false
            var parent = unlisted?.parentID
            for _ in 0..<5 where session == nil && !isEngineRun {
                guard let next = parent else { break }
                session = self.session(next)
                guard session == nil, let fetched = try? await api?.session(next) else { break }
                isEngineRun = Self.isEngineRun(fetched)
                parent = fetched.parentID
            }
            // The engine's run for a session with the coding agents, or a subagent of it: that
            // session asks you itself, and counts once on the Dock.
            if isEngineRun {
                asking[request] = nil
                return
            }
            Notifier.shared.notify(session: session?.id ?? id, title: session.flatMap { botName?($0.id) } ?? session?.title ?? AppInfo.name,
                                   subtitle: session.flatMap { botName?($0.id) == nil ? projectName($0.location.directory) : nil }, body: body,
                                   permission: isPermission ? (session: id, request: request) : nil, question: question,
                                   push: .init(isPermission ? .permission : .question, request: (session: id, id: request), machine: sessionMachines[id]))
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
        // Every one it covers (a command line's commands each): Allow takes them all.
        let shown = request.resources.filter { $0 != "*" }
        guard !shown.isEmpty else { return "Wants to \(what)." }
        let more = shown.count > 4 ? " · and \(shown.count - 4) more" : ""
        return "Wants to \(what): " + shown.prefix(4).joined(separator: " · ") + more
    }

    /// A permission request answered from its notification.
    func answer(_ request: String, in session: String, with answer: Notifier.PermissionAnswer) {
        Analytics.shared.track("permission_answered", ["decision": answer.rawValue, "from": "notification"])
        guard let decision = PermissionRequest.Decision(rawValue: answer.rawValue) else { return }
        Task {
            do {
                guard let api = api(forSession: session) else { throw CancellationError() }
                try await api.reply(session: session, permission: request, decision: decision)
            } catch {
                // The agent still waits: say so, as for a question, rather than lose the answer.
                Notifier.shared.notify(session: session, title: botName?(session) ?? self.session(session)?.title ?? AppInfo.name,
                                       body: "Your answer didn’t go. Open the conversation to answer there.")
            }
        }
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
        if let parent = session.parentID {
            parents[session.id] = parent
            return
        }
        upsert(session)
    }

    /// Each subagent's session, by the session that started it.
    private var parents: [String: String] = [:]

    /// Subagents a session handed work to that are at it now (through subagents of subagents),
    /// such as those it sent off in the background, which go on after its own turn ends.
    func helpersAtWork(in id: String) -> Int {
        running.count { $0 != id && root(of: $0) == id }
    }

    /// The session works, itself, through subagents still at it, or with a command it left
    /// running in the background: what its row, tab and bot show.
    func isWorking(_ id: String) -> Bool {
        running.contains(id) || helpersAtWork(in: id) > 0 || shellJobs[id] != nil
    }

    // MARK: Commands running for agents

    /// The shell commands the engine runs for each session's agent, while they run: one left
    /// running in the background after its turn ended keeps the session working, and shows over
    /// its composer.
    private(set) var shellJobs: [String: [ShellJob]] = [:]
    /// The commands that have run a moment, which the bar over the composer may show: the step
    /// that waits on a command claims it only once it has started, so for its first moment each
    /// one looks like it runs in the background, and most end within it. Shown at once, every
    /// command flashed the bar.
    private(set) var lastingShellJobs: Set<String> = []
    private static let lastingAfter: Milliseconds = 2000

    private func noteShellJob(_ event: ServerEvent) {
        switch event.type {
        case "shell.created":
            struct Created: Decodable { var info: ShellJob }
            guard let job = try? event.payload(as: Created.self).info, job.status == "running", let id = job.sessionID,
                  shellJobs[id]?.contains(where: { $0.id == job.id }) != true else { return }
            shellJobs[id, default: []].append(job)
            // From now: the engine's clock (a machine's) needn't be this Mac's.
            noteLasting(job.id, after: Self.lastingAfter)
        case "shell.exited", "shell.deleted":
            struct Gone: Decodable { var id: String }
            guard let gone = try? event.payload(as: Gone.self).id else { return }
            for (id, jobs) in shellJobs where jobs.contains(where: { $0.id == gone }) {
                let left = jobs.filter { $0.id != gone }
                shellJobs[id] = left.isEmpty ? nil : left
            }
            lastingShellJobs.remove(gone)
        default:
            break
        }
    }

    /// `id` counts as lasting `after` from now, if it's still running then.
    private func noteLasting(_ id: String, after: Milliseconds) {
        guard !lastingShellJobs.contains(id) else { return }
        guard after > 0 else {
            lastingShellJobs.insert(id)
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(after)))
            guard let self, shellJobs.values.contains(where: { $0.contains { $0.id == id } }) else { return }
            lastingShellJobs.insert(id)
        }
    }

    /// What runs in `directory` now, as its engine lists it: commands started while this Mac
    /// wasn't listening (before launch, or while a machine was away) show too.
    func readShellJobs(in directory: String) async {
        guard let api = api(forFolder: directory), let jobs = try? await api.shells(directory: directory) else { return }
        for session in sessions where session.location.directory == directory {
            let own = jobs.filter { $0.sessionID == session.id && $0.status == "running" }
            if (shellJobs[session.id] ?? []) != own { shellJobs[session.id] = own.isEmpty ? nil : own }
            // Ones started a while ago show at once.
            let now = Date.now.timeIntervalSince1970 * 1000
            for job in own {
                let age = job.time?.started.map { now - $0 } ?? 0
                noteLasting(job.id, after: min(Self.lastingAfter, max(0, Self.lastingAfter - age)))
            }
        }
        // And none that ended while this Mac wasn't listening.
        let running = Set(shellJobs.values.joined().map(\.id))
        if !lastingShellJobs.isSubset(of: running) { lastingShellJobs.formIntersection(running) }
    }

    /// Stops a command an agent left running: its process group is sent SIGTERM, on this Mac or
    /// on its machine, so the engine sees it end and tells the agent, with what it printed. The
    /// engine's own stop also deletes the output, and the agent hears the command was never
    /// found, so it's only for when that can't be done.
    /// How it went: "signal" or "removed" (the engine's stop), for a phone that asked.
    @discardableResult
    func stopShellJob(_ job: ShellJob, in session: String) async -> String {
        let directory = self.session(session)?.location.directory ?? ""
        let engine = api(forSession: session)
        // Announced as it started, before it had a process: the engine knows it now.
        var pid = job.pid
        if pid == nil { pid = (try? await engine?.shell(job.id, directory: directory))?.pid }
        if let pid, pid > 1 {
            let machine = RemoteFolder.machine(of: directory)
            let sent = await Task.detached { () -> Bool in
                guard let machine else { return kill(-pid_t(pid), SIGTERM) == 0 }
                return RemoteShell.run("kill -TERM -\(pid) 2>/dev/null && echo sent", on: machine).map { String(decoding: $0, as: UTF8.self).contains("sent") } ?? false
            }.value
            if sent { return "signal" }
        }
        try? await engine?.removeShell(job.id, directory: directory)
        return "removed"
    }

    /// The session a subagent's shows in (through subagents of subagents): the root one that
    /// started it; any other, itself.
    func root(of id: String) -> String {
        var id = id
        for _ in 0..<5 {
            guard let parent = parents[id] else { break }
            id = parent
        }
        return id
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
                    notifyAsk(id, body: form.message ?? "Needs your answer.", request: form.id, question: nil)
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
        if isNew { notifyAsk(model.id, body: form.message ?? "Needs your answer.", request: form.id, question: nil) }
    }

    /// `form.created` carries its session inside the form.
    private static func formSessionID(_ event: ServerEvent) -> String? {
        guard event.type == "form.created" else { return nil }
        return try? event.payload(as: EventPayload.FormCreated.self).form.sessionID
    }
}
