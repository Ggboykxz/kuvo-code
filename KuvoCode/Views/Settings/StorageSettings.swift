import AppKit
import OpenCodeKit
import SwiftUI

/// Storage: what Kuvo Code keeps on this Mac, by kind, as a bar, and the room you can get back.
struct StorageSettings: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppModel.self) private var app
    @State private var report: StorageReport?
    @State private var cleaningUp = false
    @State private var confirmingLogs = false
    @State private var confirmingDownloads = false

    var body: some View {
        ScrollingSettingsForm {
            Section {
                if let report {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(Self.format(report.total)) used by Kuvo Code")
                                .font(.headline)
                            Spacer()
                            Button("Refresh") { Task { await load() } }
                        }
                        StorageBar(kinds: report.kinds, total: report.total)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 10) {
                            ForEach(report.kinds) { kind in
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Circle().fill(kind.color).frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(kind.title)
                                        Text(Self.format(kind.size))
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                }
                                .help(kind.detail)
                            }
                        }
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([AppInfo.supportDirectory])
                        } label: {
                            Text((AppInfo.supportDirectory.path as NSString).abbreviatingWithTildeInPath)
                                .font(.callout.monospaced())
                        }
                        .buttonStyle(TextButtonStyle(outset: true))
                        .help("Show in Finder")
                    }
                    .padding(.vertical, 6)
                } else {
                    HStack(spacing: 8) {
                        Spinner(size: 16)
                        Text("Adding it up…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            } header: {
                Text("This Mac")
            }

            Section {
                LabeledContent {
                    Button("Review…") { cleaningUp = true }
                } label: {
                    Text("Clean up old sessions")
                    Text("Delete sessions you haven’t used in a while, with their messages and undo snapshots.")
                }
                LabeledContent {
                    Button("Manage") { app.settingsTabs.show(.archived) }
                } label: {
                    Text("Archived sessions")
                    Text(archivedCount == 0 ? "None." : "\(archivedCount.counting("session")), out of the sidebar but still taking room.")
                }
                LabeledContent {
                    Button("Manage") { app.settingsTabs.show(.worktrees) }
                } label: {
                    Text("Worktrees")
                    Text("Sessions’ own copies of a project, on a branch.")
                }
                LabeledContent {
                    Button("Manage") { app.settingsTabs.show(.browser) }
                } label: {
                    Text("Website data")
                    Text("What sites keep in the panel’s browser.")
                }
            } header: {
                Text("Sessions and Projects")
            }

            Section {
                LabeledContent {
                    Button("Delete…") { confirmingLogs = true }
                        .disabled((report?.size(of: .logs) ?? 0) == 0)
                } label: {
                    Text("Logs")
                    Text("What the engine and the app wrote down while running, for troubleshooting.")
                }
                LabeledContent {
                    Button("Delete…") { confirmingDownloads = true }
                        .disabled((report?.linuxEngine ?? 0) == 0)
                } label: {
                    Text("Downloads for machines")
                    Text("The Linux engine and browser, kept to set up another machine without downloading them again.")
                }
            } header: {
                Text("Files You Can Delete")
            }
        }
        .task { await load() }
        .settingsDetail(isPresented: $cleaningUp, title: "Clean Up Old Sessions", onDismiss: { Task { await load() } }) {
            OldSessions { cleaningUp = false }
        }
        .confirmationDialog("Delete the logs?", isPresented: $confirmingLogs) {
            Button("Delete", role: .destructive) {
                Task {
                    await Task.detached { StorageReport.deleteLogs() }.value
                    await load()
                }
            }
        } message: {
            Text("New ones start right away. Your sessions aren’t affected.")
        }
        .confirmationDialog("Delete the downloads for machines?", isPresented: $confirmingDownloads) {
            Button("Delete", role: .destructive) {
                try? FileManager.default.removeItem(at: StorageReport.linuxEngineFolder)
                try? FileManager.default.removeItem(at: MachineBrowser.cache)
                Task { await load() }
            }
        } message: {
            Text("Machines you’ve added keep their engine and browser. A new one downloads them again.")
        }
    }

    private var archivedCount: Int {
        workspace.sessions.filter { Workspace.isArchived($0) && !RemoteFolder.isRemote($0.location.directory) }.count
    }

    private func load() async {
        let worktrees = Array(Set(workspace.worktrees.values.map(\.root))).filter { !RemoteFolder.isRemote($0) }
        report = await Task.detached { StorageReport.measure(worktrees: worktrees) }.value
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The parts of the total, side by side in one bar.
private struct StorageBar: View {
    let kinds: [StorageReport.Kind]
    let total: Int64

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(kinds.filter { $0.size > 0 }) { kind in
                    kind.color
                        .frame(width: max(3, proxy.size.width * CGFloat(kind.size) / CGFloat(max(total, 1)) - 2))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 14)
        .background(.quaternary)
        .clipShape(.capsule)
    }
}

/// What Kuvo Code keeps on this Mac, measured.
nonisolated struct StorageReport: Sendable {
    enum KindID: String, Sendable { case sessions, snapshots, logs, engine, worktrees, browser, attachments, other }

    struct Kind: Identifiable, Sendable {
        let id: KindID
        let size: Int64

        var title: String {
            switch id {
            case .sessions: "Sessions"
            case .snapshots: "Undo snapshots"
            case .logs: "Logs"
            case .engine: "Engine"
            case .worktrees: "Worktrees"
            case .browser: "Browser"
            case .attachments: "Attachments"
            case .other: "Other"
            }
        }

        var detail: String {
            switch id {
            case .sessions: "Your sessions’ messages, and your accounts and settings."
            case .snapshots: "Copies of files the agent changed, so Undo From Here can put them back."
            case .logs: "What the engine and the app wrote down while running."
            case .engine: "The opencode engine, and its Linux build for machines."
            case .worktrees: "Sessions’ own copies of a project."
            case .browser: "The panel browser’s website data and history."
            case .attachments: "Files you pasted into messages."
            case .other: "Caches, command output and the usage menu’s files."
            }
        }

        var color: Color {
            switch id {
            case .sessions: .blue
            case .snapshots: .purple
            case .logs: .orange
            case .engine: .teal
            case .worktrees: .green
            case .browser: .pink
            case .attachments: .yellow
            case .other: .gray
            }
        }
    }

    let kinds: [Kind]
    let linuxEngine: Int64

    var total: Int64 { kinds.reduce(0) { $0 + $1.size } }

    func size(of id: KindID) -> Int64 { kinds.first { $0.id == id }?.size ?? 0 }

    static var support: URL { AppInfo.supportDirectory }
    static var engineData: URL { support.appending(path: "opencode/data/opencode") }
    static var linuxEngineFolder: URL { support.appending(path: "engine-linux") }
    static var appLogs: URL { URL.libraryDirectory.appending(path: "Logs/\(AppInfo.name)") }

    static func measure(worktrees: [String]) -> StorageReport {
        let home = URL.libraryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "run.kuvo.code"
        let sessions = ["opencode.db", "opencode.db-wal", "opencode.db-shm"].reduce(Int64(0)) { $0 + size(of: engineData.appending(path: $1)) }
            + size(of: support.appending(path: "opencode/config"))
        let snapshots = size(of: engineData.appending(path: "snapshot"))
        let logs = size(of: engineData.appending(path: "log")) + size(of: appLogs)
        let linux = size(of: linuxEngineFolder) + size(of: support.appending(path: "browser-linux"))
        let engine = size(of: support.appending(path: "engine")) + linux
        let trees = worktrees.reduce(Int64(0)) { $0 + size(of: URL(filePath: $1)) }
        let browser = size(of: home.appending(path: "WebKit/\(bundleID)")) + size(of: home.appending(path: "HTTPStorages/\(bundleID)"))
            + size(of: support.appending(path: "Browser"))
        let attachments = size(of: support.appending(path: "Attachments"))
        let other = size(of: engineData.appending(path: "shell")) + size(of: engineData.appending(path: "repos"))
            + size(of: support.appending(path: "opencode/cache")) + size(of: support.appending(path: "opencode/state"))
            + size(of: support.appending(path: "Usage")) + size(of: home.appending(path: "Caches/\(bundleID)"))
        return StorageReport(kinds: [
            Kind(id: .sessions, size: sessions),
            Kind(id: .snapshots, size: snapshots),
            Kind(id: .worktrees, size: trees),
            Kind(id: .engine, size: engine),
            Kind(id: .browser, size: browser),
            Kind(id: .attachments, size: attachments),
            Kind(id: .logs, size: logs),
            Kind(id: .other, size: other),
        ], linuxEngine: linux)
    }

    /// The space a file or folder takes on disk.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isRegularFile == true { return Int64(values.totalFileAllocatedSize ?? 0) }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// The engine's logs but the one it's writing, and the app's.
    static func deleteLogs() {
        let fm = FileManager.default
        let engineLogs = (try? fm.contentsOfDirectory(at: engineData.appending(path: "log"), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = engineLogs.max { a, b in
            ((try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                < ((try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }
        for log in engineLogs where log != newest { try? fm.removeItem(at: log) }
        // The one being written is emptied rather than removed, so the engine keeps writing to it.
        if let newest, let handle = try? FileHandle(forWritingTo: newest) {
            try? handle.truncate(atOffset: 0)
            try? handle.close()
        }
        // The usage item's own log is open too: emptied, the rest removed.
        for log in (try? fm.contentsOfDirectory(at: appLogs, includingPropertiesForKeys: nil)) ?? [] {
            if log.lastPathComponent == "Usage.log", let handle = try? FileHandle(forWritingTo: log) {
                try? handle.truncate(atOffset: 0)
                try? handle.close()
            } else {
                try? fm.removeItem(at: log)
            }
        }
    }
}

/// Picking sessions to delete by how long they've gone unused, with what that would take: in the
/// page's place.
private struct OldSessions: View {
    let done: () -> Void
    @Environment(Workspace.self) private var workspace
    @State private var days = 90
    @State private var keepsPinned = true
    @State private var isDeleting = false

    /// This Mac's sessions, not a machine's, unused for the chosen time. Not a bot's conversation
    /// (the bot lives on in it, wake-ups and all, however long it's been quiet), nor one with a
    /// message you started writing.
    private var old: [Session] {
        let cutoff = (Date.now.timeIntervalSince1970 - Double(days) * 86_400) * 1000
        let bots = workspace.botSessions
        return workspace.sessions
            .filter { $0.time.updated < cutoff && !RemoteFolder.isRemote($0.location.directory) && !(keepsPinned && Workspace.isPinned($0)) && !workspace.running.contains($0.id) }
            .filter { !bots.contains($0.id) && !Workspace.isBotFolder($0.location.directory) && Drafts.shared[$0.id].isEmpty }
            .sorted { $0.time.updated < $1.time.updated }
    }

    var body: some View {
        SettingsDetailPage {
            Section {
                Picker("Unused for more than", selection: $days) {
                    ForEach([30, 90, 180, 365], id: \.self) { Text($0 == 365 ? "a year" : "\($0) days").tag($0) }
                }
                Toggle("Keep pinned sessions", isOn: $keepsPinned)
            }
            Section {
                if old.isEmpty {
                    Text("None unused for that long.").foregroundStyle(.secondary)
                }
                ForEach(old.prefix(200)) { session in
                    LabeledContent {
                        Text(Date(timeIntervalSince1970: session.time.updated / 1000), format: .relative(presentation: .named))
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(session.title ?? "New Session")
                        Text(workspace.projectName(session.location.directory))
                    }
                }
            } header: {
                Text(old.isEmpty ? "Sessions" : old.count.counting("Session"))
            } footer: {
                Text("Deleting can’t be undone.")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            EditorFooter(primary: old.isEmpty ? "Delete Sessions" : "Delete " + old.count.counting("Session"), canDoPrimary: !old.isEmpty, onPrimary: delete, isDestructive: true,
                         onCancel: done, working: isDeleting ? "Deleting…" : nil)
        }
    }

    private func delete() {
        isDeleting = true
        let ids = old.map(\.id)
        Task {
            for id in ids { await workspace.delete(id) }
            isDeleting = false
            done()
        }
    }
}
