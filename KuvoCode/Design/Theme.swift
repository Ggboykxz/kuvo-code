import AppKit
import SwiftUI

/// Shared measurements, so spacing and shapes stay consistent and nest concentrically.
enum Metrics {
    /// The transcript and composer column. Long lines are hard to read.
    static let readableWidth: CGFloat = 760
    static let composerRadius: CGFloat = 14
    static let cardRadius: CGFloat = 14
    /// A card's header bar: icon, title and actions.
    static let cardHeaderHeight: CGFloat = 38
    /// The window's close, minimize and zoom buttons, with the tab bar hidden: the sidebar
    /// leaves this much above its first row for them, so they read as the list's first row.
    static let windowControlsHeight: CGFloat = 26
    /// Space between cards, and between cards and the window's edge.
    static let paneGap: CGFloat = 8
    static let bubbleRadius: CGFloat = 18
    static let gutter: CGFloat = 20
}

extension Animation {
    /// The app's default motion: quick, with a little give.
    static let ui: Animation = {
        #if DEBUG
        // KUVO_DEMO_SLOW=<times>: slower, to look at a transition frame by frame.
        if let slow = ProcessInfo.processInfo.environment["KUVO_DEMO_SLOW"].flatMap(Double.init) {
            return .spring(response: 0.32 * slow, dampingFraction: 0.86)
        }
        #endif
        return .spring(response: 0.32, dampingFraction: 0.86)
    }()
}

extension Color {
    static let additions = Color(nsColor: .systemGreen)
    static let deletions = Color(nsColor: .systemRed)
}

/// Text that shimmers while the agent is working ("Thinking…"): a light sweeping across it,
/// played by Core Animation (as a SwiftUI animation, three on screen took a tenth of a core,
/// even with the window hidden).
struct ShimmerText: View {
    let text: String
    @Environment(\.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .overlay {
                if !reduceMotion {
                    // Its letters, as they're set here, are where the light shows.
                    ShimmerSweep(letters: Text(text).environment(\.self, environment))
                }
            }
    }
}

private struct ShimmerSweep<Letters: View>: NSViewRepresentable {
    let letters: Letters
    @Environment(\.displayScale) private var scale

    func makeNSView(context: Context) -> ShimmerView { ShimmerView() }

    func updateNSView(_ view: ShimmerView, context: Context) {
        let renderer = ImageRenderer(content: letters)
        renderer.scale = scale
        view.show(renderer.cgImage, scale: scale)
    }
}

private final class ShimmerView: NSView {
    /// Shows only where the letters are; the light moves inside it.
    private let lit = CALayer()
    private let letters = CALayer()
    private let sweep = CAGradientLayer()
    private var image: CGImage?
    private static let cycle = 1.6

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(lit)
        lit.mask = letters
        lit.addSublayer(sweep)
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ image: CGImage?, scale: CGFloat) {
        guard image?.width != self.image?.width || image?.height != self.image?.height || self.image == nil else { return }
        self.image = image
        letters.contents = image
        letters.contentsScale = scale
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            sweep.colors = [NSColor.clear.cgColor, NSColor.labelColor.withAlphaComponent(0.9).cgColor, NSColor.clear.cgColor]
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let width = bounds.width, height = bounds.height
        lit.frame = bounds
        let scale = max(letters.contentsScale, 1)
        let size = image.map { CGSize(width: CGFloat($0.width) / scale, height: CGFloat($0.height) / scale) } ?? bounds.size
        letters.frame = CGRect(x: 0, y: (height - size.height) / 2, width: size.width, height: size.height)
        viewDidChangeEffectiveAppearance()
        // The light, six tenths as wide as the text, from well before it to just past it.
        sweep.frame = CGRect(x: 0, y: 0, width: width * 0.6, height: height)
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = -1.2 * width + width * 0.3
        animation.toValue = 1.44 * width + width * 0.3
        animation.duration = Self.cycle
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        // In step with every other one on screen.
        let now = CACurrentMediaTime()
        animation.beginTime = sweep.convertTime(now, from: nil) - now.truncatingRemainder(dividingBy: Self.cycle)
        sweep.add(animation, forKey: "sweep")
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
