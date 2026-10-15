import CryptoKit
import Foundation
import OpenCodeKit

/// The browser machines run, as `browser-runtime.json` pins it (`scripts/browser-runtime.py`):
/// Chrome for Testing's headless shell for each Linux architecture, and the Enterprise Linux 8
/// packages that hold the libraries and fonts it needs, each with its checksum.
nonisolated struct BrowserRuntime: Decodable, Sendable {
    struct Download: Decodable, Sendable {
        var url: URL
        var sha256: String
        var size: Int
    }

    struct Package: Decodable, Sendable {
        var name: String
        var version: String
        var repo: String
        var path: String
        var sha256: String
        var size: Int
    }

    struct Chromium: Decodable, Sendable {
        var version: String
        var x86_64: Download
        var aarch64: Download
    }

    var chromium: Chromium
    var packages: [String: [Package]]
    /// Names this build on a machine: the Chromium version, and a hash of everything in it, so
    /// newer libraries make a new folder too.
    var id: String

    private enum CodingKeys: String, CodingKey { case chromium, packages }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chromium = try container.decode(Chromium.self, forKey: .chromium)
        packages = try container.decode([String: [Package]].self, forKey: .packages)
        id = chromium.version
    }

    static let pinned: BrowserRuntime? = {
        guard let url = Bundle.main.url(forResource: "browser-runtime", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              var runtime = try? JSONDecoder().decode(BrowserRuntime.self, from: data) else { return nil }
        runtime.id = runtime.chromium.version + "-" + SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        return runtime
    }()

    /// The architecture's name here, from `uname -m` on the machine.
    static func architecture(_ machine: String) -> String? {
        switch machine {
        case "x86_64", "amd64": "x86_64"
        case "aarch64", "arm64": "aarch64"
        default: nil
        }
    }

    func chromium(for architecture: String) -> Download? {
        switch architecture {
        case "x86_64": chromium.x86_64
        case "aarch64": chromium.aarch64
        default: nil
        }
    }

    /// Where a package downloads from: Rocky Linux's current repositories, then its vault, which
    /// keeps every release's packages once a newer one replaces them.
    static func urls(for package: Package, architecture: String) -> [URL] {
        ["https://dl.rockylinux.org/pub/rocky/8", "https://dl.rockylinux.org/vault/rocky/8.10"].compactMap {
            URL(string: "\($0)/\(package.repo)/\(architecture)/os/\(package.path)")
        }
    }
}

nonisolated enum MachineBrowserError: LocalizedError {
    case notPinned
    case unsupported(String)
    case checksum(String)
    case download(String, Error?)
    case unpack(String)
    case browser(String)

    var errorDescription: String? {
        switch self {
        case .notPinned: "This build of Kuvo Code has no browser for machines."
        case .unsupported(let machine): "The browser runs on Linux machines with x86-64 or ARM64 processors; this one is \(machine)."
        case .checksum(let name): "The download of \(name) didn't match its checksum."
        case .download(let name, let error): "Couldn't download \(name)\(error.map { ": \($0.localizedDescription)" } ?? ".")"
        case .unpack(let output): "Couldn't put the browser together. \(output)"
        case .browser(let message): message
        }
    }
}

/// Puts the browser on a machine, in `~/.kuvo-code/browser`: Chromium and, beside it, every
/// library and font it needs, so nothing has to be installed on the machine itself. It's all
/// downloaded and checked on this Mac, put together here, and sent over SSH, so the machine
/// needs nothing but `sh` and `tar`, as for the engine, and never downloads code itself.
///
/// The helper the engine and the panel talk to, `kuvo-browser.js`, goes to `~/.kuvo-code/bin`.
nonisolated enum MachineBrowserInstaller {
    static var folder: String { "$HOME/\(RemoteEngineInstaller.root)/browser" }
    static var helperPath: String { "$HOME/\(RemoteEngineInstaller.root)/bin/kuvo-browser.js" }

    /// The machine's processor, as the runtime names it.
    static func architecture(on connection: SSHConnection) async throws -> String {
        let machine = try await connection.run("uname -m").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let architecture = BrowserRuntime.architecture(machine) else { throw MachineBrowserError.unsupported(machine) }
        return architecture
    }

    /// Whether the machine has this build in use, or a newer one: a Mac with an older version of
    /// the app uses the newer browser another Mac put there, rather than swapping it back.
    static func isInstalled(_ runtime: BrowserRuntime, on connection: SSHConnection) async throws -> Bool {
        let output = try await connection.run("""
            B="\(folder)"
            current=$(readlink "$B/current" 2>/dev/null) || exit 0
            [ -x "$B/$current/chrome-headless-shell" ] && echo "$current" || true
            """)
        let current = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return false }
        if current == runtime.id { return true }
        let theirs = current.split(separator: "-").first.map(String.init) ?? ""
        return theirs.compare(runtime.chromium.version, options: .numeric) == .orderedDescending
    }

    /// Sends a bundle to the machine and makes it the one in use. Older builds go, unless a browser
    /// still runs from one (it moves to the new one when it next starts).
    static func send(_ bundle: URL, _ runtime: BrowserRuntime, to connection: SSHConnection) async throws {
        try await connection.run("""
            set -e
            B="\(folder)"
            mkdir -p "$B"
            rm -rf "$B/.staging"
            mkdir -p "$B/.staging"
            tar xzf - -C "$B/.staging"
            rm -rf "$B/\(runtime.id)"
            mv "$B/.staging" "$B/\(runtime.id)"
            ln -sfn "\(runtime.id)" "$B/current"
            for old in "$B"/*; do
              name=$(basename "$old")
              # Not `current` (a link to the new build), nor the new build, nor website data.
              [ -L "$old" ] || [ ! -d "$old" ] && continue
              [ "$name" = "\(runtime.id)" ] || [ "$name" = profile ] && continue
              [ -e "$old/chrome-headless-shell" ] || continue
              grep -qs -- "$B/$name/" /proc/[0-9]*/cmdline 2>/dev/null && continue
              rm -rf "$old"
            done
            """, input: bundle)
    }

    // MARK: The bundle

    /// The browser for `architecture`, put together as a `.tar.gz` to unpack on a machine: from this
    /// Mac's cache when it's there and intact, else downloaded and checked first. `progress` gets
    /// the fraction downloaded.
    static func bundle(for architecture: String, runtime: BrowserRuntime, cache: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let file = cache.appending(path: "\(runtime.id)-\(architecture).tar.gz")
        let checksum = cache.appending(path: "\(runtime.id)-\(architecture).sha256")
        if fm.fileExists(atPath: file.path), let expected = try? String(contentsOf: checksum, encoding: .utf8),
           (try? sha256(of: file)) == expected.trimmingCharacters(in: .whitespacesAndNewlines) {
            return file
        }
        guard let chromium = runtime.chromium(for: architecture), let packages = runtime.packages[architecture] else {
            throw MachineBrowserError.unsupported(architecture)
        }
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let staging = cache.appending(path: ".staging-\(UUID().uuidString)")
        let root = staging.appending(path: "root")
        let bundle = staging.appending(path: "bundle")
        for folder in [root, bundle.appending(path: "lib"), bundle.appending(path: "fonts"), bundle.appending(path: "licenses")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: staging) }

        // Downloads, by size, for the progress.
        let total = Double(chromium.size + packages.reduce(0) { $0 + $1.size })
        let done = Counter()
        let report: @Sendable (String, Int) -> Void = { name, bytes in progress(min(1, Double(done.set(name, bytes)) / total)) }

        // Chromium: its folder's files at the top of the bundle.
        let zip = try await download("Chromium", from: [chromium.url], sha256: chromium.sha256, into: staging, report: report)
        try run("/usr/bin/unzip", ["-q", zip.path, "-d", staging.appending(path: "chromium").path])
        try? fm.removeItem(at: zip)
        guard let unpacked = try fm.contentsOfDirectory(at: staging.appending(path: "chromium"), includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.hasPrefix("chrome-headless-shell") }) else {
            throw MachineBrowserError.unpack("The Chromium download has no browser in it.")
        }
        for item in try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil) {
            try fm.moveItem(at: item, to: bundle.appending(path: item.lastPathComponent))
        }

        // The packages, a few at a time, unpacked into one tree.
        try await withThrowingTaskGroup(of: URL.self) { group in
            var queue = packages[...]
            func next() {
                guard let package = queue.popFirst() else { return }
                group.addTask {
                    try await download(package.name, from: BrowserRuntime.urls(for: package, architecture: architecture), sha256: package.sha256, into: staging, report: report)
                }
            }
            for _ in 0..<6 { next() }
            while let rpm = try await group.next() {
                try run("/usr/bin/tar", ["-xf", rpm.path, "-C", root.path])
                try? fm.removeItem(at: rpm)
                next()
            }
        }

        // Their libraries in `lib` (with the links between their names), their fonts in `fonts`.
        let libraries = root.appending(path: "usr/lib64")
        for name in (try? fm.contentsOfDirectory(atPath: libraries.path)) ?? [] where name.contains(".so") {
            try fm.moveItem(at: libraries.appending(path: name), to: bundle.appending(path: "lib/\(name)"))
        }
        let fonts = (fm.enumerator(at: root.appending(path: "usr/share/fonts"), includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { ["ttf", "otf", "ttc"].contains($0.pathExtension.lowercased()) }
        for font in fonts {
            try? fm.moveItem(at: font, to: bundle.appending(path: "fonts/\(font.lastPathComponent)"))
        }
        for name in (try? fm.contentsOfDirectory(atPath: root.appending(path: "usr/share/licenses").path)) ?? [] {
            try? fm.moveItem(at: root.appending(path: "usr/share/licenses/\(name)"), to: bundle.appending(path: "licenses/\(name)"))
        }
        try Data(fontConfig.utf8).write(to: bundle.appending(path: "fonts.conf"))
        try Data((runtime.chromium.version + "\n").utf8).write(to: bundle.appending(path: "chromium-version"))

        let packed = staging.appending(path: "bundle.tar.gz")
        try run("/usr/bin/tar", ["--no-xattrs", "--no-mac-metadata", "-czf", packed.path, "-C", bundle.path, "."], environment: ["COPYFILE_DISABLE": "1"])
        try? fm.removeItem(at: file)
        try fm.moveItem(at: packed, to: file)
        try Data(try sha256(of: file).utf8).write(to: checksum)
        // Older builds aren't needed again.
        for entry in (try? fm.contentsOfDirectory(atPath: cache.path)) ?? [] where !entry.hasPrefix(runtime.id) && !entry.hasPrefix(".staging") {
            try? fm.removeItem(at: cache.appending(path: entry))
        }
        progress(1)
        return file
    }

    /// The bundle's fonts, and the machine's own if it has any, for the browser's fontconfig.
    static let fontConfig = """
        <?xml version="1.0"?>
        <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
        <fontconfig>
          <dir prefix="relative">fonts</dir>
          <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
          <cachedir prefix="relative">fontcache</cachedir>
          <alias><family>sans-serif</family><prefer><family>Liberation Sans</family><family>DejaVu Sans</family></prefer></alias>
          <alias><family>serif</family><prefer><family>Liberation Serif</family><family>DejaVu Sans</family></prefer></alias>
          <alias><family>monospace</family><prefer><family>Liberation Mono</family><family>DejaVu Sans</family></prefer></alias>
          <alias><family>emoji</family><prefer><family>Noto Color Emoji</family></prefer></alias>
        </fontconfig>

        """

    /// Downloads a file, from the first address that has it, and checks it against its checksum.
    private static func download(_ name: String, from urls: [URL], sha256 expected: String, into folder: URL, report: @escaping @Sendable (String, Int) -> Void) async throws -> URL {
        var lastError: Error?
        for url in urls {
            do {
                let (temporary, response) = try await URLSession.shared.download(from: url, delegate: DownloadProgress { report(name, $0) })
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    try? FileManager.default.removeItem(at: temporary)
                    continue
                }
                guard try sha256(of: temporary) == expected else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw MachineBrowserError.checksum(name)
                }
                let file = folder.appending(path: url.lastPathComponent)
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: temporary, to: file)
                report(name, Int((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
                return file
            } catch let error as MachineBrowserError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw MachineBrowserError.download(name, lastError)
    }

    static func sha256(of file: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ tool: String, _ arguments: [String], environment: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MachineBrowserError.unpack(String(decoding: output, as: UTF8.self)) }
    }

    /// Bytes downloaded so far, from downloads running at once.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [String: Int] = [:]
        func set(_ name: String, _ count: Int) -> Int {
            lock.withLock {
                bytes[name] = count
                return bytes.values.reduce(0, +)
            }
        }
    }

    /// Reports a download's bytes as they arrive.
    private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let report: @Sendable (Int) -> Void
        private var observation: NSKeyValueObservation?

        init(report: @escaping @Sendable (Int) -> Void) {
            self.report = report
        }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            observation = task.progress.observe(\.completedUnitCount) { [report] progress, _ in
                report(Int(progress.completedUnitCount))
            }
        }
    }
}

// MARK: - The helper

extension MachineBrowserInstaller {
    /// `kuvo-browser.js` as it goes to a machine: the browsing scripts and tools the panel's
    /// browser uses, filled in. Its first line names its contents, to tell whether a machine has it.
    @MainActor static let helper: (text: String, hash: String) = {
        guard let url = Bundle.main.url(forResource: "kuvo-browser", withExtension: "js"),
              let template = try? String(contentsOf: url, encoding: .utf8) else { return ("", "") }
        let config: [String: Any] = [
            "scripts": [
                "snapshot": BrowserAgent.snapshotScript,
                "find": BrowserAgent.findElement,
                "click": BrowserAgent.clickScript,
                "type": BrowserAgent.typeScript,
                "select": BrowserAgent.selectScript,
                "press": BrowserAgent.pressScript,
            ],
            "tools": BrowserTools.definitions,
            "instructions": "Use these tools to browse in the browser on this machine, which the user can watch in Kuvo Code's panel. Start with browser_navigate, read pages with browser_snapshot, and act on elements by their number. localhost is this machine, so you can open servers you run here.",
            "version": AppInfo.version,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let marker = #"/*KUVO_CONFIG*/ { scripts: {}, tools: [], instructions: "", version: "dev" }"#
        let body = template.replacingOccurrences(of: marker, with: json)
        let hash = SHA256.hash(data: Data(body.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return ("// kuvo-browser \(hash)\n" + body, hash)
    }()

    /// Puts the helper on the machine, unless it has this one already.
    static func installHelper(_ helper: (text: String, hash: String), on connection: SSHConnection) async throws {
        let first = try await connection.run("head -n 1 \"\(helperPath)\" 2>/dev/null || true")
        guard first.trimmingCharacters(in: .whitespacesAndNewlines) != "// kuvo-browser \(helper.hash)" else { return }
        let file = FileManager.default.temporaryDirectory.appending(path: "kuvo-browser-\(UUID().uuidString).js")
        try Data(helper.text.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await connection.run("""
            set -e
            mkdir -p "$HOME/\(RemoteEngineInstaller.root)/bin"
            cat >"\(helperPath).new"
            mv -f "\(helperPath).new" "\(helperPath)"
            """, input: file)
    }

    /// The command that runs the helper on a machine, with the engine's own runtime: this
    /// version's, or the one there (a newer one another Mac put there).
    static func command(_ mode: String) -> String {
        """
        K="$HOME/\(RemoteEngineInstaller.root)"; E="$K/engine/\(OpenCodeEngine.version)/opencode"; \
        [ -x "$E" ] || E=$(ls -d "$K"/engine/*/opencode 2>/dev/null | tail -n 1); \
        KUVO_HOME="$K" BUN_BE_BUN=1 exec "$E" "\(helperPath)" \(mode)
        """
    }

    /// The machine's engine's config entry for the browser tools: the helper, as a local MCP
    /// server, under the same name as the panel's browser tools on this Mac.
    @MainActor static var engineConfig: [String: Any] {
        ["mcp": ["servers": ["kuvo-browser": [
            "type": "local",
            "command": ["sh", "-c", command("mcp")],
            "environment": ["KUVO_SEARCH": searchTemplate],
            // Plain tools, so every model calls them directly.
            "codemode": false,
        ] as [String: Any]]]]
    }

    /// The search engine chosen in Settings, with `%s` for the words.
    static var searchTemplate: String {
        SearchEngine.current.url(for: "KUVOQUERY")?.absoluteString.replacingOccurrences(of: "KUVOQUERY", with: "%s") ?? "https://www.google.com/search?q=%s"
    }
}
