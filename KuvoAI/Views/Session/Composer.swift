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

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !files.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(files, id: \.self) { file in
                            AttachmentChip(url: file) { files.removeAll { $0 == file } }
                        }
                    }
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

            HStack(spacing: 8) {
                ModeChip(agent: agent, approval: approval, onSelectAgent: onSelectAgent, onSelectApproval: onSelectApproval)
                ModelChip(selection: model, onSelect: onSelectModel)
                Spacer(minLength: 0)
                actionButton
            }
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
            files += urls.filter { $0.isFileURL && !files.contains($0) }
            return true
        } isTargeted: { isTargeted = $0 }
        .onAppear { isFocused = true }
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
}

private struct AttachmentChip: View {
    let url: URL
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(.fill.tertiary, in: .capsule)
    }
}
