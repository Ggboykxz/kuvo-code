import AppKit
import SwiftUI
import os

/// A SwiftUI button that opens a real AppKit menu, built when clicked.
///
/// SwiftUI's `Menu` can't show a value on the right of a submenu row ("Model …
/// GPT-6 Luna ›"), item subtitles, or open above its button; `NSMenu` can.
struct NativeMenuButton<Label: View>: View {
    /// Identifies the menu for the KUVO_DEMO_MENU debug hook.
    var name = ""
    let menu: () -> NSMenu
    @ViewBuilder let label: () -> Label
    @State private var anchor = Anchor()

    var body: some View {
        Button {
            anchor.popUp(menu())
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .background(AnchorView(anchor: anchor))
        #if DEBUG
        .task {
            // KUVO_DEMO_MENU=<name> opens this menu (its first submenu with "<name>s") after launch.
            guard let wanted = ProcessInfo.processInfo.environment["KUVO_DEMO_MENU"], !name.isEmpty, wanted == name || wanted == name + "s" else { return }
            try? await Task.sleep(for: .seconds(3))
            let menu = menu()
            anchor.popUp(wanted == name ? menu : menu.items.first { $0.submenu != nil }?.submenu ?? menu)
        }
        #endif
    }

    final class Anchor {
        weak var view: NSView?

        /// Opens the menu just above the button (the composer sits at the bottom of the window).
        func popUp(_ menu: NSMenu) {
            guard let view else { return }
            let origin = NSPoint(x: -8, y: view.bounds.height + menu.size.height + 8)
            menu.popUp(positioning: nil, at: origin, in: view)
        }
    }

    private struct AnchorView: NSViewRepresentable {
        let anchor: Anchor

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            anchor.view = view
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {
            anchor.view = view
        }
    }
}

/// A menu item that runs a closure. Opted out of the target's default main-actor
/// isolation because NSMenuItem's initializers aren't isolated; menus still only
/// call it on the main thread.
nonisolated final class ActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, subtitle: String? = nil, image: NSImage? = nil, checked: Bool = false, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        self.subtitle = subtitle
        self.image = image
        if image != nil { showImage() }
        state = checked ? .on : .off
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}

extension NSMenuItem {
    /// A row with a title on the left and its current value on the right, opening `submenu`.
    static func chained(_ title: String, value: String?, image: NSImage? = nil, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = image
        if image != nil { item.showImage() }
        item.submenu = submenu
        if let value { item.attributedTitle = .withValue(title, value) }
        return item
    }

    /// macOS 27 hides menu item images unless the item asks to show them. Our logos
    /// tell models apart (Claude through Copilot vs. through OpenCode), so they stay.
    nonisolated func showImage() {
        if #available(macOS 27, *) { preferredImageVisibility = .visible }
    }

    /// A row that only shows information.
    static func info(_ title: String, value: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = .withValue(title, value)
        item.isEnabled = false
        return item
    }
}

extension NSAttributedString {
    /// "Title            Value", the value right-aligned and secondary.
    static func withValue(_ title: String, _ value: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let width = max(220, (title as NSString).size(withAttributes: [.font: font]).width + (value as NSString).size(withAttributes: [.font: font]).width + 48)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: width)]
        let string = NSMutableAttributedString(string: title + "\t", attributes: [.font: font, .paragraphStyle: paragraph])
        string.append(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]))
        return string
    }
}

/// Provider and model-maker logos, kept in memory for menus (which can't wait for a download).
@Observable
final class LogoImages {
    private let log = Logger(subsystem: "run.kuvo.code", category: "logos")
    static let shared = LogoImages()
    private var images: [String: NSImage] = [:]

    /// A 16-pt template image for menu rows, if the logo has loaded. Menus don't draw
    /// the SVG originals reliably, so it's redrawn into a plain drawing-handler image.
    func menuImage(_ id: String) -> NSImage? {
        guard let source = images[id] else {
            log.debug("menu logo missing: \(id, privacy: .public) (have \(self.images.count))")
            return nil
        }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    func prefetch(_ ids: some Sequence<String>) {
        let wanted = Set(ids).filter { images[$0] == nil }
        log.debug("prefetching \(wanted.count) logos")
        for id in wanted {
            Task {
                if let image = await LogoCache.shared.logo(for: id) {
                    images[id] = image
                } else {
                    log.debug("logo failed: \(id, privacy: .public)")
                }
            }
        }
    }
}
