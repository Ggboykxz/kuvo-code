import SwiftUI

extension EnvironmentValues {
    /// The bot whose conversation this is, if it's a bot's.
    @Entry var bot: Bot?
}

/// How a bot looks: a color, a shape and a face, picked when it's made and changed any time.
struct BotLook: Codable, Hashable {
    var color: Tint
    var shape: Form
    var face: Face

    enum Tint: String, CaseIterable, Codable, Identifiable {
        case mint, sky, indigo, violet, pink, coral, orange, amber, lime, graphite
        var id: String { rawValue }

        var color: Color {
            switch self {
            case .mint: Color(red: 0.37, green: 0.78, blue: 0.72)
            case .sky: Color(red: 0.31, green: 0.61, blue: 0.96)
            case .indigo: Color(red: 0.36, green: 0.36, blue: 0.94)
            case .violet: Color(red: 0.54, green: 0.36, blue: 0.96)
            case .pink: Color(red: 0.93, green: 0.44, blue: 0.71)
            case .coral: Color(red: 0.95, green: 0.45, blue: 0.36)
            case .orange: Color(red: 0.96, green: 0.60, blue: 0.24)
            case .amber: Color(red: 0.95, green: 0.76, blue: 0.31)
            case .lime: Color(red: 0.55, green: 0.80, blue: 0.31)
            case .graphite: Color(red: 0.43, green: 0.45, blue: 0.50)
            }
        }

        /// Deep colors get light eyes; the rest dark ones.
        var isDeep: Bool { [.indigo, .violet, .graphite].contains(self) }

        var title: String { rawValue.capitalized }
    }

    enum Form: String, CaseIterable, Codable, Identifiable {
        case round, squircle, pebble, gem, bloom
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum Face: String, CaseIterable, Codable, Identifiable {
        case calm, happy, sleepy, wink, curious, bright
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    static func random() -> BotLook {
        BotLook(color: Tint.allCases.randomElement()!, shape: Form.allCases.randomElement()!, face: Face.allCases.randomElement()!)
    }
}

/// A bot's face on its shape, at any size: in the sidebar, on its tab, in its header and, large,
/// where it's made.
struct BotAvatar: View {
    let look: BotLook
    var size: CGFloat = 26

    var body: some View {
        let tint = look.color.color
        BotShape(form: look.shape)
            .fill(LinearGradient(colors: [tint.mix(with: .white, by: 0.14), tint.mix(with: .black, by: 0.06)], startPoint: .top, endPoint: .bottom))
            // A lit top edge, like the window's other raised surfaces.
            .overlay {
                BotShape(form: look.shape)
                    .stroke(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0)], startPoint: .top, endPoint: .center), lineWidth: max(0.5, size / 40))
            }
            .overlay {
                BotFace(face: look.face, deep: look.color.isDeep)
                    .frame(width: size * 0.5, height: size * 0.3)
                    .offset(x: size * 0.04, y: faceOffset)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(size > 40 ? 0.12 : 0.08), radius: size / 24, y: size / 48)
    }

    /// The pebble's face sits low, where it's widest.
    private var faceOffset: CGFloat {
        switch look.shape {
        case .pebble: size * 0.12
        default: -size * 0.03
        }
    }
}

/// The bot's outline, filling the square it's given.
nonisolated struct BotShape: Shape {
    let form: BotLook.Form

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let box = CGRect(x: rect.midX - s / 2, y: rect.midY - s / 2, width: s, height: s)
        switch form {
        case .round:
            return Path(ellipseIn: box)
        case .squircle:
            return Path(roundedRect: box.insetBy(dx: s * 0.04, dy: s * 0.04), cornerRadius: s * 0.32, style: .continuous)
        case .pebble:
            // A triangle with soft corners, wide at the bottom. Its corners reach past the box,
            // and their rounding brings the outline back inside, as large as the others.
            return rounded([
                CGPoint(x: box.minX + s * 0.5, y: box.minY - s * 0.16),
                CGPoint(x: box.minX + s * 1.1, y: box.minY + s * 0.94),
                CGPoint(x: box.minX - s * 0.1, y: box.minY + s * 0.94),
            ], radius: s * 0.24)
        case .gem:
            return rounded([
                CGPoint(x: box.midX, y: box.minY - s * 0.08),
                CGPoint(x: box.maxX + s * 0.08, y: box.midY),
                CGPoint(x: box.midX, y: box.maxY + s * 0.08),
                CGPoint(x: box.minX - s * 0.08, y: box.midY),
            ], radius: s * 0.22)
        case .bloom:
            // A circle with eight soft scallops.
            var path = Path()
            let center = CGPoint(x: box.midX, y: box.midY)
            let steps = 96
            for step in 0...steps {
                let angle = Double(step) / Double(steps) * 2 * .pi
                let radius = s * (0.455 + 0.035 * cos(8 * angle))
                let point = CGPoint(x: center.x + radius * cos(angle - .pi / 2), y: center.y + radius * sin(angle - .pi / 2))
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            return path
        }
    }

    /// A polygon through `points` with every corner rounded.
    private func rounded(_ points: [CGPoint], radius: CGFloat) -> Path {
        var path = Path()
        let count = points.count
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: mid(points[count - 1], points[0]))
        for index in 0..<count {
            path.addArc(tangent1End: points[index], tangent2End: points[(index + 1) % count], radius: radius)
        }
        path.closeSubpath()
        return path
    }
}

/// Two eyes, drawn in the box they're given (twice as wide as tall), with an expression.
private struct BotFace: View {
    let face: BotLook.Face
    /// On a deep color: light eyes.
    let deep: Bool

    private var ink: Color { deep ? Color.white.opacity(0.92) : Color(red: 0.09, green: 0.1, blue: 0.13).opacity(0.86) }

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let eye = CGSize(width: w * 0.17, height: h * 0.62)
            let left = CGPoint(x: w * 0.27, y: h * 0.5), right = CGPoint(x: w * 0.73, y: h * 0.5)
            let line = max(1, w * 0.1)

            func oval(at center: CGPoint, scale: CGFloat = 1) {
                let rect = CGRect(x: center.x - eye.width * scale / 2, y: center.y - eye.height * scale / 2, width: eye.width * scale, height: eye.height * scale)
                context.fill(Path(ellipseIn: rect), with: .color(ink))
            }
            func arc(at center: CGPoint, up: Bool) {
                var path = Path()
                let half = eye.width * 1.15
                path.move(to: CGPoint(x: center.x - half, y: center.y + (up ? h * 0.12 : -h * 0.08)))
                path.addQuadCurve(
                    to: CGPoint(x: center.x + half, y: center.y + (up ? h * 0.12 : -h * 0.08)),
                    control: CGPoint(x: center.x, y: center.y + (up ? -h * 0.32 : h * 0.3))
                )
                context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: line, lineCap: .round))
            }
            func dash(at center: CGPoint) {
                var path = Path()
                path.move(to: CGPoint(x: center.x - eye.width * 1.1, y: center.y + h * 0.06))
                path.addLine(to: CGPoint(x: center.x + eye.width * 1.1, y: center.y + h * 0.14))
                context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: line, lineCap: .round))
            }

            switch face {
            case .calm:
                oval(at: left); oval(at: right)
            case .happy:
                arc(at: left, up: true); arc(at: right, up: true)
            case .sleepy:
                dash(at: left); dash(at: right)
            case .wink:
                oval(at: left); arc(at: right, up: true)
            case .curious:
                // Looking up and aside, one eye a little bigger.
                oval(at: CGPoint(x: left.x + w * 0.05, y: left.y - h * 0.1), scale: 0.9)
                oval(at: CGPoint(x: right.x + w * 0.05, y: right.y - h * 0.1), scale: 1.12)
            case .bright:
                for center in [left, right] {
                    let rect = CGRect(x: center.x - eye.width * 0.8, y: center.y - eye.width * 0.8, width: eye.width * 1.6, height: eye.width * 1.6)
                    context.fill(Path(ellipseIn: rect), with: .color(ink))
                    let shine = CGRect(x: center.x - eye.width * 0.05, y: center.y - eye.width * 0.55, width: eye.width * 0.5, height: eye.width * 0.5)
                    context.fill(Path(ellipseIn: shine), with: .color(deep ? .black.opacity(0.35) : .white.opacity(0.85)))
                }
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        ForEach(BotLook.Form.allCases) { form in
            HStack(spacing: 14) {
                ForEach(Array(BotLook.Face.allCases.enumerated()), id: \.offset) { index, face in
                    BotAvatar(look: BotLook(color: BotLook.Tint.allCases[(index + form.hashValue) % 10], shape: form, face: face), size: 48)
                }
            }
        }
    }
    .padding(30)
}
