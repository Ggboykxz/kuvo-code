import OpenCodeKit
import AppKit
import SwiftUI

/// A message you sent, in a session or a group chat: its bubble, and under the pointer when it
/// went and what you can do with it (Copy, Undo From Here, and New Session From Here in a
/// session), which a right-click offers too.
struct YourMessage: View {
    let text: String
    /// Words with styling of their own (a group chat's mentions).
    var style: ((String) -> AttributedString?)?
    var attachments: [AttachmentItem] = []
    var comments: [ReviewComment] = []
    let sent: Date
    /// A new session from here, in a session.
    var fork: (() -> Void)?
    let undo: () -> Void
    /// What undoing does, in its confirmation.
    let undoNote: String
    /// Its engine out of reach: what needs it waits.
    var isOffline = false
    @State private var hovering = false
    @State private var confirmsUndo = false

    /// Under the pointer; KUVO_DEMO_SHOW_HOVER shows every message's buttons, for screenshots.
    private var isHovering: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["KUVO_DEMO_SHOW_HOVER"] != nil { return true }
        #endif
        return hovering
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            UserBubble(text: text, style: style, attachments: attachments, comments: comments)
            // Always laid out, shown under the pointer: nothing moves when they appear.
            HStack(spacing: 0) {
                Text(MessageTime.sentAt(sent))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 6)
                if !text.isEmpty {
                    CopyButton(text: text, help: "Copy")
                }
                if let fork {
                    MessageActionButton(symbol: "arrow.triangle.branch", help: "New Session From Here", action: fork)
                        .disabled(isOffline)
                }
                MessageActionButton(symbol: "arrow.uturn.backward", help: "Undo From Here…") { confirmsUndo = true }
                    .disabled(isOffline)
            }
            .opacity(isHovering ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") {
                Clipboard.copy(text)
            }
            .disabled(text.isEmpty)
            Divider()
            if let fork {
                Button("New Session From Here", action: fork)
                    .disabled(isOffline)
            }
            Button("Undo From Here…") { confirmsUndo = true }
                .disabled(isOffline)
        }
        .alert("Undo from this message?", isPresented: $confirmsUndo) {
            Button("Undo", action: undo)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(undoNote)
        }
    }
}

/// Rename Session, with its title to change, wherever a session can be renamed (its row, its tab,
/// the command palette).
struct RenameSession: ViewModifier {
    @Binding var session: Session?
    @Environment(Workspace.self) private var workspace
    @State private var title = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: session?.id) { title = session?.title ?? "" }
            .alert("Rename Session", isPresented: Binding(get: { session != nil }, set: { if !$0 { session = nil } })) {
                TextField("Title", text: $title)
                Button("Rename") {
                    if let session { Task { await workspace.rename(session.id, to: title) } }
                }
                Button("Cancel", role: .cancel) {}
            }
    }
}
