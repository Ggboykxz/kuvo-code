import SwiftUI

/// A solid surface for small controls that sit on glass, like the composer's mode and
/// model pills. See-through chips on see-through glass lose their edges in light mode,
/// so these are opaque (white in light mode) with a hairline.
struct SolidChip<S: InsettableShape>: ViewModifier {
    let shape: S
    /// Tints the fill (Plan mode's orange) while keeping it opaque.
    var tint: Color?

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(edge, lineWidth: 0.5))
    }

    private var fill: Color {
        let base: Color = scheme == .dark ? Color(white: 0.33) : .white
        guard let tint else { return base }
        return base.mix(with: tint, by: scheme == .dark ? 0.3 : 0.2)
    }

    private var edge: Color {
        scheme == .dark ? .white.opacity(0.1) : .black.opacity(0.14)
    }
}

extension View {
    func solidChip<S: InsettableShape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(SolidChip(shape: shape, tint: tint))
    }
}
