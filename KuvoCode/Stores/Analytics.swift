import Foundation
import MetricKit
import OpenCodeKit
import UsageKit
import os

/// Anonymous usage, sent in small batches to Kuvo's analytics collector so it's known which
/// features get used. On by default and off with Settings › General › Share Anonymous Usage.
///
/// What goes out: a random ID made for this install, the app and macOS versions, the Mac's
/// architecture and language, and events like "a session started with Anthropic's Claude
/// Sonnet 5.5" or "the Changes tab opened". Never prompts, replies, code, file names, folders,
/// account details or custom names: providers outside the public list and agents other than
/// Build and Plan go out as "other" and "custom". Sizes and durations go out as ranges, and what
/// went wrong as a kind ("rate limit", "network"), never its message.
///
/// The developer's own Macs mark themselves internal, so the numbers can leave them out:
/// `defaults write run.kuvo.code analytics.internal -bool true`.
///
/// Debug builds send nothing, unless `KUVO_ANALYTICS_URL` points them at a collector to test with.
@Observable
final class Analytics {
    static let shared = Analytics()

    static let enabledKey = "analytics.enabled"
    static let noticeKey = "analytics.noticeShown"
    private static let installKey = "analytics.installID"
    private static let activeDayKey = "analytics.activeDay"
    private static let versionKey = "analytics.version"
    private static let usageDayKey = "analytics.usageDay"
    private static let internalKey = "analytics.internal"
    private static let installDateKey = "analytics.installDate"
    /// Set while the app runs, cleared when it quits: still set at launch, the last run ended
    /// some other way (a crash, Force Quit, the Mac losing power).
    private static let runningKey = "analytics.running"
    private static let launchedKey = "analytics.launchedAt"
    private static let aliveKey = "analytics.aliveAt"
    private static let onboardedKey = "analytics.onboarded"
    private static let onboardingStepsKey = "analytics.onboardingSteps"
    private static let accountKey = "analytics.accountConnected"
    private static let endpoint = URL(string: "https://analytics.porigam.com.tr/kuvo/code")!

    /// Whether events are sent. Turning it off drops what hasn't gone out yet.
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { queue.removeAll() }
        }
    }

    /// Whether the first-launch note about it has been dismissed.
    var noticeShown: Bool {
        didSet { UserDefaults.standard.set(noticeShown, forKey: Self.noticeKey) }
    }

    private let target: URL?
    private let installID: String
    private let isFirstLaunch: Bool
    /// When this install first ran; nil for one from before it was noted.
    private let installDate: Date?
    private let launchedAt = Date.now
    /// Whether this install has sent its first message: the first run is over.
    private var isOnboarded: Bool
    private var lastOnboardingStep: String?
    private var queue: [[String: Any]] = []
    private var flushTask: Task<Void, Never>?
    private var dayTimer: Timer?
    private var sentOnce: Set<String> = []
    private let log = Logger(subsystem: AppInfo.bundleID, category: "analytics")

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Self.enabledKey: true])
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        noticeShown = defaults.bool(forKey: Self.noticeKey)
        if let id = defaults.string(forKey: Self.installKey) {
            installID = id
            isFirstLaunch = false
            // An install from before the first run was followed has long been through it.
            if defaults.object(forKey: Self.onboardedKey) == nil { defaults.set(true, forKey: Self.onboardedKey) }
        } else {
            installID = UUID().uuidString.lowercased()
            defaults.set(installID, forKey: Self.installKey)
            defaults.set(Date.now, forKey: Self.installDateKey)
            defaults.set(false, forKey: Self.onboardedKey)
            isFirstLaunch = true
        }
        installDate = defaults.object(forKey: Self.installDateKey) as? Date
        isOnboarded = defaults.bool(forKey: Self.onboardedKey)
        #if DEBUG
        target = ProcessInfo.processInfo.environment["KUVO_ANALYTICS_URL"].flatMap(URL.init(string:))
        #else
        target = Self.endpoint
        #endif
    }

    // MARK: Recording

    /// Records an event; it goes out with the next batch.
    func track(_ name: String, _ props: [String: Any] = [:]) {
        guard isEnabled, target != nil else { return }
        queue.append(["name": name, "ts": Date.now.ISO8601Format(), "props": props])
        if queue.count > 300 { queue.removeFirst(queue.count - 300) }
        if queue.count >= 25 { flush() } else { scheduleFlush() }
    }

    /// Records an event the first time it happens while the app runs (one of each `key`, if given).
    func trackOnce(_ name: String, key: String? = nil, _ props: [String: Any] = [:]) {
        guard sentOnce.insert(key.map { name + "." + $0 } ?? name).inserted else { return }
        track(name, props)
    }

    /// At launch: the launch itself, then one "active" a day for as long as the app stays open.
    func start() {
        let defaults = UserDefaults.standard
        // The last run didn't quit: how long it had been open when it was last seen.
        if defaults.bool(forKey: Self.runningKey), let launched = defaults.object(forKey: Self.launchedKey) as? Date {
            let alive = defaults.object(forKey: Self.aliveKey) as? Date ?? launched
            track("app_exited_unexpectedly", ["minutes": Self.minutes(alive.timeIntervalSince(launched))])
        }
        defaults.set(true, forKey: Self.runningKey)
        defaults.set(launchedAt, forKey: Self.launchedKey)
        defaults.set(launchedAt, forKey: Self.aliveKey)
        var props: [String: Any] = ["ram": Self.memory]
        if isFirstLaunch { props["first"] = true }
        track("app_launched", props)
        if let previous = defaults.string(forKey: Self.versionKey), previous != AppInfo.version {
            track("app_updated", ["from": previous])
        }
        defaults.set(AppInfo.version, forKey: Self.versionKey)
        defaults.set(Self.today, forKey: Self.activeDayKey)
        dayTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                UserDefaults.standard.set(Date.now, forKey: Analytics.aliveKey)
                Analytics.shared.markActiveDay()
            }
        }
        // Crashes and hangs, as macOS reports them (a day or so later, at a launch).
        MXMetricManager.shared.add(CrashReports.shared)
        // The usage panel reads its providers in the first minutes.
        Task {
            try? await Task.sleep(for: .seconds(180))
            noteUsageProviders()
        }
    }

    /// Once a day: which AI tools the menu bar's usage panel follows (their public IDs).
    private func noteUsageProviders() {
        let defaults = UserDefaults.standard
        let providers = UsageMenuBar.shared.trackedProviderIDs
        guard defaults.string(forKey: Self.usageDayKey) != Self.today, !providers.isEmpty else { return }
        defaults.set(Self.today, forKey: Self.usageDayKey)
        for provider in providers { track("usage_tracked", ["provider": provider]) }
    }

    private func markActiveDay() {
        noteUsageProviders()
        guard UserDefaults.standard.string(forKey: Self.activeDayKey) != Self.today else { return }
        UserDefaults.standard.set(Self.today, forKey: Self.activeDayKey)
        track("app_active")
    }

    // MARK: The first run

    /// A step of the first run seen, once each, until the first message is sent.
    func onboardingStep(_ step: String, _ props: [String: Any] = [:]) {
        guard !isOnboarded else { return }
        lastOnboardingStep = step
        let defaults = UserDefaults.standard
        var seen = defaults.stringArray(forKey: Self.onboardingStepsKey) ?? []
        guard !seen.contains(step) else { return }
        seen.append(step)
        defaults.set(seen, forKey: Self.onboardingStepsKey)
        var props = props
        props["step"] = step
        track("onboarding_step_viewed", props)
    }

    /// The first message this install sent: in a project, a chat or a bot's conversation.
    func messageSent(path: @autoclosure () -> String) {
        guard !isOnboarded else { return }
        isOnboarded = true
        UserDefaults.standard.set(true, forKey: Self.onboardedKey)
        var props: [String: Any] = ["path": path(), "account": UserDefaults.standard.bool(forKey: Self.accountKey)]
        if let since = sinceInstall { props["since_install"] = since }
        track("onboarding_completed", props)
    }

    /// A message that couldn't go, before the first one has.
    func firstMessageBlocked(_ reason: String) {
        guard !isOnboarded else { return }
        track("first_message_blocked", ["reason": reason])
    }

    /// An account was connected (it's said with the first message).
    func accountConnected() {
        UserDefaults.standard.set(true, forKey: Self.accountKey)
    }

    /// How long since this install first ran, as a range; nil when that isn't known.
    var sinceInstall: String? {
        installDate.map { Self.bucket(Date.now.timeIntervalSince($0), [60, 300, 900, 3600, 86400, 604_800], ["<1m", "1-5m", "5-15m", "15-60m", "1-24h", "1-7d", "7d+"]) }
    }

    // MARK: How far sessions go

    private struct SessionUse {
        var messages = 0
        var chars = 0
        var turns = 0
        let since = Date.now
    }

    private var sessionUse: [String: SessionUse] = [:]

    /// A message you sent in a session.
    func noteMessage(in session: String, chars: Int) {
        sessionUse[session, default: SessionUse()].messages += 1
        sessionUse[session]?.chars += chars
    }

    /// A run of a session you sent to here ended.
    func noteTurn(in session: String) {
        sessionUse[session]?.turns += 1
    }

    /// A session you worked in left the window (its tab closed) or the app quits.
    func sessionEnded(_ session: String) {
        guard let use = sessionUse.removeValue(forKey: session) else { return }
        track("session_ended", [
            "messages": Self.count(use.messages),
            "turns": Self.count(use.turns),
            "minutes": Self.minutes(Date.now.timeIntervalSince(use.since)),
            "chars": Self.bucket(Double(use.chars), [100, 500, 2000, 10000], ["0-100", "100-500", "500-2k", "2k-10k", "10k+"]),
        ])
    }

    // MARK: What went wrong

    /// The kind of trouble an error was, from its status and words (which never leave the Mac).
    nonisolated static func trouble(status: Int?, _ text: String) -> String {
        let text = text.lowercased()
        func says(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if says("usage limit", "usagelimit", "quota", "insufficient", "credit", "billing") { return "quota" }
        if status == 429 || says("rate limit", "ratelimit", "too many requests") { return "rate_limit" }
        if status == 401 || status == 403 || says("unauthorized", "invalid api key", "invalid_api_key", "authentication", "forbidden") { return "auth" }
        if status == 408 || status == 504 || says("timed out", "timeout") { return "timeout" }
        if status == 413 || says("context length", "context window", "maximum context", "too many tokens", "too long") { return "context_too_long" }
        if (status ?? 0) >= 500 || says("overloaded", "unavailable", "internal server error", "bad gateway") { return "provider_down" }
        if says("network", "connection", "econn", "enotfound", "fetch failed", "socket") { return "network" }
        return "other"
    }

    /// The kind of trouble a request ran into: the network, or what the engine said.
    nonisolated static func trouble(_ error: any Error) -> String {
        if let error = error as? URLError { return error.code == .timedOut ? "timeout" : "network" }
        if let error = error as? ServerError { return trouble(status: error.status, error.message) }
        return trouble(status: nil, error.localizedDescription)
    }

    // MARK: Ranges

    /// The label of the range `value` falls in: below the first bound, the first label, and so on.
    nonisolated static func bucket(_ value: Double, _ bounds: [Double], _ labels: [String]) -> String {
        labels[bounds.firstIndex { value < $0 } ?? bounds.count]
    }

    nonisolated static func minutes(_ seconds: TimeInterval) -> String {
        bucket(seconds / 60, [1, 5, 15, 60, 240], ["0-1", "1-5", "5-15", "15-60", "60-240", "240+"])
    }

    nonisolated static func count(_ count: Int) -> String {
        bucket(Double(count), [1, 2, 6, 21, 51], ["0", "1", "2-5", "6-20", "21-50", "51+"])
    }

    nonisolated static func tokens(_ count: Double) -> String {
        bucket(count, [1000, 10000, 50000, 200_000], ["0-1k", "1k-10k", "10k-50k", "50k-200k", "200k+"])
    }

    nonisolated static func cost(_ dollars: Double) -> String {
        dollars <= 0 ? "0" : bucket(dollars, [0.01, 0.1, 1], ["<0.01", "0.01-0.1", "0.1-1", "1+"])
    }

    /// This Mac's memory in GB, rounded down to a common size.
    private static var memory: String {
        let gigabytes = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return bucket(gigabytes, [12, 20, 28, 40, 80], ["8", "16", "24", "32", "48-64", "96+"])
    }

    private static var today: String {
        Date.now.formatted(.iso8601.year().month().day().timeZone(separator: .omitted))
    }

    // MARK: What's safe to name

    /// Public providers by their catalog IDs; anything else (a custom provider, named by you) is "other".
    private static let publicProviders: Set<String> = [
        "opencode", "opencode-go", "anthropic", "openai", "google", "google-vertex", "github-copilot", "openrouter",
        "xai", "deepseek", "mistral", "groq", "cerebras", "fireworks-ai", "togetherai", "moonshotai", "zai",
        "zai-coding-plan", "amazon-bedrock", "azure", "vercel", "alibaba", "huggingface", "nvidia", "perplexity",
        "ollama", "lmstudio", "minimax", "baseten", "venice", "inception", "llama",
    ]

    static func provider(_ id: String?) -> String {
        guard let id else { return "none" }
        return publicProviders.contains(id) ? id : "other"
    }

    /// The provider, and the model when it's one of a public provider's.
    static func model(provider id: String?, model: String?) -> [String: Any] {
        let provider = provider(id)
        guard provider != "other", provider != "none", let model else { return ["provider": provider] }
        return ["provider": provider, "model": String(model.prefix(80))]
    }

    /// What a permission was for, by kind.
    static func action(_ action: String) -> String {
        switch action {
        case "edit", "write", "patch": "edit"
        case "shell", "bash": "shell"
        case "read", "external_directory", "webfetch", "websearch", "subagent", "skill", "question": action
        default: action.hasPrefix("kuvo-browser_") ? "browser" : "other"
        }
    }

    /// Build and Plan by name; agents you made are "custom".
    static func mode(_ agent: String?) -> String {
        guard let agent else { return "default" }
        return ["build", "plan"].contains(agent) ? agent : "custom"
    }

    // MARK: Sending

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task {
            try? await Task.sleep(for: .seconds(60))
            flushTask = nil
            flush()
        }
    }

    /// Sends what's queued. A batch that doesn't go through is kept for the next try.
    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard isEnabled, let request = request(for: queue) else { return }
        let batch = queue
        queue.removeAll()
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // Refused outright (a bad batch): drop it. Server trouble: try again later.
                if status >= 500 || status == 429 { requeue(batch) }
            } catch {
                requeue(batch)
            }
        }
    }

    private func requeue(_ batch: [[String: Any]]) {
        guard isEnabled else { return }
        queue = Array((batch + queue).suffix(300))
        scheduleFlush()
    }

    /// At quit: how long it was open (and where a first run stopped), then one last send,
    /// waiting a moment for it.
    func flushBeforeQuit() {
        UserDefaults.standard.set(false, forKey: Self.runningKey)
        for session in Array(sessionUse.keys) { sessionEnded(session) }
        if !isOnboarded {
            var props: [String: Any] = ["step": lastOnboardingStep ?? "none"]
            if let since = sinceInstall { props["since_install"] = since }
            track("onboarding_left", props)
        }
        track("app_closed", ["minutes": Self.minutes(Date.now.timeIntervalSince(launchedAt))])
        guard isEnabled, let request = request(for: queue) else { return }
        queue.removeAll()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 2)
    }

    private func request(for events: [[String: Any]]) -> URLRequest? {
        guard let target, !events.isEmpty else { return nil }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let language = Locale.current.language
        var body: [String: Any] = [
            "install_id": installID,
            "app_version": AppInfo.version,
            "build": AppInfo.build,
            "os_version": "\(os.majorVersion).\(os.minorVersion)",
            "arch": Self.architecture,
            "events": Array(events.prefix(100)),
        ]
        if UserDefaults.standard.bool(forKey: Self.internalKey) { body["internal"] = true }
        if let code = language.languageCode?.identifier {
            body["locale"] = [code, language.region?.identifier].compactMap(\.self).joined(separator: "_")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            log.error("Couldn't encode an analytics batch")
            return nil
        }
        var request = URLRequest(url: target, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return request
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}

/// Crashes and hangs macOS noticed, as it hands them over (at a launch, up to a day later): their
/// kind and the version they happened in, never what was on the stack.
final class CrashReports: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReports()

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var events: [(String, [String: String])] = []
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                events.append(("app_crashed", [
                    "source": "metrickit",
                    "kind": Self.kind(exception: crash.exceptionType?.intValue, signal: crash.signal?.intValue),
                    "version": String(crash.metaData.applicationBuildVersion.prefix(32)),
                ]))
            }
            for hang in payload.hangDiagnostics ?? [] {
                let seconds = hang.hangDuration.converted(to: .seconds).value
                events.append(("app_hang", [
                    "seconds": Analytics.bucket(seconds, [5, 15, 60], ["2-5", "5-15", "15-60", "60+"]),
                    "version": String(hang.metaData.applicationBuildVersion.prefix(32)),
                ]))
            }
        }
        guard !events.isEmpty else { return }
        Task { @MainActor in
            for (name, props) in events { Analytics.shared.track(name, props) }
        }
    }

    /// The Mach exception's name, else the signal's.
    private nonisolated static func kind(exception: Int?, signal: Int?) -> String {
        let exceptions = [1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD"]
        let signals = [4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV"]
        return exception.flatMap { exceptions[$0] } ?? signal.flatMap { signals[$0] } ?? "other"
    }
}
