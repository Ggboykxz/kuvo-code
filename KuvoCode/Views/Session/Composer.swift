import OpenCodeKit
import SwiftUI
import UniformTypeIdentifiers

/// Where you talk to the agent: a floating glass panel with the message field,
/// the mode (Build/Plan) and model pickers, and a send button that turns into
/// Stop while the agent works.
struct Composer: View {
    @Binding var text: String
    @Binding var files: [URL]
    let agent: String
    let approval: ToolApproval
    let model: ModelRef?
    let isRunning: Bool
    /// Messages are waiting their turn, so ⌘Return adds to the queue even while idle.
    var hasQueue = false
    /// Messages sent before, oldest first: ↑ and ↓ go through them, as in a shell.
    var history: [String] = []
    /// The project's folders, the primary one first, for "@" mentions of their files.
    var folders: [String] = []
    /// Puts the cursor here when it changes.
    var focusRequest = 0
    /// Comments on the changes waiting to go with the next message.
    var commentCount = 0
    var onDiscardComments: () -> Void = {}
    var onSelectAgent: (String) -> Void
    var onSelectApproval: (ToolApproval) -> Void
    var onSelectModel: (ModelRef) -> Void
    var onSend: () -> Void
    /// ⌘Return: after the run, and anything queued before.
    var onQueue: () -> Void = {}
    /// ↑ in an empty composer brings back the last waiting message; false if there's none.
    var onEditLast: () -> Bool = { false }
    var onStop: () -> Void

    @Environment(Catalog.self) private var catalog
    @FocusState private var isFocused: Bool
    @Namespace private var glass
    @State private var isTargeted = false
    /// The sent message showing in the field, while going through them.
    @State private var historyIndex: Int?
    /// The project's files for "@", read when one is typed.
    @State private var mentionFiles: [ProjectFiles.File] = []
    @State private var mentionFilesRead: Date?
    @State private var mentionIndex = 0
    /// Where the "@" whose list was closed with Escape is, so it stays closed.
    @State private var dismissedMention: Int?

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty || commentCount > 0 }
    private var currentModel: Model? { catalog.model(model) ?? catalog.defaultModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let mention {
                MentionList(files: mention.matches, selected: min(mentionIndex, max(mention.matches.count - 1, 0))) { insertMention($0) }
            }
            if commentCount > 0 {
                Menu {
                    Button("Discard Comments", role: .destructive, action: onDiscardComments)
                } label: {
                    Label("\(commentCount) \(commentCount == 1 ? "comment" : "comments")", systemImage: "text.bubble")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: .capsule)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Your comments on the changes go with this message.")
            }
            if !files.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(files, id: \.self) { file in
                            ComposerAttachment(url: file, route: Attachments.route(file, for: currentModel)) { files.removeAll { $0 == file } }
                        }
                    }
                    // Room for each chip's remove button, which sits on its corner.
                    .padding(.top, 6)
                    .padding(.trailing, 6)
                }
                .scrollIndicators(.hidden)
            }

            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...12)
                .focused($isFocused)
                .onKeyPress(.return, phases: .down) { press in
                    if let mention, press.modifiers.isEmpty, !mention.matches.isEmpty {
                        insertMention(mention.matches[min(mentionIndex, mention.matches.count - 1)])
                        return .handled
                    }
                    // Return sends; Shift-Return starts a new line; ⌘Return queues.
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                        text += "\n"
                        return .handled
                    }
                    if press.modifiers.contains(.command) {
                        queue()
                        return .handled
                    }
                    send()
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard let mention, !mention.matches.isEmpty else { return .ignored }
                    insertMention(mention.matches[min(mentionIndex, mention.matches.count - 1)])
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard let start = Mentions.query(in: text)?.start, mention != nil else { return .ignored }
                    dismissedMention = text.distance(from: text.startIndex, to: start)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    if let mention, !mention.matches.isEmpty {
                        mentionIndex = max(0, min(mentionIndex, mention.matches.count - 1) - 1)
                        return .handled
                    }
                    // A waiting message comes back first; then what was sent before.
                    if text.isEmpty, files.isEmpty, historyIndex == nil, onEditLast() { return .handled }
                    return recall(-1) ? .handled : .ignored
                }
                .onKeyPress(.downArrow) {
                    if let mention, !mention.matches.isEmpty {
                        mentionIndex = min(mention.matches.count - 1, mentionIndex + 1)
                        return .handled
                    }
                    return recall(1) ? .handled : .ignored
                }
                // Editing a recalled message makes it a new one; the arrows move the cursor again.
                .onChange(of: text) { _, new in
                    if let index = historyIndex, !history.indices.contains(index) || new != history[index] { historyIndex = nil }
                    mentionTyped(in: new)
                }
                .onSubmit(send)

            HStack(spacing: 4) {
                Button(action: chooseFiles) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 28)
                        .hoverHighlight(in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Attach Files… You can also drop files here, or paste them.")
                ModeChip(agent: agent, approval: approval, onSelectAgent: onSelectAgent, onSelectApproval: onSelectApproval)
                ModelChip(selection: model, onSelect: onSelectModel)
                Spacer(minLength: 0)
                actionButton
            }
            // The pills are flat, so their text lines up with the message field above;
            // their hover fill reaches past it.
            .padding(.leading, -8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.composerRadius))
        // An edge and a soft lift, so it reads as a control and not as more of the page.
        .overlay(RoundedRectangle(cornerRadius: Metrics.composerRadius).strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: Metrics.composerRadius)
                    .strokeBorder(.tint, lineWidth: 2)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls.filter(\.isFileURL))
            return true
        } isTargeted: { isTargeted = $0 }
        .modifier(PasteAttachments(isActive: isFocused, attach: attach))
        .onChange(of: focusRequest) { isFocused = true }
        .onAppear {
            isFocused = true
            #if DEBUG
            // KUVO_DEMO_COMPOSER_FILES: comma-separated paths to show as attached.
            if files.isEmpty, let list = ProcessInfo.processInfo.environment["KUVO_DEMO_COMPOSER_FILES"] {
                files = list.split(separator: ",").map { URL(filePath: String($0)) }
            }
            #endif
        }
    }

    private var placeholder: String {
        isRunning ? "Add to the task, or ⌘↩ to queue a follow-up…" : agent == "plan" ? "Ask the agent to plan something…" : "Ask the agent to build, fix or explain something…"
    }

    @ViewBuilder private var actionButton: some View {
        GlassEffectContainer {
            if isRunning && !canSend {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .glassEffectID("action", in: glass)
                .help("Stop (⌘.)")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(!canSend)
                .glassEffectID("action", in: glass)
                .help(isRunning ? "Send: the agent reads it at its next step (Return). ⌘Return queues it for after this run." : "Send (Return)")
                .contextMenu {
                    Button("Send", action: send)
                    Button("Queue for After This Run", action: queue)
                        .disabled(!isRunning && !hasQueue)
                }
            }
        }
        .controlSize(.large)
        .animation(.ui, value: isRunning && !canSend)
    }

    private func send() {
        guard canSend else { return }
        onSend()
    }

    private func queue() {
        guard canSend else { return }
        onQueue()
    }

    /// The "@" being typed and the files it matches, while its list is open.
    private var mention: (query: String, matches: [ProjectFiles.File])? {
        guard !folders.isEmpty, let (query, start) = Mentions.query(in: text),
              text.distance(from: text.startIndex, to: start) != dismissedMention else { return nil }
        let matches = Mentions.matches(query, in: mentionFiles)
        return matches.isEmpty ? nil : (query, matches)
    }

    /// Reads the project's files on the first "@", and again when the list is a while old.
    private func mentionTyped(in text: String) {
        guard !folders.isEmpty, Mentions.query(in: text) != nil else {
            mentionIndex = 0
            return
        }
        guard mentionFilesRead.map({ Date().timeIntervalSince($0) > 30 }) ?? true else { return }
        mentionFilesRead = Date()
        let roots = folders.map { URL(filePath: $0) }
        Task { mentionFiles = await Task.detached { ProjectFiles.mentionable(roots) }.value }
    }

    private func insertMention(_ file: ProjectFiles.File) {
        text = Mentions.insert(file, into: text)
        mentionIndex = 0
    }

    /// ↑ from an empty field, or from a recalled message left as it was, goes back a message;
    /// ↓ comes forward, and past the newest clears the field again.
    private func recall(_ step: Int) -> Bool {
        guard !history.isEmpty else { return false }
        guard let index = historyIndex else {
            guard step < 0, text.isEmpty, files.isEmpty else { return false }
            historyIndex = history.count - 1
            text = history[history.count - 1]
            return true
        }
        let next = index + step
        if next < 0 { return true }
        if next >= history.count {
            historyIndex = nil
            text = ""
            return true
        }
        historyIndex = next
        text = history[next]
        return true
    }

    private func attach(_ urls: [URL]) {
        files += urls.filter { !files.contains($0) }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.message = "Choose files or folders to attach."
        guard panel.runModal() == .OK else { return }
        attach(panel.urls)
    }
}

/// The files an "@" matches, above the message field: the chosen one highlighted, any
/// one a click away.
private struct MentionList: View {
    let files: [ProjectFiles.File]
    let selected: Int
    let choose: (ProjectFiles.File) -> Void

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                Button { choose(file) } label: {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(file.isFolder ? String(file.path.dropLast()) : file.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        let folder = (file.path as NSString).deletingLastPathComponent
                        if !file.isFolder, !folder.isEmpty {
                            Text(folder)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(index == selected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, -8)
        .help("↑ ↓ to choose, Return or Tab to insert, Escape to close")
    }
}

/// ⌘V with files or a picture on the pasteboard attaches them, instead of pasting
/// their names (or nothing) into the message.
private struct PasteAttachments: ViewModifier {
    let isActive: Bool
    let attach: ([URL]) -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive, initial: true) { _, active in
                if active { install() } else { remove() }
            }
            .onDisappear(perform: remove)
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  let urls = Self.pastedFiles() else { return event }
            attach(urls)
            return nil
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func pastedFiles() -> [URL]? {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls
        }
        // A picture without text: a copied screenshot, an image copied from Preview.
        guard board.string(forType: .string) == nil, let image = NSImage(pasteboard: board) else { return nil }
        return Attachments.save(image, named: Attachments.pastedImageName).map { [$0] }
    }
}
