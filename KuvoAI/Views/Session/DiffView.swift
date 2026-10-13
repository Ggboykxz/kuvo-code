import OpenCodeKit
import SwiftUI

/// A unified diff, colored by line.
struct DiffView: View {
    let diff: FileDiff
    var title: String
    /// Long diffs are cut here, with a note.
    var maxLines = Int.max

    private struct Line: Identifiable {
        let id: Int
        let text: String
        let kind: Kind
        enum Kind { case added, removed, hunk, context }
    }

    private var lines: [Line] {
        diff.patch
            .split(separator: "\n", omittingEmptySubsequences: false)
            .drop { !$0.hasPrefix("@@") } // file headers (---/+++ and git metadata)
            .enumerated()
            .map { index, raw in
                let kind: Line.Kind = raw.hasPrefix("@@") ? .hunk : raw.hasPrefix("+") ? .added : raw.hasPrefix("-") ? .removed : .context
                return Line(id: index, text: String(raw), kind: kind)
            }
    }

    var body: some View {
        let lines = lines
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: diff.status == .added ? "doc.badge.plus" : diff.status == .deleted ? "doc.badge.minus" : "doc")
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                DiffStat(additions: diff.additions, deletions: diff.deletions)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.prefix(maxLines)) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.transcriptCode)
                            .foregroundStyle(foreground(line.kind))
                            .padding(.horizontal, 12)
                            .padding(.vertical, line.kind == .hunk ? 4 : 0.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // An explicit rectangle: a bare colour background follows the
                            // container's rounded shape on macOS 26, giving each line pill ends.
                            .background(Rectangle().fill(background(line.kind)))
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
            }
            if lines.count > maxLines {
                Text("\(lines.count - maxLines) more lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }

    private func foreground(_ kind: Line.Kind) -> Color {
        switch kind {
        case .hunk: .secondary
        default: .primary
        }
    }

    private func background(_ kind: Line.Kind) -> Color {
        switch kind {
        case .added: Color.additions.opacity(0.14)
        case .removed: Color.deletions.opacity(0.14)
        case .hunk: Color.accentColor.opacity(0.07)
        case .context: .clear
        }
    }
}
