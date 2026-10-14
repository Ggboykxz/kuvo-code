import AppKit
import SwiftUI
import Textual

/// GitHub's code blocks, with a copy button in the corner that shows under the pointer.
/// It's an overlay, so the block doesn't move when it appears.
struct CopyableCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        CopyableCodeBlock(configuration: configuration)
    }
}

private struct CopyableCodeBlock: View {
    let configuration: StructuredText.CodeBlockStyleConfiguration
    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false
    @State private var copied = false

    var body: some View {
        Overflow {
            configuration.label
                .textual.lineSpacing(.fontScaled(0.225))
                .textual.fontScale(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .monospaced()
                .padding(16)
        }
        // GitHub's secondary background, as its own style uses.
        .background(scheme == .dark ? Color(red: 37 / 255, green: 38 / 255, blue: 42 / 255) : Color(red: 247 / 255, green: 247 / 255, blue: 249 / 255))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) {
            Button {
                configuration.codeBlock.copyToPasteboard()
                withAnimation(.ui) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(.ui) { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 26, height: 24)
                    .background(.background.opacity(0.85), in: .rect(cornerRadius: 6))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(copied ? "Copied" : "Copy Code")
            .padding(6)
            .opacity(isHovering || copied ? 1 : 0)
        }
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }
        .textual.blockSpacing(.init(top: 0, bottom: 16))
    }
}
