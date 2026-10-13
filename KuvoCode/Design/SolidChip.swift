import SwiftUI

/// A solid surface for small controls that sit on glass: the composer's mode and model
/// chips, the account logos. See-through chips on see-through glass lose their edges in
/// light mode, so these are opaque with a hairline.
struct SolidChip<S: InsettableShape>: ViewModifier {
    let shape: S
    /// Tints the fill (Plan mode's orange) while keeping it opaque.
    var tint: Color?
    /// White in light mode, for logos, instead of the grey that reads as a button.
    var raised = false

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(edge, lineWidth: 0.5))
    }

    private var fill: Color {
        let base: Color = switch (scheme, raised) {
        case (.dark, false): Color(white: 0.29)
        case (.dark, true): Color(white: 0.33)
        case (_, false): Color(white: 0.925)
        case (_, true): .white
        }
        guard let tint else { return base }
        return base.mix(with: tint, by: scheme == .dark ? 0.3 : 0.2)
    }

    private var edge: Color {
        scheme == .dark ? .white.opacity(0.1) : .black.opacity(raised ? 0.14 : 0.08)
    }
}

extension View {
    func solidChip<S: InsettableShape>(in shape: S, tint: Color? = nil, raised: Bool = false) -> some View {
        modifier(SolidChip(shape: shape, tint: tint, raised: raised))
    }
}
