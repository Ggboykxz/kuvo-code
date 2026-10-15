import CryptoKit
import Foundation
import Security

/// One pinned build of the opencode server: where to download it and how to
/// recognise the genuine file.
public struct EngineRelease: Sendable, Equatable {
    public var version: String
    /// The npm tarball for the platform package.
    public var tarball: URL
    /// npm's `dist.integrity` for that tarball (`sha512-<base64>`).
    public var integrity: String
    /// The Apple team that signs opencode's binaries.
    public var teamIdentifier: String

    /// The build this version of the app is written against.
    public static let pinned = EngineRelease(
        version: OpenCodeEngine.version,
        tarball: URL(string: "https://registry.npmjs.org/@opencode/cli-darwin-arm64/-/cli-darwin-arm64-2.0.29.tgz")!,
        integrity: "sha512-2tJOM20RpOjNeWsYcV3VfRFPDTeu1yMMbEqAQm1sEKmHX9087Sx/TxhwBlvtiudOGq6Kr3zyKmW1t7aFF6qCsQ==",
        teamIdentifier: "5NZ4Q7NXJ4"
    )

    /// The same version for Linux machines reached over SSH, by `uname -m`. Linux builds carry no
    /// Apple signature: npm's checksum, checked on this Mac before upload, is what vouches for them.
    public static func linux(machine: String) -> EngineRelease? {
        switch machine {
        case "x86_64", "amd64":
            EngineRelease(
                version: OpenCodeEngine.version,
                tarball: URL(string: "https://registry.npmjs.org/@opencode/cli-linux-x64/-/cli-linux-x64-2.0.29.tgz")!,
                integrity: "sha512-pdG/T4uBxSC3hjUTOrTlx2pXlZl2VqABlb0AgDlZ8VO/q1pUUOYvooWmN5VeSi+EP8cKGVUsj0GUmMDeB2ympA==",
                teamIdentifier: ""
            )
        case "aarch64", "arm64":
            EngineRelease(
                version: OpenCodeEngine.version,
                tarball: URL(string: "https://registry.npmjs.org/@opencode/cli-linux-arm64/-/cli-linux-arm64-2.0.29.tgz")!,
                integrity: "sha512-EsCnvp5lMJNem0YoQJM9PkXY0KrkiugL55M9J2JlImQzKdQnZ4CKutrPAXOnsa889qHhY5tjRpAnD/ZYFzhkRA==",
                teamIdentifier: ""
            )
        default:
            nil
        }
    }
}

public enum EngineInstallError: LocalizedError {
    case integrityMismatch
    case badSignature(OSStatus)
    case extractionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .integrityMismatch: "The downloaded engine didn't match its checksum."
        case .badSignature: "The downloaded engine isn't signed by the opencode team."
        case .extractionFailed(let output): "The engine couldn't be unpacked. \(output)"
        }
    }
}

/// Keeps one verified copy of the opencode binary per version, in a folder the app owns:
/// `<root>/<version>/opencode`.
public struct EngineInstaller: Sendable {
    public var root: URL
    public var release: EngineRelease

    public init(root: URL, release: EngineRelease = .pinned) {
        self.root = root
        self.release = release
    }

    public var executable: URL {
        root.appending(path: release.version).appending(path: "opencode")
    }

    /// The installed binary, if it's there and still carries opencode's signature.
    public func installed() -> URL? {
        let url = executable
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return (try? verifySignature(of: url)) != nil ? url : nil
    }

    /// Downloads, verifies and unpacks the pinned release. `progress` gets the fraction downloaded.
    public func install(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        if let url = installed() { return url }

        let download = try await Self.download(release, progress: progress)
        defer { try? FileManager.default.removeItem(at: download) }

        // Unpack next to the final location, then move into place, so a crash never
        // leaves a half-written binary where `installed()` would find it.
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appending(path: ".staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try untar(download, into: staging)

        let binary = staging.appending(path: "package/bin/opencode")
        try verifySignature(of: binary)
        let destination = executable.deletingLastPathComponent()
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try fm.moveItem(at: binary, to: executable)
        removeOtherVersions()
        progress(1)
        return executable
    }

    /// Downloads a release's tarball to a temporary file and checks it against npm's checksum.
    static func download(_ release: EngineRelease, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let observer = DownloadProgress(report: progress)
        let (download, response) = try await URLSession.shared.download(from: release.tarball, delegate: observer)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: download)
            throw URLError(.badServerResponse)
        }
        do {
            try verifyIntegrity(of: download, against: release)
        } catch {
            try? FileManager.default.removeItem(at: download)
            throw error
        }
        return download
    }

    static func verifyIntegrity(of file: URL, against release: EngineRelease) throws {
        guard release.integrity.hasPrefix("sha512-") else { throw EngineInstallError.integrityMismatch }
        let expected = Data(base64Encoded: String(release.integrity.dropFirst("sha512-".count)))
        var hasher = SHA512()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        guard Data(hasher.finalize()) == expected else { throw EngineInstallError.integrityMismatch }
    }

    /// Checks the binary is intact and signed with a Developer ID from opencode's team.
    private func verifySignature(of binary: URL) throws {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(binary as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw EngineInstallError.badSignature(status) }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(release.teamIdentifier)\""
        status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess else { throw EngineInstallError.badSignature(status) }
        status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)
        guard status == errSecSuccess else { throw EngineInstallError.badSignature(status) }
    }

    private func untar(_ archive: URL, into directory: URL) throws {
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", directory.path]
        let pipe = Pipe()
        tar.standardError = pipe
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw EngineInstallError.extractionFailed(output)
        }
    }

    private func removeOtherVersions() {
        let fm = FileManager.default
        for entry in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where entry != release.version {
            try? fm.removeItem(at: root.appending(path: entry))
        }
    }
}

/// Reports a download task's progress while `URLSession.download(from:delegate:)` runs.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void
    nonisolated(unsafe) private var observation: NSKeyValueObservation?

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
            report(progress.fractionCompleted)
        }
    }
}
