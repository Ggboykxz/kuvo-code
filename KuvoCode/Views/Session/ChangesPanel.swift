import AppKit
import OpenCodeKit
import SwiftUI

/// What's changed in the project, Codex-style: uncommitted (or unstaged, or staged)
/// changes from git, new files included, each file folded to its changes with the
/// rest a click away. Lines take comments, which go to the agent with the next message.
struct ChangesPanel: View {
    /// The session, for its comments and its record of edits; none for a project
    /// without one open (no comments then).
    let model: SessionModel?
    /// The project's folders, the primary one first; a menu picks which one's changes show.
    let folders: [String]
    @State private var changes: ProjectChanges
    @State private var collapsed: Set<String> = []
    @State private var expandedFolds: Set<String> = []
    /// The line a comment is being written for: file and line index.
    @State private var draft: DraftTarget?
    /// Syntax colors, per file, worked out off the main thread.
    @State private var highlighting: [String: DiffHighlighting] = [:]

    struct DraftTarget: Equatable { var file: String; var line: Int }
    @Environment(AppModel.self) private var app
    @State private var isCommitting = false

    init(directory: String, folders: [String] = [], model: SessionModel?) {
        self.model = model
        self.folders = folders.isEmpty ? [directory] : folders
        _changes = State(initialValue: ProjectChanges(directory: directory))
    }

    private var isPrimary: Bool { changes.directory == folders.first }

    /// The session's record of its edits is about its own folder.
    private var engineChanges: [FileDiff] { isPrimary ? model?.changes ?? [] : [] }

    /// Comments name files by their path, after the folder's name outside the primary folder,
    /// as the agent knows the project's folders.
    private var commentPrefix: String { isPrimary ? "" : (changes.directory as NSString).lastPathComponent + "/" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        // Git is quick to ask; look again every few seconds while the panel is open.
        .task(id: "\(changes.directory)\n\(changes.scope)") {
            while !Task.isCancelled {
                await changes.refresh(fallback: engineChanges)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .task(id: changes.files) {
            for file in changes.files {
                guard !Task.isCancelled else { return }
                highlighting[file.id] = await DiffHighlighting.make(for: file)
            }
        }
        .onChange(of: model?.isRunning) { Task { await changes.refresh(fallback: engineChanges) } }
        .onChange(of: engineChanges) { Task { await changes.refresh(fallback: engineChanges) } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if folders.count > 1 {
                Menu {
                    Picker("Folder", selection: Binding(get: { changes.directory }, set: { folder in
                        let scope = changes.scope
                        changes = ProjectChanges(directory: folder)
                        changes.scope = scope
                        collapsed = []
                    })) {
                        ForEach(folders, id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label((changes.directory as NSString).lastPathComponent, systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 13, weight: .semibold))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Which of the project's folders to show")
            }
            if changes.isRepository {
                Menu {
                    Picker("Changes", selection: $changes.scope) {
                        ForEach(ProjectChanges.Scope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(changes.scope.title)
                        .font(.system(size: 13, weight: .semibold))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
            } else {
                Text("This Session")
                    .font(.system(size: 13, weight: .semibold))
                    .help("Not a git repository: showing the agent's edits in this session.")
            }
            DiffStat(additions: changes.additions, deletions: changes.deletions)
            Spacer()
            // Kept while its form is open, so a push problem stays readable after the commit.
            if changes.isRepository, !changes.files.isEmpty || isCommitting {
                Button("Commit…") { isCommitting = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .help("Commit the changes, and push them if you like")
                    .popover(isPresented: $isCommitting, arrowEdge: .bottom) {
                        CommitForm(changes: changes, environment: app.shellEnvironment, api: app.api, session: model?.id, model: model?.session.model) { isCommitting = false }
                    }
            }
            Button {
                withAnimation(.ui) {
                    collapsed = collapsed.count == changes.files.count ? [] : Set(changes.files.map(\.id))
                }
            } label: {
                Image(systemName: collapsed.count == changes.files.count && !changes.files.isEmpty ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
            }
            .buttonStyle(CardActionStyle())
            .help(collapsed.count == changes.files.count ? "Expand All" : "Collapse All")
            .disabled(changes.files.isEmpty)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    // MARK: Files

    @ViewBuilder private var content: some View {
        if changes.files.isEmpty {
            ContentUnavailableView {
                Label(changes.isLoaded ? "No Changes" : "Reading Changes…", systemImage: "doc.text.magnifyingglass")
            } description: {
                if changes.isLoaded {
                    Text(changes.isRepository ? "Nothing \(changes.scope.title.lowercased()) in this project." : "Files the agent edits show up here.")
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(changes.files) { file in
                        Section {
                            if !collapsed.contains(file.id) {
                                FileBody(
                                    file: file,
                                    highlighted: highlighting[file.id],
                                    comments: model?.reviewComments.filter { $0.file == commentPrefix + file.path } ?? [],
                                    expandedFolds: $expandedFolds,
                                    draft: $draft,
                                    addComment: model.map { model in { [commentPrefix] comment in
                                        var comment = comment
                                        comment.file = commentPrefix + comment.file
                                        model.reviewComments.append(comment)
                                    } },
                                    deleteComment: { comment in model?.reviewComments.removeAll { $0.id == comment.id } }
                                )
                            }
                        } header: {
                            FileHeader(file: file, isCollapsed: collapsed.contains(file.id), scope: changes.isRepository ? changes.scope : nil) {
                                withAnimation(.ui) {
                                    if collapsed.contains(file.id) { collapsed.remove(file.id) } else { collapsed.insert(file.id) }
                                }
                            } perform: { action in
                                Task {
                                    if let failure = await changes.perform(action, on: file) { model?.failure = failure }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }
}

// MARK: - Commit

/// A commit message, what it'll take, and whether to push afterwards (remembered).
private struct CommitForm: View {
    let changes: ProjectChanges
    let environment: [String: String]
    let api: OpenCodeAPI?
    /// The session open in the window: its model suggests the message.
    let session: String?
    let model: ModelRef?
    let done: () -> Void
    @State private var isSuggesting = false
    @State private var message = ""
    @State private var hasStaged: Bool?
    @State private var failure: String?
    @State private var isWorking = false
    @AppStorage("changes.pushAfterCommit") private var pushes = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commit Changes")
                .font(.headline)
            TextField("Message", text: $message, axis: .vertical)
                .lineLimit(3...10)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
            if api != nil {
                Button {
                    suggest()
                } label: {
                    Label(isSuggesting ? "Writing…" : "Suggest a Message", systemImage: "sparkles")
                }
                .buttonStyle(.link)
                .font(.callout)
                .disabled(isSuggesting)
                .help("Have the session's model write a message from the changes")
            }
            if let hasStaged {
                Text(hasStaged ? "Commits what's staged." : "Commits all the changes shown, \(changes.files.count) \(changes.files.count == 1 ? "file" : "files").")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Toggle("Push afterwards", isOn: $pushes)
            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isWorking { Spinner(size: 12) }
                Spacer()
                Button("Cancel", role: .cancel, action: done)
                    .keyboardShortcut(.cancelAction)
                Button(pushes ? "Commit and Push" : "Commit") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }
        }
        .padding(16)
        .frame(width: 340)
        .task {
            isFocused = true
            hasStaged = await changes.hasStaged()
        }
    }

    private func suggest() {
        guard let api else { return }
        isSuggesting = true
        failure = nil
        Task {
            defer { isSuggesting = false }
            let diff = await changes.commitDiff()
            let prompt = """
            Write a git commit message for the changes below. A summary line in the imperative mood, under 72 characters; then, only if it helps, a blank line and a few short lines on what changed and why. Reply with the message alone: no quotes, no code fences.

            \(diff)
            """
            do {
                // Through the session where there is one: free models only answer there.
                let text = if let session { try await api.generate(prompt, session: session) } else { try await api.generate(prompt, model: model) }
                message = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "`\"")))
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func commit() {
        isWorking = true
        failure = nil
        Task {
            failure = await changes.commit(message: message.trimmingCharacters(in: .whitespacesAndNewlines), push: pushes, environment: environment)
            isWorking = false
            if failure == nil { done() }
        }
    }
}

// MARK: - File header

private struct FileHeader: View {
    let file: ChangedFile
    let isCollapsed: Bool
    /// What the panel shows, for which git actions make sense; nil outside a repository.
    let scope: ProjectChanges.Scope?
    let toggle: () -> Void
    let perform: (ProjectChanges.Action) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var confirmsDiscard = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .frame(width: 18, height: 18)
            pathText
                .lineLimit(1)
                .truncationMode(.head)
                .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
            if file.status != .modified {
                Text(statusLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(statusColor.opacity(0.14), in: .capsule)
            }
            Spacer(minLength: 6)
            DiffStat(additions: file.additions, deletions: file.deletions)
            Button {
                NSWorkspace.shared.open(file.url)
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(CardActionStyle())
            .help("Open in Editor")
            .disabled(file.status == .deleted)
            Menu {
                Button("Open in Editor") { NSWorkspace.shared.open(file.url) }
                    .disabled(file.status == .deleted)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                    .disabled(file.status == .deleted)
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
                if let scope {
                    Divider()
                    if scope == .staged {
                        Button("Unstage") { perform(.unstage) }
                    } else {
                        Button("Stage") { perform(.stage) }
                        Button("Discard Changes…", role: .destructive) { confirmsDiscard = true }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(CardActionStyle())
            .fixedSize()
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 38)
        // Opaque: the header stays pinned while the file's lines scroll under it. A plain
        // rectangle: without a shape, the background takes the rounded shape of its container.
        .background(scheme == .dark ? Color(white: 0.21) : .white, in: .rect)
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(.rect)
        .onTapGesture { if hasBody { toggle() } }
        .alert("Discard the changes to \((file.path as NSString).lastPathComponent)?", isPresented: $confirmsDiscard) {
            Button("Discard", role: .destructive) { perform(.discard) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(file.status == .added
                 ? "It's a new file, so it goes to the Trash."
                 : scope == .unstaged ? "Its unstaged changes are thrown away; staged ones stay. This can't be undone." : "It goes back to how it was in the last commit. This can't be undone.")
        }
    }

    /// Binary files other than pictures have nothing to open.
    private var hasBody: Bool { !file.isBinary || file.isImage }

    /// "Sources/Models/" quiet, "Message.swift" bold.
    private var pathText: Text {
        let name = (file.path as NSString).lastPathComponent
        let folder = String(file.path.dropLast(name.count))
        let folderText = Text(folder).foregroundStyle(.secondary).font(.system(size: 13))
        let nameText = Text(name).font(.system(size: 13, weight: .semibold))
        return Text("\(folderText)\(nameText)")
    }

    private var statusLabel: String {
        switch file.status {
        case .added: "NEW"
        case .deleted: "DELETED"
        case .renamed: "RENAMED"
        case .modified: ""
        }
    }

    private var statusColor: Color {
        switch file.status {
        case .added: .green
        case .deleted: .red
        default: .secondary
        }
    }
}

// MARK: - File body

/// A file's lines, folded around its changes. Rows are direct children of the panel's
/// lazy stack, so long files only build what's on screen.
private struct FileBody: View {
    let file: ChangedFile
    let highlighted: DiffHighlighting?
    let comments: [ReviewComment]
    @Binding var expandedFolds: Set<String>
    @Binding var draft: ChangesPanel.DraftTarget?
    /// Nil without a session: lines don't take comments then.
    let addComment: ((ReviewComment) -> Void)?
    let deleteComment: (ReviewComment) -> Void

    var body: some View {
        if file.isImage {
            ImageDiff(file: file)
        } else if file.isBinary {
            // Nothing to show line by line; the header says what changed.
            EmptyView()
        } else if file.lines.isEmpty {
            Text(file.status == .renamed ? "Renamed without changes" : "No content changes")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        } else {
            let gutter = DiffLineRow.gutterWidth(for: file.lines)
            ForEach(DiffFolding.rows(for: file.lines, expanded: expandedFolds, file: file.id)) { row in
                switch row.kind {
                case .fold(let range):
                    FoldRow(count: range.count) {
                        withAnimation(.ui) { _ = expandedFolds.insert(row.id) }
                    }
                case .gap:
                    FoldRow(count: nil) {}
                case .line(let index):
                    let line = file.lines[index]
                    DiffLineRow(line: line, runs: highlighted?.runs(for: line, at: index), gutterWidth: gutter,
                                comment: addComment == nil ? nil : { draft = .init(file: file.id, line: index) })
                    ForEach(comments.filter { $0.matches(line) }) { comment in
                        CommentCard(comment: comment) { deleteComment(comment) }
                    }
                    if draft == .init(file: file.id, line: index) {
                        CommentEditor {
                            draft = nil
                        } save: { text in
                            addComment?(ReviewComment(file: file.path, line: line.number, side: line.kind == .removed ? .old : .new, snippet: line.text.trimmingCharacters(in: .whitespaces), text: text))
                            draft = nil
                        }
                    }
                }
            }
        }
    }
}

/// A changed picture: before and after side by side, or just the one that exists.
private struct ImageDiff: View {
    let file: ChangedFile
    @State private var images: Pair?

    struct Pair { var old: NSImage?; var new: NSImage? }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let images {
                if let old = images.old { side(images.new == nil ? nil : "Before", old, edge: .deletions) }
                if let new = images.new { side(images.old == nil ? nil : "After", new, edge: .additions) }
                if images.old == nil && images.new == nil {
                    Text("Couldn't read this picture")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .task(id: file) { images = await Self.load(file) }
    }

    private func side(_ label: String?, _ image: NSImage, edge: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(edge)
            }
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 260, maxHeight: 220, alignment: .topLeading)
                .background(Color.primary.opacity(0.04))
                .clipShape(.rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(edge.opacity(0.6), lineWidth: 1))
            if let rep = image.representations.first, rep.pixelsWide > 0 {
                Text("\(rep.pixelsWide) × \(rep.pixelsHigh)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Each side from git when it's committed or staged, otherwise from disk.
    private static func load(_ file: ChangedFile) async -> Pair {
        await Task.detached {
            func read(_ object: String?, disk: URL?) -> NSImage? {
                if let object, let root = file.root, let data = Git.data(["show", object], in: root) { return NSImage(data: data) }
                if let disk, FileManager.default.fileExists(atPath: disk.path) { return NSImage(contentsOf: disk) }
                return nil
            }
            return Pair(
                old: file.status == .added ? nil : read(file.oldObject, disk: nil),
                new: file.status == .deleted ? nil : read(file.newObject, disk: file.url)
            )
        }.value
    }
}

extension ReviewComment {
    func matches(_ line: DiffLine) -> Bool {
        side == (line.kind == .removed ? .old : .new) && self.line == line.number
    }
}

extension DiffLine {
    /// The number shown in the gutter: the old one for a removed line, the new one otherwise.
    var number: Int { (kind == .removed ? oldNumber : newNumber) ?? 0 }
}

// MARK: - Folding

/// Shows each change with a few lines around it and folds the long unchanged stretches.
enum DiffFolding {
    static let context = 3

    struct Row: Identifiable {
        enum Kind { case line(Int), fold(Range<Int>), gap }
        var id: String
        var kind: Kind
    }

    static func rows(for lines: [DiffLine], expanded: Set<String>, file: String) -> [Row] {
        var rows: [Row] = []
        var index = 0
        while index < lines.count {
            if lines[index].gapBefore { rows.append(Row(id: "\(file)#gap\(index)", kind: .gap)) }
            guard lines[index].kind == .context else {
                rows.append(Row(id: "\(file)#\(index)", kind: .line(index)))
                index += 1
                continue
            }
            // A run of unchanged lines, up to the next change (or a gap git left).
            var end = index + 1
            while end < lines.count, lines[end].kind == .context, !lines[end].gapBefore { end += 1 }
            let keepStart = index == 0 || lines[index].gapBefore ? 0 : context
            let keepEnd = end == lines.count || lines[end].gapBefore ? 0 : context
            let foldStart = index + keepStart, foldEnd = end - keepEnd
            let foldID = "\(file)#fold\(foldStart)"
            if foldEnd - foldStart > 3, !expanded.contains(foldID) {
                rows += (index..<foldStart).map { Row(id: "\(file)#\($0)", kind: .line($0)) }
                rows.append(Row(id: foldID, kind: .fold(foldStart..<foldEnd)))
                rows += (foldEnd..<end).map { Row(id: "\(file)#\($0)", kind: .line($0)) }
            } else {
                rows += (index..<end).map { Row(id: "\(file)#\($0)", kind: .line($0)) }
            }
            index = end
        }
        return rows
    }
}

private struct FoldRow: View {
    /// Nil for a gap that can't be opened (git left those lines out).
    let count: Int?
    let expand: () -> Void

    var body: some View {
        Button(action: expand) {
            HStack(spacing: 10) {
                Image(systemName: count == nil ? "ellipsis" : "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 30)
                if let count {
                    Text("\(count) unmodified lines")
                }
                Spacer()
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(height: 26)
            .background(Color.primary.opacity(0.04), in: .rect)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(count == nil)
        .help(count == nil ? "" : "Show these lines")
    }
}

// MARK: - Lines

/// One diff line: its number, a colored edge for changes, and the code, wrapped.
/// Hovering the number offers a comment.
struct DiffLineRow: View {
    let line: DiffLine
    var runs: [CodeHighlighter.Run]?
    let gutterWidth: CGFloat
    /// Nil where lines don't take comments.
    var comment: (() -> Void)?
    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    static func gutterWidth(for lines: [DiffLine]) -> CGFloat {
        let largest = lines.map(\.number).max() ?? 1
        return CGFloat(String(largest).count) * 7.5 + 22
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.number > 0 ? "\(line.number)" : "")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(numberColor)
                .frame(width: gutterWidth - 10, alignment: .trailing)
                .padding(.trailing, 10)
                .overlay(alignment: .leading) {
                    if let comment, isHovering {
                        Button(action: comment) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 16, height: 16)
                                .background(Color.accentColor, in: .rect(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 2)
                        .help("Comment on This Line")
                    }
                }
            code
                .font(.system(size: 12, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .padding(.trailing, 12)
        }
        .padding(.vertical, 1.5)
        .background(rowColor, in: .rect)
        .overlay(alignment: .leading) {
            if line.kind != .context {
                Rectangle().fill(edgeColor).frame(width: 3)
            }
        }
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }

    private var code: Text {
        guard let runs, !runs.isEmpty else { return Text(line.text.isEmpty ? " " : line.text) }
        var string = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if let color = CodeColors.color(for: run.type, dark: scheme == .dark) { piece.foregroundColor = color }
            string += piece
        }
        return Text(string)
    }

    private var rowColor: Color {
        switch line.kind {
        case .added: Color.additions.opacity(scheme == .dark ? 0.12 : 0.12)
        case .removed: Color.deletions.opacity(scheme == .dark ? 0.13 : 0.10)
        case .context: .clear
        }
    }

    private var edgeColor: Color { line.kind == .added ? .additions : .deletions }

    private var numberColor: Color {
        switch line.kind {
        case .added: Color.additions.opacity(0.9)
        case .removed: Color.deletions.opacity(0.9)
        case .context: Color.secondary.opacity(0.7)
        }
    }
}

/// Highlighted runs for a file's lines: the new side for added and unchanged lines,
/// the old side for removed ones, each tokenized whole so strings and comments that
/// span lines come out right.
nonisolated struct DiffHighlighting: Sendable {
    private var newSide: [[CodeHighlighter.Run]]
    private var oldSide: [[CodeHighlighter.Run]]
    private var newIndex: [Int: Int]
    private var oldIndex: [Int: Int]

    static func make(for file: ChangedFile) async -> DiffHighlighting? {
        guard let language = CodeHighlighter.language(for: file.path) else { return nil }
        var newLines: [String] = [], oldLines: [String] = []
        var newIndex: [Int: Int] = [:], oldIndex: [Int: Int] = [:]
        for (index, line) in file.lines.enumerated() {
            if line.kind != .removed { newIndex[index] = newLines.count; newLines.append(line.text) }
            if line.kind != .added { oldIndex[index] = oldLines.count; oldLines.append(line.text) }
        }
        let highlighter = CodeHighlighter.shared
        let new = await highlighter.lines(of: newLines.joined(separator: "\n"), language: language) ?? []
        let old = oldLines.isEmpty ? [] : await highlighter.lines(of: oldLines.joined(separator: "\n"), language: language) ?? []
        return DiffHighlighting(newSide: new, oldSide: old, newIndex: newIndex, oldIndex: oldIndex)
    }

    func runs(for line: DiffLine, at index: Int) -> [CodeHighlighter.Run]? {
        if line.kind == .removed {
            guard let position = oldIndex[index], position < oldSide.count else { return nil }
            return oldSide[position]
        }
        guard let position = newIndex[index], position < newSide.count else { return nil }
        return newSide[position]
    }
}

// MARK: - Comments

/// A comment under its line, until it's sent.
struct CommentCard: View {
    let comment: ReviewComment
    var delete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Avatar()
                Text("You")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Comment on line \(comment.side == .old ? "L" : "R")\(comment.line)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(comment.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let delete {
                HStack {
                    Spacer()
                    Button("Delete", action: delete)
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.1)))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// A comment as sent, in the transcript: where it points, the line, and what it says.
struct CommentReference: View {
    let comment: ReviewComment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(comment.location, systemImage: "text.bubble")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            if !comment.snippet.isEmpty {
                Text(comment.snippet)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(comment.side == .old ? Color.deletions : Color.additions).frame(width: 2)
                    }
            }
            Text(comment.text)
                .font(.transcript)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.fill.tertiary, in: .rect(cornerRadius: 14))
    }
}

/// Writing a comment: ⌘Return saves, Escape cancels.
private struct CommentEditor: View {
    let cancel: () -> Void
    let save: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Avatar()
                Text("You")
                    .font(.system(size: 12, weight: .semibold))
            }
            TextField("Add a comment…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(2...8)
                .focused($focused)
                .onKeyPress(.escape) { cancel(); return .handled }
                // Here, not on the button: a button's ⌘Return would take it from the composer too.
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    submit()
                    return .handled
                }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("Comment") { submit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Comment (⌘Return)")
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.system(size: 12))
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5)))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { focused = true }
    }

    private func submit() {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        save(text)
    }
}

/// The user's initials in a circle.
private struct Avatar: View {
    var body: some View {
        Text(initials)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background(Color.primary.opacity(0.08), in: .circle)
    }

    private var initials: String {
        var name = NSFullUserName()
        #if DEBUG
        // KUVO_DEMO_NAME stands in for the user's name, for screenshots.
        if let demo = ProcessInfo.processInfo.environment["KUVO_DEMO_NAME"] { name = demo }
        #endif
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}
