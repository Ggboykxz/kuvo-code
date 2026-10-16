import AppKit
import SwiftUI

/// Shows `content` with a SwiftUI view graph of its own, for something that changes every frame
/// (a bot moving): a frame then updates only it. In the window's graph, each frame laid out and
/// drew the whole window again, a fifth of a core for the sidebar's bots at rest. It takes the
/// size it's given and lets clicks and the pointer through to what's around it.
struct OwnGraph<Content: View>: NSViewRepresentable {
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> PassThroughHost<AnyView> {
        let view = PassThroughHost(rootView: root(context))
        view.sizingOptions = []
        return view
    }

    func updateNSView(_ view: PassThroughHost<AnyView>, context: Context) {
        view.rootView = root(context)
    }

    /// Its own graph doesn't get the window's environment, only what AppKit hands every view
    /// (the appearance, whether the window is active, the system's settings), which is all a
    /// bot reads.
    private func root(_ context: Context) -> AnyView {
        AnyView(content.ignoresSafeArea())
    }
}

final class PassThroughHost<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
