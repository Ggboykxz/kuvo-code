import SwiftUI

/// The quotes you're answering, each with your answer under it: as tall as they are up to a
/// point, then they scroll, made as they come into view (there can be hundreds), with the
/// one you're answering in view.
struct QuoteList: View {
    @Binding var quotes: [Drafts.Quote]
    var answering: FocusState<UUID?>.Binding
    let focus: UUID?
    let font: Font
    let onSubmit: () -> Void
    /// How tall they are together, measured as they lay out.
    @State private var height: CGFloat = 0
    @State private var position = ScrollPosition(idType: UUID.self)

    private static let tallest: CGFloat = 260

    /// Your answer to a quote, found by its ID each time: a field on its way out (the quote was
    /// just dropped) reads nothing rather than a place in the list that's gone, which crashed.
    private func response(to id: UUID) -> Binding<String> {
        Binding(
            get: { quotes.first { $0.id == id }?.response ?? "" },
            set: { text in
                guard let index = quotes.firstIndex(where: { $0.id == id }) else { return }
                quotes[index].response = text
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if quotes.count > 2 {
                HStack {
                    Text("\(quotes.count) quotes")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove All") { withAnimation(.ui) { quotes.removeAll() } }
                        .buttonStyle(TextButtonStyle())
                        .font(.subheadline)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(quotes) { quote in
                        VStack(alignment: .leading, spacing: 6) {
                            QuoteCard(text: quote.text) {
                                let id = quote.id
                                withAnimation(.ui) { quotes.removeAll { $0.id == id } }
                            }
                            TextField("Your answer to this…", text: response(to: quote.id), axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(font)
                                .lineLimit(1...6)
                                .focused(answering, equals: quote.id)
                                .onSubmit(onSubmit)
                                .padding(.leading, 12)
                                .padding(.bottom, 4)
                        }
                        .id(quote.id)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                    }
                }
                .scrollTargetLayout()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .scrollPosition($position)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(height > Self.tallest ? .automatic : .never)
            // Taller than it shows: it fades out at the edges, rather than being cut there.
            .mask {
                let fade = height > Self.tallest ? 14 / Self.tallest : 0
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: fade),
                                       .init(color: .black, location: 1 - fade), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            // Its own height until it's measured, so it doesn't take the window's first.
            .frame(height: height == 0 ? nil : min(height, Self.tallest))
            .fixedSize(horizontal: false, vertical: height == 0)
            .onChange(of: focus, initial: true) { _, id in
                guard let id else { return }
                Task {
                    await Task.yield()
                    position.scrollTo(id: id)
                }
            }
        }
    }
}
