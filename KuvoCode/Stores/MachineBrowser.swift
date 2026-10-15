import AppKit
import ImageIO
import OpenCodeKit
import os

/// Where a machine's browser sends its page's pictures as they come.
@MainActor protocol PictureView: AnyObject {
    func show(_ picture: MachineBrowser.Picture?)
    /// The agent is about to act on the element at `rect` (CSS pixels in the window).
    func point(_ action: AgentPointer.Action, at rect: CGRect)
}

/// A machine's browser: a Chromium kept running on the machine (`kuvo-browser.js`), which the
/// agents there browse with, so it carries on while this Mac is off. Kuvo Code sets it up when it
/// connects to the machine. Its pages are the panel's browser tabs while a session on the machine
/// is in view: the one you look at shows live, and you can click and type in it yourself.
@Observable
final class MachineBrowser {
    enum Setup: Equatable {
        case unknown
        /// Downloading, by the fraction done; nil while it's being sent to the machine.
        case installing(Double?)
        case ready
        case failed(String)
    }

    enum State: Equatable {
        case idle
        case connecting
        case live
        case failed(String)
    }

    struct Page: Identifiable, Equatable {
        let id: String
        var title: String
        var url: String

        /// Nothing on it yet.
        var isBlank: Bool { url.isEmpty || url == "about:blank" }

        /// Its title, else its address, for tabs and menus.
        var name: String {
            if isBlank { return "New Tab" }
            // Until a page sets its title, Chromium gives its address without the scheme.
            if !title.isEmpty, title != url, !url.hasSuffix("://" + title) { return title }
            return URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? url
        }
    }

    /// An alert, confirmation or question the page is waiting on.
    struct Dialog: Equatable {
        var type: String
        var message: String
        var defaultPrompt: String
    }

    let machine: Machine
    private(set) var setup = Setup.unknown
    private(set) var state = State.idle
    /// The browser's pages, in the order they opened.
    private(set) var pages: [Page] = []
    /// The page in use: the one the agent or you last used.
    private(set) var activeID: String?
    /// The page the panel shows.
    private(set) var shownPage: String?
    /// Its latest picture, which goes straight to the view showing it (`pictureView`), never
    /// through SwiftUI: they come many times a second.
    @ObservationIgnored private(set) var picture: Picture? {
        didSet {
            pictureView?.show(picture)
            if (picture != nil) != hasPicture { hasPicture = picture != nil }
        }
    }
    private(set) var hasPicture = false
    /// Files its pages downloaded on the machine lately, the latest last, while the bar shows them.
    private(set) var downloads: [Download] = []

    /// A file a page downloaded into the browser's folder on the machine, and its copy on this Mac.
    struct Download: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var path: String
        var state: State = .onMachine

        enum State: Equatable { case onMachine, saving, saved(URL), failed(String) }
    }
    @ObservationIgnored weak var pictureView: PictureView? {
        didSet { pictureView?.show(picture) }
    }

    /// A picture of the page: its size and where it was scrolled to, in CSS pixels.
    struct Picture {
        var image: CGImage
        var size: CGSize
        var scroll: CGPoint
    }
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// An agent is using the browser right now.
    /// An agent is at work in the page shown.
    var isAgentBrowsing: Bool { shownPage.map(workingPages.contains) ?? false }
    /// The session of the agent at work in the page shown, when it says.
    var browsingSession: String? { shownPage.flatMap { workers[$0] } }
    /// The pages agents are at work in, and whose sessions they are.
    private var workingPages: Set<String> = []
    private var workers: [String: String] = [:]

    private static func workingPages(_ status: [String: Any]) -> Set<String> {
        guard status["working"] as? Bool == true else { return [] }
        return Set(status["pages"] as? [String] ?? [])
    }

    private func noteWorkers(_ status: [String: Any]) {
        var found: [String: String] = [:]
        for worker in status["workers"] as? [[String: Any]] ?? [] {
            if let page = worker["targetId"] as? String, let session = worker["session"] as? String { found[page] = session }
        }
        if found != workers { workers = found }
    }
    private(set) var dialog: Dialog?

    /// Told when pages open or close, and when the agent moves to another page (or you do).
    @ObservationIgnored var onPages: ([Page]) -> Void = { _ in }
    @ObservationIgnored var onActive: (_ page: String, _ byAgent: Bool, _ session: String?) -> Void = { _, _, _ in }
    /// The conversation in view, whose agent a page you pick is for.
    @ObservationIgnored var sessionInView: (() -> String?)?
    /// Told when the agent asks you for something (a sign-in, a code, a step only you can do),
    /// and when that ask ends without you (it stopped waiting, or another Mac answered).
    @ObservationIgnored var onAsk: (BrowserAsks.Ask) -> Void = { _ in }
    @ObservationIgnored var onAskClosed: (String) -> Void = { _ in }
    /// The asks open on the machine.
    @ObservationIgnored private var openAsks: Set<String> = []
    @ObservationIgnored private var expecting = false

    @ObservationIgnored private var link: MachineBrowserLink?
    @ObservationIgnored private var session: String?
    /// Goes up with each page shown, so a slower earlier switch can't win.
    @ObservationIgnored private var generation = 0
    /// The panel wants the browser while its tabs are in the strip, and while a tab shows a page.
    @ObservationIgnored private var keepers = 0
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var dropTask: Task<Void, Never>?
    @ObservationIgnored private var viewport = (size: CGSize(width: 800, height: 600), scale: CGFloat(2))
    @ObservationIgnored private var viewportTask: Task<Void, Never>?
    @ObservationIgnored private var history: [Int] = []
    @ObservationIgnored private var historyIndex = 0
    @ObservationIgnored private var preparing: Task<Void, Never>?
    @ObservationIgnored private var reconnects = 0
    private let log = Logger(subsystem: "run.kuvo.code", category: "machine-browser")

    init(machine: Machine) {
        self.machine = machine
        // After the Mac sleeps, the connection is gone, though SSH takes a while to notice: start
        // a fresh one right away.
        NotificationCenter.default.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        })
    }

    private func wake() {
        guard link != nil || state != .idle else { return }
        disconnect()
        resume()
    }

    /// Where this Mac keeps the browser for machines, put together, so the next needs no download.
    static var cache: URL { AppInfo.supportDirectory.appending(path: "browser-linux") }

    private var isWanted: Bool { keepers > 0 || viewers > 0 }

    func page(_ id: String?) -> Page? {
        pages.first { $0.id == id }
    }

    /// A page's address, unless it's empty.
    func url(of id: String?) -> URL? {
        guard let page = page(id), !page.isBlank else { return nil }
        return URL(string: page.url)
    }

    // MARK: Setting it up

    /// Makes sure the machine has the browser, installing it if not. Once at a time.
    func prepare() async {
        if setup == .ready { return }
        if let preparing { return await preparing.value }
        let task = Task { await install() }
        preparing = task
        await task.value
        preparing = nil
        if setup == .ready, isWanted, link == nil { connect() }
    }

    private func install() async {
        guard let runtime = BrowserRuntime.pinned else {
            setup = .failed(MachineBrowserError.notPinned.localizedDescription)
            return
        }
        let connection = machine.connection
        do {
            if try await MachineBrowserInstaller.isInstalled(runtime, on: connection) {
                setup = .ready
                return
            }
            setup = .installing(0)
            let architecture = try await MachineBrowserInstaller.architecture(on: connection)
            let bundle = try await MachineBrowserInstaller.bundle(for: architecture, runtime: runtime, cache: Self.cache) { fraction in
                Task { @MainActor in
                    if case .installing(let done?) = self.setup, fraction > done { self.setup = .installing(fraction) }
                }
            }
            setup = .installing(nil)
            try await MachineBrowserInstaller.send(bundle, runtime, to: connection)
            setup = .ready
            log.notice("\(self.machine.destination, privacy: .public) has the browser \(runtime.id, privacy: .public)")
        } catch {
            log.error("\(self.machine.destination, privacy: .public) couldn't get the browser: \(error.localizedDescription, privacy: .public)")
            setup = .failed(error.localizedDescription)
        }
    }

    /// The machine was removed, or you disconnected it: the live view ends with it.
    func reset() {
        disconnect()
        state = .idle
        pages = []
        shownPage = nil
        if case .failed = setup { setup = .unknown }
    }

    /// The machine is connected (again, maybe after the Mac slept): tabs in view come back live.
    func resume() {
        reconnects = 0
        guard isWanted else { return }
        connectWhenReady()
    }

    // MARK: What the panel wants

    /// The panel has this browser's tabs in its strip (or stops having them): the browser stays
    /// connected while it does, to keep them in step with its pages.
    func keep(_ keeping: Bool) {
        keepers = max(0, keepers + (keeping ? 1 : -1))
        wantsChanged()
    }

    /// A tab shows `page`: it's the page in use now, and it shows live.
    func show(_ page: String) {
        viewers += 1
        shownPage = page
        if activeID != page {
            activeID = page
            // Picked for the conversation in view: its agent goes on in this page.
            var params: [String: Any] = ["targetId": page, "by": "user"]
            if let session = sessionInView?() { params["session"] = session }
            link?.fire("Kuvo.setActive", params)
        }
        wantsChanged()
        if state == .live { Task { await attach(page) } }
    }

    /// A tab stopped showing `page` (another took its place, or the panel closed).
    func hide(_ page: String) {
        viewers = max(0, viewers - 1)
        if viewers == 0, shownPage == page {
            // A moment later, unless another tab shows it again: no more pictures.
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard viewers == 0, shownPage == page else { return }
                stopShowing()
            }
        }
        wantsChanged()
    }

    private func wantsChanged() {
        dropTask?.cancel()
        if isWanted {
            connectWhenReady()
        } else {
            // A few seconds later, if nothing wants it again: the connection closes (the browser
            // keeps running on the machine).
            dropTask = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, !isWanted else { return }
                disconnect()
            }
        }
    }

    private func connectWhenReady() {
        if setup != .ready {
            Task { await prepare() }
        } else if link == nil {
            connect()
        }
    }

    /// Connects again after it stopped.
    func retry() {
        reconnects = 0
        if setup != .ready {
            setup = .unknown
            Task { await prepare() }
        } else {
            disconnect()
            connect()
        }
    }

    private func connect() {
        guard link == nil else { return }
        state = .connecting
        let link = MachineBrowserLink(connection: machine.connection, command: MachineBrowserInstaller.command("connect"))
        link.onEvent = { [weak self] method, params, session in self?.handle(method, params, session) }
        link.onFrame = { [weak self] frame in
            guard let self, frame.session == self.session else { return }
            #if DEBUG
            meter.frame(frame.image)
            #endif
            picture = Picture(image: frame.image, size: frame.size, scroll: frame.scroll)
            // Back at the browser's own size: another viewer (another Mac) that set its size left.
            if frame.size == Self.windowSize, viewport.size != Self.windowSize { reapplyViewport() }
        }
        link.onClose = { [weak self, weak link] reason in
            guard let self, let link, self.link === link else { return }
            closed(reason)
        }
        self.link = link
        do {
            try link.start()
        } catch {
            self.link = nil
            state = .failed(error.localizedDescription)
        }
    }

    private func disconnect() {
        link?.stop()
        link = nil
        session = nil
        workingPages = []
        dialog = nil
        if case .live = state { state = .idle }
        if case .connecting = state { state = .idle }
    }

    private func closed(_ reason: String) {
        let wasLive = state == .live
        link = nil
        session = nil
        workingPages = []
        if case .failed = state { return }
        // It stopped (the machine restarted, the browser quit): back by itself if it can.
        if isWanted, reconnects < 3 {
            reconnects += 1
            state = .connecting
            Task {
                try? await Task.sleep(for: .seconds(wasLive ? 1 : 3))
                guard isWanted, link == nil else { return }
                connect()
            }
        } else {
            state = isWanted ? .failed(reason.isEmpty ? "The connection to the browser on \(machine.name) closed." : reason) : .idle
        }
    }

    private func handle(_ method: String, _ params: [String: Any], _ sessionID: String?) {
        switch method {
        case "Kuvo.hello":
            // This Mac can answer what agents ask in the browser.
            link?.fire("Kuvo.viewing")
            activeID = params["targetId"] as? String
            workingPages = (params["status"] as? [String: Any]).map(Self.workingPages) ?? []
            noteWorkers(params["status"] as? [String: Any] ?? [:])
            for ask in params["asks"] as? [[String: Any]] ?? [] { asked(ask) }
            Task { await begin() }
        case "Kuvo.asked":
            asked(params)
        case "Kuvo.pointer":
            guard params["targetId"] as? String == shownPage, let rect = params["rect"] as? [String: Any],
                  let x = (rect["x"] as? NSNumber)?.doubleValue, let y = (rect["y"] as? NSNumber)?.doubleValue,
                  let width = (rect["width"] as? NSNumber)?.doubleValue, let height = (rect["height"] as? NSNumber)?.doubleValue else { return }
            pictureView?.point(AgentPointer.Action(rawValue: params["action"] as? String ?? "") ?? .click, at: CGRect(x: x, y: y, width: width, height: height))
        case "Kuvo.downloaded":
            guard let name = params["name"] as? String, let path = params["path"] as? String else { return }
            downloads = (downloads + [Download(name: name, path: path)]).suffix(3)
            #if DEBUG
            // KUVO_DEMO_SAVE_DOWNLOADS: each download is saved to this Mac, as Save to Mac does.
            if ProcessInfo.processInfo.environment["KUVO_DEMO_SAVE_DOWNLOADS"] != nil, let id = downloads.last?.id {
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    saveToMac(id)
                }
            }
            #endif
        case "Kuvo.askClosed":
            if let id = params["id"] as? String, openAsks.remove(id) != nil { onAskClosed(id) }
        case "Kuvo.error":
            let message = params["message"] as? String ?? "The browser couldn't start."
            link?.stop()
            link = nil
            if params["kind"] as? String == "missing" {
                // Set up again: the machine lost it, or never had it.
                state = .idle
                setup = .unknown
                Task { await prepare() }
            } else {
                state = .failed(message)
            }
        case "Kuvo.activeChanged":
            guard let id = params["targetId"] as? String else {
                activeID = nil
                return
            }
            let byAgent = params["by"] as? String == "agent"
            guard id != activeID || byAgent else { return }
            activeID = id
            onActive(id, byAgent, params["session"] as? String)
        case "Kuvo.status":
            workingPages = Self.workingPages(params)
            noteWorkers(params)
        case "Target.targetCreated", "Target.targetInfoChanged":
            if let info = params["targetInfo"] as? [String: Any] { note(info) }
        case "Target.targetDestroyed":
            let id = params["targetId"] as? String
            guard pages.contains(where: { $0.id == id }) else { return }
            pages.removeAll { $0.id == id }
            if shownPage == id { stopShowing() }
            onPages(pages)
        case "Target.detachedFromTarget":
            if params["sessionId"] as? String == session { session = nil }
        default:
            guard sessionID != nil, sessionID == session else { return }
            switch method {
            case "Page.frameStartedLoading":
                if params["frameId"] as? String == shownPage { isLoading = true }
            case "Page.frameStoppedLoading":
                if params["frameId"] as? String == shownPage { isLoading = false }
            case "Page.frameNavigated":
                if (params["frame"] as? [String: Any])?["parentId"] == nil { Task { await refreshHistory() } }
            case "Page.navigatedWithinDocument":
                Task { await refreshHistory() }
                Task { await refreshPages() }
            case "Page.domContentEventFired", "Page.loadEventFired":
                Task { await refreshPages() }
            case "Page.javascriptDialogOpening":
                dialog = Dialog(type: params["type"] as? String ?? "alert", message: params["message"] as? String ?? "", defaultPrompt: params["defaultPrompt"] as? String ?? "")
            case "Page.javascriptDialogClosed":
                dialog = nil
            default:
                break
            }
        }
    }

    private func asked(_ params: [String: Any]) {
        guard let id = params["id"] as? String, !openAsks.contains(id), let host = params["host"] as? String else { return }
        let kind: BrowserAsks.Kind
        switch params["kind"] as? String {
        case "signIn": kind = .signIn(username: params["username"] as? Bool ?? false, password: params["password"] as? Bool ?? false)
        case "code": kind = .code(prompt: params["prompt"] as? String ?? "")
        case "action": kind = .action(instruction: params["instruction"] as? String ?? "")
        default: return
        }
        openAsks.insert(id)
        onAsk(BrowserAsks.Ask(id: id, kind: kind, host: host, machine: machine.id, session: params["session"] as? String))
    }

    /// Your answer to an ask, back to the machine's browser, which fills it in.
    func answer(_ id: String, _ answer: BrowserAsks.Answer) {
        openAsks.remove(id)
        let value: [String: Any] = switch answer {
        case .signIn(let username, let password): ["type": "signIn", "username": username ?? NSNull(), "password": password ?? NSNull()]
        case .code(let code): ["type": "code", "code": code]
        case .done: ["type": "done"]
        case .declined, .timedOut: ["type": "declined"]
        }
        link?.fire("Kuvo.answer", ["id": id, "answer": value])
    }

    /// An agent on the machine is about to ask you something: the browser stays connected, to
    /// hear it, until it's answered (or a while goes by without one).
    func expectAsk() {
        guard !expecting else { return }
        expecting = true
        keep(true)
        Task {
            let start = ContinuousClock.now
            while ContinuousClock.now < start + .seconds(960) {
                try? await Task.sleep(for: .seconds(5))
                if openAsks.isEmpty, ContinuousClock.now > start + .seconds(30) { break }
            }
            expecting = false
            keep(false)
        }
    }

    private func note(_ info: [String: Any]) {
        guard info["type"] as? String == "page", let id = info["targetId"] as? String else { return }
        let page = Page(id: id, title: info["title"] as? String ?? "", url: info["url"] as? String ?? "")
        if let index = pages.firstIndex(where: { $0.id == id }) {
            if pages[index] != page { pages[index] = page }
        } else {
            pages.append(page)
            onPages(pages)
        }
    }

    /// Once connected: the pages, and the one a tab shows, live.
    private func begin() async {
        guard let link else { return }
        do {
            _ = try await link.send("Target.setDiscoverTargets", ["discover": true])
            let infos = try await link.send("Target.getTargets")["targetInfos"] as? [[String: Any]] ?? []
            pages = infos.compactMap { info in
                guard info["type"] as? String == "page", let id = info["targetId"] as? String else { return nil }
                return Page(id: id, title: info["title"] as? String ?? "", url: info["url"] as? String ?? "")
            }
            state = .live
            reconnects = 0
            onPages(pages)
            if let shownPage { await attach(shownPage) }
            keepTitles(link)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Pages' titles: Chromium says when a page's address changes, not when its title does.
    private func refreshPages() async {
        guard let link, let infos = try? await link.send("Target.getTargets")["targetInfos"] as? [[String: Any]], self.link === link else { return }
        let open = Set(infos.compactMap { $0["type"] as? String == "page" ? $0["targetId"] as? String : nil })
        let gone = pages.contains { !open.contains($0.id) }
        pages.removeAll { !open.contains($0.id) }
        for info in infos { note(info) }
        if gone { onPages(pages) }
    }

    /// Every few seconds while live, for pages that change their title as you use them.
    private func keepTitles(_ link: MachineBrowserLink) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(4))
                guard let self, self.link === link, state == .live else { return }
                await refreshPages()
            }
        }
    }

    /// Shows `target` live: its pictures, at the panel's size.
    private func attach(_ target: String) async {
        guard let link, shownPage == target else { return }
        generation += 1
        let current = generation
        if let old = session {
            session = nil
            link.fire("Target.detachFromTarget", ["sessionId": old])
        }
        picture = nil
        isLoading = false
        dialog = nil
        do {
            let attached = try await link.send("Target.attachToTarget", ["targetId": target, "flatten": true])
            guard let id = attached["sessionId"] as? String else { return }
            guard generation == current, self.link === link, shownPage == target else {
                link.fire("Target.detachFromTarget", ["sessionId": id])
                return
            }
            session = id
            _ = try await link.send("Page.enable", session: id)
            // What a right-click lands on, for the Mac's own menu where the page has none.
            link.fire("Page.addScriptToEvaluateOnNewDocument", ["source": Self.menuRecorder], session: id)
            link.fire("Runtime.evaluate", ["expression": Self.menuRecorder], session: id)
            // As the page in front: it gets focus, and shows its caret.
            link.fire("Emulation.setFocusEmulationEnabled", ["enabled": true], session: id)
            await applyViewport()
            await refreshHistory()
        } catch {
            // Closed as it was picked: its tab goes with it.
            log.error("Couldn't show a page: \(error.localizedDescription, privacy: .public)")
            await refreshPages()
        }
    }

    /// No tab shows a page: no more pictures, though the connection stays for the tabs.
    private func stopShowing() {
        generation += 1
        if let old = session { link?.fire("Target.detachFromTarget", ["sessionId": old]) }
        session = nil
        shownPage = nil
        picture = nil
        isLoading = false
        dialog = nil
    }

    /// The browser's window size on the machine (`--window-size`), which pages have when nobody
    /// watching has set their own.
    static let windowSize = CGSize(width: 1280, height: 800)

    @ObservationIgnored private var lastReapplied = Date.distantPast

    private func reapplyViewport() {
        guard Date.now.timeIntervalSince(lastReapplied) > 2 else { return }
        lastReapplied = .now
        Task { await applyViewport() }
    }

    /// The view's size: the page takes it, at the screen's scale, so it lays out for the room the
    /// panel has, as the panel's own browser does.
    func resize(to size: CGSize, scale: CGFloat) {
        let size = CGSize(width: max(200, size.width.rounded()), height: max(150, size.height.rounded()))
        guard size != viewport.size || scale != viewport.scale else { return }
        viewport = (size, scale)
        viewportTask?.cancel()
        viewportTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await applyViewport()
        }
    }

    // MARK: Zoom

    /// How large pages show: below 1 they lay out wider than the panel (as on a desktop) and
    /// shrink to fit; above 1 they grow. Still at the screen's full sharpness either way.
    private(set) var zoom: CGFloat = 1
    static let zooms: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5]

    func zoom(in bigger: Bool) {
        let next = bigger ? Self.zooms.first { $0 > zoom + 0.001 } : Self.zooms.last { $0 < zoom - 0.001 }
        guard let next else { return }
        zoom = next
        Task { await applyViewport() }
    }

    func resetZoom() {
        guard zoom != 1 else { return }
        zoom = 1
        Task { await applyViewport() }
    }

    private func applyViewport() async {
        guard let link, let session else { return }
        let (size, scale) = viewport
        _ = try? await link.send("Emulation.setDeviceMetricsOverride", ["width": Int((size.width / zoom).rounded()), "height": Int((size.height / zoom).rounded()), "deviceScaleFactor": scale * zoom, "mobile": false], session: session)
        _ = try? await link.send("Page.startScreencast", ["format": "jpeg", "quality": 75, "maxWidth": Int(size.width * scale), "maxHeight": Int(size.height * scale)], session: session)
    }

    private func refreshHistory() async {
        guard let link, let session else { return }
        guard let result = try? await link.send("Page.getNavigationHistory", session: session), session == self.session else { return }
        let entries = result["entries"] as? [[String: Any]] ?? []
        history = entries.compactMap { $0["id"] as? Int }
        historyIndex = result["currentIndex"] as? Int ?? 0
        canGoBack = historyIndex > 0
        canGoForward = historyIndex < history.count - 1
    }

    // MARK: What you do

    /// Goes to an address, or searches for anything else, in the page shown.
    func load(_ input: String) {
        guard let url = BrowserSession.url(from: input) else { return }
        fire("Page.navigate", ["url": url.absoluteString])
    }

    func goBack() { step(-1) }
    func goForward() { step(1) }

    private func step(_ by: Int) {
        guard history.indices.contains(historyIndex + by) else { return }
        fire("Page.navigateToHistoryEntry", ["entryId": history[historyIndex + by]])
    }

    func reload() { fire("Page.reload") }
    func stopLoading() { fire("Page.stopLoading") }

    /// A new page, at `address` if given: its ID once the browser has opened it, or nil if it
    /// couldn't. Waits for the browser to be set up and connected first (the first time on a
    /// machine, that's a download and an upload).
    func newPage(_ address: String? = nil) async -> String? {
        connectWhenReady()
        let deadline = ContinuousClock.now + .seconds(900)
        while state != .live {
            if case .failed = setup { return nil }
            if case .failed = state { return nil }
            if ContinuousClock.now > deadline { return nil }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let link else { return nil }
        let url = address.flatMap { BrowserSession.url(from: $0)?.absoluteString } ?? "about:blank"
        guard let id = try? await link.send("Target.createTarget", ["url": url])["targetId"] as? String else { return nil }
        if !pages.contains(where: { $0.id == id }) {
            pages.append(Page(id: id, title: "", url: url))
            onPages(pages)
        }
        return id
    }

    /// Closes a page (its tab closed).
    func close(_ id: String) {
        pages.removeAll { $0.id == id }
        if shownPage == id { stopShowing() }
        link?.fire("Target.closeTarget", ["targetId": id])
    }

    func answer(_ dialog: Dialog, accept: Bool, text: String? = nil) {
        var params: [String: Any] = ["accept": accept]
        if let text { params["promptText"] = text }
        fire("Page.handleJavaScriptDialog", params)
        self.dialog = nil
    }

    #if DEBUG
    /// KUVO_DEMO_LOG_FRAMES: the live view's frames a second, their size, and how long after you
    /// scroll the page's next picture arrives, in the log.
    @ObservationIgnored private let meter = FrameMeter()

    final class FrameMeter {
        private let on = ProcessInfo.processInfo.environment["KUVO_DEMO_LOG_FRAMES"] != nil
        private let log = Logger(subsystem: "run.kuvo.code", category: "machine-browser")
        private var count = 0, since = Date.now, waitingSince: Date?, delays: [Double] = []
        private var size = ""

        func input() { if on, waitingSince == nil { waitingSince = .now } }

        func frame(_ image: CGImage) {
            guard on else { return }
            count += 1
            size = "\(image.width)x\(image.height)"
            if let start = waitingSince {
                delays.append(Date.now.timeIntervalSince(start) * 1000)
                waitingSince = nil
            }
            let elapsed = Date.now.timeIntervalSince(since)
            guard elapsed >= 1 else { return }
            let delay = delays.isEmpty ? "-" : String(format: "%.0f", delays.reduce(0, +) / Double(delays.count))
            log.notice("frames \(String(format: "%.1f", Double(self.count) / elapsed), privacy: .public)/s \(self.size, privacy: .public), scroll to frame \(delay, privacy: .public) ms")
            count = 0
            since = .now
            delays = []
        }
    }
    #endif

    // MARK: Downloads

    /// Copies a download from the machine into this Mac's Downloads folder, over SSH.
    func saveToMac(_ id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        let download = downloads[index]
        downloads[index].state = .saving
        let destination = BrowserSession.free(BrowserSession.safeName(download.name), in: BrowserSession.downloadsFolder)
        let connection = machine.connection
        Task {
            let outcome: Download.State = await Task.detached {
                guard FileManager.default.createFile(atPath: destination.path, contents: nil), let handle = try? FileHandle(forWritingTo: destination) else {
                    return .failed("Couldn't write to Downloads.")
                }
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/ssh")
                process.arguments = connection.arguments(running: "cat -- '" + download.path.replacingOccurrences(of: "'", with: "'\\''") + "'")
                process.standardOutput = handle
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {}
                try? handle.close()
                guard process.terminationStatus == 0 else {
                    try? FileManager.default.removeItem(at: destination)
                    return .failed("The file isn't on the machine any more.")
                }
                return .saved(destination)
            }.value
            if let index = downloads.firstIndex(where: { $0.id == id }) { downloads[index].state = outcome }
        }
    }

    func dismissDownloads() {
        downloads.removeAll { $0.state != .saving }
    }

    // MARK: Input

    /// CDP's modifier bits: Alt 1, Control 2, Meta 4, Shift 8.
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        (flags.contains(.option) ? 1 : 0) | (flags.contains(.control) ? 2 : 0) | (flags.contains(.command) ? 4 : 0) | (flags.contains(.shift) ? 8 : 0)
    }

    func mouse(_ type: String, at point: CGPoint, button: String = "none", buttons: Int = 0, clicks: Int = 0, modifiers: Int = 0) {
        fire("Input.dispatchMouseEvent", ["type": type, "x": point.x, "y": point.y, "button": button, "buttons": buttons, "clickCount": clicks, "modifiers": modifiers])
    }

    // MARK: Context menu

    /// Notes, as a right-click reaches the page, whether the page took it (its own menu) and what
    /// it landed on: a link, a picture, a selection, a field.
    static let menuRecorder = """
    if (!window.__kuvoMenuRecorder) {
      window.__kuvoMenuRecorder = true;
      window.addEventListener('contextmenu', (event) => {
        const target = event.target instanceof Element ? event.target : event.target && event.target.parentElement;
        const link = target && target.closest('a[href]');
        const image = target && target.closest('img');
        window.__kuvoMenu = {
          prevented: event.defaultPrevented,
          link: link ? link.href : null,
          image: image ? (image.currentSrc || image.src) : null,
          selection: String(getSelection() || '').slice(0, 20000),
          editable: !!(target && target.closest('input, textarea, [contenteditable=""], [contenteditable="true"]')),
          at: Date.now(),
        };
      });
    }
    """

    /// What the last right-click landed on, if the page left it to us.
    struct MenuTarget {
        var link: URL?
        var image: URL?
        var selection: String
        var editable: Bool
    }

    func menuTarget() async -> MenuTarget? {
        guard let link, let session else { return nil }
        let expression = "(() => { const m = window.__kuvoMenu; return m && Date.now() - m.at < 2000 && !m.prevented ? m : null })()"
        guard let result = try? await link.send("Runtime.evaluate", ["expression": expression, "returnByValue": true], session: session),
              let value = (result["result"] as? [String: Any])?["value"] as? [String: Any] else { return nil }
        return MenuTarget(
            link: (value["link"] as? String).flatMap(URL.init(string:)),
            image: (value["image"] as? String).flatMap(URL.init(string:)),
            selection: value["selection"] as? String ?? "",
            editable: value["editable"] as? Bool ?? false
        )
    }

    /// The CSS cursor over `point` in the page shown ("pointer" over a link, "text" over a field),
    /// for the Mac's own pointer.
    func cursor(at point: CGPoint) async -> String? {
        guard let link, let session else { return nil }
        let expression = """
        (() => {
          const element = document.elementFromPoint(\(Int(point.x)), \(Int(point.y)));
          if (!element) return 'default';
          const cursor = getComputedStyle(element).cursor;
          if (cursor && cursor !== 'auto') return cursor;
          const field = element.closest('textarea, [contenteditable=""], [contenteditable="true"], input:not([type=button]):not([type=submit]):not([type=checkbox]):not([type=radio]):not([type=range]):not([type=color]):not([type=file])');
          return field ? 'text' : 'default';
        })()
        """
        let result = try? await link.send("Runtime.evaluate", ["expression": expression, "returnByValue": true], session: session)
        return (result?["result"] as? [String: Any])?["value"] as? String
    }

    func wheel(at point: CGPoint, dx: CGFloat, dy: CGFloat, modifiers: Int) {
        #if DEBUG
        meter.input()
        #endif
        fire("Input.dispatchMouseEvent", ["type": "mouseWheel", "x": point.x, "y": point.y, "deltaX": dx, "deltaY": dy, "modifiers": modifiers])
    }

    func key(_ type: String, key: String, code: String, keyCode: Int, text: String? = nil, modifiers: Int = 0, commands: [String] = []) {
        var params: [String: Any] = ["type": type, "key": key, "code": code, "windowsVirtualKeyCode": keyCode, "nativeVirtualKeyCode": keyCode, "modifiers": modifiers]
        if let text {
            params["text"] = text
            params["unmodifiedText"] = text
        }
        if !commands.isEmpty { params["commands"] = commands }
        fire("Input.dispatchKeyEvent", params)
    }

    func insertText(_ text: String) {
        fire("Input.insertText", ["text": text])
    }

    func compose(_ text: String, selection: NSRange) {
        fire("Input.imeSetComposition", ["text": text, "selectionStart": selection.location, "selectionEnd": selection.location + selection.length])
    }

    /// What's selected on the page, for Copy.
    func selectedText() async -> String? {
        guard let link, let session else { return nil }
        let expression = """
            (() => {
              const element = document.activeElement;
              if (element && typeof element.selectionStart === 'number' && typeof element.value === 'string') {
                return element.value.slice(element.selectionStart, element.selectionEnd);
              }
              return String(getSelection());
            })()
            """
        let result = try? await link.send("Runtime.evaluate", ["expression": expression, "returnByValue": true], session: session)
        return (result?["result"] as? [String: Any])?["value"] as? String
    }

    /// The page in view as a PNG file in Attachments, for Add Screenshot to Message.
    func screenshotFile() -> URL? {
        guard let frame = picture?.image else { return nil }
        let host = url(of: shownPage)?.host()?.replacingOccurrences(of: "www.", with: "") ?? "page"
        guard let png = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]) else { return nil }
        return Attachments.write(png, named: "Screenshot of \(host)", extension: "png")
    }

    private func fire(_ method: String, _ params: [String: Any] = [:]) {
        guard let link, let session else { return }
        link.fire(method, params, session: session)
    }
}

// MARK: - The connection

/// One live connection to a machine's browser: `kuvo-browser.js connect` over SSH, speaking
/// Chrome's DevTools protocol, a message per line. Pictures of the page are read and decoded off
/// the main thread, and acknowledged right away, so the next one comes as soon as it's ready.
final class MachineBrowserLink {
    private let process = Process()
    private let reader: Reader
    private var next = 1
    private var waiting: [Int: CheckedContinuation<Message, Error>] = [:]
    private var stopped = false
    var onEvent: (String, [String: Any], String?) -> Void = { _, _, _ in }
    var onFrame: (Reader.Frame) -> Void = { _ in }
    var onClose: (String) -> Void = { _ in }

    /// A message as it crosses from the reading thread.
    nonisolated struct Message: @unchecked Sendable {
        var value: [String: Any]
    }

    init(connection: SSHConnection, command: String) {
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        process.arguments = connection.arguments(running: command, shared: false)
        reader = Reader()
    }

    func start() throws {
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        reader.writer = input.fileHandleForWriting
        reader.deliver = { [weak self] message in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(message) } }
        }
        reader.deliverFrame = { [weak self] frame in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onFrame(frame) } }
        }
        output.fileHandleForReading.readabilityHandler = { [reader] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                reader.read(data)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [reader] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { reader.noteError(data) }
        }
        process.terminationHandler = { [weak self, reader] _ in
            let text = reader.errors.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(text) } }
        }
        try process.run()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        fail("The browser connection closed.")
    }

    /// Sends a request and waits for its answer (30 s at most).
    func send(_ method: String, _ params: [String: Any] = [:], session: String? = nil) async throws -> [String: Any] {
        guard !stopped else { throw MachineBrowserError.browser("The browser connection closed.") }
        let id = next
        next += 1
        let message = try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            write(id: id, method, params, session: session)
            Task {
                try? await Task.sleep(for: .seconds(30))
                waiting.removeValue(forKey: id)?.resume(throwing: MachineBrowserError.browser("The browser didn't answer (\(method))."))
            }
        }
        return message.value
    }

    /// Sends a request without waiting for its answer, for input and actions.
    func fire(_ method: String, _ params: [String: Any] = [:], session: String? = nil) {
        guard !stopped else { return }
        let id = next
        next += 1
        write(id: id, method, params, session: session)
    }

    private func write(id: Int, _ method: String, _ params: [String: Any], session: String?) {
        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let session { message["sessionId"] = session }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        reader.write(data + Data("\n".utf8))
    }

    private func receive(_ message: Message) {
        let value = message.value
        if let id = value["id"] as? Int {
            guard let continuation = waiting.removeValue(forKey: id) else { return }
            if let error = value["error"] as? [String: Any] {
                continuation.resume(throwing: MachineBrowserError.browser(error["message"] as? String ?? "The browser refused that."))
            } else {
                continuation.resume(returning: Message(value: value["result"] as? [String: Any] ?? [:]))
            }
        } else if let method = value["method"] as? String {
            onEvent(method, value["params"] as? [String: Any] ?? [:], value["sessionId"] as? String)
        }
    }

    private func ended(_ output: String) {
        guard !stopped else { return }
        stopped = true
        fail(output)
        onClose(output)
    }

    private func fail(_ reason: String) {
        let pending = waiting
        waiting = [:]
        for continuation in pending.values { continuation.resume(throwing: MachineBrowserError.browser(reason.isEmpty ? "The browser connection closed." : reason)) }
    }

    /// Reads lines off the connection, and writes to it, on threads of its own.
    nonisolated final class Reader: @unchecked Sendable {
        struct Frame: @unchecked Sendable {
            var image: CGImage
            var size: CGSize
            var scroll: CGPoint
            var session: String?
        }

        var writer: FileHandle?
        var deliver: @Sendable (Message) -> Void = { _ in }
        var deliverFrame: @Sendable (Frame) -> Void = { _ in }
        private var buffer = Data()
        private let writing = DispatchQueue(label: "run.kuvo.code.machine-browser.write")
        private let lock = NSLock()
        private var errorOutput = Data()

        /// The last of what SSH wrote to stderr, for when it stops.
        var errors: String { lock.withLock { String(decoding: errorOutput, as: UTF8.self) } }

        func noteError(_ data: Data) {
            lock.withLock {
                errorOutput.append(data)
                if errorOutput.count > 8192 { errorOutput.removeFirst(errorOutput.count - 8192) }
            }
        }

        func write(_ data: Data) {
            writing.async { [writer] in try? writer?.write(contentsOf: data) }
        }

        func read(_ data: Data) {
            buffer.append(data)
            while let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<end]
                buffer.removeSubrange(buffer.startIndex...end)
                guard !line.isEmpty, let value = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                if value["method"] as? String == "Page.screencastFrame", let params = value["params"] as? [String: Any] {
                    frame(params, session: value["sessionId"] as? String)
                } else {
                    deliver(Message(value: value))
                }
            }
        }

        /// A picture of the page: acknowledged at once, so the next comes, and decoded here.
        private func frame(_ params: [String: Any], session: String?) {
            if let id = params["sessionId"] {
                var ack: [String: Any] = ["id": -1, "method": "Page.screencastFrameAck", "params": ["sessionId": id]]
                if let session { ack["sessionId"] = session }
                if let data = try? JSONSerialization.data(withJSONObject: ack) { write(data + Data("\n".utf8)) }
            }
            guard let base64 = params["data"] as? String, let data = Data(base64Encoded: base64),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return }
            let metadata = params["metadata"] as? [String: Any] ?? [:]
            let width = (metadata["deviceWidth"] as? NSNumber)?.doubleValue ?? Double(image.width)
            let height = (metadata["deviceHeight"] as? NSNumber)?.doubleValue ?? Double(image.height)
            let scroll = CGPoint(x: (metadata["scrollOffsetX"] as? NSNumber)?.doubleValue ?? 0, y: (metadata["scrollOffsetY"] as? NSNumber)?.doubleValue ?? 0)
            deliverFrame(Frame(image: image, size: CGSize(width: width, height: height), scroll: scroll, session: session))
        }
    }
}
