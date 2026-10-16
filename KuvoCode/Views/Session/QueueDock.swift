import OpenCodeKit
import SwiftUI

/// Messages waiting for the agent, on the composer: those for its next step, then the queue,
/// in the order it gets them. Each can go now, come back to the composer for editing, or be
/// removed. A long queue scrolls.
struct QueueDock: View {
    let model: SessionModel

    private static let rowHeight: CGFloat = 30
    private static let visibleRows = 5

    var body: some View {
        let items = model.waiting
        let isPaused = model.isQueuePaused && !model.isRunning
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(items.count) waiting" + (isPaused ? " · Paused" : ""))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if isPaused {
                    Button("Resume", systemImage: "play.fill", action: model.resumeQueue)
                        .font(.system(size: 12, weight: .medium))
                        .buttonStyle(.borderless)
                        .help("Send the waiting messages, one after another")
                }
            }
            .frame(height: 22)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        QueueRow(item: item, position: position(of: item, at: index, in: items), isRunning: model.isRunning, model: model)
                            .frame(height: Self.rowHeight)
                    }
                }
            }
            .frame(height: CGFloat(min(items.count, Self.visibleRows)) * Self.rowHeight)
            .scrollBounceBehavior(.basedOnSize)
            .animation(.ui, value: items.map(\.id))
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// Where a queued message stands in the queue: 1 goes first.
    private func position(of item: Transcript.Pending, at index: Int, in items: [Transcript.Pending]) -> Int? {
        guard item.delivery == .queue else { return nil }
        return items[...index].filter { $0.delivery == .queue }.count
    }
}

private struct QueueRow: View {
    let item: Transcript.Pending
    /// In the queue; nil for a message going in at the next step.
    let position: Int?
    let isRunning: Bool
    let model: SessionModel

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let position {
                    Text("\(position)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                } else {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(.tertiary)
            .frame(width: 18)
            .help(position == nil ? "The agent gets this at its next step" : "Sent after the current run, in this order")

            Text(summary)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if item.isLocal {
                Spinner(size: 10)
                    .frame(width: 26 * 3, alignment: .trailing)
                    .help("Sending…")
            } else {
                Button("Send Now", systemImage: "arrow.up") { model.sendNow(item) }
                    .buttonStyle(CardActionStyle())
                    .help(isRunning ? "Send Now: the agent stops its current step and takes this message" : "Send Now")
                Button("Edit", systemImage: "pencil") { model.edit(item) }
                    .buttonStyle(CardActionStyle())
                    .help("Edit: back to the message field (↑ edits the last one)")
                Button("Remove", systemImage: "xmark") { model.cancelPending(item) }
                    .buttonStyle(CardActionStyle())
                    .help("Remove")
            }
        }
        .contentShape(.rect)
        .onTapGesture(count: 2) { model.edit(item) }
        .contextMenu {
            Button("Send Now") { model.sendNow(item) }
            Button("Edit") { model.edit(item) }
            Divider()
            Button("Remove", role: .destructive) { model.cancelPending(item) }
        }
        .disabled(item.isLocal)
    }

    /// The message's first line, or what's attached when there's no text.
    private var summary: String {
        let (withComments, paths) = Attachments.split(item.text)
        let (text, comments) = ReviewComments.split(withComments)
        if let line = text.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return String(line)
        }
        let names = item.files.map(\.lastPathComponent) + paths.map { ($0 as NSString).lastPathComponent }
        if !names.isEmpty { return names.joined(separator: ", ") }
        return comments.isEmpty ? "" : comments.count.counting("comment")
    }
}
