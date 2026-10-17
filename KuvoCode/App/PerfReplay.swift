#if DEBUG
import AppKit
import Darwin
import OpenCodeKit
import os

/// KUVO_DEMO_REPLAY=<file>: a run recorded from a real engine (one JSON object a line: `t`, ms
/// from the start, and `raw`, the event as the engine sent it) played into a new session in
/// KUVO_DEMO_FOLDER, at the pace it came, as if the engine were sending it now. How the app kept up
/// meanwhile goes to KUVO_PERF_LOG: the same run every time, to measure what streaming costs.
/// KUVO_DEMO_REPLAY_SPEED plays it that many times faster; KUVO_DEMO_REPLAY_HOLD measures that many
/// seconds after it ends instead. Debug builds only.
@MainActor
enum PerfReplay {
    private static let log = Logger(subsystem: "run.kuvo.code", category: "perf")

    struct Event {
        var time: Double
        var raw: String
    }

    /// The recorded session's events, in order.
    static func read(_ path: String) -> (session: String, events: [Event])? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        struct Line: Decodable { var t: Double; var raw: String }
        struct Head: Decodable { var type: String; var data: Data? }
        struct Data: Decodable { var sessionID: String? }
        var session: String?
        var events: [Event] = []
        for line in text.split(separator: "\n") {
            guard let entry = try? JSONDecoder().decode(Line.self, from: Foundation.Data(line.utf8)),
                  let head = try? JSONDecoder().decode(Head.self, from: Foundation.Data(entry.raw.utf8)),
                  let id = head.data?.sessionID, head.type.hasPrefix("session.") else { continue }
            // The first session to send something is the one recorded.
            if session == nil, head.type != "session.created" { session = id }
            guard id == session, !["session.created", "session.deleted", "session.moved"].contains(head.type) else { continue }
            events.append(Event(time: entry.t, raw: entry.raw))
        }
        return session.map { ($0, events) }
    }

    static func play(_ path: String, into id: String, workspace: Workspace) async {
        guard let (recorded, events) = read(path), let first = events.first else {
            return log.error("KUVO_DEMO_REPLAY: nothing to play in \(path, privacy: .public)")
        }
        let speed = Double(ProcessInfo.processInfo.environment["KUVO_DEMO_REPLAY_SPEED"] ?? "") ?? 1
        var meter = PerfMeter()
        meter.start()
        let start = ContinuousClock.now
        // Each block's words as shown, against the engine's when it ends: none lost or doubled.
        var checked = 0
        var wrong = 0
        // KUVO_DEMO_REPLAY_UNTIL=<ms>: only that much of it, to look at it there.
        let until = Double(ProcessInfo.processInfo.environment["KUVO_DEMO_REPLAY_UNTIL"] ?? "") ?? .infinity
        for event in events where event.time - first.time <= until {
            let due = start + .milliseconds(Int((event.time - first.time) / speed))
            if due > .now { try? await Task.sleep(until: due) }
            let raw = event.raw.replacingOccurrences(of: recorded, with: id)
            guard let event = try? ServerEvent(json: Foundation.Data(raw.utf8)) else { continue }
            if event.type == "session.text.ended" || event.type == "session.reasoning.ended",
               let ended = try? event.payload(as: EventPayload.BlockEnded.self) {
                // Once what streamed in has shown.
                try? await Task.sleep(for: .milliseconds(120))
                let shown = workspace.model(for: id)?.transcript.messages.reversed().lazy.compactMap { message -> String? in
                    guard case .assistant(let step) = message, step.id == ended.assistantMessageID else { return nil }
                    return step.content.reversed().lazy.compactMap { block -> String? in
                        switch block {
                        case .text(let text) where event.type == "session.text.ended": text.text
                        case .reasoning(let text) where event.type == "session.reasoning.ended": text.text
                        default: nil
                        }
                    }.first
                }.first
                checked += 1
                if shown != ended.text { wrong += 1 }
            }
            workspace.handle(event)
        }
        // A moment for the last of it to be drawn. KUVO_DEMO_REPLAY_HOLD: measured that many
        // seconds from then instead (scrolling the finished conversation with KUVO_DEMO_WANDER, say).
        try? await Task.sleep(for: .seconds(1))
        if let hold = ProcessInfo.processInfo.environment["KUVO_DEMO_REPLAY_HOLD"].flatMap(Double.init) {
            _ = meter.stop()
            meter = PerfMeter()
            meter.start()
            try? await Task.sleep(for: .seconds(hold))
        }
        let played = ContinuousClock.now - start
        let recordedLength = ((events.last?.time ?? 0) - first.time) / 1000 / speed
        let thinking = workspace.model(for: id)?.transcript.messages.reduce(0) { total, message in
            guard case .assistant(let step) = message else { return total }
            return total + step.content.reduce(0) { if case .reasoning(let text) = $1 { $0 + text.text.count } else { $0 } }
        } ?? 0
        // How far from the end the conversation is scrolled: 0 when it followed the end.
        func scrollViews(in view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
        let scroll = NSApp.windows.compactMap(\.contentView).flatMap(scrollViews).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
        let fromEnd = scroll.map { Int(($0.documentView?.frame.height ?? 0) - $0.contentView.bounds.maxY) } ?? -1
        let line = "replay \((path as NSString).lastPathComponent) x\(speed): \(events.count) events, \(thinking) characters of thinking, \(wrong) of \(checked) blocks shown wrong, played in \(played) (recorded \(String(format: "%.1f", recordedLength)) s), ended \(fromEnd) pt from the end of \(Int(scroll?.documentView?.frame.height ?? 0)), \(workspace.model(for: id)?.transcript.messages.count ?? -1) messages; " + meter.stop() + "\n"
        log.notice("\(line, privacy: .public)")
        if let file = ProcessInfo.processInfo.environment["KUVO_PERF_LOG"] {
            if let handle = FileHandle(forWritingAtPath: file) { handle.seekToEndOfFile(); handle.write(Foundation.Data(line.utf8)); try? handle.close() } else { FileManager.default.createFile(atPath: file, contents: Foundation.Data(line.utf8)) }
        }
    }
}

/// How the app keeps up while it's measured: how long the main thread takes to get to something
/// asked of it (a stand-in for your clicks, keys and scrolling), its CPU time and the process's,
/// memory, and the frames drawn.
nonisolated final class PerfMeter: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var isRunning = true
    private var waits: [Double] = []
    private var peakMemory: UInt64 = 0
    private var link: CADisplayLink?
    private var frames = 0
    private var lateFrames = 0
    private var lastFrame: CFTimeInterval = 0
    private var began = CACurrentMediaTime()
    private var cpuAtStart: Double = 0
    private var made = (rows: 0, pieces: 0, codeBlocks: 0)
    private var rowsByID: [String: Int] = [:]
    private var mainAtStart: Double = 0
    private let mainThread = mach_thread_self()

    @MainActor func start() {
        began = CACurrentMediaTime()
        cpuAtStart = Self.processCPU()
        mainAtStart = mainCPU()
        made = (ScrollFrameMonitor.rowsMade, ScrollFrameMonitor.piecesMade, ScrollFrameMonitor.codeBlocksMade)
        rowsByID = ScrollFrameMonitor.rowsMadeByID
        Thread { [self] in pingMain() }.start()
        if let view = NSApp.windows.first(where: \.isVisible)?.contentView {
            let link = view.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    /// "main thread …; process …; memory …; frames …".
    @MainActor func stop() -> String {
        lock.withLock { isRunning = false }
        link?.invalidate()
        let seconds = CACurrentMediaTime() - began
        let cpu = (Self.processCPU() - cpuAtStart) / seconds * 100
        let main = (mainCPU() - mainAtStart) / seconds * 100
        let sorted = lock.withLock { waits.sorted() }
        func percentile(_ p: Double) -> Int { sorted.isEmpty ? 0 : Int(sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]) }
        let over50 = sorted.count { $0 > 50 }
        let over100 = sorted.count { $0 > 100 }
        let stalled = sorted.filter { $0 > 16 }.reduce(0, +) / 1000
        return "main thread \(Int(main))% busy, waits p50 \(percentile(0.5)) ms, p95 \(percentile(0.95)) ms, p99 \(percentile(0.99)) ms, worst \(Int(sorted.last ?? 0)) ms, \(over50) over 50 ms, \(over100) over 100 ms, \(String(format: "%.1f", stalled)) s stalled; process \(Int(cpu))% CPU; memory peak \(peakMemory / 1_048_576) MB; \(frames) frames (\(Int(Double(frames) / seconds)) a second), \(lateFrames) late; made \(ScrollFrameMonitor.rowsMade - made.rows) rows, \(ScrollFrameMonitor.piecesMade - made.pieces) Markdown pieces, \(ScrollFrameMonitor.codeBlocksMade - made.codeBlocks) code blocks" + mostMade
    }

    /// The rows made most often meanwhile, as " (id ×count, …)".
    @MainActor private var mostMade: String {
        let counts = ScrollFrameMonitor.rowsMadeByID.map { ($0.key, $0.value - (rowsByID[$0.key] ?? 0)) }.filter { $0.1 > 1 }.sorted { $0.1 > $1.1 }.prefix(4)
        return counts.isEmpty ? "" : " (" + counts.map { "\($0.0) ×\($0.1)" }.joined(separator: ", ") + ")"
    }

    /// Asks the main thread for something, every few milliseconds, and notes how long it took.
    private func pingMain() {
        var count = 0
        while lock.withLock({ isRunning }) {
            let start = CACurrentMediaTime()
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { done.signal() }
            done.wait()
            let wait = (CACurrentMediaTime() - start) * 1000
            count += 1
            let memory = count % 20 == 0 ? Self.memory() : 0
            lock.withLock {
                waits.append(wait)
                peakMemory = max(peakMemory, memory)
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        if lastFrame > 0, link.timestamp - lastFrame > link.duration * 1.5 { lateFrames += 1 }
        lastFrame = link.timestamp
        frames += 1
    }

    private static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private func mainCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(mainThread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
    }

    private static func memory() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
#endif
