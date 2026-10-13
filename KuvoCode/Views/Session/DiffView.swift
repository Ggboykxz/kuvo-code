import OpenCodeKit
import SwiftUI

/// A short diff in a card, for a tool call or a permission request: the same lines,
/// numbers and colors as the Changes panel, without folding or comments.
struct DiffView: View {
    let diff: FileDiff
    var title: String
    /// Long diffs are cut here, with a note.
    var maxLines = Int.max

    @State private var highlighting: DiffHighlighting?

    private var file: ChangedFile { DiffParser.file(from: diff, directory: "/") }

    var body: some View {
        let file = file
        let shown = Array(file.lines.prefix(maxLines))
        let gutter = DiffLineRow.gutterWidth(for: shown)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: diff.status == .added ? "doc.badge.plus" : diff.status == .deleted ? "doc.badge.minus" : "doc")
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                DiffStat(additions: diff.additions, deletions: diff.deletions)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                    if line.gapBefore, index > 0 {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, gutter / 2)
                            .frame(height: 18)
                    }
                    DiffLineRow(line: line, runs: highlighting?.runs(for: line, at: index), gutterWidth: gutter)
                }
            }
            .padding(.vertical, 4)
            .textSelection(.enabled)

            if file.lines.count > maxLines {
                Text("\(file.lines.count - maxLines) more lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
        .task(id: diff) {
            var named = file
            named.path = diff.file
            highlighting = await DiffHighlighting.make(for: named)
        }
    }
}
