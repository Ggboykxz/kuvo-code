import OpenCodeKit
import SwiftUI

/// Projects and their sessions. Each project has a compose button; a new session
/// shows as a "New Session" row only while it's being written.
struct SidebarView: View {
    @Environment(Catalog.self) private var catalog
    @Environment(Workspace.self) private var workspace

    @Binding var selection: String?
    let newSession: (String?) -> Void
    let openFolder: () -> Void
    let showProviders: () -> Void

    @State private var renaming: Session?
    @State private var newTitle = ""

    /// The selection tag of a project's not-yet-sent new session.
    static func draftTag(_ directory: String) -> String { "draft:" + directory }

    static func draftDirectory(from tag: String) -> String? {
        tag.hasPrefix("draft:") ? String(tag.dropFirst("draft:".count)) : nil
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(workspace.projects) { project in
                // The header is a plain row rather than a section header: inset lists pin
                // section headers with a shaded band, which reads as heavy chrome here.
                ProjectHeader(project: project) { newSession(project.directory) }
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                    .padding(.top, project.id == workspace.projects.first?.id ? 0 : 10)
                    .contextMenu {
                        Button("New Session") { newSession(project.directory) }
                        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.directory) }
                        if project.sessions.isEmpty {
                            Divider()
                            Button("Remove from Sidebar") { workspace.removeFolder(project.directory) }
                        }
                    }
                if selection == Self.draftTag(project.directory) {
                    DraftRow()
                        .tag(Self.draftTag(project.directory))
                        .listRowSeparator(.hidden)
                }
                ForEach(project.sessions) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                        .listRowSeparator(.hidden)
                        .contextMenu { menu(for: session) }
                }
            }
        }
        // Inset, not .sidebar: sidebar lists draw vibrant (see-through) text for glass,
        // which looks washed out on an opaque card.
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .overlay {
            if workspace.isLoaded && workspace.projects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder")
                } description: {
                    Text("Open a folder for the agent to work in.")
                } actions: {
                    Button("Open Folder…", action: openFolder)
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // 16 from the bottom, like the composer next to it, so their bottom edges line up.
            AccountsChip(action: showProviders)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 16)
        }
        .alert("Rename Session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let session = renaming { Task { await workspace.rename(session.id, to: newTitle) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private func menu(for session: Session) -> some View {
        Button("Rename…") {
            newTitle = session.title ?? ""
            renaming = session
        }
        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.location.directory) }
        Divider()
        Button("Delete", role: .destructive) {
            if selection == session.id { selection = nil }
            Task { await workspace.delete(session.id) }
        }
    }
}

private struct ProjectHeader: View {
    let project: Workspace.Project
    let newSession: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(project.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .help(project.directory)
            Spacer(minLength: 4)
            // The same compose icon as the toolbar's New Session button.
            Button(action: newSession) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("New Session in \(project.name)")
        }
        .padding(.vertical, 4)
    }
}

/// The new session being written, until its first message creates it.
private struct DraftRow: View {
    var body: some View {
        Label {
            Text("New Session")
                .font(.system(size: 14))
        } icon: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 13))
        }
        .padding(.vertical, 4)
    }
}

private struct SessionRow: View {
    @Environment(Workspace.self) private var workspace
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title ?? "New Session")
                    .font(.system(size: 14, weight: session.isUnread ? .semibold : .regular))
                    .lineLimit(1)
                Text(Date(timeIntervalSince1970: session.time.updated / 1000), format: .relative(presentation: .named))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            status
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var status: some View {
        if workspace.needsAttention(session.id) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
                .help("Waiting for you")
        } else if workspace.running.contains(session.id) {
            ActivityDot(size: 8)
                .help("Working")
        } else if session.outcome == .failed {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.red)
                .help("The last run failed")
        } else if session.isUnread {
            Circle().fill(.tint).frame(width: 8, height: 8)
                .help("Finished")
        }
    }
}

/// Which accounts are connected, at the bottom of the sidebar.
private struct AccountsChip: View {
    @Environment(Catalog.self) private var catalog
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if catalog.connectedProviders.isEmpty {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 16))
                        .foregroundStyle(.tint)
                } else {
                    HStack(spacing: 8) {
                        ForEach(catalog.connectedProviders.prefix(3)) { provider in
                            ProviderLogo(id: provider.id, size: 20)
                        }
                    }
                    .padding(.leading, 2)
                }
                Text(label)
                    .font(.system(size: 14))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
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
