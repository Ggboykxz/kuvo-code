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
    var onSelectAgent: (String) -> Void
    var onSelectApproval: (ToolApproval) -> Void
    var onSelectModel: (ModelRef) -> Void
    var onSend: () -> Void
    var onStop: () -> Void

    @Environment(Catalog.self) private var catalog
    @FocusState private var isFocused: Bool
    @Namespace private var glass
    @State private var isTargeted = false

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty }
    private var currentModel: Model? { catalog.model(model) ?? catalog.defaultModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    // Return sends; Shift-Return starts a new line.
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                        text += "\n"
                        return .handled
                    }
                    send()
                    return .handled
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
        isRunning ? "Add to the task, or queue a follow-up…" : agent == "plan" ? "Ask the agent to plan something…" : "Ask the agent to build, fix or explain something…"
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
                .help(isRunning ? "Send now; the agent reads it at its next step" : "Send (Return)")
            }
        }
        .controlSize(.large)
        .animation(.ui, value: isRunning && !canSend)
    }

    private func send() {
        guard canSend else { return }
        onSend()
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
