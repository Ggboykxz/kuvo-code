import SwiftUI

/// Find in the conversation: the words, which match is in view, and a way through them.
/// Return goes to the next match, Shift-Return to the previous, Escape closes.
struct FindBar: View {
    @Binding var query: String
    let current: Int
    let count: Int
    /// Reading what came before, to look in it too.
    var isSearchingEarlier = false
    /// The conversation goes back further than what's been read: a way to look there too.
    var searchEarlier: (() -> Void)?
    let step: (Int) -> Void
    let close: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in Conversation", text: $query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .frame(width: 220)
                .onKeyPress(.return, phases: .down) { press in
                    step(press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }
                .onExitCommand(perform: close)
            if !query.isEmpty {
                Text(count == 0 ? "No matches" : "\(current + 1) of \(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                if isSearchingEarlier {
                    Spinner(size: 11)
                } else if let searchEarlier {
                    Button("Search Earlier", action: searchEarlier)
                        .buttonStyle(.borderless)
                        .font(.callout.weight(.medium))
                        .help("Read the rest of the conversation, from its start, and look in it too")
                }
            }
            Button("Previous", systemImage: "chevron.up") { step(-1) }
                .buttonStyle(CardActionStyle())
                .disabled(count == 0)
                .help("Previous Match (⇧Return)")
            Button("Next", systemImage: "chevron.down") { step(1) }
                .buttonStyle(CardActionStyle())
                .disabled(count == 0)
                .help("Next Match (Return)")
            Button("Done", action: close)
                .buttonStyle(.borderless)
                .font(.callout.weight(.medium))
        }
        .font(.callout)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .onAppear { isFocused = true }
    }
}
