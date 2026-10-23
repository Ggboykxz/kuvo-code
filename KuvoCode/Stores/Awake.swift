import Foundation

/// Keeps this Mac from falling asleep on its own while agents work on it (Settings › General), so
/// a long task, or a bot's wake-up, isn't cut off when you step away. The display can still sleep,
/// and sessions on your machines run there whatever this Mac does.
final class Awake {
    static let shared = Awake()
    static let key = "keepsAwake"

    static var isOn: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// Whether agents are at work on this Mac.
    private var isWorking = false
    private var activity: NSObjectProtocol?

    /// Whether it keeps this Mac awake now.
    var isHolding: Bool { activity != nil }

    func agentsWork(_ working: Bool) {
        guard working != isWorking else { return }
        isWorking = working
        update()
    }

    /// Holds or lets go, as the setting and the work say.
    func update() {
        let wanted = Self.isOn && isWorking
        if wanted, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Agents are working in Kuvo Code")
        } else if !wanted, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
