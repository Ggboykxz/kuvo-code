import AppKit
import Observation

/// Whether any of Kuvo Code's windows can be seen: not hidden, minimized or covered. What moves
/// only for show (bots' idle animations) holds still while none can, rather than drawing frames
/// nobody sees.
@Observable
final class WindowVisibility {
    static let shared = WindowVisibility()

    private(set) var isVisible = true

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WindowVisibility.shared.update() }
            }
        }
    }

    private func update() {
        #if DEBUG
        // KUVO_PERF_ALWAYS_VISIBLE: as if seen, for measuring a background copy's animations.
        if ProcessInfo.processInfo.environment["KUVO_PERF_ALWAYS_VISIBLE"] != nil { return }
        #endif
        // Its own windows: not the menu bar item's, which is always on screen, nor panels.
        let visible = !NSApp.isHidden && NSApp.windows.contains { $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
        if visible != isVisible { isVisible = visible }
    }
}
