import OpenCodeKit
import SwiftUI

/// New Session on top, then projects (each a folder that opens to its sessions), then
/// the most recent sessions across projects, and the connected accounts at the bottom.
/// Rows are flat: a soft fill under the pointer, a stronger one for the open session.
struct SidebarView: View {
    @Environment(Workspace.self) private var workspace

    @Binding var selection: String?
    let newSession: (String?) -> Void
    let openFolder: () -> Void
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

    private enum Place { case project, recents }
    @State private var newTitle = ""

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

                    SectionHeader(title: "Projects") {
                        Button(action: openFolder) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Open Folder… (⌘O)")
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
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.never)

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
            Button("Delete", role: .destructive) {
                guard let session = deleting else { return }
                if selection == session.id { selection = nil }
                Task { await workspace.delete(session.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The session and its transcript will be deleted. This can't be undone.")
        }
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
            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.directory) }
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

    private var recents: [Session] {
        Array(workspace.projects.flatMap(\.sessions).sorted { $0.time.updated > $1.time.updated }.prefix(Self.recentCount))
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
        } accessory: {
            SessionStatus(session: session)
        }
        .contextMenu { menu(for: session) }
    }

    @ViewBuilder private func menu(for session: Session) -> some View {
        Button("Rename…") {
            newTitle = session.title ?? ""
            renaming = session
        }
        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.location.directory) }
        Divider()
        Button("Delete…", role: .destructive) { deleting = session }
    }
}

// MARK: - Rows

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
        .help(project.directory)
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
