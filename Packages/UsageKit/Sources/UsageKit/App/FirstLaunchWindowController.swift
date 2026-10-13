import AppKit
import SwiftUI

/// AppKit only owns the early window; the welcome model and view own the flow. The host is a regular
/// app with its own windows, so this never changes the activation policy, and closing the window only
/// postpones the choice until the next click on the menu bar item.
@MainActor
final class FirstLaunchWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var detectionTask: Task<Void, Never>?
    private var finishing = false
    private let onClose: () -> Void

    init(setup: FirstLaunchSetup, finish: @escaping () -> Void, onClose: @escaping () -> Void) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 650),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        self.onClose = onClose
        super.init()
        window.title = "Usage"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: FirstLaunchWelcomeView(setup: setup, finish: finish))
        window.center()
        detectionTask = Task { await setup.detect() }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func finish() {
        finishing = true
        detectionTask?.cancel()
        window.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !finishing {
            detectionTask?.cancel()
            onClose()
        }
        return true
    }
}
