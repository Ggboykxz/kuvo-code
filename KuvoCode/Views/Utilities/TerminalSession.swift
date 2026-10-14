import AppKit
import SwiftTerm
import SwiftUI

/// A shell in the project folder (SwiftTerm, MIT): the login shell with the same
/// environment as Terminal, colored to match the app.
@Observable
final class TerminalSession: NSObject {
    let view: LocalProcessTerminalView
    private(set) var title = "Terminal"
    private(set) var isRunning = true
    /// Add to Message in the right-click menu, with the selected text.
    @ObservationIgnored var addToMessage: ((String) -> Void)?
    @ObservationIgnored private var appliedLook: (dark: Bool, focused: Bool)?

    /// A shell, typing `command` once it starts (so it stays a shell when the command ends).
    init(directory: String, environment: [String: String], command: String? = nil) {
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        super.init()
        view.processDelegate = self
        view.font = Self.font
        view.optionAsMetaKey = true
        // Scrolling works as anywhere else; a permanent scroll bar track is just clutter.
        for scroller in view.subviews.compactMap({ $0 as? NSScroller }) { scroller.isHidden = true }
        let menu = NSMenu()
        menu.delegate = self
        view.menu = menu
        var environment = environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "KuvoCode"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        let shell = environment["SHELL"] ?? "/bin/zsh"
        // A leading "-" in the process name makes it a login shell, as Terminal does.
        view.startProcess(
            executable: shell,
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: directory
        )
        if let command { view.send(txt: command + "\r") }
    }

    /// Interrupts whatever runs in the shell (Control-C), then types `command`.
    func run(_ command: String) {
        view.send([0x03])
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            view.send(txt: command + "\r")
        }
    }

    func terminate() {
        guard isRunning else { return }
        view.terminate()
        isRunning = false
    }

    /// Colors for the app's appearance: the card's own background, so the terminal is part of
    /// the card rather than a box in it, and an ANSI palette that stays readable on it. (Solid,
    /// not see-through: SwiftTerm draws reverse video from the background color.)
    func apply(dark: Bool, focused: Bool) {
        guard appliedLook.map({ $0 != (dark, focused) }) ?? true else { return }
        appliedLook = (dark, focused)
        let background = CardFill.solid(dark: dark, focused: focused)
        view.nativeBackgroundColor = background
        view.layer?.backgroundColor = background.cgColor
        view.needsDisplay = true
        view.nativeForegroundColor = dark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.12, alpha: 1)
        view.caretColor = .controlAccentColor
        view.selectedTextBackgroundColor = NSColor.selectedTextBackgroundColor
        view.installColors(dark ? Self.darkPalette : Self.lightPalette)
    }

    /// A Nerd Font when one is installed (shell prompts draw icons with them), else SF Mono.
    private static let font: NSFont = {
        let families = NSFontManager.shared.availableFontFamilies
        let nerd = families.first { $0.contains("Nerd Font Mono") } ?? families.first { $0.contains("Nerd Font") || $0.hasSuffix(" NF") }
        if let nerd, let font = NSFont(name: nerd, size: 12) ?? NSFontManager.shared.font(withFamily: nerd, traits: [], weight: 5, size: 12) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }()

    private static func palette(_ hex: [UInt32]) -> [SwiftTerm.Color] {
        hex.map { value in
            SwiftTerm.Color(red: UInt16((value >> 16) & 0xFF) * 257, green: UInt16((value >> 8) & 0xFF) * 257, blue: UInt16(value & 0xFF) * 257)
        }
    }

    private static let darkPalette = palette([
        0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
        0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xFFFFFF,
    ])

    private static let lightPalette = palette([
        0x000000, 0xCD3131, 0x107C10, 0x949800, 0x0451A5, 0xBC05BC, 0x0598BC, 0x555555,
        0x666666, 0xCD3131, 0x14A314, 0xB5BA00, 0x0451A5, 0xBC05BC, 0x0598BC, 0xA5A5A5,
    ])
}

/// Right-click: Add to Message, Copy and Paste.
extension TerminalSession: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hasSelection = view.selectionActive
        let add = NSMenuItem(title: "Add to Message", action: hasSelection ? #selector(addSelection) : nil, keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        menu.addItem(.separator())
        let copy = NSMenuItem(title: "Copy", action: hasSelection ? #selector(NSText.copy(_:)) : nil, keyEquivalent: "")
        copy.target = view
        menu.addItem(copy)
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        paste.target = view
        menu.addItem(paste)
    }

    /// The selection as a code block, without the blank space terminals pad lines with.
    @objc private func addSelection() {
        guard let selection = view.getSelection() else { return }
        let lines = selection.components(separatedBy: "\n").map { String($0.reversed().drop(while: \.isWhitespace).reversed()) }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }
        addToMessage?("```\n\(text)\n```")
    }
}

extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        self.title = title.isEmpty ? "Terminal" : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
    }
}

/// Puts a session's terminal in the panel, on the card itself as in Rex: the card's color
/// edge to edge, with the text inset like the rest of the card. The view outlives the tab
/// being shown, so the shell keeps its state while you look at something else.
struct TerminalHost: View {
    let session: TerminalSession
    var isFocused = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TerminalRepresentable(session: session, dark: scheme == .dark, focused: isFocused)
            // The right side already has room SwiftTerm keeps for its (hidden) scroll bar.
            .padding(.leading, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .background(Color(nsColor: CardFill.solid(dark: scheme == .dark, focused: isFocused)))
    }
}

private struct TerminalRepresentable: NSViewRepresentable {
    let session: TerminalSession
    let dark: Bool
    let focused: Bool

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.apply(dark: dark, focused: focused)
        DispatchQueue.main.async { session.view.window?.makeFirstResponder(session.view) }
        return session.view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        session.apply(dark: dark, focused: focused)
    }
}
