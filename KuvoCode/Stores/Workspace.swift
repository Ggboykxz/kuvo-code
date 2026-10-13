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
    private(set) var isLoaded = false

    private var models: [String: SessionModel] = [:]
    /// Current git branch per project folder, when it has one.
    private(set) var branches: [String: String] = [:]

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
    }

    /// Projects with their sessions, most recently active first.
    var projects: [Project] {
        let grouped = Dictionary(grouping: sessions.filter { $0.time.archived == nil }, by: \.location.directory)
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

    func session(_ id: String?) -> Session? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    /// The live model behind a session view. Created on first use, then kept so
    /// switching back is instant.
    func model(for id: String) -> SessionModel? {
        if let model = models[id] { return model }
        guard let api, let session = session(id) else { return nil }
        let directory = session.location.directory
        let model = SessionModel(session: session, api: api) { [weak self] in self?.settings[directory]?.folders ?? [] }
        models[id] = model
        return model
    }

    func loadBranch(for directory: String) async {
        guard let api, let info = try? await api.vcs(directory: directory) else { return }
        branches[directory] = info.branch?.current
    }

    func needsAttention(_ id: String) -> Bool {
        guard let model = models[id] else { return false }
        return !model.transcript.permissions.isEmpty || !model.transcript.forms.isEmpty
    }

    // MARK: Changes

    func addFolder(_ directory: String) {
        guard !folders.contains(directory) else { return }
        folders.insert(directory, at: 0)
        UserDefaults.standard.set(folders, forKey: "projectFolders")
    }

    func removeFolder(_ directory: String) {
        folders.removeAll { $0 == directory }
        UserDefaults.standard.set(folders, forKey: "projectFolders")
        settings[directory] = nil
        saveSettings()
    }

    /// The project's name: its own, or its primary folder's.
    func projectName(_ directory: String) -> String {
        settings[directory]?.name ?? (directory as NSString).lastPathComponent
    }

    /// Adds a project, or updates one, and gives its open sessions the new folders.
    func saveProject(_ directory: String, settings project: ProjectSettings) {
        addFolder(directory)
        var project = project
        project.name = project.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if project.name?.isEmpty == true || project.name == (directory as NSString).lastPathComponent { project.name = nil }
        project.folders = project.folders.filter { $0 != directory }
        settings[directory] = project == ProjectSettings() ? nil : project
        saveSettings()
        // Sessions not open yet catch up when they open.
        for model in models.values where model.session.location.directory == directory {
            Task { await model.syncFolders() }
        }
    }

    func createSession(in directory: String, model: ModelRef?, agent: String?, approval: ToolApproval = .approveAll) async throws -> Session {
        guard let api else { throw CancellationError() }
        addFolder(directory)
        let extra = settings[directory]?.folders ?? []
        let rules = ProjectFolders.permissions(approval.rules, folders: extra)
        let session = try await api.createSession(directory: directory, agent: agent, model: model, permissions: rules.isEmpty ? nil : rules)
        if !extra.isEmpty {
            try? await api.setInstruction(session: session.id, key: ProjectFolders.instructionKey, text: ProjectFolders.instructions(primary: directory, folders: extra))
        }
        upsert(session)
        return session
    }

    private static func loadSettings() -> [String: ProjectSettings] {
        guard let data = UserDefaults.standard.data(forKey: "projectSettings") else { return [:] }
        return (try? JSONDecoder().decode([String: ProjectSettings].self, from: data)) ?? [:]
    }

    private func saveSettings() {
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: "projectSettings")
    }

    func delete(_ id: String) async {
        sessions.removeAll { $0.id == id }
        models[id] = nil
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

    /// After a reconnect: re-read the list and every open session.
    func resync() async {
        await refresh()
        for model in models.values { await model.load() }
    }

    func handle(_ event: ServerEvent) {
        if event.type == "vcs.branch.updated", let directory = event.location?.directory {
            struct Branch: Decodable { var branch: String? }
            branches[directory] = (try? event.payload(as: Branch.self))?.branch
        }
        if let id = event.sessionID ?? Self.formSessionID(event), let model = models[id] {
            model.apply(event)
        }
        guard let id = event.sessionID else { return }

        switch event.type {
        case "session.created", "session.renamed", "session.moved":
            Task { await reload(id) }
        case "session.deleted":
            sessions.removeAll { $0.id == id }
            models[id] = nil
        case "session.execution.started":
            running.insert(id)
            touch(id)
        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted":
            running.remove(id)
            // Picks up the new idle time (unread state) and outcome.
            Task { await reload(id) }
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

    func markViewed(_ id: String) {
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
