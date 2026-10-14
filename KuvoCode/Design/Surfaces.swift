import SwiftUI

/// The window's materials in one place: the light the canvas carries, the cards' fills, the lit
/// edges that stand in for gray borders, the accent glass that marks what's yours or selected,
/// and the recessed well code sits in.
///
/// Glass over flat gray reads as muddy gray, so the canvas carries a faint warm-to-cool light
/// for the glass to pick up, and edges are lit (a bright rim along the top and a hairline
/// outside) instead of drawn with dark strokes.
enum Surface {
    /// Slate, for hairlines and wells: a cool near-black reads cleaner than gray on white.
    static let slate = Color(red: 15 / 255, green: 23 / 255, blue: 42 / 255)

    /// The hairline just outside a card, pill or bubble.
    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black.opacity(0.45) : slate.opacity(0.07)
    }

    /// The lit top edge of a raised surface.
    static func highlight(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.13) : .white.opacity(0.8)
    }

    /// The tint over the window's behind-window glass, solid enough that other windows behind
    /// don't show as shapes. Dark mode lets the desktop's color through; light mode is a warm
    /// ivory with only a hint of it, since a dark wallpaper under thin glass turned the sidebar
    /// a murky olive gray beside the white cards.
    static func canvasTint(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(white: 0.06, opacity: 0.25)
            : Color(red: 0xF6 / 255, green: 0xF4 / 255, blue: 0xEE / 255).opacity(0.86)
    }

    /// The canvas's ambient light: warm from the top left, cool toward the bottom right, a few
    /// percent each, so the glass has some color to refract even over a gray desktop.
    static func ambient(_ scheme: ColorScheme) -> LinearGradient {
        let warm = Color(red: 1, green: 0.62, blue: 0.42)
        let cool = Color(red: 0.42, green: 0.55, blue: 1)
        let strength = scheme == .dark ? 0.06 : 0.07
        return LinearGradient(
            stops: [
                .init(color: warm.opacity(strength), location: 0),
                .init(color: warm.opacity(strength * 0.25), location: 0.4),
                .init(color: cool.opacity(strength * 0.25), location: 0.6),
                .init(color: cool.opacity(strength), location: 1),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The focused card is crisp (white in light mode, a deep cool gray in dark); the others are
    /// a warm ivory (a lighter cool gray in dark), which separates them without heavier borders.
    static func cardFill(_ scheme: ColorScheme, focused: Bool) -> Color {
        Color(nsColor: cardFillColor(dark: scheme == .dark, focused: focused))
    }

    /// The card's fill as one solid color, for content that paints its own background (the
    /// terminal) and has to blend into its card.
    static func cardFillColor(dark: Bool, focused: Bool) -> NSColor {
        switch (dark, focused) {
        case (true, true): NSColor(srgbRed: 0.094, green: 0.102, blue: 0.122, alpha: 1)
        case (true, false): NSColor(srgbRed: 0.125, green: 0.133, blue: 0.157, alpha: 1)
        case (false, true): .white
        case (false, false): NSColor(srgbRed: 0.976, green: 0.969, blue: 0.945, alpha: 1)
        }
    }

    /// The accent glass's fill: a soft wash of the accent color.
    static func accentWash(_ scheme: ColorScheme) -> Color {
        Color.accentColor.opacity(scheme == .dark ? 0.22 : 0.1)
    }

    /// The fill of a recessed well, like a code block, a step below the card.
    static func well(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black.opacity(0.3) : slate.opacity(0.035)
    }

    /// The well's inner border.
    static func wellBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.07) : slate.opacity(0.07)
    }
}

extension View {
    /// A lit edge in place of a gray border: a bright highlight along the top that fades down
    /// the sides, and a hairline just outside. Apply after any clip, so the hairline shows.
    func specularRim<S: InsettableShape>(_ shape: S, strength: Double = 1) -> some View {
        modifier(SpecularRim(shape: shape, strength: strength))
    }

    /// Accent glass, for what's yours or selected (your messages, the selected row, the send
    /// button): a soft accent wash with a luminous edge, white at the top into the accent.
    func accentGlass<S: InsettableShape>(_ shape: S, isOn: Bool = true) -> some View {
        modifier(AccentGlass(shape: shape, isOn: isOn))
    }

    /// A text field drawn into the surface: sunken, with no bezel and no focus outline, like the
    /// sidebar's search. For fields outside a grouped form (a form's own fields stay native).
    func wellField(cornerRadius: CGFloat = 10) -> some View {
        modifier(WellField(cornerRadius: cornerRadius))
    }

    /// A recessed well, one step below the card, with a subtle inner border: for code.
    func recessedWell<S: InsettableShape>(_ shape: S) -> some View {
        modifier(RecessedWell(shape: shape))
    }
}

private struct SpecularRim<S: InsettableShape>: ViewModifier {
    let shape: S
    let strength: Double
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let light = Surface.highlight(scheme).opacity(strength)
        content
            .overlay {
                shape
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: light, location: 0),
                                .init(color: light.opacity(0.3), location: 0.12),
                                .init(color: .clear, location: 0.45),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .inset(by: -0.5)
                    .strokeBorder(Surface.hairline(scheme).opacity(strength), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

private struct AccentGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let isOn: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background {
                if isOn { shape.fill(Surface.accentWash(scheme)) }
            }
            .overlay {
                if isOn {
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(scheme == .dark ? 0.2 : 0.85),
                                    Color.accentColor.opacity(scheme == .dark ? 0.4 : 0.25),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct WellField: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Surface.well(scheme), in: .rect(cornerRadius: cornerRadius))
    }
}

private struct RecessedWell<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(Surface.well(scheme), in: shape)
            .overlay {
                shape
                    .strokeBorder(Surface.wellBorder(scheme), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

extension EnvironmentValues {
    /// Whether the card this view is in is the focused one, for opaque fills inside it (a pinned
    /// header, the terminal) that have to match the card's own.
    @Entry var cardIsFocused = true
}
