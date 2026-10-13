import SwiftUI

/// The window's building block: a rounded pane floating on the window's glass,
/// with a header (icon, title, actions) and content. The focused card is solid;
/// the others are slightly frosted, but stay opaque enough to read over any
/// wallpaper (a grey one turned 55% white into a muddy grey).
struct Card<Icon: View, Actions: View, Content: View>: View {
    var title: String
    var detail: String?
    var isFocused = true
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                icon()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(isFocused ? .primary : .secondary)
                HStack(spacing: 0) {
                    Text(title)
                    if let detail {
                        Text(" | " + detail)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isFocused ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    actions()
                }
                .buttonStyle(CardActionStyle())
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 38)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(fill, in: .rect(cornerRadius: Metrics.cardRadius))
        .overlay {
            // Dark mode: a glassy highlight, brighter at the top edge. Light mode: a dark
            // hairline, since a white edge vanishes against white.
            RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .strokeBorder(
                    scheme == .dark
                        ? AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(Color.black.opacity(isFocused ? 0.09 : 0.07)),
                    lineWidth: 1
                )
        }
        .clipShape(.rect(cornerRadius: Metrics.cardRadius))
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : (isFocused ? 0.1 : 0.04)), radius: isFocused ? 12 : 4, y: isFocused ? 4 : 1)
        .animation(.ui, value: isFocused)
    }

    private var fill: Color {
        switch (scheme, isFocused) {
        case (.dark, true): Color(white: 0.21, opacity: 0.92)
        case (.dark, false): Color(white: 0.19, opacity: 0.8)
        case (_, true): Color.white
        case (_, false): Color(white: 0.965, opacity: 0.94)
        }
    }
}

extension Card where Actions == EmptyView {
    init(title: String, detail: String? = nil, isFocused: Bool = true, @ViewBuilder icon: @escaping () -> Icon, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, detail: detail, isFocused: isFocused, icon: icon, actions: { EmptyView() }, content: content)
    }
}

/// The quiet glyph buttons in a card header (split, expand, close).
struct CardActionStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(isHovering ? .primary : .tertiary)
            .frame(width: 26, height: 24)
            .background(isHovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(.rect)
            .onHover { isHovering = $0 }
    }
}
