import AppKit
import SwiftUI

extension View {
    /// A right-click (and Control-click) menu that also works in the title bar, where
    /// SwiftUI's `.contextMenu` never fires: the window's toolbar takes those clicks.
    /// The view only marks where it is; clicks are caught at the window before the
    /// toolbar sees them.
    func rightClickMenu(_ items: @escaping @MainActor () -> [NSMenuItem]) -> some View {
        background(RightClickMarker(items: items).allowsHitTesting(false))
    }
}

private struct RightClickMarker: NSViewRepresentable {
    let items: @MainActor () -> [NSMenuItem]

    func makeNSView(context: Context) -> MarkerView { MarkerView() }

    func updateNSView(_ view: MarkerView, context: Context) {
        view.items = items
    }
}

private final class MarkerView: NSView {
    var items: (@MainActor () -> [NSMenuItem])?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { RightClickMenus.shared.add(self) }
    }

    /// Shows the menu if the click landed on this view.
    func showMenu(for event: NSEvent) -> Bool {
        guard !isHiddenOrHasHiddenAncestor,
              convert(bounds, to: nil).contains(event.locationInWindow),
              let items = items?(), !items.isEmpty else { return false }
        let menu = NSMenu()
        // Items carry their own enabled state (Close Other Tabs with one tab open).
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        return true
    }
}

/// One window-level watcher for every marked view.
@MainActor
private final class RightClickMenus {
    static let shared = RightClickMenus()

    private let views = NSHashTable<MarkerView>.weakObjects()
    private var monitor: Any?

    func add(_ view: MarkerView) {
        views.add(view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return event }
            for view in views.allObjects where view.window === event.window {
                if view.showMenu(for: event) { return nil }
            }
            return event
        }
    }
}
