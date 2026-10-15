import OpenCodeKit
import SwiftUI

/// A command you ran with "!": a line like the agent's own steps, saying it was you, with what it
/// printed open under it.
struct ShellRow: View {
    let shell: Message.Shell
    @State private var isExpanded = true

    private static let iconWidth: CGFloat = 16
    private static let iconGap: CGFloat = 8

    private var output: String {
        shell.output?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if output.isEmpty {
                header.foregroundStyle(.secondary)
            } else {
                Button {
                    withAnimation(.ui) { isExpanded.toggle() }
                } label: {
                    header
                }
                .buttonStyle(TextButtonStyle(outset: true))
            }
            if isExpanded, !output.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    OutputBlock(text: output)
                    if shell.output?.truncated == true {
                        Text("Only the end is kept; it printed more.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, Self.iconWidth + Self.iconGap)
                .padding(.top, 8)
                .overlay(alignment: .topLeading) {
                    // The line down from the icon, beside what it opened.
                    Capsule()
                        .fill(.separator)
                        .frame(width: 1)
                        .padding(.top, 3)
                        .padding(.leading, (Self.iconWidth - 1) / 2)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contextMenu {
            Button("Copy Command") { copy(shell.command) }
            if !output.isEmpty { Button("Copy Output") { copy(output) } }
        }
    }

    private var header: some View {
        HStack(spacing: Self.iconGap) {
            Group {
                if shell.isRunning {
                    Spinner(size: 11)
                } else {
                    Image(systemName: "terminal")
                }
            }
            .frame(width: Self.iconWidth)
            Text((shell.isRunning ? "Running " : "You ran ") + "`\(shell.command)`")
                .lineLimit(1)
                .truncationMode(.middle)
            if let exit = shell.exit, exit != 0 {
                Text("exit \(exit)")
                    .foregroundStyle(.red)
            } else if ["timeout", "killed"].contains(shell.status) {
                Text(shell.status == "timeout" ? "timed out" : "stopped")
                    .foregroundStyle(.red)
            }
            if !output.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .contentShape(.rect)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
