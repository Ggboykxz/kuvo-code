import AppKit
import SwiftUI

/// A machine's browser in the panel: its page live, with back, forward, reload and the address,
/// its pages in a menu, and what the agent is doing. Clicks, scrolling and typing go to the page.
struct MachineBrowserPane: View {
    let browser: MachineBrowser
    /// Attaches files to the message being written, for Add Screenshot to Message.
    var attach: ([URL]) -> Void = { _ in }
    @State private var address = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                navigation
                addressField
                actions
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            if let dialog = browser.dialog {
                DialogBar(dialog: dialog, browser: browser)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.ui, value: browser.dialog)
        .onAppear {
            browser.show()
            address = displayAddress
        }
        .onDisappear { browser.hide() }
        .onChange(of: browser.url) { if !editing { address = displayAddress } }
        .onChange(of: editing) { _, isEditing in address = isEditing ? (browser.url?.absoluteString ?? "") : displayAddress }
    }

    @ViewBuilder private var content: some View {
        switch browser.setup {
        case .unknown:
            Spinner(size: 16)
        case .installing(let progress):
            SetupCard(machine: browser.machine.name, progress: progress)
        case .failed(let message):
            problem("Couldn’t Set Up the Browser", message) { browser.retry() }
        case .ready:
            switch browser.state {
            case .failed(let message):
                problem("The Browser Isn’t Available", message) { browser.retry() }
            case .idle, .connecting:
                ZStack {
                    LivePage(browser: browser)
                        .opacity(0.4)
                    Spinner(size: 16)
                }
            case .live:
                LivePage(browser: browser)
                    .overlay(alignment: .bottom) {
                        if browser.isAgentBrowsing {
                            AgentBadge()
                                .padding(.bottom, 12)
                                .transition(.opacity)
                        }
                    }
                    .overlay {
                        if browser.url == nil, !browser.isLoading {
                            EmptyPageHint(machine: browser.machine.name)
                                .allowsHitTesting(false)
                        }
                    }
                    .animation(.ui, value: browser.isAgentBrowsing)
            }
        }
    }

    private func problem(_ title: String, _ message: String, retry: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
                .textSelection(.enabled)
        } actions: {
            Button("Try Again", action: retry)
        }
    }

    private var isLive: Bool { browser.state == .live }

    private var navigation: some View {
        HStack(spacing: 0) {
            Button { browser.goBack() } label: { Label("Back", systemImage: "arrow.left") }
                .disabled(!isLive || !browser.canGoBack)
                .help("Back")
            Button { browser.goForward() } label: { Label("Forward", systemImage: "arrow.right") }
                .disabled(!isLive || !browser.canGoForward)
                .help("Forward")
            Divider().frame(height: 16).padding(.horizontal, 2)
            Button {
                if browser.isLoading { browser.stopLoading() } else { browser.reload() }
            } label: {
                Label(browser.isLoading ? "Stop" : "Reload", systemImage: browser.isLoading ? "xmark" : "arrow.clockwise")
            }
            .disabled(!isLive || browser.url == nil)
            .help(browser.isLoading ? "Stop" : "Reload")
        }
        .buttonStyle(ToolbarGroupStyle())
        .padding(.horizontal, 3)
        .frame(height: 34)
        .background(Color.primary.opacity(0.06), in: .capsule)
    }

    private var addressField: some View {
        HStack(spacing: 7) {
            Image(systemName: browser.url?.scheme == "https" && !editing ? "lock.fill" : "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Search or enter a URL", text: $address)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($editing)
                .disabled(!isLive)
                .onSubmit {
                    browser.load(address)
                    editing = false
                }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color.primary.opacity(0.06), in: .capsule)
        .overlay(alignment: .bottom) {
            if browser.isLoading {
                Capsule().fill(.tint).frame(height: 2)
                    .padding(.horizontal, 16)
                    .opacity(0.6)
            }
        }
        .contentShape(.capsule)
        .onTapGesture { if isLive { editing = true } }
        .help("The page loads on \(browser.machine.name), so localhost is that machine")
    }

    private var actions: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(browser.pages) { page in
                    Button {
                        browser.select(page.id)
                    } label: {
                        if page.id == browser.activeID {
                            Label(page.name, systemImage: "checkmark")
                        } else {
                            Text(page.name)
                        }
                    }
                }
                Divider()
                Button("New Page") { browser.newPage() }
                Button("Close Page") { if let id = browser.activeID { browser.close(id) } }
                    .disabled(browser.activeID == nil)
            } label: {
                Label("Pages", systemImage: "square.on.square")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!isLive)
            .help(browser.pages.count == 1 ? "1 page open on \(browser.machine.name)" : "\(browser.pages.count) pages open on \(browser.machine.name)")
            Button {
                if let file = browser.screenshotFile() { attach([file]) }
            } label: {
                Label("Add Screenshot to Message", systemImage: "camera.viewfinder")
            }
            .disabled(!isLive || browser.frame == nil || browser.url == nil)
            .help("Add a screenshot of the page to your message, so the agent sees what you see")
            Menu {
                Button("Copy Address") {
                    guard let url = browser.url else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                .disabled(browser.url == nil)
                Button("Reload Page") { browser.reload() }
                    .disabled(!isLive || browser.url == nil)
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

    /// The host while browsing, the full address while editing.
    private var displayAddress: String {
        guard let url = browser.url else { return "" }
        if editing { return url.absoluteString }
        return url.host()?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
    }
}

/// The page, live: only this view follows each new picture, not the toolbar around it.
private struct LivePage: View {
    let browser: MachineBrowser

    var body: some View {
        RemotePage(browser: browser, image: browser.frame, size: browser.frameSize)
    }
}

/// While the browser goes onto the machine, the first time.
private struct SetupCard: View {
    let machine: String
    let progress: Double?

    var body: some View {
        VStack(spacing: 14) {
            Spinner(size: 22)
            VStack(spacing: 6) {
                Text("Setting Up the Browser on \(machine)")
                    .font(.system(size: 15, weight: .semibold))
                Text("Kuvo Code puts a browser and everything it needs in ~/.kuvo-code on the machine. Nothing is installed on the system.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            if let progress {
                ProgressView(value: progress)
                    .frame(width: 200)
                Text("Downloading… \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("Sending it to \(machine)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}

/// A page with nothing on it yet: what this browser is.
private struct EmptyPageHint: View {
    let machine: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("Browser on \(machine)")
                .font(.system(size: 15, weight: .semibold))
            Text("It runs on the machine and keeps running when you quit. Agents there browse with it, and you can watch or take over here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// While an agent uses the browser.
private struct AgentBadge: View {
    var body: some View {
        HStack(spacing: 7) {
            Spinner(size: 11)
            Text("Agent is browsing")
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .allowsHitTesting(false)
    }
}

/// The page asks something (an alert, a confirmation, a question): answer it here.
private struct DialogBar: View {
    let dialog: MachineBrowser.Dialog
    let browser: MachineBrowser
    @State private var text = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dialog.message.isEmpty ? "The page asks to continue." : dialog.message)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .lineLimit(6)
            if dialog.type == "prompt" {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { browser.answer(dialog, accept: true, text: text) }
            }
            HStack {
                Spacer()
                if dialog.type != "alert" {
                    Button("Cancel") { browser.answer(dialog, accept: false) }
                        .keyboardShortcut(.cancelAction)
                }
                Button(dialog.type == "beforeunload" ? "Leave" : "OK") { browser.answer(dialog, accept: true, text: dialog.type == "prompt" ? text : nil) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.small)
        .padding(12)
        .background(Surface.well(scheme), in: .rect(cornerRadius: 10))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .onAppear { text = dialog.defaultPrompt }
    }
}

// MARK: - The page

/// Shows the page's pictures, fitted to the width, and sends what you do there to the page.
private struct RemotePage: NSViewRepresentable {
    let browser: MachineBrowser
    let image: CGImage?
    let size: CGSize

    func makeNSView(context: Context) -> RemotePageView {
        RemotePageView(browser: browser)
    }

    func updateNSView(_ view: RemotePageView, context: Context) {
        view.show(image, size: size)
    }
}

final class RemotePageView: NSView, @preconcurrency NSTextInputClient {
    private let browser: MachineBrowser
    private let imageLayer = CALayer()
    private var pageSize = CGSize(width: 1280, height: 800)
    private var tracking: NSTrackingArea?
    private var lastMove = Date.distantPast
    private var marked: String?

    init(browser: MachineBrowser) {
        self.browser = browser
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ image: CGImage?, size: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        if size.width > 0, size.height > 0 { pageSize = size }
        placeImage()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeImage()
        CATransaction.commit()
        reportSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportSize()
    }

    private func reportSize() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        browser.resize(to: bounds.size, scale: window?.backingScaleFactor ?? 2)
    }

    /// Where the page shows: as wide as the view, from its top (the page follows the view's
    /// size, so this only differs for a moment while it resizes).
    private var pageRect: CGRect {
        guard pageSize.width > 0 else { return bounds }
        let scale = min(bounds.width / pageSize.width, bounds.height / pageSize.height)
        let size = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height, width: size.width, height: size.height)
    }

    private func placeImage() {
        imageLayer.frame = pageRect
    }

    /// A point in the view, in the page's CSS pixels.
    private func pagePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let rect = pageRect
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(
            x: ((point.x - rect.minX) / rect.width * pageSize.width).rounded(),
            y: ((rect.maxY - point.y) / rect.height * pageSize.height).rounded()
        )
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        browser.mouse("mousePressed", at: pagePoint(event), button: "left", buttons: 1, clicks: event.clickCount, modifiers: MachineBrowser.modifiers(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        browser.mouse("mouseReleased", at: pagePoint(event), button: "left", buttons: 0, clicks: event.clickCount, modifiers: MachineBrowser.modifiers(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) {
        browser.mouse("mouseMoved", at: pagePoint(event), button: "left", buttons: 1, modifiers: MachineBrowser.modifiers(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        // Hovers at most 30 times a second: each is a message over the network.
        guard Date.now.timeIntervalSince(lastMove) > 1.0 / 30 else { return }
        lastMove = .now
        browser.mouse("mouseMoved", at: pagePoint(event), modifiers: MachineBrowser.modifiers(event.modifierFlags))
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        browser.mouse("mousePressed", at: pagePoint(event), button: "right", buttons: 2, clicks: 1, modifiers: MachineBrowser.modifiers(event.modifierFlags))
    }

    override func rightMouseUp(with event: NSEvent) {
        browser.mouse("mouseReleased", at: pagePoint(event), button: "right", buttons: 0, clicks: 1, modifiers: MachineBrowser.modifiers(event.modifierFlags))
    }

    override func otherMouseDown(with event: NSEvent) {
        browser.mouse("mousePressed", at: pagePoint(event), button: "middle", buttons: 4, clicks: 1, modifiers: MachineBrowser.modifiers(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        browser.mouse("mouseReleased", at: pagePoint(event), button: "middle", buttons: 0, clicks: 1, modifiers: MachineBrowser.modifiers(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        var dx = -event.scrollingDeltaX
        var dy = -event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= 40
            dy *= 40
        }
        guard dx != 0 || dy != 0 else { return }
        browser.wheel(at: pagePoint(event), dx: dx, dy: dy, modifiers: MachineBrowser.modifiers(event.modifierFlags))
    }

    // MARK: Keyboard

    /// Keys that aren't text, by the Mac's key code: their name, code and Windows key code.
    private static let keys: [UInt16: (key: String, code: String, keyCode: Int)] = [
        36: ("Enter", "Enter", 13), 76: ("Enter", "NumpadEnter", 13), 48: ("Tab", "Tab", 9),
        51: ("Backspace", "Backspace", 8), 117: ("Delete", "Delete", 46), 53: ("Escape", "Escape", 27),
        123: ("ArrowLeft", "ArrowLeft", 37), 124: ("ArrowRight", "ArrowRight", 39),
        125: ("ArrowDown", "ArrowDown", 40), 126: ("ArrowUp", "ArrowUp", 38),
        115: ("Home", "Home", 36), 119: ("End", "End", 35), 116: ("PageUp", "PageUp", 33), 121: ("PageDown", "PageDown", 34),
    ]

    override func keyDown(with event: NSEvent) {
        if let special = keyEvent(for: event) {
            browser.key(special.text == nil ? "rawKeyDown" : "keyDown", key: special.key, code: special.code, keyCode: special.keyCode, text: special.text, modifiers: special.modifiers)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control), let character = event.charactersIgnoringModifiers?.lowercased().first, character.isLetter || character.isNumber {
            // A shortcut the menus don't take: as Control is on Linux (⌘B bolds in an editor).
            let letter = String(character).uppercased()
            let code = character.isLetter ? "Key\(letter)" : "Digit\(letter)"
            let keyCode = Int(letter.unicodeScalars.first?.value ?? 0)
            var modifiers = MachineBrowser.modifiers(flags.subtracting(.command))
            modifiers |= 2
            browser.key("rawKeyDown", key: String(character), code: code, keyCode: keyCode, modifiers: modifiers)
            browser.key("keyUp", key: String(character), code: code, keyCode: keyCode, modifiers: modifiers)
            return
        }
        interpretKeyEvents([event])
    }

    override func keyUp(with event: NSEvent) {
        guard let special = keyEvent(for: event) else { return }
        browser.key("keyUp", key: special.key, code: special.code, keyCode: special.keyCode, modifiers: special.modifiers)
    }

    /// A key that isn't text, as Chrome on Linux knows it: the Mac's ⌘ and ⌥ moves become Linux's
    /// Home, End and Control ones.
    private func keyEvent(for event: NSEvent) -> (key: String, code: String, keyCode: Int, text: String?, modifiers: Int)? {
        guard var key = Self.keys[event.keyCode] else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = MachineBrowser.modifiers(flags.subtracting([.command, .option, .function, .numericPad]))
        let horizontal = event.keyCode == 123 || event.keyCode == 124
        if flags.contains(.command) {
            switch event.keyCode {
            case 123: key = Self.keys[115]!
            case 124: key = Self.keys[119]!
            case 126: key = Self.keys[115]!; modifiers |= 2
            case 125: key = Self.keys[119]!; modifiers |= 2
            default: modifiers |= 2
            }
        } else if flags.contains(.option) {
            // Word by word.
            if horizontal || event.keyCode == 51 || event.keyCode == 117 { modifiers |= 2 } else { modifiers |= 1 }
        }
        let text: String? = key.key == "Enter" ? "\r" : nil
        return (key.key, key.code, key.keyCode, text, modifiers)
    }

    override func doCommand(by selector: Selector) {
        // Keys are sent as they are, above; nothing to beep about.
    }

    // Edit menu commands, for the page.

    @objc func copy(_ sender: Any?) {
        Task {
            guard let text = await browser.selectedText(), !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    @objc func cut(_ sender: Any?) {
        Task {
            if let text = await browser.selectedText(), !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            browser.key("rawKeyDown", key: "Delete", code: "Delete", keyCode: 46)
            browser.key("keyUp", key: "Delete", code: "Delete", keyCode: 46)
        }
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        browser.insertText(text)
    }

    @objc override func selectAll(_ sender: Any?) {
        controlShortcut("a", command: "selectAll")
    }

    @objc func undo(_ sender: Any?) {
        controlShortcut("z", command: "undo")
    }

    @objc func redo(_ sender: Any?) {
        controlShortcut("z", command: "redo", shift: true)
    }

    private func controlShortcut(_ letter: String, command: String, shift: Bool = false) {
        let code = "Key\(letter.uppercased())"
        let keyCode = Int(letter.uppercased().unicodeScalars.first!.value)
        let modifiers = 2 | (shift ? 8 : 0)
        browser.key("rawKeyDown", key: letter, code: code, keyCode: keyCode, modifiers: modifiers, commands: [command])
        browser.key("keyUp", key: letter, code: code, keyCode: keyCode, modifiers: modifiers)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(paste(_:)), #selector(selectAll(_:)), #selector(undo(_:)), #selector(redo(_:)):
            browser.state == .live
        default:
            false
        }
    }

    // MARK: Text input

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        marked = nil
        guard !text.isEmpty else { return }
        browser.insertText(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        marked = text.isEmpty ? nil : text
        browser.compose(text, selection: selectedRange)
    }

    func unmarkText() {
        if let marked { browser.insertText(marked) }
        marked = nil
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        marked.map { NSRange(location: 0, length: ($0 as NSString).length) } ?? NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { marked != nil }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Where the page's caret is isn't known here: the input method's window goes near the
        // view's bottom left.
        guard let window else { return .zero }
        let rect = convert(CGRect(x: 20, y: 20, width: 1, height: 20), to: nil)
        return window.convertToScreen(rect)
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    #if DEBUG
    // KUVO_DEMO_PAGE_INPUT: what you'd do on the page, steps separated by `;`, through the same
    // handlers as real events: `wait:<s>`, `click:<x>,<y>` (points from the page's top left),
    // `type:<text>`, `key:<code>` (a Mac key code), `scroll:<x>,<y>,<dy>`, `selectAll`, `copy`, `paste`.
    private static var demoStarted = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Once, in the page view that's live (one shows dimmed while connecting).
        guard !Self.demoStarted, window != nil, browser.state == .live, let script = ProcessInfo.processInfo.environment["KUVO_DEMO_PAGE_INPUT"] else { return }
        Self.demoStarted = true
        Task { @MainActor in
            for step in script.split(separator: ";").map(String.init) {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                let value = parts.count > 1 ? parts[1] : ""
                let numbers = value.split(separator: ",").compactMap { Double($0) }
                switch parts[0] {
                case "wait": try? await Task.sleep(for: .seconds(numbers.first ?? 1))
                case "click" where numbers.count == 2: demoMouse(CGPoint(x: numbers[0], y: numbers[1]))
                case "type": for character in value { demoKey(String(character), code: 0) }
                case "key": demoKey("", code: UInt16(numbers.first ?? 0))
                case "scroll" where numbers.count == 3: demoScroll(CGPoint(x: numbers[0], y: numbers[1]), dy: numbers[2])
                case "selectAll": selectAll(nil)
                case "copy": copy(nil)
                case "paste": paste(nil)
                default: break
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func demoLocation(_ point: CGPoint) -> CGPoint {
        convert(CGPoint(x: point.x, y: bounds.height - point.y), to: nil)
    }

    private func demoMouse(_ point: CGPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: demoLocation(point), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            if type == .leftMouseDown { mouseDown(with: event) } else { mouseUp(with: event) }
        }
    }

    private func demoKey(_ characters: String, code: UInt16) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { continue }
            if type == .keyDown { keyDown(with: event) } else { keyUp(with: event) }
        }
    }

    private func demoScroll(_ point: CGPoint, dy: Double) {
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0) else { return }
        let location = window?.convertPoint(toScreen: demoLocation(point)) ?? .zero
        cgEvent.location = CGPoint(x: location.x, y: (NSScreen.screens.first?.frame.height ?? 0) - location.y)
        if let event = NSEvent(cgEvent: cgEvent) { scrollWheel(with: event) }
    }
    #endif
}
