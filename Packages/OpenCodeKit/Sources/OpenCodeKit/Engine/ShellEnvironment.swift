import Foundation

/// The environment a terminal would have. Apps opened from the Finder or Dock
/// inherit launchd's bare environment (PATH is `/usr/bin:/bin:/usr/sbin:/sbin`),
/// so the agent's shell commands wouldn't find Homebrew, nvm, bun, etc.
/// opencode's own desktop app does the same thing.
public enum ShellEnvironment {
    /// Runs the user's login shell once and returns its environment, or the
    /// app's own if the shell doesn't answer in time.
    public static func load(timeout: Duration = .seconds(5)) async -> [String: String] {
        let fallback = ProcessInfo.processInfo.environment
        let shell = fallback["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        // nushell doesn't take POSIX flags.
        guard !shell.hasSuffix("/nu") else { return fallback }

        for flags in ["-ilc", "-lc"] {
            if let environment = await run(shell: shell, flags: flags, timeout: timeout), environment["PATH"] != nil {
                return environment
            }
        }
        return fallback
    }

    private static func run(shell: String, flags: String, timeout: Duration) async -> [String: String]? {
        let process = Process()
        process.executableURL = URL(filePath: shell)
        process.arguments = [flags, "/usr/bin/env -0"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        // Keeps interactive shells from asking about things like oh-my-zsh updates.
        var environment = ProcessInfo.processInfo.environment
        environment["DISABLE_AUTO_UPDATE"] = "true"
        process.environment = environment

        do { try process.run() } catch { return nil }
        let reader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        let data = await reader.value
        watchdog.cancel()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for entry in data.split(separator: 0) {
            guard let line = String(data: entry, encoding: .utf8), let equals = line.firstIndex(of: "=") else { continue }
            result[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return result
    }
}
