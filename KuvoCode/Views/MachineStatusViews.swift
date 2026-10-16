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
            case .downloading(let progress):
                ProgressView(value: progress)
                    .frame(width: 220)
            case .starting:
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
        case .downloading: "Installing the engine on \(name)…"
        case .starting, .ready: "Connecting to \(name)…"
        case .failed where engine.isRetrying: "Reconnecting to \(name)…"
        case .failed: "Couldn’t connect to \(name)"
        case .preparing: "\(name) isn’t connected"
        }
    }
}

/// Over the composer while a session's machine can't be reached: that it's connecting again,
/// that what you write waits, and a way to connect now.
struct MachineOfflineBar: View {
    let engine: MachineEngine
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            Spinner(size: 13)
            VStack(alignment: .leading, spacing: 1) {
                Text("Reconnecting to \(engine.machine.name)…")
                    .font(.system(size: 13, weight: .medium))
                Text("You can write meanwhile; it sends once the connection is back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Connect Now") { app.reconnectNow(engine) }
                .buttonStyle(.glass)
                .help("Drop this connection and connect to \(engine.machine.name) again")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
