import SwiftUI

/// A small activity spinner drawn in SwiftUI, like the system's spoked one. `ProgressView` hosts an
/// AppKit view, which flies in from the window's corner when it appears during an animation (a tab
/// starting work while the tab strip animates); this one is laid out in place like any other view.
struct Spinner: View {
    var size: CGFloat = 11

    private static let spokes = 8
    private static let tick = 1.0 / 12

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.tick)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / Self.tick) % Self.spokes
            ZStack {
                ForEach(0..<Self.spokes, id: \.self) { index in
                    Capsule()
                        .fill(.secondary)
                        .frame(width: size * 0.14, height: size * 0.3)
                        .offset(y: -size * 0.33)
                        .rotationEffect(.degrees(Double(index) * 360 / Double(Self.spokes)))
                        .opacity(opacity(index, step: step))
                }
            }
            .frame(width: size, height: size)
        }
        .accessibilityLabel("Working")
    }

    /// The spoke at `step` is the brightest; the ones behind it fade.
    private func opacity(_ index: Int, step: Int) -> Double {
        let behind = (step - index + Self.spokes) % Self.spokes
        return 1 - Double(behind) * 0.1
    }
}
