import OpenCodeKit
import SwiftUI

/// The window: the engine's setup screen until it's running, then the workspace.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Appearance.key) private var appearance = Appearance.system

    var body: some View {
        ZStack {
            switch app.engine {
            case .ready:
                MainView()
                    .transition(.opacity)
            default:
                EngineSetupView()
                    .transition(.opacity.combined(with: .scale(0.98)))
            }
        }
        .animation(.ui, value: app.engine == .ready)
        .frame(minWidth: 620, minHeight: 520)
        // The window itself is frosted glass, tinted by what's behind it; cards float on it.
        .windowGlass()
        .onChange(of: appearance, initial: true) { appearance.apply() }
        // The usage menu's "Open Kuvo Code" brings this window back, even after it's closed.
        .onAppear { app.openMainWindow = { [openWindow] in openWindow(id: "main") } }
    }
}

/// First launch downloads the engine; every launch waits a moment for it to start.
struct EngineSetupView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: isWorking)
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 56)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420)
            }

            switch app.engine {
            case .downloading(let progress):
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 280)
            case .failed:
                Button("Try Again") { Task { await app.restart() } }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            default:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private var isWorking: Bool {
        if case .failed = app.engine { false } else { true }
    }

    private var symbol: String {
        switch app.engine {
        case .failed: "exclamationmark.triangle"
        case .downloading: "arrow.down.circle"
        default: "sparkles"
        }
    }

    private var title: String {
        switch app.engine {
        case .downloading: "Setting up"
        case .failed: "The engine couldn't start"
        default: "Starting"
        }
    }

    private var detail: String {
        switch app.engine {
        case .downloading(let progress):
            "Downloading the agent engine (opencode \(OpenCodeEngine.version)). This happens once.\n\(Int(progress * 100))%"
        case .failed(let message):
            message
        default:
            "Getting the agent engine ready…"
        }
    }
}
