import AppKit
import WebKit

/// Lets the agent use the panel's browser, the way browser-use does: it reads a page as
/// numbered interactive elements (browser-use's buildDomTree.js, MIT, bundled in
/// Resources), then clicks, types and scrolls by number. Every step happens in the
/// browser you see, and the numbers are drawn on the page while it works.
@MainActor
final class BrowserAgent {
    private let utilities: Utilities

    init(utilities: Utilities) {
        self.utilities = utilities
    }

    // MARK: Actions

    func navigate(_ address: String) async -> String {
        let browser = browser()
        guard BrowserSession.url(from: address) != nil else { return "Not an address or search: \(address)" }
        browser.load(address)
        await settle(browser, expectNavigation: true)
        return await snapshot()
    }

    func newTab(_ address: String?) async -> String {
        let browser = utilities.newBrowser(address, byAgent: true)
        Analytics.shared.trackOnce("agent_used_browser")
        utilities.reveal()
        if address != nil { await settle(browser, expectNavigation: true) }
        return await snapshot()
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
        let outcome = await run(Self.clickScript, ["index": index], in: browser)
        guard outcome == "ok" else { return outcome }
        await settleAfterClick(browser, from: before)
        return "Clicked [\(index)].\n\n" + (await snapshot())
    }

    func type(_ index: Int, text: String, submit: Bool, clear: Bool) async -> String {
        let browser = browser()
        let outcome = await run(Self.typeScript, ["index": index, "text": text, "submit": submit, "clear": clear], in: browser)
        guard outcome == "ok" else { return outcome }
        await settle(browser, expectNavigation: submit)
        return "Typed into [\(index)]\(submit ? " and submitted" : "").\n\n" + (await snapshot())
    }

    func select(_ index: Int, option: String) async -> String {
        let browser = browser()
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
        guard let image = try? await browser.webView.takeSnapshot(configuration: nil) else { return nil }
        let scale = min(1, 1280 / max(image.size.width, 1))
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])?.base64EncodedString()
    }

    func wait(_ seconds: Double) async -> String {
        try? await Task.sleep(for: .seconds(min(max(seconds, 0), 10)))
        return await snapshot()
    }

    // MARK: Helpers

    /// The browser in view, or a new one; either way the panel shows it.
    private func browser() -> BrowserSession {
        let browser = utilities.activeBrowser ?? utilities.newBrowser(byAgent: true)
        Analytics.shared.trackOnce("agent_used_browser")
        utilities.reveal(browser)
        return browser
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
          .map((name) => `${name}="${String(node.attributes[name]).slice(0, 100)}"`)
          .join(' ');
        const tag = node.tagName || 'element';
        lines.push(`[${node.highlightIndex}]<${tag}${attributes ? ' ' + attributes : ''}>${textUntilClickable(nodeID).slice(0, 150)}</${tag}>`);
        inside = true;
      }
      (node.children || []).forEach((child) => walk(child, inside));
    })(result.rootId, false);
    window.__kuvoIndex = index;
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

    static let clickScript = """
    const element = find(index);
    if (!element) return missing(index);
    document.getElementById('playwright-highlight-container')?.remove();
    element.scrollIntoView({ block: 'center', inline: 'center' });
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
