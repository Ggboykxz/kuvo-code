import AppKit
import Quartz
import SwiftUI
import Textual
import UniformTypeIdentifiers

/// A file tab: the file on the left (rendered, highlighted or previewed), the project's
/// tree on the right. With no file yet, the tree fills the tab.
struct FilesView: View {
    /// The project's folders, the primary one first.
    let roots: [String]
    let file: URL?
    @Binding var showsTree: Bool
    let open: (URL) -> Void
    @State private var tree: FileTree
    @State private var width: CGFloat = 600

    init(roots: [String], file: URL?, showsTree: Binding<Bool>, open: @escaping (URL) -> Void) {
        self.roots = roots
        self.file = file
        _showsTree = showsTree
        self.open = open
        _tree = State(initialValue: FileTree(roots: roots.map { URL(filePath: $0) }))
    }

    /// The folder `file` is in, for its breadcrumb.
    private func root(of file: URL) -> String {
        roots.first { file.path.hasPrefix($0 + "/") } ?? roots[0]
    }

    /// How a message names `file`, as "@" does: its path in the primary folder, after its
    /// folder's name in the others, in full anywhere else.
    private func mention(of file: URL) -> String {
        guard let index = roots.firstIndex(where: { file.path.hasPrefix($0 + "/") }) else { return file.path }
        let relative = String(file.path.dropFirst(roots[index].count + 1))
        return index == 0 ? relative : URL(filePath: roots[index]).lastPathComponent + "/" + relative
    }

    var body: some View {
        HStack(spacing: 0) {
            if let file {
                FileViewer(url: file, root: root(of: file), mention: mention(of: file), showsTree: $showsTree)
                    .id(file)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .clipped()
            }
            if showsTree || file == nil {
                if file != nil { Divider() }
                FileTreeView(tree: tree, selected: file, open: open)
                    .frame(width: file == nil ? nil : treeWidth)
                    .frame(maxWidth: file == nil ? .infinity : nil)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
    }

    /// Beside a file, the tree takes up to 260 points, less in a narrow panel, so the file
    /// keeps most of the room.
    private var treeWidth: CGFloat {
        min(260, max(140, width * 0.4))
    }
}

// MARK: - Tree

@Observable
final class FileTree {
    struct Entry: Identifiable, Hashable {
        let url: URL
        let isDirectory: Bool
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    /// The project's folders, the primary one first.
    let roots: [URL]
    var expanded: Set<URL> = []
    var filter = ""
    private var children: [URL: [Entry]] = [:]
    /// Every file, for filtering; read on first use.
    private(set) var allFiles: [ProjectFiles.File]?

    init(roots: [URL]) {
        self.roots = roots
        // With several folders each is a row of its own; the primary one starts open.
        if roots.count > 1, let primary = roots.first { expanded.insert(primary) }
    }

    /// The tree as rows, with each row's depth: one folder's contents, or each folder with
    /// its contents under it.
    var rows: [(entry: Entry, depth: Int)] {
        var rows: [(Entry, Int)] = []
        func walk(_ directory: URL, depth: Int) {
            for entry in entries(in: directory) {
                rows.append((entry, depth))
                if entry.isDirectory, expanded.contains(entry.url) { walk(entry.url, depth: depth + 1) }
            }
        }
        if roots.count == 1, let root = roots.first {
            walk(root, depth: 0)
        } else {
            for root in roots {
                rows.append((Entry(url: root, isDirectory: true), 0))
                if expanded.contains(root) { walk(root, depth: 1) }
            }
        }
        return rows
    }

    /// Files whose path contains the filter, up to a few hundred.
    var matches: [ProjectFiles.File] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty, let allFiles else { return [] }
        return Array(allFiles.lazy.filter { $0.path.lowercased().contains(query) }.prefix(300))
    }

    func toggle(_ directory: URL) {
        if expanded.contains(directory) { expanded.remove(directory) } else { expanded.insert(directory) }
    }

    func entries(in directory: URL) -> [Entry] {
        if let cached = children[directory] { return cached }
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let entries = urls
            .filter { $0.lastPathComponent != ".DS_Store" }
            .map { Entry(url: $0, isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true) }
            .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
        children[directory] = entries
        return entries
    }

    /// Forgets what's been read, so the tree shows files created since.
    func reload() {
        children = [:]
        allFiles = nil
    }

    func loadAllFiles() async {
        guard allFiles == nil else { return }
        let roots = roots
        allFiles = await Task.detached { ProjectFiles.list(roots) }.value
    }
}

private struct FileTreeView: View {
    @Bindable var tree: FileTree
    let selected: URL?
    let open: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter files…", text: $tree.filter)
                    .textFieldStyle(.plain)
                if !tree.filter.isEmpty {
                    Button { tree.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(ClearFieldButtonStyle())
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
            .padding(10)
            .task(id: tree.filter.isEmpty) { if !tree.filter.isEmpty { await tree.loadAllFiles() } }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if tree.filter.isEmpty {
                        ForEach(tree.rows, id: \.entry.id) { row in
                            TreeRow(entry: row.entry, depth: row.depth, isRoot: tree.roots.count > 1 && row.depth == 0, isOpen: tree.expanded.contains(row.entry.url), isSelected: row.entry.url == selected) {
                                if row.entry.isDirectory { tree.toggle(row.entry.url) } else { open(row.entry.url) }
                            }
                        }
                    } else {
                        ForEach(tree.matches) { match in
                            MatchRow(path: match.path, isSelected: match.url == selected) { open(match.url) }
                        }
                        if tree.allFiles == nil {
                            ProgressView().controlSize(.small).padding()
                        } else if tree.matches.isEmpty {
                            Text("No matching files")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
        }
        .contextMenu {
            Button("Reload") { tree.reload() }
        }
    }
}

private struct TreeRow: View {
    let entry: FileTree.Entry
    let depth: Int
    /// One of the project's folders, in a tree of several.
    var isRoot = false
    let isOpen: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Group {
                    if entry.isDirectory {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                }
                .frame(width: 16)
                Text(entry.name)
                    .font(.system(size: 13, weight: isRoot ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6 + CGFloat(depth) * 14)
            .padding(.trailing, 6)
            .frame(height: 26)
            .hoverHighlight(in: RoundedRectangle(cornerRadius: 6), selected: isSelected)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            Button("Copy Path") { copyPath(entry.url) }
        }
    }
}

private struct MatchRow: View {
    let path: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 13))
                let folder = (path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(folder)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .truncationMode(.head)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .hoverHighlight(in: RoundedRectangle(cornerRadius: 6), selected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

private func copyPath(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.path, forType: .string)
}

// MARK: - Viewer

/// One file: Markdown rendered (or its source), code highlighted with line numbers,
/// pictures shown, anything else in Quick Look.
private struct FileViewer: View {
    let url: URL
    let root: String
    let mention: String
    @Binding var showsTree: Bool
    @Environment(AppModel.self) private var app
    @State private var content: Content?
    @State private var showsSource = false

    enum Content {
        case text(String)
        case image(NSImage)
        case preview
    }

    private var isMarkdown: Bool { ["md", "markdown", "mdx"].contains(url.pathExtension.lowercased()) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch content {
                case .text(let text) where isMarkdown && !showsSource:
                    ScrollView {
                        StructuredText(markdown: text)
                            .font(.transcript)
                            .textual.codeBlockStyle(CopyableCodeBlockStyle())
                            .textual.highlighterTheme(CodeColors.theme)
                            .textual.structuredTextStyle(.gitHub)
                            .textual.textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                case .text(let text):
                    CodeTextView(text: text, language: CodeHighlighter.language(for: url.path)) { lines in
                        let range = lines.count == 1 ? "\(lines.lowerBound)" : "\(lines.lowerBound)-\(lines.upperBound)"
                        app.utilities.addToMessage?("@\(mention):\(range)")
                    }
                case .image(let image):
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                            .padding(20)
                    }
                case .preview:
                    QuickLookView(url: url)
                case nil:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: url) { content = await Self.load(url) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            breadcrumb
                .lineLimit(1)
                .truncationMode(.head)
                .help(url.path)
            Spacer(minLength: 8)
            if isMarkdown {
                Button(showsSource ? "View Rendered" : "View Source") { showsSource.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .hoverHighlight(in: Capsule())
            }
            Button { withAnimation(.ui) { showsTree.toggle() } } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(CardActionStyle())
            .help(showsTree ? "Hide Files" : "Show Files")
            OpenMenu(url: url)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 40)
    }

    /// "kuvo-ai › Sources › App.swift".
    private var breadcrumb: Text {
        let base = URL(filePath: root)
        // A file outside the project shows under its own folder.
        let parts = url.path.hasPrefix(base.path + "/")
            ? [base.lastPathComponent] + url.path.dropFirst(base.path.count + 1).split(separator: "/").map(String.init)
            : [url.deletingLastPathComponent().lastPathComponent, url.lastPathComponent]
        var text = Text("")
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            if index > 0 { text = Text("\(text)\(Text("  ›  ").foregroundStyle(.tertiary))") }
            let partText = Text(part)
                .font(.system(size: 13, weight: isLast ? .semibold : .regular))
                .foregroundStyle(isLast ? .primary : .secondary)
            text = Text("\(text)\(partText)")
        }
        return text
    }

    /// Text up to 2 MB as text, pictures as pictures, the rest for Quick Look.
    private static func load(_ url: URL) async -> Content {
        await Task.detached { () -> Content in
            let type = UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .image) == true, let image = NSImage(contentsOf: url) { return .image(image) }
            if type?.conforms(to: .pdf) == true { return .preview }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size <= 2_000_000, let data = try? Data(contentsOf: url), !data.contains(0),
               let text = String(data: data, encoding: .utf8) {
                return .text(text)
            }
            return .preview
        }.value
    }
}

/// "Open" in the file's default app, with the other apps that open it a click away.
private struct OpenMenu: View {
    let url: URL

    var body: some View {
        let workspace = NSWorkspace.shared
        let defaultApp = workspace.urlForApplication(toOpen: url)
        Menu {
            ForEach(workspace.urlsForApplications(toOpen: url).prefix(10), id: \.self) { app in
                Button {
                    workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                } label: {
                    Label {
                        Text(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""))
                    } icon: {
                        Image(nsImage: workspace.icon(forFile: app.path))
                    }
                }
            }
            Divider()
            Button("Show in Finder") { workspace.activateFileViewerSelecting([url]) }
            Button("Copy Path") { copyPath(url) }
        } label: {
            HStack(spacing: 6) {
                if let defaultApp {
                    Image(nsImage: workspace.icon(forFile: defaultApp.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text("Open")
            }
        } primaryAction: {
            workspace.open(url)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .hoverHighlight(in: Capsule())
        .fixedSize()
        .help(defaultApp.map { "Open in \(FileManager.default.displayName(atPath: $0.path))" } ?? "Open")
    }
}

/// Quick Look, for anything the panel doesn't draw itself.
private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
