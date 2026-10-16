import SwiftUI

/// Kuvo Code's loader: its prompt mark (the chevron and the cursor) drawing itself in short
/// dashes, over a faint copy of itself, then fading to start again. Quiet and in one ink, so it
/// sits in a row of text. Drawn in SwiftUI, not `ProgressView`, which hosts an AppKit view that
/// flies in from the window's corner when it appears during an animation.
struct Spinner: View {
    var size: CGFloat = 11
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive

    private static let cycle = 1.6

    var body: some View {
        Group {
            if reduceMotion {
                mark(chevron: 1, cursor: 1, opacity: 0.8)
            } else {
                TimelineView(.animation(minimumInterval: appearsActive ? 1.0 / 30 : 1.0 / 15, paused: !WindowVisibility.shared.isVisible)) { context in
                    let p = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.cycle) / Self.cycle
                    // The chevron draws, then the cursor; both hold a moment, then fade.
                    mark(chevron: eased((p - 0.0) / 0.4), cursor: eased((p - 0.32) / 0.28), opacity: p < 0.78 ? 1 : 1 - (p - 0.78) / 0.22)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Working")
    }

    private func mark(chevron: Double, cursor: Double, opacity: Double) -> some View {
        let width = size
        let height = size * PromptMark.aspect
        let line = max(1, size * 0.11)
        let style = StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round, dash: [line * 1.0, line * 1.8])
        return ZStack {
            // The whole mark, faintly, so its shape reads from the start.
            PromptMark(part: .chevron).stroke(.secondary.opacity(0.18), style: style)
            PromptMark(part: .cursor).stroke(.secondary.opacity(0.18), style: style)
            PromptMark(part: .chevron).trim(from: 0, to: chevron).stroke(.secondary, style: style)
            PromptMark(part: .cursor).trim(from: 0, to: cursor).stroke(.secondary, style: style)
        }
        .opacity(0.35 + 0.65 * opacity)
        .frame(width: width, height: height)
    }

    private func eased(_ x: Double) -> Double {
        let t = max(0, min(1, x))
        return t * t * (3 - 2 * t)
    }
}

/// The app icon's prompt, `>_`: its chevron or its cursor, in the box it's given.
nonisolated struct PromptMark: Shape {
    enum Part { case chevron, cursor }
    let part: Part

    /// Height over width of the two together.
    static let aspect: CGFloat = 530.0 / 690.0

    func path(in rect: CGRect) -> Path {
        // The icon's coordinates (scripts/icon.py), around the mark and its stroke.
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - 170) / 690 * rect.width, y: rect.minY + (y - 250) / 530 * rect.height)
        }
        var path = Path()
        switch part {
        case .chevron:
            path.move(to: point(247, 324))
            path.addLine(to: point(437, 512))
            path.addLine(to: point(247, 700))
        case .cursor:
            path.move(to: point(547, 700))
            path.addLine(to: point(777, 700))
        }
        return path
    }
}
