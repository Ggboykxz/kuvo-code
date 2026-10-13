import SwiftUI

/// Shared measurements, so spacing and shapes stay consistent and nest concentrically.
enum Metrics {
    /// The transcript and composer column. Long lines are hard to read.
    static let readableWidth: CGFloat = 760
    static let composerRadius: CGFloat = 24
    static let cardRadius: CGFloat = 14
    /// Space between cards, and between cards and the window's edge.
    static let paneGap: CGFloat = 8
    static let bubbleRadius: CGFloat = 18
    static let gutter: CGFloat = 20
}

extension Animation {
    /// The app's default motion: quick, with a little give.
    static let ui = Animation.spring(response: 0.32, dampingFraction: 0.86)
}

extension Font {
    static let transcript = Font.system(size: 14)
    static let transcriptCode = Font.system(size: 12.5, design: .monospaced)
}

extension Color {
    static let additions = Color(nsColor: .systemGreen)
    static let deletions = Color(nsColor: .systemRed)
}

/// A small dot that pulses while something is working.
struct ActivityDot: View {
    var color: Color = .accentColor
    var size: CGFloat = 7
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(color.opacity(0.35))
                    .scaleEffect(pulse ? 2.4 : 1)
                    .opacity(pulse ? 0 : 1)
            }
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

/// Text that shimmers while the agent is working ("Thinking…").
struct ShimmerText: View {
    let text: String
    @State private var phase: CGFloat = -1

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(colors: [.clear, .primary.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width * 1.2)
                }
                .mask(Text(text))
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
    }
}

/// `+12 −3`, in diff colors.
struct DiffStat: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            if additions > 0 { Text("+\(additions)").foregroundStyle(Color.additions) }
            if deletions > 0 { Text("−\(deletions)").foregroundStyle(Color.deletions) }
        }
        .font(.caption.monospacedDigit().weight(.medium))
    }
}

extension View {
    /// Centers content in the readable column.
    func readableColumn() -> some View {
        frame(maxWidth: Metrics.readableWidth).frame(maxWidth: .infinity)
    }
}

extension Double {
    /// "$0.42", "<$0.01", or nothing for free.
    var formattedCost: String? {
        guard self > 0 else { return nil }
        return self < 0.01 ? "<$0.01" : formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}

extension Int {
    /// 950, 12.4k, 1.2M
    var compactTokens: String {
        formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }
}
