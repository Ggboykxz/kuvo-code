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
    /// Told about each page that finishes loading, for the new tab page's suggestions.
    @ObservationIgnored var onVisit: ((URL, String, URL?) -> Void)?
    /// Opens a window the page asked for, as a tab of its own, and hands back its web view.
    @ObservationIgnored var openWindow: ((WKWebViewConfiguration) -> WKWebView?)?
    /// The page closed its own window (a sign-in popup that's done).
    @ObservationIgnored var onClose: (() -> Void)?
    /// A sign-in you just sent, which the toolbar offers to save.
    var pendingLogin: PendingLogin?
    /// The saved logins for the page's site, and whether it has a field to fill them into.
    private(set) var savedLogins: [Passwords.Login] = []
    private(set) var hasLoginField = false

    /// A new tab, or, with the configuration WebKit passes for a window a page opens, that window:
    /// it stays connected to the page that opened it, which sign-in popups need to report back.
    init(configuration: WKWebViewConfiguration? = nil) {
        let configuration = configuration ?? Self.makeConfiguration()
        PasswordCapture.install(in: configuration)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        super.init()
        PasswordCapture.shared.register(self)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        observations = [
            webView.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.title = view.title ?? "" } },
            webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.url = view.url } },
            webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.isLoading = view.isLoading } },
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in MainActor.assumeIsolated { self?.progress = view.estimatedProgress } },
        ]
    }

    private static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Present as Safari, so sites don't serve a reduced page to an unknown browser.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        return configuration
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

    // MARK: Passwords

    func offerToSave(_ login: PendingLogin) {
        pendingLogin = login
    }

    func savePendingLogin() {
        guard let login = pendingLogin else { return }
        Passwords.save(host: login.host, account: login.account, password: login.password)
        Analytics.shared.track("password_saved")
        pendingLogin = nil
        refreshLogins()
    }

    func dismissPendingLogin(never: Bool) {
        if never, let host = pendingLogin?.host { Passwords.setNever(host, true) }
        pendingLogin = nil
    }

    /// Fills the page's sign-in fields with a saved login: only when you ask, from the toolbar.
    func fill(_ login: Passwords.Login) {
        guard let password = Passwords.password(for: login) else { return }
        Task {
            _ = try? await webView.callAsyncJavaScript(Passwords.fillScript, arguments: ["username": login.account, "secret": password], contentWorld: Passwords.world)
        }
    }

    /// What the toolbar's key offers for the page in view.
    func refreshLogins() {
        guard let host = webView.url?.host() else {
            savedLogins = []
            hasLoginField = false
            return
        }
        savedLogins = Passwords.logins(for: host)
        guard !savedLogins.isEmpty else {
            hasLoginField = false
            return
        }
        Task {
            hasLoginField = (try? await webView.callAsyncJavaScript(Passwords.hasLoginFieldScript, contentWorld: Passwords.world) as? Bool) ?? false
        }
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
        return SearchEngine.current.url(for: text)
    }
}

extension BrowserSession: WKUIDelegate {
    /// A window the page opens, a link or a script's, becomes a real window in a tab of its own, as
    /// in any browser. It stays connected to the page that opened it, which sign-in windows like
    /// "Sign in with Google" need to report back before they close.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let window = openWindow?(configuration) { return window }
        webView.load(navigationAction.request)
        return nil
    }

    /// The page closed its own window, like a sign-in popup that's done.
    func webViewDidClose(_ webView: WKWebView) {
        onClose?()
    }
}

extension BrowserSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A login offered on another site doesn't follow you around.
        if let pending = pendingLogin, pending.host != webView.url?.host() { pendingLogin = nil }
        refreshLogins()
        guard let url = webView.url, let onVisit else { return }
        let title = webView.title ?? ""
        // The page's own icon, the largest it names; the site's /favicon.ico otherwise.
        let script = """
        (() => {
          // Only icons meant for the current appearance (sites name light and dark ones).
          const links = [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]')]
            .filter((l) => !l.media || matchMedia(l.media).matches);
          const size = (l) => parseInt((l.sizes && l.sizes.value || '0').split('x')[0]) || (l.rel.includes('apple') ? 180 : 16);
          links.sort((a, b) => size(b) - size(a));
          return links.length ? links[0].href : null;
        })()
        """
        webView.evaluateJavaScript(script) { result, _ in
            MainActor.assumeIsolated { onVisit(url, title, (result as? String).flatMap(URL.init(string:))) }
        }
    }
}

/// A browser tab in the panel: back, forward and reload, the address, a few actions, and the
/// page, or the new tab page while the tab hasn't gone anywhere.
struct BrowserPane<NewTab: View>: View {
    let session: BrowserSession
    /// Attaches files to the message being written, for Add Screenshot to Message.
    var attach: ([URL]) -> Void = { _ in }
    @ViewBuilder let newTab: () -> NewTab
    @State private var address = ""
    @FocusState private var editing: Bool
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                navigation
                addressField
                actions
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            if let login = session.pendingLogin {
                SaveLoginBar(login: login, session: session)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Divider()
            if session.url == nil && !session.isLoading {
                newTab()
            } else {
                WebViewHost(webView: session.webView)
            }
        }
        .onAppear {
            address = displayAddress
            if session.url == nil, !AppInfo.staysInBackground { editing = true }
        }
        .onChange(of: session.url) { if !editing { address = displayAddress } }
        .onChange(of: editing) { _, isEditing in address = isEditing ? (session.url?.absoluteString ?? "") : displayAddress }
    }

    private var navigation: some View {
        HStack(spacing: 0) {
            Button { session.webView.goBack() } label: { Label("Back", systemImage: "arrow.left") }
                .disabled(!session.canGoBack)
                .help("Back")
            Button { session.webView.goForward() } label: { Label("Forward", systemImage: "arrow.right") }
                .disabled(!session.canGoForward)
                .help("Forward")
            Divider().frame(height: 16).padding(.horizontal, 2)
            Button {
                if session.isLoading { session.webView.stopLoading() } else { session.webView.reload() }
            } label: {
                Label(session.isLoading ? "Stop" : "Reload", systemImage: session.isLoading ? "xmark" : "arrow.clockwise")
            }
            .disabled(session.url == nil)
            .help(session.isLoading ? "Stop" : "Reload")
        }
        .buttonStyle(ToolbarGroupStyle())
        .padding(.horizontal, 3)
        .frame(height: 34)
        .background(Color.primary.opacity(0.06), in: .capsule)
    }

    private var addressField: some View {
        HStack(spacing: 7) {
            Image(systemName: session.url?.scheme == "https" && !editing ? "lock.fill" : "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Search or enter a URL", text: $address)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($editing)
                .onSubmit {
                    session.load(address)
                    editing = false
                }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color.primary.opacity(0.06), in: .capsule)
        .overlay(alignment: .bottom) {
            if session.isLoading {
                GeometryReader { proxy in
                    Capsule().fill(.tint).frame(width: proxy.size.width * session.progress, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 16)
            }
        }
        .contentShape(.capsule)
        .onTapGesture { editing = true }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if session.hasLoginField, !session.savedLogins.isEmpty {
                // Filling is yours to ask for: never on its own, never the agent's.
                Menu {
                    ForEach(session.savedLogins) { login in
                        Button(login.account.isEmpty ? "No username" : login.account) { session.fill(login) }
                    }
                    Divider()
                    Button("Passwords…") { app.openSettings(.passwords) }
                } label: {
                    Label("Fill Password", systemImage: "key.fill")
                } primaryAction: {
                    if let login = session.savedLogins.first { session.fill(login) }
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(session.savedLogins.count == 1 ? "Fill in the saved password for \(session.savedLogins[0].account)" : "Fill in a saved password")
            }
            Button(action: addScreenshot) {
                Label("Add Screenshot to Message", systemImage: "camera.viewfinder")
            }
            .disabled(session.url == nil)
            .help("Add a screenshot of the page to your message, so the agent sees what you see")
            Button {
                if let url = session.url { NSWorkspace.shared.open(url) }
            } label: { Label("Open in Your Browser", systemImage: "arrow.up.forward.app") }
                .disabled(session.url == nil)
                .help("Open in Your Browser")
            Menu {
                Button("Copy Address") {
                    guard let url = session.url else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                .disabled(session.url == nil)
                Button("Reload Page") { session.webView.reload() }
                    .disabled(session.url == nil)
                Divider()
                Button("Actual Size") { session.webView.magnification = 1 }
                Button("Zoom In") { session.webView.magnification = min(session.webView.magnification + 0.1, 3) }
                Button("Zoom Out") { session.webView.magnification = max(session.webView.magnification - 0.1, 0.5) }
                Divider()
                Button("Browser Settings…") { app.openSettings(.browser) }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .buttonStyle(ToolbarGroupStyle())
        .padding(.horizontal, 3)
        .frame(height: 34)
        .background(Color.primary.opacity(0.06), in: .capsule)
    }

    /// What's in view of the page, as a picture attached to the message being written.
    private func addScreenshot() {
        let host = session.url?.host()?.replacingOccurrences(of: "www.", with: "") ?? "page"
        session.webView.takeSnapshot(with: nil) { image, _ in
            MainActor.assumeIsolated {
                guard let image, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                      let url = Attachments.write(png, named: "Screenshot of \(host)", extension: "png") else { return }
                Analytics.shared.track("browser_screenshot_added")
                attach([url])
            }
        }
    }

    /// The host while browsing ("google.com"), the full address while editing.
    private var displayAddress: String {
        guard let url = session.url else { return "" }
        if editing { return url.absoluteString }
        return url.host()?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
    }
}

/// Under the toolbar after you sign in somewhere: save the password, or don't.
private struct SaveLoginBar: View {
    let login: PendingLogin
    let session: BrowserSession
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(login.isUpdate ? "Update the saved password?" : "Save this password?")
                    .font(.system(size: 13, weight: .semibold))
                Text(login.account.isEmpty ? login.host : "\(login.account) on \(login.host)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Menu("Not Now") {
                Button("Never for This Site") { withAnimation(.ui) { session.dismissPendingLogin(never: true) } }
            } primaryAction: {
                withAnimation(.ui) { session.dismissPendingLogin(never: false) }
            }
            .fixedSize()
            Button(login.isUpdate ? "Update" : "Save") { withAnimation(.ui) { session.savePendingLogin() } }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Surface.well(scheme), in: .rect(cornerRadius: 10))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

/// The buttons inside the toolbar's capsules.
struct ToolbarGroupStyle: ButtonStyle {
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? (isHovering ? .primary : .secondary) : .quaternary)
            .frame(width: 30, height: 28)
            .background(isHovering && isEnabled ? Color.primary.opacity(0.08) : .clear, in: .capsule)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(.capsule)
            .onHover { isHovering = $0 }
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
