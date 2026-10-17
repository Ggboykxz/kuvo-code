import Foundation
import Sparkle

/// Software updates, via Sparkle. Release builds name an update feed in their
/// Info.plist (see scripts/build-app.sh); development builds have none, so the
/// updater never starts and the update controls stay hidden.
@Observable
final class Updates {
    /// Whether this build can update itself at all.
    let isAvailable: Bool
    /// False while a check is already running.
    private(set) var canCheck = false
    /// Check once a day in the background.
    var checksAutomatically: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = checksAutomatically }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private let steps = UpdateSteps()

    init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            isAvailable = false
            checksAutomatically = false
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: steps, userDriverDelegate: nil)
        self.controller = controller
        isAvailable = true
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let canCheck = change.newValue ?? false
            MainActor.assumeIsolated { self?.canCheck = canCheck }
        }
    }

    func check() {
        controller?.checkForUpdates(nil)
    }
}

/// Each step of an update, for anonymous usage: checked, found, downloaded, installed, or where
/// and why it failed (a kind, never the error's words).
nonisolated private final class UpdateSteps: NSObject, SPUUpdaterDelegate {
    /// A download that failed was just counted: Sparkle then ends the update with the same error.
    private var downloadFailed = false

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        downloadFailed = false
        guard updateCheck != .updateInformation else { return }
        let manual = updateCheck == .updates
        track("update_checked") { ["manual": manual] }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let to = Self.version(item)
        track("update_available") { ["from": AppInfo.version, "to": to] }
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        let to = Self.version(item)
        track("update_downloaded") { ["to": to] }
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        downloadFailed = true
        let reason = Self.reason(error)
        track("update_failed") { ["stage": "download", "reason": reason] }
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        track("update_failed") { ["stage": "download", "reason": "cancelled"] }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let to = Self.version(item)
        track("update_installed") { ["from": AppInfo.version, "to": to] }
        // It quits to install: what's queued goes now.
        Task { @MainActor in Analytics.shared.flush() }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let error = error as NSError
        // Finding no update isn't a failure, and a failed download was counted as it failed.
        guard error.domain != SUSparkleErrorDomain || error.code != Int(SUError.noUpdateError.rawValue) else { return }
        guard !downloadFailed else {
            downloadFailed = false
            return
        }
        let stage = switch error.code {
        case 1000..<2000: "check"
        // Without a failed download, it's the update feed that couldn't be fetched.
        case Int(SUError.downloadError.rawValue): "check"
        case 2000..<3000: "download"
        case 3000..<4000: "extract"
        default: "install"
        }
        let reason = Self.reason(error)
        track("update_failed") { ["stage": stage, "reason": reason] }
    }

    private func track(_ name: String, _ props: @escaping @MainActor @Sendable () -> [String: Any]) {
        Task { @MainActor in Analytics.shared.track(name, props()) }
    }

    private static func version(_ item: SUAppcastItem) -> String {
        String(item.displayVersionString.prefix(32))
    }

    private static func reason(_ error: any Error) -> String {
        let error = error as NSError
        if error.domain == NSURLErrorDomain || (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.domain == NSURLErrorDomain { return "network" }
        guard error.domain == SUSparkleErrorDomain else { return "other" }
        return switch Int32(error.code) {
        case SUError.signatureError.rawValue, SUError.validationError.rawValue, SUError.insufficientSigningError.rawValue: "signature"
        case SUError.downloadError.rawValue, SUError.appcastError.rawValue: "network"
        case SUError.temporaryDirectoryError.rawValue, SUError.fileCopyFailure.rawValue, SUError.installationWriteNoPermissionError.rawValue: "disk"
        case SUError.installationCanceledError.rawValue, SUError.installationAuthorizeLaterError.rawValue: "cancelled"
        default: "other"
        }
    }
}
