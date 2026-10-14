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
    @Environment(\.colorScheme) private var scheme
    @State private var name: String
    /// What runs in each new worktree; nil until it's known that the primary folder is in a
    /// git repository (and what the engine has for it).
    @State private var setup: String?
    @State private var savedSetup: String?
    @State private var engineProject: String?
    @State private var run: String
    @FocusState private var isRunFocused: Bool
    @FocusState private var isSetupFocused: Bool
    private let focusesRun: Bool
    /// The primary folder first.
    @State private var folders: [String]
    @FocusState private var isNameFocused: Bool

    init(project: Workspace.Project?, folders: [String] = [], focusesRun: Bool = false, save: @escaping (String, Workspace.ProjectSettings) -> Void) {
        self.project = project
        self.save = save
        self.focusesRun = focusesRun
        _name = State(initialValue: project?.settings.name ?? "")
        _run = State(initialValue: project?.settings.run ?? "")
        _folders = State(initialValue: project?.allFolders ?? folders)
    }

    private var isNew: Bool { project == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(isNew ? "New Project" : "Edit Project")
                .font(.title2.weight(.bold))

            nameField

            section("Folders", note: "Sessions run in the primary folder; the agent can work in the others too.") {
                folderList
            }

            section("Run", note: Text("Adds a \(Image(systemName: "play.fill")) Run button to the title bar that starts your app in a terminal in the side panel (⌘R).")) {
                WellGroup(isActive: isRunFocused) {
                    WellRow(isActive: isRunFocused) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13))
                    } content: {
                        TextField("Run", text: $run, prompt: Text(verbatim: "npm run dev"))
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, design: .monospaced))
                            .focused($isRunFocused)
                    }
                }
            }

            if setup != nil {
                section("Worktree Setup", note: Text(verbatim: "Runs in each new worktree before its session starts, to install dependencies or copy files git doesn't have. $OPENCODE_WORKTREE_BASE is the project's folder.")) {
                    WellGroup(isActive: isSetupFocused) {
                        WellRow(isActive: isSetupFocused) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 14))
                        } content: {
                            TextField("Worktree setup", text: Binding(get: { setup ?? "" }, set: { setup = $0 }), prompt: Text(verbatim: "npm install && cp \"$OPENCODE_WORKTREE_BASE/.env\" ."), axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14, design: .monospaced))
                                .lineLimit(1...4)
                                .focused($isSetupFocused)
                                .padding(.vertical, 12)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                Button(isNew ? "Create Project" : "Save") {
                    guard let primary = folders.first else { return }
                    save(primary, Workspace.ProjectSettings(name: name, folders: Array(folders.dropFirst()), run: run))
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
        .onAppear { if focusesRun { isRunFocused = true } else { isNameFocused = true } }
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

    /// A titled part of the sheet, with a line under it saying what it's for.
    private func section(_ title: String, note: String, @ViewBuilder content: () -> some View) -> some View {
        section(title, note: Text(note), content: content)
    }

    private func section(_ title: String, note: Text, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
            note
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Name

    private var nameField: some View {
        WellGroup(isActive: isNameFocused) {
            WellRow(isActive: isNameFocused) {
                Image(systemName: "folder")
            } content: {
                // Left empty, the project takes its primary folder's name.
                TextField("Project name", text: $name, prompt: Text(folders.first.map { ($0 as NSString).lastPathComponent } ?? "Project name"))
                    .textFieldStyle(.plain)
                    .focused($isNameFocused)
            }
        }
        .font(.system(size: 15))
    }

    // MARK: Folders

    /// The folders as rows of one field, the way the name is drawn, with adding a folder as
    /// its last row.
    private var folderList: some View {
        WellGroup {
            ForEach(folders, id: \.self) { folder in
                FolderRow(
                    path: folder,
                    isPrimary: folder == folders.first,
                    canChangePrimary: isNew,
                    makePrimary: { withAnimation(.ui) { folders.removeAll { $0 == folder }; folders.insert(folder, at: 0) } },
                    remove: { withAnimation(.ui) { folders.removeAll { $0 == folder } } }
                )
                WellDivider()
            }
            Button(action: addFolders) {
                WellRow {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                } content: {
                    Text(folders.isEmpty ? "Add Folder…" : "Add Another Folder…")
                }
                .contentShape(.rect)
            }
            .buttonStyle(WellRowButtonStyle())
        }
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
        WellRow(height: 52) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 22, height: 22)
        } content: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text((path as NSString).lastPathComponent)
                        .lineLimit(1)
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(path)
                Spacer(minLength: 8)
                // A checkmark: a state, not a button like Make Primary.
                if isPrimary {
                    Label("Primary", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .help("Sessions run in this folder")
                } else if canChangePrimary {
                    Button("Make Primary", action: makePrimary)
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(TextButtonStyle(outset: true))
                        .help("Run sessions in this folder")
                }
                if !(isPrimary && !canChangePrimary) {
                    Button(action: remove) {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(RemoveButtonStyle())
                    .help("Remove from the project")
                }
            }
        }
    }
}

/// A group of rows drawn into the sheet like one field: sunken, with an edge of its own and no
/// outline, a touch deeper while you type in it.
private struct WellGroup<Content: View>: View {
    var isActive = false
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) { content }
            .background((scheme == .dark ? Color.black : Surface.slate).opacity(isActive ? 0.05 : 0), in: .rect(cornerRadius: 10))
            .clipShape(.rect(cornerRadius: 10))
            .recessedWell(RoundedRectangle(cornerRadius: 10))
            .animation(.easeOut(duration: 0.15), value: isActive)
    }
}

/// One row of a well: an icon in its own column, a hairline, then the content. The icon takes
/// the accent color while the row's field has the focus, in place of an outline.
private struct WellRow<Icon: View, Content: View>: View {
    var isActive = false
    var height: CGFloat = 44
    @ViewBuilder var icon: Icon
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            icon
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 42)
            Rectangle()
                .fill(Surface.wellBorder(scheme))
                .frame(width: 1)
            content
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: height)
    }
}

/// The hairline between a well's rows.
private struct WellDivider: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(Surface.wellBorder(scheme))
            .frame(height: 1)
    }
}

/// A row of a well that's a button, like Add Folder…: secondary ink and a soft fill under
/// the pointer, so it reads as a field to click.
private struct WellRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WellRowButton(configuration: configuration)
    }

    private struct WellRowButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovering ? .primary : .secondary)
                .background(configuration.isPressed ? Pressable.pressedFill : isHovering ? Pressable.hoverFill : .clear)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}
