import AppKit
import SwiftUI
import WebKit

/// A browser tab: a web view and what the toolbar shows about it.
@Observable
final class BrowserSession: NSObject {
    let webView: WKWebView
    private(set) var title = ""
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var progress = 0.0
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Present as Safari, so sites don't serve a reduced page to an unknown browser.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        super.init()
        webView.uiDelegate = self
        observations = [
            webView.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.title = view.title ?? "" } },
            webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.url = view.url } },
            webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.isLoading = view.isLoading } },
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in MainActor.assumeIsolated { self?.progress = view.estimatedProgress } },
        ]
    }

    /// The tab's name: the page title, else its host.
    var displayTitle: String {
        if !title.isEmpty { return title }
        return url?.host() ?? "New Tab"
    }

    /// Goes to an address, or searches for anything that doesn't look like one.
    func load(_ input: String) {
        guard let url = Self.url(from: input) else { return }
        webView.load(URLRequest(url: url))
    }

    func close() {
        webView.stopLoading()
        observations = []
    }

    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https", "file", "about"].contains(scheme.lowercased()) {
            return url
        }
        // "localhost:3000", "example.com/path": an address without its scheme.
        let looksLikeHost = !text.contains(" ") && (text.contains(".") || text.hasPrefix("localhost") || text.contains(":"))
        if looksLikeHost, let url = URL(string: (text.hasPrefix("localhost") || text.hasPrefix("127.") ? "http://" : "https://") + text) {
            return url
        }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }
}

extension BrowserSession: WKUIDelegate {
    /// Links that would open a new window open in this tab.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }
}

/// A browser tab in the panel: back, forward, reload, the address, and the page.
struct BrowserPane: View {
    let session: BrowserSession
    @State private var address = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { session.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!session.canGoBack)
                    .help("Back")
                Button { session.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!session.canGoForward)
                    .help("Forward")
                Button {
                    if session.isLoading { session.webView.stopLoading() } else { session.webView.reload() }
                } label: {
                    Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise")
                }
                .help(session.isLoading ? "Stop" : "Reload")
                TextField("Search or enter an address", text: $address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .multilineTextAlignment(editing ? .leading : .center)
                    .focused($editing)
                    .onSubmit {
                        session.load(address)
                        editing = false
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color.primary.opacity(0.06), in: .capsule)
                    .overlay(alignment: .bottomLeading) {
                        if session.isLoading {
                            GeometryReader { proxy in
                                Capsule().fill(.tint).frame(width: proxy.size.width * session.progress, height: 2)
                            }
                            .frame(height: 2)
                            .padding(.horizontal, 10)
                        }
                    }
                Button {
                    if let url = session.url { NSWorkspace.shared.open(url) }
                } label: { Image(systemName: "arrow.up.right.square") }
                    .disabled(session.url == nil)
                    .help("Open in Your Browser")
            }
            .buttonStyle(CardActionStyle())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if session.url == nil && !session.isLoading {
                ContentUnavailableView("New Tab", systemImage: "globe", description: Text("Search, or enter an address above."))
                    .frame(maxHeight: .infinity)
            } else {
                WebViewHost(webView: session.webView)
            }
        }
        .onAppear {
            address = displayAddress
            if session.url == nil { editing = true }
        }
        .onChange(of: session.url) { if !editing { address = displayAddress } }
        .onChange(of: editing) { _, isEditing in address = isEditing ? (session.url?.absoluteString ?? "") : displayAddress }
    }

    /// The host while browsing ("google.com"), the full address while editing.
    private var displayAddress: String {
        guard let url = session.url else { return "" }
        if editing { return url.absoluteString }
        return url.host()?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
