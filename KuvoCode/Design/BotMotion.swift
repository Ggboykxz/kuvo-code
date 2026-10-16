import AppKit
import QuartzCore
import SwiftUI

/// A bot moving, played by Core Animation. BotPose works out its motion over one cycle of its
/// mood, which goes to the window server as keyframes; it plays them on the GPU, so a moving bot
/// costs the app nothing from one frame to the next (moving in SwiftUI, a frame at a time, the
/// sidebar's bots at rest took a third of a core). Its pieces are pictures drawn once, by the
/// same views a still bot is drawn with.
struct BotMotion: NSViewRepresentable {
    let look: BotLook
    let size: CGFloat
    let mood: BotMood
    let noticed: Bool
    let seed: Double
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var scale

    func makeNSView(context: Context) -> BotMotionView { BotMotionView() }

    func updateNSView(_ view: BotMotionView, context: Context) {
        view.show(BotMotionView.Spec(look: look, size: size, mood: mood, noticed: noticed, seed: seed, scheme: scheme, scale: scale))
    }
}

final class BotMotionView: NSView {
    struct Spec: Equatable {
        var look: BotLook
        var size: CGFloat
        var mood: BotMood
        var noticed: Bool
        var seed: Double
        var scheme: ColorScheme
        var scale: CGFloat

        /// The same pictures do for both.
        func drawsLike(_ other: Spec) -> Bool {
            look == other.look && size == other.size && scheme == other.scheme && scale == other.scale
        }
    }

    private var spec: Spec?
    /// Laid out from the top left, as SwiftUI lays out the still bot.
    private let root = CALayer()
    private let glow = CALayer()
    /// The bot itself, which hops, leans and squashes from its base.
    private let figure = CALayer()
    private let body = CALayer()
    private let face = CALayer()
    /// Two sparks, five dots each, head first.
    private let dots = (0..<10).map { _ in CALayer() }
    private let zs = (0..<3).map { _ in CALayer() }
    private let star = CALayer()
    private var faces: [BotLook.Face: CGImage] = [:]

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        root.isGeometryFlipped = true
        root.masksToBounds = false
        layer?.addSublayer(root)
        for piece in [glow, figure, star] + zs { root.addSublayer(piece) }
        for piece in dots + [body, face] { figure.addSublayer(piece) }
        body.zPosition = 0
        face.zPosition = 0.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Clicks and the pointer go to what it's in (a row in the sidebar).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        CATransaction.commit()
    }

    func show(_ spec: Spec) {
        guard spec != self.spec else { return }
        let redraw = self.spec.map { !$0.drawsLike(spec) } ?? true
        self.spec = spec
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if redraw { draw(spec) }
        animate(spec)
        CATransaction.commit()
    }

    // MARK: Pictures

    private func draw(_ spec: Spec) {
        let size = spec.size
        let center = CGPoint(x: size / 2, y: size / 2)
        func picture(_ view: some View) -> CGImage? {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, spec.scheme))
            renderer.scale = spec.scale
            return renderer.cgImage
        }
        func place(_ layer: CALayer, _ image: CGImage?, at position: CGPoint) {
            layer.contents = image
            layer.contentsScale = spec.scale
            let points = image.map { CGSize(width: CGFloat($0.width) / spec.scale, height: CGFloat($0.height) / spec.scale) } ?? .zero
            layer.bounds = CGRect(origin: .zero, size: points)
            layer.position = position
        }

        glow.contents = picture(Circle().fill(Color.orange).frame(width: size, height: size))
        glow.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        glow.position = center

        figure.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        figure.anchorPoint = CGPoint(x: 0.5, y: 1)
        figure.position = CGPoint(x: size / 2, y: size)

        // With room for its shadow.
        let room = size * 0.25
        place(body, picture(BotAvatar.body(spec.look, size: size)
            .shadow(color: .black.opacity(size > 40 ? 0.12 : 0.08), radius: size / 24, y: size / 48)
            .padding(room)), at: center)

        faces = [:]
        face.bounds = CGRect(x: 0, y: 0, width: size * 0.5, height: size * 0.3)
        face.position = CGPoint(x: center.x + size * 0.04, y: center.y + BotAvatar.faceOffset(spec.look.shape, size: size))
        face.contentsScale = spec.scale

        let tint = spec.look.color.color
        for (index, dot) in dots.enumerated() {
            place(dot, picture(BotAvatar.sparkDot(step: index % 5, tint: tint, size: size)), at: center)
        }
        let letter = picture(BotAvatar.zLetter(size: size).fixedSize())
        for z in zs { place(z, letter, at: center) }
        place(star, picture(BotAvatar.star(size: size)), at: center)
    }

    private func faceImage(_ kind: BotLook.Face, _ spec: Spec) -> CGImage? {
        if let image = faces[kind] { return image }
        let renderer = ImageRenderer(content: BotFace(face: kind, deep: spec.look.color.isDeep).frame(width: spec.size * 0.5, height: spec.size * 0.3))
        renderer.scale = spec.scale
        let image = renderer.cgImage
        faces[kind] = image
        return image
    }

    // MARK: Motion

    /// How long one round of a mood's motion is, a length its parts' own rhythms fit into (so it
    /// loops without a jump), and how often in it the pose is worked out; Core Animation moves
    /// smoothly between those.
    static func cycle(_ mood: BotMood, noticed: Bool) -> (length: Double, rate: Double) {
        switch mood {
        // Breaths of 3.8 s, a fidget every 4.2 s; noticed, hops of half a second.
        case .idle: noticed ? (19, 30) : (79.8, 20)
        // Hops of 2.8 s, eyes along a line in 1.2 s, a turn in 6 s.
        case .working: (42, 30)
        // A hop and wiggle every 2.4 s, a pulse every 1.6 s.
        case .waiting: (4.8, 30)
        // Breaths of 2.6 s, hops and a sparkle every 3.6 s.
        case .news: (46.8, 30)
        // Breaths of 4.2 s and a look out one way and the other every 6.4 s.
        case .watching: noticed ? (42, 20) : (134.4, 20)
        // Breaths of 3.6 s, a nod in 7.2 s, a z every 4.2 s.
        case .sleeping: (50.4, 20)
        }
    }

    private func animate(_ spec: Spec) {
        for layer in [glow, figure, body, face, star] + dots + zs { layer.removeAllAnimations() }
        let (length, rate) = Self.cycle(spec.mood, noticed: spec.noticed)
        let count = Int((length * rate).rounded())
        let poses = (0..<count).map { index in
            BotPose(mood: spec.mood, noticed: spec.noticed, time: Double(index) / rate + spec.seed, seed: spec.seed, small: spec.size < 24)
        }
        let size = spec.size
        let center = CGPoint(x: size / 2, y: size / 2)
        // Where in the round it is now: bots that came in at different times still move apart.
        let now = CACurrentMediaTime()
        let into = now.truncatingRemainder(dividingBy: length)

        /// Each pose's value, back to the first at the end, as the round starts again.
        func play(_ layer: CALayer, _ keyPath: String, discrete: Bool = false, _ value: (BotPose) -> Any) {
            var values = poses.map(value)
            values.append(values[0])
            // The same all round: set, not played.
            let still = if let numbers = values as? [Double] {
                numbers.allSatisfy { abs($0 - numbers[0]) < 0.0001 }
            } else {
                values.allSatisfy { CFEqual($0 as CFTypeRef, values[0] as CFTypeRef) }
            }
            if still {
                layer.setValue(values[0], forKeyPath: keyPath)
                return
            }
            layer.setValue(values[0], forKeyPath: keyPath)
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.duration = length
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            if discrete { animation.calculationMode = .discrete }
            animation.beginTime = layer.convertTime(now, from: nil) - into
            layer.add(animation, forKey: keyPath)
        }

        let degrees = Double.pi / 180
        play(figure, "transform.translation.y") { Double($0.lift * size) }
        play(figure, "transform.rotation.z") { $0.tilt * degrees }
        play(figure, "transform.scale.x") { Double($0.scaleX) }
        play(figure, "transform.scale.y") { Double($0.scaleY) }

        // A turn goes on round: each pose's angle counts the whole circles before it, and the
        // round ends a whole number of circles on (working's 42 s at 60° a second is seven), so
        // the next one starts where it looks the same, rather than spinning back.
        if spec.look.shape == .bloom || spec.look.shape == .gem {
            func step(_ from: Double, _ to: Double) -> Double {
                let step = (to - from).truncatingRemainder(dividingBy: 360)
                return step > 180 ? step - 360 : step < -180 ? step + 360 : step
            }
            var turned = poses[0].spin
            var values = [turned * degrees]
            for index in 1..<poses.count {
                turned += step(poses[index - 1].spin, poses[index].spin)
                values.append(turned * degrees)
            }
            turned += step(poses[poses.count - 1].spin, poses[0].spin)
            values.append(turned * degrees)
            let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            animation.values = values
            animation.duration = length
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.beginTime = body.convertTime(now, from: nil) - into
            body.setValue(poses[0].spin * degrees, forKeyPath: "transform.rotation.z")
            if values.contains(where: { abs($0) > 0.0001 }) { body.add(animation, forKey: "transform.rotation.z") }
        } else {
            body.setValue(0.0, forKeyPath: "transform.rotation.z")
        }

        let faceWidth = Double(size * 0.5)
        play(face, "contents", discrete: true) { pose -> Any in self.faceImage(pose.face ?? spec.look.face, spec) ?? NSNull() }
        play(face, "transform.translation.x") { Double($0.glance) * faceWidth }
        play(face, "transform.scale.y") { pose in
            // Only open eyes shut; closed-looking ones stay as they are.
            switch pose.face ?? spec.look.face {
            case .happy, .sleepy: 1
            default: 1 - 0.88 * Double(pose.blink)
            }
        }

        play(glow, "opacity") { Double(0.4 * (1 - $0.glow)) * ($0.glow > 0 ? 1 : 0) }
        play(glow, "transform.scale") { Double(1 + 0.5 * $0.glow) }

        for (index, dot) in dots.enumerated() {
            let spark = index / 5, step = index % 5
            func placement(_ pose: BotPose) -> BotAvatar.Placement? {
                guard pose.sparks.indices.contains(spark) else { return nil }
                return BotAvatar.sparkDots(at: pose.sparks[spark], size: size)[step]
            }
            play(dot, "position") { pose in
                let offset = placement(pose)?.offset ?? .zero
                return NSValue(point: CGPoint(x: center.x + offset.width, y: center.y + offset.height))
            }
            play(dot, "transform.scale") { Double(placement($0)?.scale ?? 1) }
            play(dot, "opacity") { placement($0)?.opacity ?? 0 }
            play(dot, "zPosition", discrete: true) { pose in
                pose.sparks.indices.contains(spark) && BotAvatar.sparkInFront(pose.sparks[spark]) ? 1.0 : -1.0
            }
        }

        for (index, z) in zs.enumerated() {
            func placement(_ pose: BotPose) -> BotAvatar.Placement? {
                pose.zs.indices.contains(index) ? BotAvatar.z(at: pose.zs[index], size: size) : nil
            }
            play(z, "position") { pose in
                let offset = placement(pose)?.offset ?? .zero
                return NSValue(point: CGPoint(x: center.x + offset.width, y: center.y + offset.height))
            }
            play(z, "transform.scale") { Double(placement($0)?.scale ?? 1) }
            play(z, "opacity") { placement($0)?.opacity ?? 0 }
        }

        let starAt = BotAvatar.starOffset(size: size)
        star.position = CGPoint(x: center.x + starAt.width, y: center.y + starAt.height)
        play(star, "transform.scale") { Double($0.twinkle) }
        play(star, "transform.rotation.z") { Double($0.twinkle) * 45 * degrees }
    }
}
