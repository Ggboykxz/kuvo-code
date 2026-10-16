import AppKit
import UniformTypeIdentifiers
import WebKit

/// Lets the agent use the panel's browser, the way browser-use does: it reads a page as
/// numbered interactive elements (browser-use's buildDomTree.js, MIT, bundled in
/// Resources), then clicks, types and scrolls by number. Every step happens in the
/// browser you see, and the numbers are drawn on the page while it works.
@MainActor
final class BrowserAgent {
    private let utilities: Utilities
    private let asks: BrowserAsks
    /// The bot on this Mac this agent is, which browses in tabs of its own; nil for an agent in
    /// your sessions, which uses yours.
    let owner: String?
    /// The session whose tool call this agent serves, when the engine says.
    let caller: String?

    init(utilities: Utilities, asks: BrowserAsks, owner: String? = nil, caller: String? = nil) {
        self.utilities = utilities
        self.asks = asks
        self.owner = owner
        self.caller = caller
    }

    /// Which bot on this Mac a session is, if it is one.
    static var botOwner: (String) -> String? = { _ in nil }

    /// The agent for one tool call: a bot's browses in its own tabs.
    func serving(_ caller: String?) -> BrowserAgent {
        BrowserAgent(utilities: utilities, asks: asks, owner: caller.flatMap(Self.botOwner), caller: caller)
    }

    static let stillHeld = "The user took over the browser and still has it. Carry on without it for now, or try again later; if you work on your own (a bot), schedule a wake-up to come back to it."
    static let handedBack = "The user took over the browser while you worked, and has handed it back. The page may have changed: this is where it is now. Go on from here.\n\n"

    /// While you have the page this agent would use, it waits, up to ten minutes; once you hand
    /// it back, it says so, with the page as it is now, rather than doing its step. Nil when the
    /// page is the agent's to use.
    func waitForControl() async -> String? {
        let page = owner.map { owner in use ?? utilities.botBrowser(owner) } ?? utilities.activeBrowser
        guard let page, page.isHeld else { return nil }
        page.agentWorks(caller)
        touched = page
        let started = ContinuousClock.now
        while page.isHeld, ContinuousClock.now - started < .seconds(600) {
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard !page.isHeld else { return Self.stillHeld }
        return Self.handedBack + (await snapshot())
    }

    /// The tool call ended: the page's badge stays a moment, for the next.
    func finished() {
        touched?.agentRests()
    }

    /// The page this call worked in.
    private weak var touched: BrowserSession?

    // MARK: Actions

    func navigate(_ address: String) async -> String {
        let browser = browser()
        guard BrowserSession.url(from: address) != nil else { return "Not an address or search: \(address)" }
        browser.load(address)
        await settle(browser, expectNavigation: true)
        return await snapshot()
    }

    func newTab(_ address: String?) async -> String {
        let browser = utilities.newBrowser(address, byAgent: true, owner: owner)
        Analytics.shared.trackOnce("agent_used_browser")
        utilities.reveal()
        if address != nil { await settle(browser, expectNavigation: true) }
        return await snapshot()
    }

    /// Attaches files on this Mac to the page's file input [index] (or the one its button is for).
    func upload(_ index: Int, files paths: [String]) async -> String {
        let browser = browser()
        var files: [[String: String]] = []
        var total = 0
        for path in paths {
            let url = URL(filePath: (path as NSString).expandingTildeInPath)
            guard let data = try? Data(contentsOf: url) else { return "Can't read \(path) on this Mac. Give its full path." }
            total += data.count
            guard total <= 25_000_000 else { return "That's too much to attach at once (25 MB at most)." }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            files.append(["name": url.lastPathComponent, "type": type, "data": data.base64EncodedString()])
        }
        let outcome = await run(Self.uploadScript, ["index": index, "files": files], in: browser)
        switch outcome {
        case "ok":
            try? await Task.sleep(for: .milliseconds(400))
            return "Attached \(paths.count == 1 ? "the file" : "\(paths.count) files").\n\n" + (await snapshot())
        case "missing": return "There's no element [\(index)] on the page now. Take a fresh browser_snapshot."
        case "none": return "[\(index)] isn't a file input, and the page doesn't have just one. Give the number of the upload button or its file input."
        default: return outcome
        }
    }

    /// What happened in the browser since the agent's last tool (a download), for its next result.
    func takeNotes() -> String {
        let notes = utilities.browsers.values.flatMap { browser in
            defer { browser.agentNotes = [] }
            return browser.agentNotes
        }
        return notes.isEmpty ? "" : notes.joined(separator: "\n") + "\n\n"
    }

    static let unanswered = "The user didn't answer in time. Carry on with what you can without it, and say in your reply what you need; if you work on your own (a bot), schedule a wake-up to try again later."

    /// Browser tools at work: while any is, dialogs pages show are answered at once.
    static var working = 0
    static var isWorking: Bool { working > 0 }
    /// Of them, those that said to accept confirmations and prompts rather than decline them.
    static var accepting = 0
    static var acceptsDialogs: Bool { accepting > 0 }

    /// The panel's browser tabs (a bot's own, for a bot), numbered from 1; or switches to one, or
    /// closes one.
    func tabs(_ action: String, tab number: Int?) async -> String {
        let open = utilities.browserTabs(of: owner)
        if action != "list" {
            guard let number, open.indices.contains(number - 1) else { return "There's no tab [\(number ?? 0)]. " + Self.list(open.map(\.browser), inUse: utilities.activeBrowser) }
            let chosen = open[number - 1]
            if action == "close" {
                utilities.close(chosen.id)
                return "Closed tab [\(number)]. " + Self.list(utilities.browserTabs(of: owner).map(\.browser), inUse: inUse)
            }
            utilities.reveal(chosen.browser)
            if owner != nil { use = chosen.browser }
            return await snapshot()
        }
        return Self.list(open.map(\.browser), inUse: inUse)
    }

    private static func list(_ browsers: [BrowserSession], inUse: BrowserSession?) -> String {
        guard !browsers.isEmpty else { return "No tabs are open." }
        return "Tabs:\n" + browsers.enumerated().map { index, browser in
            let title = browser.title.isEmpty ? "(untitled)" : browser.title
            return "[\(index + 1)] \(title) — \(browser.url?.absoluteString ?? "empty")" + (browser === inUse ? " (in use)" : "")
        }.joined(separator: "\n")
    }

    /// The page as text: title, address, scroll position, and its numbered elements.
    func snapshot() async -> String {
        let browser = browser()
        guard browser.url != nil else { return "The browser is empty. Use browser_navigate to open a page." }
        let script = Self.snapshotScript
        let result = try? await browser.webView.callAsyncJavaScript(script, contentWorld: .page) as? [String: Any]
        guard let result else { return "Couldn't read the page at \(browser.url?.absoluteString ?? "")." }
        let text = result["text"] as? String ?? ""
        let above = result["above"] as? Int ?? 0, below = result["below"] as? Int ?? 0
        let body = text.count > 18_000 ? String(text.prefix(18_000)) + "\n… (cut; scroll or use browser_text for more)" : text
        return """
        Page: \(result["title"] as? String ?? "")
        URL: \(result["url"] as? String ?? "")
        Scroll: \(above) px above, \(below) px below
        Interactive elements are numbered like [3]; use the number with browser_click, browser_type and browser_select.

        \(body.isEmpty ? "(no visible content)" : body)
        """
    }

    func click(_ index: Int) async -> String {
        let browser = browser()
        let before = browser.url
        await point(.click, at: index, in: browser)
        let outcome = await run(Self.clickScript, ["index": index], in: browser)
        guard outcome == "ok" else { return outcome }
        await settleAfterClick(browser, from: before)
        return "Clicked [\(index)].\n\n" + (await snapshot())
    }

    func type(_ index: Int, text: String, submit: Bool, clear: Bool) async -> String {
        let browser = browser()
        await point(.type, at: index, in: browser)
        let outcome = await run(Self.typeScript, ["index": index, "text": text, "submit": submit, "clear": clear], in: browser)
        guard outcome == "ok" else { return outcome }
        await settle(browser, expectNavigation: submit)
        return "Typed into [\(index)]\(submit ? " and submitted" : "").\n\n" + (await snapshot())
    }

    func select(_ index: Int, option: String) async -> String {
        let browser = browser()
        await point(.select, at: index, in: browser)
        let outcome = await run(Self.selectScript, ["index": index, "option": option], in: browser)
        guard outcome == "ok" else { return outcome }
        await settle(browser, expectNavigation: false)
        return "Selected “\(option)” in [\(index)].\n\n" + (await snapshot())
    }

    func scroll(down: Bool, pages: Double) async -> String {
        let browser = browser()
        _ = await run("window.scrollBy({top: (down ? 1 : -1) * window.innerHeight * 0.85 * pages, behavior: 'instant'}); return 'ok';", ["down": down, "pages": pages], in: browser)
        try? await Task.sleep(for: .milliseconds(300))
        return await snapshot()
    }

    func press(_ key: String) async -> String {
        let browser = browser()
        let outcome = await run(Self.pressScript, ["key": key], in: browser)
        guard outcome == "ok" else { return outcome }
        await settle(browser, expectNavigation: key == "Enter")
        return "Pressed \(key).\n\n" + (await snapshot())
    }

    func back() async -> String {
        let browser = browser()
        guard browser.canGoBack else { return "There's no page to go back to." }
        browser.webView.goBack()
        await settle(browser, expectNavigation: true)
        return await snapshot()
    }

    func forward() async -> String {
        let browser = browser()
        guard browser.canGoForward else { return "There's no page to go forward to." }
        browser.webView.goForward()
        await settle(browser, expectNavigation: true)
        return await snapshot()
    }

    /// The page's readable text, for reading rather than acting.
    func text() async -> String {
        let browser = browser()
        let text = (try? await browser.webView.callAsyncJavaScript("return document.body ? document.body.innerText : ''", contentWorld: .page) as? String) ?? ""
        return text.count > 30_000 ? String(text.prefix(30_000)) + "\n… (cut)" : (text.isEmpty ? "(no text)" : text)
    }

    /// What's on screen, as a PNG (base64), at most 1280 points wide.
    func screenshot() async -> String? {
        let browser = browser()
        // What you filled in stays out of the picture.
        _ = await run(Self.maskScript, [:], in: browser)
        let image = try? await browser.webView.takeSnapshot(configuration: nil)
        _ = await run(Self.unmaskScript, [:], in: browser)
        guard let image else { return nil }
        let scale = min(1, 1280 / max(image.size.width, 1))
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])?.base64EncodedString()
    }

    // MARK: Asking you

    /// Signs in with your username and password, which you type (or pick from your saved
    /// passwords) in Kuvo Code: they go straight into the fields named, and the agent never sees
    /// them. A password only goes into a password field.
    func signIn(username: Int?, password: Int?, for caller: String? = nil) async -> String {
        let browser = browser()
        guard let host = Self.site(of: browser.url) else { return "Open the sign-in page first." }
        guard username != nil || password != nil else { return "Name the username field, the password field, or both, by number." }
        if let problem = await checkFields(username: username, password: password, in: browser) { return problem }
        switch await asks.ask(.signIn(username: username != nil, password: password != nil), host: host, session: caller) {
        case .signIn(let user, let secret):
            var filled: [String] = []
            if let username, let user, !user.isEmpty {
                let outcome = await run(Self.fillScript, ["index": username, "value": user], in: browser)
                guard outcome == "ok" else { return outcome }
                filled.append("the username")
            }
            if let password, let secret, !secret.isEmpty {
                let outcome = await run(Self.fillScript, ["index": password, "value": secret], in: browser)
                guard outcome == "ok" else { return outcome }
                filled.append("the password")
            }
            guard !filled.isEmpty else { return "The user didn't give a sign-in for that." }
            try? await Task.sleep(for: .milliseconds(300))
            return "Filled \(filled.joined(separator: " and ")) for \(host) (you can't see them). Submit the form to sign in.\n\n" + (await snapshot())
        case .timedOut:
            return Self.unanswered
        default:
            return "The user didn't sign in. Ask them in the chat how to go on."
        }
    }

    /// A one-time code (from a text, an email or an authenticator) that you type in Kuvo Code,
    /// filled into the field named.
    func askCode(_ index: Int, prompt: String?, for caller: String? = nil) async -> String {
        let browser = browser()
        guard let host = Self.site(of: browser.url) else { return "Open the page that asks for the code first." }
        let kind = await run(Self.fieldKindScript, ["index": index], in: browser)
        guard kind == "text" || kind == "password" else { return kind == "missing" ? "There's no element [\(index)] on the page now. Take a fresh browser_snapshot." : "[\(index)] isn't a field to type a code into." }
        switch await asks.ask(.code(prompt: prompt ?? ""), host: host, session: caller) {
        case .code(let code):
            let outcome = await run(Self.fillScript, ["index": index, "value": code], in: browser)
            guard outcome == "ok" else { return outcome }
            try? await Task.sleep(for: .milliseconds(300))
            return "Filled the code (you can't see it). Submit it if the page doesn't on its own.\n\n" + (await snapshot())
        case .timedOut:
            return Self.unanswered
        default:
            return "The user didn't give a code. Ask them in the chat how to go on."
        }
    }

    /// Something only you can do on the page (a CAPTCHA, approving the sign-in on your phone):
    /// waits until you say you're done.
    func askUser(_ instruction: String, for caller: String? = nil) async -> String {
        let browser = browser()
        let host = Self.site(of: browser.url) ?? "the page"
        switch await asks.ask(.action(instruction: instruction), host: host, session: caller) {
        case .done:
            await settle(browser, expectNavigation: false)
            return "The user says it's done.\n\n" + (await snapshot())
        case .timedOut:
            return Self.unanswered
        default:
            return "The user couldn't do it. Ask them in the chat how to go on."
        }
    }

    /// The site a page is on, as the ask names it and Passwords keeps it: its host, or for a page
    /// from a file, that it is one.
    static func site(of url: URL?) -> String? {
        guard let url else { return nil }
        return url.isFileURL ? "a file on this Mac" : url.host()
    }

    /// Nil if the fields are there and fit what goes in them, else why not.
    private func checkFields(username: Int?, password: Int?, in browser: BrowserSession) async -> String? {
        for (index, wanted) in [(password, "password"), (username, "text")] {
            guard let index else { continue }
            let kind = await run(Self.fieldKindScript, ["index": index], in: browser)
            if kind == "missing" { return "There's no element [\(index)] on the page now. Take a fresh browser_snapshot." }
            if wanted == "password", kind != "password" { return "[\(index)] isn't a password field: a password only goes into one." }
            if wanted == "text", kind != "text" { return "[\(index)] isn't a field for a username or email." }
        }
        return nil
    }

    func wait(_ seconds: Double) async -> String {
        try? await Task.sleep(for: .seconds(min(max(seconds, 0), 10)))
        return await snapshot()
    }

    /// Until `wanted` shows on the page, for 30 seconds at most.
    func wait(for wanted: String) async -> String {
        let browser = browser()
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            let found = try? await browser.webView.callAsyncJavaScript("return (document.body ? document.body.innerText : '').toLowerCase().includes(wanted.toLowerCase())", arguments: ["wanted": wanted], contentWorld: .page) as? Bool
            if found == true { return "“\(wanted)” is on the page.\n\n" + (await snapshot()) }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return "“\(wanted)” didn't show up in 30 seconds.\n\n" + (await snapshot())
    }

    func hover(_ index: Int) async -> String {
        let browser = browser()
        await point(.hover, at: index, in: browser)
        let outcome = await run(Self.hoverScript, ["index": index], in: browser)
        guard outcome == "ok" else { return outcome }
        try? await Task.sleep(for: .milliseconds(400))
        return "Hovered over [\(index)].\n\n" + (await snapshot())
    }

    // MARK: Helpers

    /// The browser in view, or a new one; either way the panel shows it. A bot on this Mac uses
    /// its own tab, out of sight unless its conversation is in view.
    private func browser() -> BrowserSession {
        let browser: BrowserSession
        if let owner {
            browser = use ?? utilities.botBrowser(owner) ?? utilities.newBrowser(byAgent: true, owner: owner)
            use = browser
        } else {
            browser = utilities.activeBrowser ?? utilities.newBrowser(byAgent: true)
        }
        Analytics.shared.trackOnce("agent_used_browser")
        utilities.reveal(browser)
        browser.agentWorks(caller)
        touched = browser
        return browser
    }

    /// The tab a bot works in during this call.
    private var use: BrowserSession?

    /// The tab in use, for the tab list.
    private var inUse: BrowserSession? {
        owner.flatMap { utilities.botBrowser($0) } ?? utilities.activeBrowser
    }

    /// Shows the pointer where the agent's about to act, and gives it a moment to get there.
    private func point(_ action: AgentPointer.Action, at index: Int, in browser: BrowserSession) async {
        guard let json = try? await browser.webView.callAsyncJavaScript(Self.findElement + Self.rectScript, arguments: ["index": index], contentWorld: .page) as? String,
              let values = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Double],
              let x = values["x"], let y = values["y"], let width = values["width"], let height = values["height"] else { return }
        browser.showAgentStep(action, at: CGRect(x: x, y: y, width: width, height: height))
        try? await Task.sleep(for: .milliseconds(150))
    }

    /// Runs one of the element scripts with the index map from the last snapshot.
    private func run(_ body: String, _ arguments: [String: Any], in browser: BrowserSession) async -> String {
        do {
            let result = try await browser.webView.callAsyncJavaScript(Self.findElement + body, arguments: arguments, contentWorld: .page)
            return result as? String ?? "ok"
        } catch {
            return "The page refused that: \(error.localizedDescription)"
        }
    }

    /// A click may start a navigation a beat later: wait up to a second for the address to
    /// change or loading to begin, then for it to finish.
    private func settleAfterClick(_ browser: BrowserSession, from before: URL?) async {
        let start = ContinuousClock.now
        while ContinuousClock.now < start + .seconds(1), !browser.isLoading, browser.url == before {
            try? await Task.sleep(for: .milliseconds(100))
        }
        await settle(browser, expectNavigation: browser.isLoading || browser.url != before)
    }

    /// Waits for a navigation to start and finish (up to 10 s), then a moment for the page to settle.
    private func settle(_ browser: BrowserSession, expectNavigation: Bool) async {
        if expectNavigation { try? await Task.sleep(for: .milliseconds(250)) }
        let deadline = ContinuousClock.now + .seconds(10)
        while browser.isLoading, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
        try? await Task.sleep(for: .milliseconds(expectNavigation ? 500 : 350))
    }

    // MARK: Scripts

    static let domTree: String = {
        guard let url = Bundle.main.url(forResource: "buildDomTree", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return "() => ({ rootId: null, map: {} })" }
        // The file is one arrow function ending in ";", which can't sit inside parentheses.
        var function = source.trimmingCharacters(in: .whitespacesAndNewlines)
        while function.hasSuffix(";") { function.removeLast() }
        return function
    }()

    /// Runs buildDomTree, keeps index → XPath for the actions, and writes the elements out
    /// the way browser-use shows them to a model.
    static let snapshotScript = """
    document.getElementById('playwright-highlight-container')?.remove();
    const result = (\(domTree))({ doHighlightElements: false, focusHighlightIndex: -1, viewportExpansion: 0, debugMode: false });
    const map = result.map || {};
    const ATTRIBUTES = ['title', 'type', 'checked', 'name', 'role', 'value', 'placeholder', 'alt', 'aria-label', 'aria-expanded', 'aria-checked', 'data-state', 'href'];
    const index = {};
    const lines = [];
    const clean = (text) => text.replace(/\\s+/g, ' ').trim();
    function textUntilClickable(id) {
      const parts = [];
      (function walk(nodeID, isRoot) {
        const node = map[nodeID];
        if (!node) return;
        if (node.type === 'TEXT_NODE') { if (node.isVisible !== false) parts.push(node.text); return; }
        if (!isRoot && node.highlightIndex !== undefined && node.highlightIndex !== null) return;
        (node.children || []).forEach((child) => walk(child, false));
      })(id, true);
      return clean(parts.join(' '));
    }
    (function walk(nodeID, insideClickable) {
      const node = map[nodeID];
      if (!node) return;
      if (node.type === 'TEXT_NODE') {
        if (!insideClickable && node.isVisible !== false && clean(node.text)) lines.push(clean(node.text));
        return;
      }
      let inside = insideClickable;
      if (node.highlightIndex !== undefined && node.highlightIndex !== null) {
        index[node.highlightIndex] = node.xpath;
        const attributes = ATTRIBUTES
          .filter((name) => node.attributes && node.attributes[name])
          // A password field's value never goes to the model.
          .filter((name) => !(name === 'value' && String(node.attributes.type).toLowerCase() === 'password'))
          // Nor what the user filled in through Kuvo Code.
          .filter((name) => !(name === 'value' && node.attributes['data-kuvo-secret'] !== undefined))
          .map((name) => `${name}="${String(node.attributes[name]).slice(0, 100)}"`)
          .join(' ');
        const tag = node.tagName || 'element';
        lines.push(`[${node.highlightIndex}]<${tag}${attributes ? ' ' + attributes : ''}>${textUntilClickable(nodeID).slice(0, 150)}</${tag}>`);
        inside = true;
      }
      (node.children || []).forEach((child) => walk(child, inside));
    })(result.rootId, false);
    window.__kuvoIndex = index;
    // A page that asks to sign in (or for a one-time code) says what to do about it, where the
    // agent reads it: ask the user in Kuvo Code, not in the chat.
    const shown = (field) => !field.disabled && field.getClientRects().length > 0 && getComputedStyle(field).visibility !== 'hidden';
    const fields = [...document.querySelectorAll('input')].filter(shown);
    const filled = fields.some((field) => field.hasAttribute('data-kuvo-secret'));
    const autocomplete = (pattern) => fields.some((field) => pattern.test(field.autocomplete || ''));
    if (!filled && autocomplete(/one-time-code/)) {
      lines.unshift('(This page asks for a one-time code: call browser_ask_code with its field now, unless the user already said no. The user types it in Kuvo Code; never ask for it in the chat.)', '');
    } else if (!filled && (fields.some((field) => field.type === 'password') || autocomplete(/\\busername\\b|current-password/))) {
      lines.unshift('(This page asks to sign in: call browser_sign_in with its fields now, unless the user already said no. The user answers in Kuvo Code, where they can also say Not Now; do not ask in the chat whether to sign in, or for their password.)', '');
    }
    const scrollHeight = Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0);
    return {
      text: lines.join('\\n'),
      title: document.title,
      url: location.href,
      above: Math.round(window.scrollY),
      below: Math.max(0, Math.round(scrollHeight - window.scrollY - window.innerHeight)),
    };
    """

    static let findElement = """
    const find = (number) => {
      const xpath = (window.__kuvoIndex || {})[number];
      if (!xpath) return null;
      const path = xpath.startsWith('/') ? xpath : '/' + xpath;
      return document.evaluate(path, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;
    };
    const missing = (number) => `There's no element [${number}] on the page now. Take a fresh browser_snapshot.`;

    """

    /// Brings [index] into view, as the actions do, and says where it is (JSON, CSS pixels from
    /// the window's top left), for the pointer that shows what the agent's doing.
    static let rectScript = """
    const element = find(index);
    if (!element) return '';
    element.scrollIntoView({ block: 'center', inline: 'nearest' });
    const r = element.getBoundingClientRect();
    return JSON.stringify({ x: r.left, y: r.top, width: r.width, height: r.height });
    """

    /// What the page hears when the pointer comes over [index].
    static let hoverScript = """
    const element = find(index);
    if (!element) return missing(index);
    element.scrollIntoView({ block: 'center', inline: 'nearest' });
    const rect = element.getBoundingClientRect();
    const options = { bubbles: true, cancelable: true, view: window, clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2 };
    for (const type of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointermove', 'mousemove']) {
      const bubbles = !type.endsWith('enter');
      element.dispatchEvent(type.startsWith('pointer') ? new PointerEvent(type, { ...options, bubbles }) : new MouseEvent(type, { ...options, bubbles }));
    }
    return 'ok';
    """

    static let clickScript = """
    const element = find(index);
    if (!element) return missing(index);
    document.getElementById('playwright-highlight-container')?.remove();
    element.scrollIntoView({ block: 'center', inline: 'nearest' });
    const rect = element.getBoundingClientRect();
    const options = { bubbles: true, cancelable: true, view: window, clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2, button: 0 };
    for (const type of ['pointerover', 'pointerdown', 'mousedown', 'pointerup', 'mouseup']) {
      element.dispatchEvent(type.startsWith('pointer') ? new PointerEvent(type, options) : new MouseEvent(type, options));
    }
    if (typeof element.focus === 'function') element.focus();
    element.click();
    return 'ok';
    """

    static let typeScript = """
    const element = find(index);
    if (!element) return missing(index);
    document.getElementById('playwright-highlight-container')?.remove();
    element.scrollIntoView({ block: 'center' });
    element.focus();
    if (element.isContentEditable) {
      if (clear) { document.execCommand('selectAll', false); document.execCommand('delete', false); }
      document.execCommand('insertText', false, text);
    } else if ('value' in element) {
      const prototype = element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(prototype, 'value').set;
      setter.call(element, (clear ? '' : element.value) + text);
      element.dispatchEvent(new Event('input', { bubbles: true }));
      element.dispatchEvent(new Event('change', { bubbles: true }));
    } else {
      return `[${index}] doesn't take text. Click it first, or pick an input.`;
    }
    if (submit) {
      const init = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
      const proceed = element.dispatchEvent(new KeyboardEvent('keydown', init));
      element.dispatchEvent(new KeyboardEvent('keypress', init));
      element.dispatchEvent(new KeyboardEvent('keyup', init));
      if (proceed && element.form) element.form.requestSubmit ? element.form.requestSubmit() : element.form.submit();
    }
    return 'ok';
    """

    static let selectScript = """
    const element = find(index);
    if (!element) return missing(index);
    if (!(element instanceof HTMLSelectElement)) return `[${index}] isn't a list to select from.`;
    const wanted = option.toLowerCase();
    const match = Array.from(element.options).find((item) => item.text.trim().toLowerCase() === wanted || item.value.toLowerCase() === wanted);
    if (!match) return `No option “${option}” in [${index}]. Options: ` + Array.from(element.options).map((item) => item.text.trim()).join(', ');
    element.value = match.value;
    element.dispatchEvent(new Event('input', { bubbles: true }));
    element.dispatchEvent(new Event('change', { bubbles: true }));
    return 'ok';
    """

    /// The file input [index] stands for: itself, one inside it or that its label is for, the
    /// nearest one around it (an upload button beside its hidden input), or the page's only one;
    /// else "missing" or "none".
    static let fileInputScript = """
    const element = find(index);
    if (!element) return 'missing';
    const isFile = (node) => node instanceof HTMLInputElement && node.type === 'file';
    let input = isFile(element) ? element : element.querySelector && element.querySelector('input[type=file]');
    const label = element.closest && element.closest('label');
    if (!input && label && isFile(label.control)) input = label.control;
    for (let around = element.parentElement, level = 0; !input && around && level < 3; around = around.parentElement, level++) {
      const inside = around.querySelectorAll('input[type=file]');
      if (inside.length === 1) input = inside[0];
    }
    if (!input) {
      const all = [...document.querySelectorAll('input[type=file]')];
      if (all.length === 1) input = all[0];
    }
    return input || 'none';
    """

    /// Puts `files` ({name, type, data in base64}) into the file input [index], as choosing them
    /// in the file picker would.
    static let uploadScript = """
    const input = (() => {
    \(fileInputScript)
    })();
    if (typeof input === 'string') return input;
    const transfer = new DataTransfer();
    for (const file of files) {
      const bytes = Uint8Array.from(atob(file.data), (c) => c.charCodeAt(0));
      transfer.items.add(new File([bytes], file.name, { type: file.type }));
    }
    input.files = transfer.files;
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
    return 'ok';
    """

    /// What kind of field [index] is: "password", "text" (a username, an email, a code), "other"
    /// or "missing".
    static let fieldKindScript = """
    const element = find(index);
    if (!element) return 'missing';
    if (element instanceof HTMLInputElement) {
      const type = (element.type || 'text').toLowerCase();
      if (type === 'password') return 'password';
      return ['text', 'email', 'tel', 'number', 'search', 'url'].includes(type) ? 'text' : 'other';
    }
    return element instanceof HTMLTextAreaElement ? 'text' : 'other';
    """

    /// Puts what the user gave into [index], as typing would, and marks it so it stays out of
    /// what the agent reads and sees.
    static let fillScript = """
    const element = find(index);
    if (!element) return missing(index);
    element.scrollIntoView({ block: 'center' });
    element.focus();
    const prototype = element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(prototype, 'value').set.call(element, value);
    element.dispatchEvent(new Event('input', { bubbles: true }));
    element.dispatchEvent(new Event('change', { bubbles: true }));
    element.setAttribute('data-kuvo-secret', '');
    return 'ok';
    """

    /// Hides what the user filled in, for a screenshot, and shows it again.
    static let maskScript = """
    if (!document.getElementById('kuvo-secret-mask')) {
      const style = document.createElement('style');
      style.id = 'kuvo-secret-mask';
      style.textContent = '[data-kuvo-secret]{color:transparent!important;-webkit-text-fill-color:transparent!important;text-shadow:none!important}';
      (document.head || document.documentElement).appendChild(style);
    }
    return 'ok';
    """

    static let unmaskScript = """
    document.getElementById('kuvo-secret-mask')?.remove();
    return 'ok';
    """

    static let pressScript = """
    const target = document.activeElement || document.body;
    const codes = { Enter: 13, Escape: 27, Tab: 9, Backspace: 8, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39, ' ': 32 };
    const init = { key: key, code: key, keyCode: codes[key] || 0, which: codes[key] || 0, bubbles: true, cancelable: true };
    const proceed = target.dispatchEvent(new KeyboardEvent('keydown', init));
    if (key === 'Enter') target.dispatchEvent(new KeyboardEvent('keypress', init));
    target.dispatchEvent(new KeyboardEvent('keyup', init));
    if (key === 'Enter' && proceed && target.form) target.form.requestSubmit ? target.form.requestSubmit() : target.form.submit();
    if (key === 'Escape' && typeof target.blur === 'function') target.blur();
    return 'ok';
    """
}
