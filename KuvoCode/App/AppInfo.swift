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

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "run.kuvo.code"
    }

    /// `~/Library/Application Support/<bundle id>`: the engine binary and its data live here.
    static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "run.kuvo.code")
    }

    /// Where Help points: the docs, what's new in each release, and reporting a problem.
    static let docs = URL(string: "https://kuvo.run/code/docs/")!
    static let releases = URL(string: "https://github.com/serhatandic/kuvo-code/releases")!
    static let newIssue = URL(string: "https://github.com/serhatandic/kuvo-code/issues/new/choose")!
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
