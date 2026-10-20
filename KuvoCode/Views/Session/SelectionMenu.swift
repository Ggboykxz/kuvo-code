import AppKit
import SwiftUI
import WebKit

/// Over what you select in the conversation: Add to Chat (it goes over the composer as a quote
/// to answer) or Copy. It shows when a drag or a double click leaves text selected, and goes
/// at the next click, scroll or key.
struct SelectionMenu: ViewModifier {
    let addToChat: (String) -> Void
    /// A conversation kept hidden (see `SessionView`) has none.
    @Environment(\.isConversationShown) private var isShown
    /// Where it shows, in the conversation's own space; nil while it doesn't.
    @State private var point: CGPoint?
    @State private var frame: CGRect = .zero
    @State private var menuFrame: CGRect = .zero
    @State private var monitor: Any?
    @State private var windowBox = WindowBox()
    /// Where the button went down, to tell a drag from a click.
    @State private var downAt: CGPoint?
    /// What's selected in a page in the conversation (a widget), read as the menu shows: a page
    /// copies only a moment later, too late for Add to Chat.
    @State private var pageSelection: String?

    func body(content: Content) -> some View {
        content
            .background(WindowReader(box: windowBox))
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame = $0 }
            .overlay(alignment: .topLeading) {
                if let point {
                    menu
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { menuFrame = $0 }
                        .fixedSize()
                        .position(x: min(max(point.x, 90), max(frame.width - 90, 90)), y: max(point.y - 26, 18))
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeOut(duration: 0.12), value: point == nil)
            .onAppear {
                install()
                #if DEBUG
                // KUVO_DEMO_SELECTION_MENU=<x>,<y>: shown there, as if text were selected.
                if let spec = ProcessInfo.processInfo.environment["KUVO_DEMO_SELECTION_MENU"] {
                    let xy = spec.split(separator: ",").compactMap { Double($0) }
                    if xy.count == 2 { point = CGPoint(x: xy[0], y: xy[1]) }
                }
                #endif
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    private var menu: some View {
        HStack(spacing: 2) {
            Button {
                if let text = pageSelection ?? Quoting.selection() { addToChat(text) }
                point = nil
            } label: {
                Label("Add to Chat", systemImage: "text.quote")
            }
            .help("Reply to this part: it goes over the composer, to answer under")
            Divider().frame(height: 14)
            Button {
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                point = nil
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
        .font(.callout)
        .buttonStyle(TextButtonStyle())
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .scrollWheel, .keyDown]) { event in
            handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard isShown else {
            point = nil
            return
        }
        guard let window = windowBox.window, event.window === window, let view = window.contentView else { return }
        let location = view.convert(event.locationInWindow, from: nil)
        let inWindow = view.isFlipped ? location : CGPoint(x: location.x, y: view.bounds.height - location.y)
        switch event.type {
        case .leftMouseDown:
            // A click on the menu is its own.
            guard point == nil || !menuFrame.contains(inWindow) else { return }
            point = nil
            menuFrame = .zero
            downAt = inWindow
        case .leftMouseUp:
            guard frame.contains(inWindow), point == nil || !menuFrame.contains(inWindow) else { return }
            let dragged = downAt.map { hypot($0.x - inWindow.x, $0.y - inWindow.y) > 4 } ?? false
            guard dragged || event.clickCount >= 2 else { return }
            let at = CGPoint(x: inWindow.x - frame.minX, y: inWindow.y - frame.minY)
            // Once the text has its selection.
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                // A page says it can copy whether or not anything is selected (a drag in a
                // widget's drawing selects nothing): it's asked what is.
                if let page = Self.page(in: window) {
                    let text = (try? await page.evaluateJavaScript("String(getSelection())", in: nil, contentWorld: .defaultClient) as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !text.isEmpty else { return }
                    pageSelection = text
                    point = at
                } else if Self.hasSelection(in: window) {
                    pageSelection = nil
                    point = at
                }
            }
        default:
            point = nil
            menuFrame = .zero
        }
    }

    /// The page that has the keyboard, if one does.
    private static func page(in window: NSWindow) -> WKWebView? {
        var view = window.firstResponder as? NSView
        while let current = view, !(current is WKWebView) { view = current.superview }
        return view as? WKWebView
    }

    /// Text is selected in the conversation: what has the keyboard can copy (asked without
    /// copying, so the clipboard is left alone), and it isn't a field you type in.
    private static func hasSelection(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder, responder !== window else { return false }
        if let editor = responder as? NSTextView, editor.isEditable { return false }
        guard let validator = responder as? NSUserInterfaceValidations, responder.responds(to: #selector(NSText.copy(_:))) else { return false }
        return validator.validateUserInterfaceItem(CopyItem())
    }

    private final class CopyItem: NSObject, NSValidatedUserInterfaceItem {
        var action: Selector? { #selector(NSText.copy(_:)) }
        var tag: Int { 0 }
    }
}

extension EnvironmentValues {
    /// The conversation is the one in view, not one kept hidden for going back to.
    @Entry var isConversationShown = true
}
