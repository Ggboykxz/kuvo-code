import AppKit
import SwiftUI

/// Lets macOS move the window by its title bar only while the pointer is over the title bar.
///
/// A window whose content reaches up under its title bar has macOS work out, each time anything
/// moves, which parts of the title bar strip are content and which drag the window; SwiftUI then
/// walks every view that takes clicks or the keyboard to answer. Scrolling the sidebar spent a
/// third of its time there, and every scroll, reply and animation paid some. Not movable, the
/// window has none of that; it's made movable again as the pointer comes to the title bar, so
/// dragging it (and snapping it to the screen's edges) is as it always was.
@MainActor final class TitleBarMoveGate: NSObject {
    private weak var window: NSWindow?
    private var tracking: NSTrackingArea?
    private var observers: [NSObjectProtocol] = []
    private static var gates: [ObjectIdentifier: TitleBarMoveGate] = [:]

    static func install(on window: NSWindow) {
        guard gates[ObjectIdentifier(window)] == nil else { return }
        let gate = TitleBarMoveGate(window: window)
        gates[ObjectIdentifier(window)] = gate
    }

    private init(window: NSWindow) {
        self.window = window
        super.init()
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.remove() }
        })
        update()
    }

    /// The title bar strip, in the content view's coordinates: what the content reaches up under.
    private func strip(in content: NSView, of window: NSWindow) -> NSRect {
        let height = max(0, content.bounds.height - window.contentLayoutRect.height) + 4
        let y = content.isFlipped ? 0 : content.bounds.height - height
        return NSRect(x: 0, y: y, width: content.bounds.width, height: height)
    }

    private func update() {
        guard let window, let content = window.contentView else { return }
        if let tracking { content.removeTrackingArea(tracking) }
        let rect = strip(in: content, of: window)
        let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        content.addTrackingArea(area)
        tracking = area
        // Where the pointer is now decides, as it would have entering or leaving.
        let pointer = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setMovable(rect.contains(pointer) || window.styleMask.contains(.fullScreen))
    }

    private func setMovable(_ movable: Bool) {
        guard let window, window.isMovable != movable else { return }
        window.isMovable = movable
    }

    @objc func mouseEntered(with event: NSEvent) { setMovable(true) }

    @objc func mouseExited(with event: NSEvent) {
        // Not mid-drag (the window moves with the pointer, which can slip out of the strip): once
        // the button's up, if the pointer is still out.
        guard NSEvent.pressedMouseButtons == 0 else {
            Task { [weak self] in
                while NSEvent.pressedMouseButtons != 0 { try? await Task.sleep(for: .milliseconds(100)) }
                self?.update()
            }
            return
        }
        setMovable(window?.styleMask.contains(.fullScreen) ?? false)
    }

    private func remove() {
        if let tracking, let content = window?.contentView { content.removeTrackingArea(tracking) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let window { Self.gates[ObjectIdentifier(window)] = nil }
    }
}

/// Installs the gate on the window it's in.
struct TitleBarMoveGateInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { InstallerView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class InstallerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { TitleBarMoveGate.install(on: window) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
