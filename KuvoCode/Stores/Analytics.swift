import Foundation
import os

/// Anonymous usage, sent in small batches to Kuvo's analytics collector so it's known which
/// features get used. On by default and off with Settings › General › Share Anonymous Usage.
///
/// What goes out: a random ID made for this install, the app and macOS versions, the Mac's
/// architecture and language, and events like "a session started with Anthropic's Claude
/// Sonnet 5.5" or "the Changes tab opened". Never prompts, replies, code, file names, folders,
/// account details or custom names: providers outside the public list and agents other than
/// Build and Plan go out as "other" and "custom".
///
/// Debug builds send nothing, unless `KUVO_ANALYTICS_URL` points them at a collector to test with.
@Observable
final class Analytics {
    static let shared = Analytics()

    static let enabledKey = "analytics.enabled"
    static let noticeKey = "analytics.noticeShown"
    private static let installKey = "analytics.installID"
    private static let activeDayKey = "analytics.activeDay"
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
        } else {
            installID = UUID().uuidString.lowercased()
            defaults.set(installID, forKey: Self.installKey)
            isFirstLaunch = true
        }
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

    /// Records an event the first time it happens while the app runs.
    func trackOnce(_ name: String, _ props: [String: Any] = [:]) {
        guard sentOnce.insert(name).inserted else { return }
        track(name, props)
    }

    /// At launch: the launch itself, then one "active" a day for as long as the app stays open.
    func start() {
        track("app_launched", isFirstLaunch ? ["first": true] : [:])
        UserDefaults.standard.set(Self.today, forKey: Self.activeDayKey)
        dayTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
            Task { @MainActor in Analytics.shared.markActiveDay() }
        }
    }

    private func markActiveDay() {
        guard UserDefaults.standard.string(forKey: Self.activeDayKey) != Self.today else { return }
        UserDefaults.standard.set(Self.today, forKey: Self.activeDayKey)
        track("app_active")
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

    /// At quit: one last send, waiting a moment for it.
    func flushBeforeQuit() {
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
