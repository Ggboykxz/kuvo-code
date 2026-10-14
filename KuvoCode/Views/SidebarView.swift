import OpenCodeKit
import SwiftUI
import UniformTypeIdentifiers

/// New Session on top, then projects (each a folder that opens to its sessions), then
/// the most recent sessions across projects, and the connected accounts at the bottom.
/// Rows are flat: a soft fill under the pointer, a stronger one for the open session.
struct SidebarView: View {
    @Environment(Workspace.self) private var workspace

    @Binding var selection: String?
    let newSession: (String?) -> Void
    let newProject: () -> Void
    let editProject: (Workspace.Project) -> Void
    let showProviders: () -> Void

    /// Folders the user closed, by path (newline-separated).
    @AppStorage("collapsedProjects") private var collapsedStorage = ""
    /// Projects showing all their sessions instead of the latest few.
    @State private var showsAll: Set<String> = []
    /// Where the open session was picked from. A session shows in its project and in
    /// Recents; only the row you clicked is highlighted (both open the same tab).
    @State private var pickedIn: (place: Place, id: String)?
    @State private var renaming: Session?
    /// The session waiting for the user to confirm its deletion.
    @State private var deleting: Session?
    /// A session in a worktree being archived, while the user decides about its worktree.
    @State private var archiving: Session?
    /// The worktree of the session being archived or deleted has changes that aren't committed.
    @State private var worktreeIsDirty = false

    private enum Place { case pinned, project, recents }
    @State private var newTitle = ""
    /// Sessions whose title or project has this, instead of the usual lists.
    @State private var search = ""

    /// A project lists this many sessions until you ask for the rest.
    private static let sessionsPerProject = 5
    private static let recentCount = 8

    /// The selection tag of a project's not-yet-sent new session.
    static func draftTag(_ directory: String) -> String { "draft:" + directory }

    static func draftDirectory(from tag: String) -> String? {
        tag.hasPrefix("draft:") ? String(tag.dropFirst("draft:".count)) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    SidebarRow(isSelected: false, action: { newSession(nil) }) {
                        Image(systemName: "square.and.pencil")
                    } title: {
                        Text("New Session")
                    }
                    .help("New Session (⌘N)")

                    SearchRow(text: $search)

                    if !search.isEmpty {
                        SectionHeader(title: "Results") { EmptyView() }
                        if results.isEmpty {
                            Text("No sessions match.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        ForEach(results) { session in
                            sessionRow(session, in: .recents)
                        }
                    } else {
                    if !pinned.isEmpty {
                        SectionHeader(title: "Pinned") { EmptyView() }
                        ForEach(pinned) { session in
                            sessionRow(session, in: .pinned)
                        }
                    }
                    SectionHeader(title: "Projects") {
                        Button(action: newProject) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("New Project… (⇧⌘N)")
                    }
                    if workspace.isLoaded && workspace.projects.isEmpty {
                        Text("Open a folder for the agent to work in.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    ForEach(workspace.projects) { project in
                        projectSection(project)
                    }

                    if !recents.isEmpty {
                        SectionHeader(title: "Recents") { EmptyView() }
                        ForEach(recents) { session in
                            sessionRow(session, in: .recents)
                        }
                    }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.never)

            if !Analytics.shared.noticeShown {
                AnalyticsNotice()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            Divider()
                .padding(.horizontal, 10)
            AccountsRow(action: showProviders)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .alert("Rename Session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let session = renaming { Task { await workspace.rename(session.id, to: newTitle) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            deleting.flatMap(\.title).map { "Delete “\($0)”?" } ?? "Delete This Session?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            if let session = deleting, hasOwnWorktree(session) {
                Button("Delete and Remove Worktree", role: .destructive) { delete(session, removingWorktree: true) }
                Button("Delete Session Only") { delete(session, removingWorktree: false) }
            } else {
                Button("Delete", role: .destructive) { if let session = deleting { delete(session, removingWorktree: false) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let session = deleting, hasOwnWorktree(session) {
                Text("The session and its transcript will be deleted. This can't be undone. " + worktreeNote(session))
            } else {
                Text("The session and its transcript will be deleted. This can't be undone.")
            }
        }
        .alert("Remove Its Worktree Too?", isPresented: Binding(get: { archiving != nil }, set: { if !$0 { archiving = nil } })) {
            if let session = archiving {
                Button("Archive and Remove Worktree", role: worktreeIsDirty ? .destructive : nil) { archive(session, removingWorktree: true) }
                Button("Archive Only") { archive(session, removingWorktree: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let session = archiving { Text(worktreeNote(session)) }
        }
    }

    // MARK: Worktrees

    /// In a worktree no other session is working in.
    private func hasOwnWorktree(_ session: Session) -> Bool {
        workspace.worktrees[session.location.directory] != nil && !workspace.worktreeIsShared(session.location.directory, besides: session.id)
    }

    private func worktreeNote(_ session: Session) -> String {
        let branch = workspace.worktrees[session.location.directory]?.branch ?? "its branch"
        return "Its worktree is a copy of the project on \(branch). Removing it keeps the branch and its commits"
            + (worktreeIsDirty ? ", but throws away the changes that aren't committed." : ".")
    }

    /// Asks about the worktree first when the session has one of its own.
    private func confirm(_ session: Session, then ask: @escaping (Session) -> Void) {
        guard hasOwnWorktree(session) else { return ask(session) }
        let directory = session.location.directory
        Task {
            worktreeIsDirty = await Task.detached { Git.hasUncommittedChanges(in: directory) }.value
            ask(session)
        }
    }

    private func archive(_ session: Session, removingWorktree: Bool) {
        Task {
            if removingWorktree { await removeWorktree(of: session) }
            await workspace.setArchived(session.id, true)
        }
    }

    private func delete(_ session: Session, removingWorktree: Bool) {
        if selection == session.id { selection = nil }
        Task {
            if removingWorktree { await removeWorktree(of: session) }
            await workspace.delete(session.id)
        }
    }

    private func removeWorktree(of session: Session) async {
        do { try await workspace.removeWorktree(session.location.directory) } catch { NSAlert(error: error).runModal() }
    }

    // MARK: Projects

    @ViewBuilder private func projectSection(_ project: Workspace.Project) -> some View {
        let isOpen = !collapsed.contains(project.directory)
        ProjectRow(project: project, isOpen: isOpen) {
            withAnimation(.ui) { toggle(project.directory) }
        } newSession: {
            newSession(project.directory)
        }
        .contextMenu {
            Button("New Session") { newSession(project.directory) }
            Button("Edit Project…") { editProject(project) }
            Divider()
            OpenInMenu(folder: URL(filePath: project.directory))
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(project.allFolders.map { URL(filePath: $0) }) }
            if project.sessions.isEmpty {
                Divider()
                Button("Remove from Sidebar") { workspace.removeFolder(project.directory) }
            }
        }
        if isOpen {
            if selection == Self.draftTag(project.directory) {
                SidebarRow(isSelected: true, indented: true, action: {}) {
                    EmptyView()
                } title: {
                    Text("New Session")
                }
            }
            let all = showsAll.contains(project.directory)
            ForEach(all ? project.sessions : Array(project.sessions.prefix(Self.sessionsPerProject))) { session in
                sessionRow(session, in: .project)
            }
            if project.sessions.count > Self.sessionsPerProject {
                SidebarRow(isSelected: false, indented: true, action: {
                    withAnimation(.ui) {
                        if all { showsAll.remove(project.directory) } else { showsAll.insert(project.directory) }
                    }
                }) {
                    EmptyView()
                } title: {
                    Text(all ? "Show Less" : "Show \(project.sessions.count - Self.sessionsPerProject) More")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var collapsed: Set<String> {
        Set(collapsedStorage.split(separator: "\n").map(String.init))
    }

    private func toggle(_ directory: String) {
        var folders = collapsed
        if folders.contains(directory) { folders.remove(directory) } else { folders.insert(directory) }
        collapsedStorage = folders.sorted().joined(separator: "\n")
    }

    // MARK: Sessions

    /// Sessions whose title or project name has the search, newest first; archived ones too.
    private var results: [Session] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return workspace.sessions.filter { session in
            workspace.projectName(session.location.directory).localizedStandardContains(query)
                || (session.title ?? "New Session").localizedStandardContains(query)
        }
        .sorted { $0.time.updated > $1.time.updated }
    }

    /// Pinned ones are already at the top.
    private var recents: [Session] {
        Array(workspace.projects.flatMap(\.sessions).filter { !Workspace.isPinned($0) }.sorted { $0.time.updated > $1.time.updated }.prefix(Self.recentCount))
    }

    private var pinned: [Session] {
        workspace.projects.flatMap(\.sessions).filter(Workspace.isPinned).sorted { $0.time.updated > $1.time.updated }
    }

    /// Highlighted where it was picked; picked elsewhere (a tab, a new session), in its project.
    private func isHighlighted(_ id: String, in place: Place) -> Bool {
        guard selection == id else { return false }
        if let pickedIn, pickedIn.id == id { return pickedIn.place == place }
        return place == .project
    }

    private func sessionRow(_ session: Session, in place: Place) -> some View {
        SidebarRow(isSelected: isHighlighted(session.id, in: place), indented: place == .project, action: {
            pickedIn = (place, session.id)
            selection = session.id
        }) {
            EmptyView()
        } title: {
            Text(session.title ?? "New Session")
                .fontWeight(session.isUnread ? .semibold : .regular)
                .foregroundStyle(Workspace.isArchived(session) ? .secondary : .primary)
        } accessory: {
            if Workspace.isArchived(session) {
                Text("Archived")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 6) {
                    if let tree = workspace.worktrees[session.location.directory] {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .help("Works in a worktree, on \(tree.branch)")
                    }
                    SessionStatus(session: session)
                }
            }
        }
        .contextMenu { menu(for: session) }
    }

    /// Saves the conversation as a Markdown file where you choose.
    private func export(_ session: Session) async {
        do {
            guard let text = try await workspace.markdown(of: session.id) else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = (session.title ?? "Conversation").replacingOccurrences(of: "/", with: "-") + ".md"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try text.write(to: url, atomically: true, encoding: .utf8)
            Analytics.shared.track("session_exported", ["how": "file"])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @ViewBuilder private func menu(for session: Session) -> some View {
        if !Workspace.isArchived(session) {
            if Workspace.isPinned(session) {
                Button("Unpin") { Task { await workspace.setPinned(session.id, false) } }
            } else {
                Button("Pin") { Task { await workspace.setPinned(session.id, true) } }
            }
        }
        Button("Rename…") {
            newTitle = session.title ?? ""
            renaming = session
        }
        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.location.directory) }
        Divider()
        Button("Copy as Markdown") {
            Task {
                do {
                    guard let text = try await workspace.markdown(of: session.id) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    Analytics.shared.track("session_exported", ["how": "copy"])
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
        Button("Export as Markdown…") { Task { await export(session) } }
        Divider()
        if Workspace.isArchived(session) {
            Button("Unarchive") { Task { await workspace.setArchived(session.id, false) } }
        } else {
            Button("Archive") {
                if hasOwnWorktree(session) { confirm(session) { archiving = $0 } } else { Task { await workspace.setArchived(session.id, true) } }
            }
        }
        Button("Delete…", role: .destructive) { confirm(session) { deleting = $0 } }
    }
}

// MARK: - Rows

/// The developer apps on this Mac that open a folder: editors, terminals, git apps, then the
/// Finder. (The system's own list for folders is mostly archivers and readers.)
private struct OpenInMenu: View {
    let folder: URL

    /// By bundle identifier, in the order they're listed.
    private static let apps = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed",
        "com.apple.dt.Xcode", "com.panic.Nova", "com.sublimetext.4", "com.barebones.bbedit",
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.WebStorm", "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce", "com.jetbrains.goland", "com.jetbrains.rider", "com.google.android.studio",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.DanPristupov.Fork", "com.fournova.Tower3", "com.github.GitHubClient", "com.torusknot.SourceTreeNotMAS",
        "com.apple.finder",
    ]

    var body: some View {
        let workspace = NSWorkspace.shared
        let installed = Self.apps.compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        Menu("Open In") {
            ForEach(installed, id: \.self) { app in
                Button {
                    workspace.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                } label: {
                    Label {
                        Text(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""))
                    } icon: {
                        Image(nsImage: workspace.icon(forFile: app.path))
                    }
                }
            }
        }
    }
}

/// Finding a session: a quiet field shaped like a row, cleared with its button or Escape.
private struct SearchRow: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: SidebarMetrics.iconWidth)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isFocused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: SidebarMetrics.rowHeight)
        .background(Color.primary.opacity(isFocused ? 0.07 : 0.04), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onTapGesture { isFocused = true }
        .padding(.vertical, 4)
    }
}

private enum SidebarMetrics {
    static let rowHeight: CGFloat = 32
    static let iconWidth: CGFloat = 18
}

/// One line in the sidebar: an optional icon, a title, an optional trailing accessory.
/// Indented rows line their titles up with the project names above them.
private struct SidebarRow<Icon: View, Title: View, Accessory: View>: View {
    var isSelected: Bool
    var indented = false
    let action: () -> Void
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var title: () -> Title
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if Icon.self != EmptyView.self {
                    icon()
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: SidebarMetrics.iconWidth)
                } else if indented {
                    Color.clear.frame(width: SidebarMetrics.iconWidth, height: 1)
                }
                title()
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                accessory()
            }
            .padding(.horizontal, 10)
            .frame(height: SidebarMetrics.rowHeight)
            .hoverHighlight(selected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

extension SidebarRow where Accessory == EmptyView {
    init(isSelected: Bool, indented: Bool = false, action: @escaping () -> Void, @ViewBuilder icon: @escaping () -> Icon, @ViewBuilder title: @escaping () -> Title) {
        self.init(isSelected: isSelected, indented: indented, action: action, icon: icon, title: title, accessory: { EmptyView() })
    }
}

/// A project: its folder (open or closed) and name. Clicking opens or closes it; the
/// compose button for a new session in it shows under the pointer, in place.
private struct ProjectRow: View {
    let project: Workspace.Project
    let isOpen: Bool
    let toggle: () -> Void
    let newSession: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                FolderIcon(isOpen: isOpen)
                    .foregroundStyle(.secondary)
                    .frame(width: SidebarMetrics.iconWidth)
                Text(project.name)
                    .font(.system(size: 14))
                    .lineLimit(1)
                Spacer(minLength: 6)
                // Room for the compose button, so a long name never runs under it.
                Color.clear.frame(width: 22, height: 1)
            }
            .padding(.horizontal, 10)
            .frame(height: SidebarMetrics.rowHeight)
            .hoverHighlight(selected: false)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            Button(action: newSession) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.trailing, 4)
            .opacity(isHovering ? 1 : 0)
            .help("New Session in \(project.name)")
        }
        .onHover { isHovering = $0 }
        .help(project.allFolders.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n"))
    }
}

/// "Projects", "Recents": a quiet heading, with room for a trailing button.
private struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .frame(height: 22)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

/// How a session is doing, at the end of its row.
private struct SessionStatus: View {
    @Environment(Workspace.self) private var workspace
    let session: Session

    var body: some View {
        if workspace.needsAttention(session.id) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .help("Waiting for you")
        } else if workspace.running.contains(session.id) {
            Spinner(size: 12)
                .help("Working")
        } else if session.outcome == .failed {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .help("The last run failed")
        } else if session.isUnread {
            Circle().fill(.tint).frame(width: 7, height: 7)
                .help("Finished")
        }
    }
}

/// Which accounts are connected, at the bottom of the sidebar. A plain row, like the rest.
private struct AccountsRow: View {
    @Environment(Catalog.self) private var catalog
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if catalog.connectedProviders.isEmpty {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 15))
                        .foregroundStyle(.tint)
                } else {
                    HStack(spacing: 8) {
                        ForEach(catalog.connectedProviders.prefix(3)) { provider in
                            ProviderLogo(id: provider.id, size: 18)
                        }
                    }
                }
                Text(label)
                    .font(.system(size: 14))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .hoverHighlight(selected: false)
        }
        .buttonStyle(.plain)
        .help("Accounts (⇧⌘K)")
    }

    private var label: String {
        switch catalog.connectedProviders.count {
        case 0: "Connect an Account"
        case 1: catalog.connectedProviders[0].name
        case let count: "\(count) Accounts"
        }
    }
}
