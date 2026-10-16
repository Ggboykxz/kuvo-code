import SwiftUI

/// A machine's connection, as a dot and a word or two: green when connected, a spinner while
/// connecting, orange when it couldn't (the reason on hover).
struct MachineStatus: View {
    let engine: MachineEngine

    var body: some View {
        HStack(spacing: 5) {
            switch engine.state {
            case .ready where engine.isLive:
                Circle().fill(.green).frame(width: 7, height: 7)
            case .failed where !engine.isRetrying:
                Circle().fill(.orange).frame(width: 7, height: 7)
            case .preparing:
                Circle().fill(.secondary).frame(width: 7, height: 7)
            default:
                Spinner(size: 11)
            }
            Text(engine.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .help(failure ?? engine.statusText)
    }

    private var failure: String? {
        if case .failed(let reason) = engine.state { return reason }
        return nil
    }
}

/// In place of a session or a new session on a machine that isn't connected: what's happening,
/// and a way to try again.
struct MachineWaitingView: View {
    let engine: MachineEngine
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            switch engine.state {
            case .downloading(let progress) where progress > 0:
                ProgressView(value: progress)
                    .frame(width: 220)
            case .downloading, .starting:
                Spinner(size: 16)
            case .failed where engine.isRetrying:
                Spinner(size: 16)
            case .failed(let reason):
                Text(reason)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 440)
                Button("Try Again") { app.connect(engine) }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            case .preparing:
                Button("Connect") { app.connect(engine) }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            case .ready:
                Spinner(size: 16)
            }
            Spacer()
            Spacer()
        }
        .padding(Metrics.gutter)
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        let name = engine.machine.name
        return switch engine.state {
        // At 0 it's only checking the engine it has.
        case .downloading(let progress) where progress > 0: "Installing the engine on \(name)…"
        case .downloading, .starting, .ready: engine.isRetrying ? "Reconnecting to \(name)…" : "Connecting to \(name)…"
        case .failed where engine.isRetrying: "Reconnecting to \(name)…"
        case .failed: "Couldn’t connect to \(name)"
        case .preparing: "\(name) isn’t connected"
        }
    }
}

/// Over the composer while a session's machine can't be reached: what's happening, that the
/// conversation above is as last seen and what you write waits, and a way to connect now.
struct MachineOfflineBar: View {
    let engine: MachineEngine
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            if isWorking {
                Spinner(size: 13)
            } else {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text("This is the conversation as last seen. You can write meanwhile, and send once it’s back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .help(failure ?? title)
            Spacer(minLength: 8)
            // Not while it's trying already.
            if !isAttempting {
                Button(isWorking ? "Connect Now" : engine.state == .preparing ? "Connect" : "Try Again") { app.reconnectNow(engine) }
                    .buttonStyle(.glass)
                    .help("Connect to \(engine.machine.name) again")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Connecting by itself: no need to do anything.
    private var isWorking: Bool {
        switch engine.state {
        case .preparing: false
        case .failed: engine.isRetrying
        default: true
        }
    }

    /// Connecting this moment (not waiting to try again).
    private var isAttempting: Bool {
        switch engine.state {
        case .starting, .downloading: true
        default: false
        }
    }

    private var title: String {
        let name = engine.machine.name
        return switch engine.state {
        // At 0 it's only checking the engine it has.
        case .downloading(let progress) where progress > 0: "Installing the engine on \(name)…"
        case .preparing: "\(name) isn’t connected"
        case .failed where !engine.isRetrying: "Couldn’t connect to \(name)"
        case .starting where !engine.isRetrying: "Connecting to \(name)…"
        default: "Reconnecting to \(name)…"
        }
    }

    private var failure: String? {
        if case .failed(let reason) = engine.state { return reason }
        return nil
    }
}
