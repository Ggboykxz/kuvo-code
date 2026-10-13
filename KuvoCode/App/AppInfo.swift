import AppKit

/// The app's identity, read from the bundle so renaming the app only touches
/// `Config/App.xcconfig`.
nonisolated enum AppInfo {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// `~/Library/Application Support/<bundle id>`: the engine binary and its data live here.
    static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "run.kuvo.code")
    }
}

/// System, light or dark, for the whole app (AppKit menus and sheets included).
enum Appearance: String, CaseIterable {
    case system, light, dark
    static let key = "appearance"

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    @MainActor func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
