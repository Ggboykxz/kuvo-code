import AppKit
import OpenCodeKit
import SwiftUI
import WebKit

/// What an agent made for you with show_widget: a page of its own (a chart, a diagram, a small
/// app, a game, choices to click), live in the conversation, in place of the call. Its script can
/// answer the agent for you, with `kuvo.send(text)`, when you click something in it.
struct WidgetCard: View {
    /// A call of show_widget, whichever engine's.
    static func isWidget(_ call: Message.ToolCall) -> Bool {
        call.name == "kuvo-browser_" + BrowserTools.showWidget
    }

    /// Its title in arguments still being written (partial JSON), once it's all there.
    static func title(inPartial input: String) -> String? {
        guard let match = input.firstMatch(of: /"title"\s*:\s*"((?:[^"\\]|\\.)*)"/) else { return nil }
        let raw = String(match.1)
        return (try? JSONDecoder().decode(String.self, from: Data("\"\(raw)\"".utf8))) ?? raw
    }

    let call: Message.ToolCall
    /// Sends what the page wrote back, as your message.
    let send: (String) -> Void
    @State private var height: CGFloat

    /// Each page's height when last drawn, by call. The conversation makes a row again when you
    /// scroll back to it, and a page coming back short, then growing, would push everything
    /// under it down as you scroll.
    private static var heights: [String: CGFloat] = [:]

    init(call: Message.ToolCall, send: @escaping (String) -> Void) {
        self.call = call
        self.send = send
        _height = State(initialValue: Self.heights[call.id] ?? 0)
    }
    /// Shown larger, over the window.
    @State private var isLarge = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.cardIsFocused) private var cardIsFocused

    private static let shape = RoundedRectangle(cornerRadius: 12)
    #if DEBUG
    private static var openedLarge = false
    #endif

    var body: some View {
        // One card while it's written and once it's done, so the page carries on from its draft.
        if case .failed = call.state {
            ToolCallView(call: call, directory: "")
        } else if let content {
            card(html: content.html, title: content.title, draft: content.draft)
        } else if case .streaming(let input) = call.state {
            HStack(spacing: 8) {
                Spinner(size: 12)
                ShimmerText(text: Self.title(inPartial: input).map { "Making “\($0)”…" } ?? "Making something…")
                Text(ByteCountFormatter.string(fromByteCount: Int64(input.utf8.count), countStyle: .file))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .font(.callout)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Surface.well(scheme), in: Self.shape)
        }
    }

    /// What there is to show: while it's written, what's come so far (once there's something to
    /// see), with how much has come; then the page.
    private var content: (html: String, title: String?, draft: Int?)? {
        switch call.state {
        case .streaming(let input):
            guard let html = Self.html(inPartial: input), html.count > 120 else { return nil }
            return (html, Self.title(inPartial: input), input.utf8.count)
        case .running(let input, _), .completed(let input, _, _):
            guard let html = input["html"]?.string, !html.isEmpty else { return nil }
            return (html, input["title"]?.string, nil)
        case .failed:
            return nil
        }
    }

    /// The page's HTML in arguments still being written (partial JSON): what's there so far.
    static func html(inPartial input: String) -> String? {
        guard let start = input.range(of: #""html"\s*:\s*""#, options: .regularExpression) else { return nil }
        var html = ""
        var characters = input[start.upperBound...].makeIterator()
        while let character = characters.next() {
            switch character {
            case "\"": return html
            case "\\":
                guard let escaped = characters.next() else { return html }
                switch escaped {
                case "n": html.append("\n")
                case "t": html.append("\t")
                case "r": html.append("\r")
                case "b", "f": break
                case "u":
                    var hex = ""
                    for _ in 0..<4 { if let digit = characters.next() { hex.append(digit) } }
                    if hex.count == 4, let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) { html.unicodeScalars.append(scalar) }
                default: html.append(escaped)
                }
            default: html.append(character)
            }
        }
        return html
    }

    /// `draft`: still being written, this many bytes so far.
    private func card(html: String, title: String?, draft: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles.rectangle.stack")
                    .foregroundStyle(.tint)
                Text(title.flatMap { $0.isEmpty ? nil : $0 } ?? "Made for you")
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let draft {
                    Spinner(size: 11)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(draft), countStyle: .file))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                } else {
                    MessageActionButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Open Larger") { isLarge = true }
                    CopyButton(text: html, help: "Copy Its HTML")
                }
            }
            .font(.callout)
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 32)
            Divider()
            WidgetPage(html: html, accent: NSColor.controlAccentColor, height: $height, isDraft: draft != nil, send: send)
                .frame(height: max(height, 60))
                .onChange(of: height) { if height > 0 { Self.heights[call.id] = height } }
        }
        .background(Surface.cardFill(scheme, focused: cardIsFocused), in: Self.shape)
        .clipShape(Self.shape)
        .recessedWell(Self.shape)
        #if DEBUG
        // KUVO_DEMO_WIDGET_LARGE: the first widget shown opens larger.
        .onAppear {
            guard ProcessInfo.processInfo.environment["KUVO_DEMO_WIDGET_LARGE"] != nil, !Self.openedLarge else { return }
            Self.openedLarge = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                isLarge = true
            }
        }
        #endif
        .sheet(isPresented: $isLarge) {
            VStack(spacing: 0) {
                HStack {
                    Text(title.flatMap { $0.isEmpty ? nil : $0 } ?? "Made for you")
                        .font(.headline)
                    Spacer()
                    Button("Done") { isLarge = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(14)
                Divider()
                // Its own room, scrolling inside; what it writes back goes on, then it closes.
                WidgetPage(html: html, accent: NSColor.controlAccentColor, height: .constant(0), scrollsInside: true) { text in
                    isLarge = false
                    send(text)
                }
            }
            .frame(width: 960, height: 720)
        }
    }
}

extension EnvironmentValues {
    /// Sends text to the agent of the conversation in view, as your message (a widget's
    /// `kuvo.send`).
    @Entry var answerAgent: (String) -> Void = { _ in }
}

/// The page itself: a web view of its own, with nothing kept after it closes, reaching nothing
/// but the usual places for libraries, its links opening in your browser. As tall as what's on
/// it, up to a point, then it scrolls inside.
private struct WidgetPage: NSViewRepresentable {
    let html: String
    let accent: NSColor
    @Binding var height: CGFloat
    /// It has room of its own (larger, in a sheet): it always scrolls in itself.
    var scrollsInside = false
    /// Still being written: drawn without its scripts, a couple of times a second.
    var isDraft = false
    let send: (String) -> Void

    /// Taller than this, it scrolls inside.
    static let tallest: CGFloat = 760

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WidgetWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let content = configuration.userContentController
        content.add(WeakHandler(context.coordinator), name: "kuvo")
        content.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Apart from the page's own scripts, so it measures a draft drawn without them too.
        content.add(WeakHandler(context.coordinator), contentWorld: .defaultClient, name: "kuvo")
        content.addUserScript(WKUserScript(source: Self.measure, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let view = WidgetWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WidgetWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.height = $height
        coordinator.send = send
        coordinator.view = view
        coordinator.scrollsInside = scrollsInside
        if scrollsInside { view.fits = false }
        coordinator.show(Self.page(html, accent: accent), draft: isDraft)
    }

    /// Libraries from the usual places, pictures from anywhere; nothing it can send to.
    private static let policy = "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://unpkg.com; style-src 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://unpkg.com https://fonts.googleapis.com; font-src https://fonts.gstatic.com https://cdnjs.cloudflare.com https://cdn.jsdelivr.net data:; img-src data: blob: https:; media-src data: blob:; connect-src 'none'; frame-src 'none'; form-action 'none'"

    /// `html` as a page: a fragment in a page of its own, or a whole page as it is; either way
    /// with the policy above, and the window's look to start from.
    static func page(_ html: String, accent: NSColor) -> String {
        let hex = accent.usingColorSpace(.sRGB).map { String(format: "#%02X%02X%02X", Int($0.redComponent * 255), Int($0.greenComponent * 255), Int($0.blueComponent * 255)) } ?? "#0A84FF"
        let head = """
        <meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\(policy)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; --kuvo-accent: \(hex); }
        html, body { margin: 0; background: transparent; }
        body { font: 13px/1.45 -apple-system, BlinkMacSystemFont, sans-serif; color: CanvasText; padding: 12px; box-sizing: border-box; }
        </style>
        """
        if let range = html.range(of: "<head>", options: .caseInsensitive) {
            var page = html
            page.insert(contentsOf: head, at: range.upperBound)
            return page
        }
        if html.range(of: "<html", options: .caseInsensitive) != nil {
            return head + html
        }
        return "<!doctype html><html><head>\(head)</head><body>\(html)</body></html>"
    }

    /// `kuvo.send(text)`: the page writes back to the agent as you, only from a click of yours.
    private static let bridge = """
    window.kuvo = {
      send(text) {
        if (navigator.userActivation && !navigator.userActivation.isActive) return false;
        window.webkit.messageHandlers.kuvo.postMessage({ type: "send", text: String(text) });
        return true;
      },
    };
    """

    /// Its height, whenever it changes.
    private static let measure = """
    (() => {
      const report = () => window.webkit.messageHandlers.kuvo.postMessage({ type: "height", value: Math.ceil(document.documentElement.scrollHeight) });
      new ResizeObserver(report).observe(document.documentElement);
      report();
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var height: Binding<CGFloat>?
        var send: (String) -> Void = { _ in }
        weak var view: WidgetWebView?
        var loaded: String?
        var scrollsInside = false
        /// What's shown is a draft: no scripts.
        private(set) var isDraft = false
        private var lastDraft = Date.distantPast
        private var waitingDraft: Task<Void, Never>?
        /// Loading again with a height already (scrolled back to, or finished after its draft),
        /// it keeps that height for a moment and only grows: a page draws in steps, and
        /// coming in short would move the conversation under it.
        private var keepsHeightUntil = Date.distantPast
        private var measured: CGFloat?

        /// Loads `page`: the finished one at once, a draft at most twice a second (the last
        /// one coming once it's had its turn).
        func show(_ page: String, draft: Bool) {
            guard loaded != page else { return }
            waitingDraft?.cancel()
            let due = lastDraft.addingTimeInterval(0.5)
            if draft, due > .now {
                waitingDraft = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(due.timeIntervalSinceNow))
                    guard !Task.isCancelled else { return }
                    self?.load(page, draft: true)
                }
                return
            }
            load(page, draft: draft)
        }

        private func load(_ page: String, draft: Bool) {
            isDraft = draft
            if draft { lastDraft = .now }
            loaded = page
            measured = nil
            view?.loadHTMLString(page, baseURL: nil)
            guard (height?.wrappedValue ?? 0) > 0 else { return }
            keepsHeightUntil = .now.addingTimeInterval(1.5)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.6))
                guard let self, let measured, let height, abs(height.wrappedValue - measured) > 0.5 else { return }
                height.wrappedValue = measured
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            switch body["type"] as? String {
            case "height":
                guard let value = body["value"] as? Double else { return }
                let fits = CGFloat(value) <= WidgetPage.tallest
                view?.fits = fits && !scrollsInside
                let new = min(CGFloat(value), WidgetPage.tallest)
                measured = new
                let current = height?.wrappedValue ?? 0
                if keepsHeightUntil > .now, new < current { return }
                if abs(current - new) > 0.5 { height?.wrappedValue = new }
            case "send":
                guard let text = body["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                send(String(text.prefix(4000)))
            default:
                break
            }
        }

        #if DEBUG
        /// KUVO_DEMO_WIDGET_SNAPSHOTS=<folder>: each page, once drawn, as a picture there (a
        /// background copy's window doesn't draw web pages, so they can't be captured).
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let folder = ProcessInfo.processInfo.environment["KUVO_DEMO_WIDGET_SNAPSHOTS"] else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                let configuration = WKSnapshotConfiguration()
                guard let image = try? await webView.takeSnapshot(configuration: configuration),
                      let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                let name = "widget-\(abs((loaded ?? "").hashValue) % 100_000).png"
                try? png.write(to: URL(filePath: folder).appending(path: name))
            }
        }
        #endif

        /// Its own page loads (a draft without its scripts); a link goes to your browser instead.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            if action.navigationType == .linkActivated || (action.targetFrame?.isMainFrame == true && action.request.url?.scheme.map(["http", "https"].contains) == true) {
                if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel, preferences)
                return
            }
            preferences.allowsContentJavaScript = !isDraft
            decisionHandler(.allow, preferences)
        }

        /// A link meant for a new window, too.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}

/// Scrolling over a page that fits goes on to the conversation around it.
final class WidgetWebView: WKWebView {
    var fits = true

    override func scrollWheel(with event: NSEvent) {
        if fits { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}

/// Holds the page's handler without the page holding it back.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
