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
    @ObservationIgnored private var appliedDark: Bool?

    init(directory: String, environment: [String: String]) {
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        super.init()
        view.processDelegate = self
        view.font = Self.font
        view.optionAsMetaKey = true
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
    }

    func terminate() {
        guard isRunning else { return }
        view.terminate()
        isRunning = false
    }

    /// Colors for the app's appearance: the card's background, and an ANSI palette that
    /// stays readable on it.
    func apply(dark: Bool) {
        guard appliedDark != dark else { return }
        appliedDark = dark
        view.nativeBackgroundColor = dark ? NSColor(white: 0.13, alpha: 1) : .white
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

/// Puts a session's terminal in the panel. The view outlives the tab being shown, so the
/// shell keeps its state while you look at something else.
struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.apply(dark: scheme == .dark)
        DispatchQueue.main.async { session.view.window?.makeFirstResponder(session.view) }
        return session.view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        session.apply(dark: scheme == .dark)
    }
}
