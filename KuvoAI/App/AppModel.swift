import Foundation
import OpenCodeKit
import os

/// Owns the engine (the opencode server) and the stores fed by it.
@Observable
final class AppModel {
    enum EngineState: Equatable {
        case preparing
        case downloading(progress: Double)
        case starting
        case ready
        case failed(String)
    }

    private(set) var engine = EngineState.preparing
    private(set) var api: OpenCodeAPI?
    /// False while the live event feed is down (the UI shows it, and re-syncs after).
    private(set) var isLive = false

    let catalog = Catalog()
    let workspace = Workspace()

    private var server: ServerProcess?
    private var eventTask: Task<Void, Never>?
    private var isStopping = false
    private let log = Logger(subsystem: "run.kuvo.ai", category: "engine")

    private var installer: EngineInstaller {
        EngineInstaller(root: AppInfo.supportDirectory.appending(path: "engine"))
    }

    /// Downloads the engine if needed, starts it, and connects the stores.
    func start() async {
        guard engine != .ready, engine != .starting else { return }
        isStopping = false
        do {
            // Set KUVO_OPENCODE_BINARY to run a local opencode build instead of the pinned download.
            async let environment = ShellEnvironment.load()
            let binary: URL
            if let override = ProcessInfo.processInfo.environment["KUVO_OPENCODE_BINARY"] {
                binary = URL(filePath: override)
            } else if let installed = installer.installed() {
                binary = installed
            } else {
                engine = .downloading(progress: 0)
                binary = try await installer.install { progress in
                    Task { @MainActor in
                        if case .downloading = self.engine { self.engine = .downloading(progress: progress) }
                    }
                }
            }

            engine = .starting
            let server = try await ServerProcess.start(
                executable: binary,
                folders: EngineFolders(root: AppInfo.supportDirectory.appending(path: "opencode")),
                environment: await environment,
                onExit: { status in Task { @MainActor in self.engineExited(status: status) } }
            )
            self.server = server
            let api = OpenCodeAPI(endpoint: server.endpoint)
            try await waitUntilReady(api)
            self.api = api
            catalog.api = api
            workspace.api = api
            engine = .ready
            listen(to: api)
            // In parallel: the catalog can wait on the engine's plugins (and they on a
            // macOS permission prompt); sessions shouldn't wait with it.
            async let catalogLoaded: Void = catalog.refresh()
            async let workspaceLoaded: Void = workspace.refresh()
            _ = await (catalogLoaded, workspaceLoaded)
        } catch {
            log.error("Engine failed to start: \(error.localizedDescription, privacy: .public)")
            engine = .failed(error.localizedDescription)
        }
    }

    func restart() async {
        stop()
        engine = .preparing
        await start()
    }

    func stop() {
        isStopping = true
        eventTask?.cancel()
        eventTask = nil
        server?.stop()
        server = nil
        api = nil
        isLive = false
    }

    /// The server answers 503 until it has loaded.
    private func waitUntilReady(_ api: OpenCodeAPI) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while true {
            do {
                _ = try await api.info()
                return
            } catch let error as ServerError where error.status == 503 {
                if ContinuousClock.now > deadline { throw error }
                try await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func listen(to api: OpenCodeAPI) {
        eventTask = Task { [weak self] in
            for await update in api.events.updates() {
                guard let self else { return }
                switch update {
                case .connected:
                    // Missed events aren't replayed: re-read everything on screen.
                    let wasLive = isLive
                    isLive = true
                    if !wasLive {
                        await catalog.refresh()
                        await workspace.resync()
                    }
                case .disconnected:
                    isLive = false
                case .event(let event):
                    catalog.handle(event)
                    workspace.handle(event)
                }
            }
        }
    }

    private func engineExited(status: Int32) {
        guard !isStopping else { return }
        let output = server?.recentOutput.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        log.error("Engine exited with status \(status): \(output, privacy: .public)")
        stop()
        engine = .failed("The engine stopped unexpectedly (exit code \(status)).\(output.isEmpty ? "" : "\n\n" + String(output.suffix(600)))")
    }
}
