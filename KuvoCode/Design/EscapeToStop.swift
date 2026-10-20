import AppKit
import SwiftUI
import WebKit

/// Escape stops the agent at work in the window's conversation, wherever the keyboard is, as the
/// composer's Escape does: not when something there takes Escape itself (a text field, a page in
/// the panel, a terminal, a sheet or another window).
struct EscapeToStop: NSViewRepresentable {
    var canStop: Bool
    var stop: () -> Void

    func makeNSView(context: Context) -> Watcher { Watcher() }

    func updateNSView(_ view: Watcher, context: Context) {
        view.canStop = canStop
        view.stop = stop
    }

    final class Watcher: NSView {
        var canStop = false
        var stop: () -> Void = {}
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.takes(event) else { return event }
                self.stop()
                return nil
            }
        }

        private func takes(_ event: NSEvent) -> Bool {
            guard canStop, event.keyCode == 53,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty,
                  let window, event.window === window, window.attachedSheet == nil else { return false }
            let responder = window.firstResponder
            // Escape is theirs: an input method composing, a field you type in (the composer
            // stops on its own), a page, a terminal.
            if let text = responder as? NSTextView, text.isEditable || text.hasMarkedText() { return false }
            if responder is NSTextField || responder is WKWebView { return false }
            if let view = responder as? NSView, String(describing: type(of: view)).contains("Terminal") { return false }
            return true
        }
    }
}
