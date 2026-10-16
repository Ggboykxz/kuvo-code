import AppKit

/// Copying text, as Copy does everywhere: what was on the clipboard goes, the text takes its place.
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
