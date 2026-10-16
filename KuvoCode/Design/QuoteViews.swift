import SwiftUI

/// Over the composer: what you're replying to, shortened, with a way to drop it.
struct QuoteCard: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule()
                .fill(.tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Don’t Reply to This", systemImage: "xmark", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .help("Drop the quote")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .recessedWell(RoundedRectangle(cornerRadius: 10))
    }
}

/// In a message you sent: what it replied to, above your words.
struct QuoteBlock: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule()
                .fill(.secondary.opacity(0.45))
                .frame(width: 3)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
