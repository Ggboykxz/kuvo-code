import AppKit
import OpenCodeKit
import SwiftUI

/// Creating a project, or changing one: its name and its folders. Sessions run in the primary
/// folder, and the agent can work in the others too. An existing project keeps its primary
/// folder, since its sessions live there.
struct ProjectSheet: View {
    /// The project being edited; nil for a new one.
    let project: Workspace.Project?
    let save: (_ primary: String, _ settings: Workspace.ProjectSettings) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var name: String
    /// What runs in each new worktree; nil until it's known that the primary folder is in a
    /// git repository (and what the engine has for it).
    @State private var setup: String?
    @State private var savedSetup: String?
    @State private var engineProject: String?
    /// The primary folder first.
    @State private var folders: [String]
    @FocusState private var isNameFocused: Bool

    init(project: Workspace.Project?, folders: [String] = [], save: @escaping (String, Workspace.ProjectSettings) -> Void) {
        self.project = project
        self.save = save
        _name = State(initialValue: project?.settings.name ?? "")
        _folders = State(initialValue: project?.allFolders ?? folders)
    }

    private var isNew: Bool { project == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(isNew ? "New Project" : "Edit Project")
                .font(.title2.weight(.bold))

            nameField

            VStack(alignment: .leading, spacing: 8) {
                Text("Folders")
                    .font(.headline)
                folderList
            }

            if setup != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Worktree Setup")
                        .font(.headline)
                    TextField("Setup command", text: Binding(get: { setup ?? "" }, set: { setup = $0 }), prompt: Text("npm install && cp \"$OPENCODE_WORKTREE_BASE/.env\" ."), axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    Text("Runs in each new worktree before its session starts, to install dependencies or copy files git doesn't have. $OPENCODE_WORKTREE_BASE is the project's folder.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                Button(isNew ? "Create Project" : "Save") {
                    guard let primary = folders.first else { return }
                    save(primary, Workspace.ProjectSettings(name: name, folders: Array(folders.dropFirst())))
                    saveSetup()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(folders.isEmpty)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 560)
        .onAppear { isNameFocused = true }
        .task(id: folders.first) { await loadSetup() }
    }

    // MARK: Worktree setup

    /// The engine keeps the setup command with its project (the repository).
    private func loadSetup() async {
        setup = nil
        guard let primary = folders.first, let api = app.api,
              await Task.detached(operation: { Git.run(["rev-parse", "--git-dir"], in: primary) != nil }).value,
              let project = try? await api.location(directory: primary).project else { return }
        let command = (try? await api.projects())?.first { $0.id == project.id }?.commands?.start ?? ""
        engineProject = project.id
        savedSetup = command
        setup = command
    }

    private func saveSetup() {
        guard let api = app.api, let engineProject, let setup, setup != savedSetup else { return }
        let command = setup.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { try? await api.setSetupCommand(project: engineProject, command.isEmpty ? nil : command) }
    }

    // MARK: Name

    private var nameField: some View {
        HStack(spacing: 0) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 42)
            Divider()
            // Left empty, the project takes its primary folder's name.
            TextField("Project name", text: $name, prompt: Text(folders.first.map { ($0 as NSString).lastPathComponent } ?? "Project name"))
                .textFieldStyle(.plain)
                .focused($isNameFocused)
                .padding(.horizontal, 12)
        }
        .font(.system(size: 15))
        .frame(height: 44)
        .background(.fill.quaternary, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isNameFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isNameFocused ? 2 : 1))
    }

    // MARK: Folders

    private var folderList: some View {
        VStack(spacing: 0) {
            if folders.isEmpty {
                VStack(spacing: 12) {
                    Text("Add the folders this project works with.")
                        .foregroundStyle(.secondary)
                    Button("Add Folder…", systemImage: "folder.badge.plus", action: addFolders)
                        .buttonStyle(.glass)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ForEach(folders, id: \.self) { folder in
                    FolderRow(
                        path: folder,
                        isPrimary: folder == folders.first,
                        canChangePrimary: isNew,
                        makePrimary: { withAnimation(.ui) { folders.removeAll { $0 == folder }; folders.insert(folder, at: 0) } },
                        remove: { withAnimation(.ui) { folders.removeAll { $0 == folder } } }
                    )
                    Divider().padding(.leading, 48)
                }
                Button(action: addFolders) {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        Text("Add Folder…")
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .contentShape(.rect)
                    .hoverHighlight(in: Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(.background, in: .rect(cornerRadius: Metrics.cardRadius))
        .clipShape(.rect(cornerRadius: Metrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(.separator))
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = folders.isEmpty ? "Choose the project's folders. The first one is where sessions run." : "Choose more folders for the agent to work with."
        guard panel.runModal() == .OK else { return }
        withAnimation(.ui) {
            folders += panel.urls.map(\.path).filter { !folders.contains($0) }
        }
    }
}

private struct FolderRow: View {
    let path: String
    let isPrimary: Bool
    /// A new project can still move its sessions' home; an existing one can't.
    let canChangePrimary: Bool
    let makePrimary: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent)
                    .lineLimit(1)
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if isPrimary {
                Text("Primary")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .overlay(Capsule().strokeBorder(.separator))
                    .help("Sessions run in this folder")
            } else if canChangePrimary {
                Button("Make Primary", action: makePrimary)
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.borderless)
                    .help("Run sessions in this folder")
            }
            Button("Remove", systemImage: "xmark", action: remove)
                .buttonStyle(CardActionStyle())
                .help(isPrimary && !canChangePrimary ? "Sessions run here, so it stays" : "Remove from the project")
                .disabled(isPrimary && !canChangePrimary)
                .opacity(isPrimary && !canChangePrimary ? 0 : 1)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .help(path)
    }
}
