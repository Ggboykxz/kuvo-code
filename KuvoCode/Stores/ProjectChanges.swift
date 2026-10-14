import Foundation
import OpenCodeKit
import UniformTypeIdentifiers

/// One changed file, parsed from a unified diff: every line it shows, with its numbers
/// on each side. Git is asked for the whole file as context, so unchanged stretches can
/// be folded and opened again without another call.
nonisolated struct ChangedFile: Identifiable, Hashable, Sendable {
    enum Status: Sendable { case added, deleted, modified, renamed }

    /// Relative to the repository (or the project, without one).
    var path: String
    var oldPath: String?
    var status: Status
    var isBinary = false
    var lines: [DiffLine] = []
    /// Where the file is on disk.
    var url: URL
    /// The repository, and git's names for the two versions ("HEAD:path", ":path" for
    /// the index); nil reads that side from disk, or means there's none.
    var root: String?
    var oldObject: String?
    var newObject: String?

    var id: String { path }

    /// Pictures get a before and after instead of lines.
    var isImage: Bool {
        UTType(filenameExtension: (path as NSString).pathExtension)?.conforms(to: .image) == true
    }
    var additions: Int { lines.count { $0.kind == .added } }
    var deletions: Int { lines.count { $0.kind == .removed } }
}

nonisolated struct DiffLine: Hashable, Sendable {
    enum Kind: Sendable { case context, added, removed }
    var kind: Kind
    var oldNumber: Int?
    var newNumber: Int?
    var text: String
    /// Unchanged lines git left out between two hunks (only with very long files).
    var gapBefore = false
}

/// What's changed in a project, as Codex shows it: the working tree against git, new
/// files included. Outside a repository, it falls back to the engine's record of the
/// session's edits.
@Observable
final class ProjectChanges {
    enum Scope: String, CaseIterable, Identifiable {
        case uncommitted, unstaged, staged
        var id: Self { self }
        var title: String {
            switch self {
            case .uncommitted: "Uncommitted"
            case .unstaged: "Unstaged"
            case .staged: "Staged"
            }
        }
    }

    let directory: String
    var scope = Scope.uncommitted
    private(set) var files: [ChangedFile] = []
    /// False outside a git repository; the scopes don't apply then.
    private(set) var isRepository = true
    private(set) var isLoaded = false
    private var signature = 0

    init(directory: String) {
        self.directory = directory
    }

    var additions: Int { files.reduce(0) { $0 + $1.additions } }
    var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

    /// Reads the changes again. `fallback` is the engine's diff, used outside a repository.
    func refresh(fallback: [FileDiff] = []) async {
        let directory = directory, scope = scope
        let result = await Task.detached { Git.changes(in: directory, scope: scope) }.value
        if let result {
            isRepository = true
            apply(result)
        } else {
            isRepository = false
            apply(fallback.map { DiffParser.file(from: $0, directory: directory) })
        }
        isLoaded = true
    }

    enum Action { case stage, unstage, discard }

    /// Stages, unstages or discards one file's changes, then reads the changes again. Discard
    /// follows the scope: in Unstaged only what isn't staged, otherwise back to the last commit.
    /// A file git doesn't know yet goes to the Trash. Returns git's complaint, if any.
    func perform(_ action: Action, on file: ChangedFile) async -> String? {
        guard let root = file.root else { return nil }
        let scope = scope
        let failure = await Task.detached { Git.perform(action, on: file, root: root, scope: scope) }.value
        await refresh()
        return failure
    }

    /// Commits what's staged, or everything in the project's folder when nothing is, and
    /// pushes if asked. Returns git's complaint, if any. `environment` is your shell's, so
    /// hooks, signing and pushing see what they do in Terminal.
    func commit(message: String, push: Bool, environment: [String: String]) async -> String? {
        let directory = directory
        let failure = await Task.detached { Git.commit(message: message, push: push, in: directory, environment: environment) }.value
        await refresh()
        return failure
    }

    /// The diff a commit would take (what's staged, or everything with new files' names),
    /// cut to a size a model reads quickly.
    func commitDiff() async -> String {
        let directory = directory
        return await Task.detached { Git.commitDiff(in: directory) }.value
    }

    /// Whether anything is staged, which is what a commit takes then.
    func hasStaged() async -> Bool {
        let directory = directory
        return await Task.detached { Git.hasStaged(in: directory) }.value
    }

    /// Only publishes when something changed, so a refresh doesn't redraw the panel.
    private func apply(_ files: [ChangedFile]) {
        let signature = files.hashValue
        guard signature != self.signature else { return }
        self.signature = signature
        self.files = files
    }
}

// MARK: - Git

nonisolated enum Git {
    /// The changed files in `scope`, or nil when `directory` isn't in a repository.
    static func changes(in directory: String, scope: ProjectChanges.Scope) -> [ChangedFile]? {
        guard let root = run(["rev-parse", "--show-toplevel"], in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !root.isEmpty else { return nil }
        // A repository without commits yet: compare with the empty tree.
        let base = run(["rev-parse", "--verify", "-q", "HEAD"], in: root) == nil ? "4b825dc642cb6eb9a060e54bf8d69288fbee4904" : "HEAD"
        let limit = relativePath(of: directory, in: root)
        var arguments = ["-c", "core.quotepath=off", "diff", "--no-color", "--no-ext-diff", "--find-renames", "-U100000"]
        switch scope {
        case .uncommitted: arguments.append(base)
        case .unstaged: break
        case .staged: arguments += ["--cached", base]
        }
        arguments += ["--", limit.isEmpty ? "." : limit]
        guard let patch = run(arguments, in: root) else { return nil }
        var files = DiffParser.files(from: patch, root: root).map { file in
            // Where each side lives, for showing pictures.
            var file = file
            file.root = root
            if file.status != .added { file.oldObject = (scope == .unstaged ? ":" : base + ":") + (file.oldPath ?? file.path) }
            if scope == .staged, file.status != .deleted { file.newObject = ":" + file.path }
            return file
        }
        if scope != .staged {
            let untracked = run(["-c", "core.quotepath=off", "ls-files", "--others", "--exclude-standard", "-z", "--", limit.isEmpty ? "." : limit], in: root) ?? ""
            for path in untracked.split(separator: "\0").map(String.init) where !files.contains(where: { $0.path == path }) {
                files.append(newFile(path, root: root))
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func perform(_ action: ProjectChanges.Action, on file: ChangedFile, root: String, scope: ProjectChanges.Scope) -> String? {
        let paths = [file.path] + (file.oldPath.map { [$0] } ?? [])
        let tracked = run(["ls-files", "--error-unmatch", "--", file.path], in: root) != nil
        func git(_ arguments: [String]) -> String? {
            run(arguments, in: root) == nil ? "git couldn't \(arguments.first ?? "do that") \(file.path)." : nil
        }
        switch action {
        case .stage:
            return git(["add", "-A", "--"] + paths)
        case .unstage:
            return git(["restore", "--staged", "--"] + paths)
        case .discard:
            // New to git (or only staged): it has no committed version to go back to.
            if file.status == .added, scope != .unstaged || !tracked {
                if tracked { _ = run(["rm", "--cached", "-q", "--", file.path], in: root) }
                do { try FileManager.default.trashItem(at: file.url, resultingItemURL: nil) } catch { return error.localizedDescription }
                return nil
            }
            if scope == .unstaged { return git(["restore", "--worktree", "--"] + paths) }
            if file.status == .renamed, let old = file.oldPath {
                _ = run(["rm", "--cached", "-q", "--", file.path], in: root)
                try? FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                return git(["restore", "--source=HEAD", "--staged", "--worktree", "--", old])
            }
            return git(["restore", "--source=HEAD", "--staged", "--worktree", "--", file.path])
        }
    }

    static func commitDiff(in directory: String, limit: Int = 40_000) -> String {
        var text: String
        if hasStaged(in: directory) {
            text = run(["diff", "--cached", "--no-color", "--no-ext-diff"], in: directory) ?? ""
        } else {
            text = run(["diff", "HEAD", "--no-color", "--no-ext-diff"], in: directory) ?? ""
            let untracked = run(["ls-files", "--others", "--exclude-standard"], in: directory) ?? ""
            if !untracked.isEmpty { text += "\nNew files:\n" + untracked }
        }
        return text.count > limit ? String(text.prefix(limit)) + "\n…" : text
    }

    static func hasStaged(in directory: String) -> Bool {
        // `diff --quiet` fails when there are differences.
        run(["diff", "--cached", "--quiet"], in: directory) == nil
    }

    static func commit(message: String, push: Bool, in directory: String, environment: [String: String]) -> String? {
        guard let root = run(["rev-parse", "--show-toplevel"], in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return "Not a git repository." }
        if !hasStaged(in: root) {
            let limit = relativePath(of: directory, in: root)
            if let failure = report(["add", "-A", "--", limit.isEmpty ? "." : limit], in: root, environment: environment) { return failure }
        }
        if let failure = report(["commit", "-m", message], in: root, environment: environment) { return failure }
        guard push else { return nil }
        var failure = report(["push"], in: root, environment: environment)
        // A new branch: push it and track it, as `git push -u` would.
        if failure?.contains("no upstream branch") == true {
            failure = report(["push", "-u", "origin", "HEAD"], in: root, environment: environment)
        }
        return failure.map { "Committed, but the push didn't go through:\n\($0)" }
    }

    /// Runs git for something that changes the repository; nil when it worked, else what git
    /// said. It never waits for a password: with nothing to answer, it fails instead.
    private static func report(_ arguments: [String], in directory: String, environment: [String: String]) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(filePath: directory)
        var environment = environment.isEmpty ? ProcessInfo.processInfo.environment : environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return error.localizedDescription }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "git \(arguments.first ?? "") failed." : text
    }

    /// An untracked file, as all-new lines.
    private static func newFile(_ path: String, root: String) -> ChangedFile {
        let url = URL(filePath: root).appending(path: path)
        var file = ChangedFile(path: path, status: .added, url: url)
        file.root = root
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= 2_000_000, let data = try? Data(contentsOf: url), !data.contains(0),
              let text = String(data: data, encoding: .utf8) else {
            file.isBinary = true
            return file
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        file.lines = lines.enumerated().map { DiffLine(kind: .added, newNumber: $0 + 1, text: $1) }
        return file
    }

    private static func relativePath(of directory: String, in root: String) -> String {
        let resolved = URL(filePath: directory).resolvingSymlinksInPath().path
        let base = URL(filePath: root).resolvingSymlinksInPath().path
        guard resolved.hasPrefix(base) else { return "" }
        return String(resolved.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Runs git and returns its output, or nil when it fails.
    static func run(_ arguments: [String], in directory: String) -> String? {
        data(arguments, in: directory).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Runs git and returns its raw output (for file contents), or nil when it fails.
    static func data(_ arguments: [String], in directory: String) -> Data? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(filePath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"  // Reading only: don't hold the index lock.
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}

// MARK: - Parsing

nonisolated enum DiffParser {
    /// Every file in `git diff` output.
    static func files(from patch: String, root: String) -> [ChangedFile] {
        var files: [ChangedFile] = []
        var current: ChangedFile?
        var oldLine = 0, newLine = 0, sawHunk = false
        // Set when git left unchanged lines out before the next line (between hunks).
        var pendingGap = false

        func finish() { if let current { files.append(current) } }

        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                finish()
                let path = pathFromHeader(line)
                current = ChangedFile(path: path, status: .modified, url: URL(filePath: root).appending(path: path))
                sawHunk = false
                continue
            }
            guard var file = current else { continue }
            defer { current = file }
            if line.hasPrefix("@@") {
                let numbers = hunkStarts(line)
                oldLine = numbers.old
                newLine = numbers.new
                pendingGap = sawHunk || (numbers.old > 1 && numbers.new > 1)
                sawHunk = true
                continue
            }
            if !sawHunk {
                if line.hasPrefix("new file mode") { file.status = .added }
                else if line.hasPrefix("deleted file mode") { file.status = .deleted }
                else if line.hasPrefix("rename from ") { file.oldPath = String(line.dropFirst("rename from ".count)); file.status = .renamed }
                else if line.hasPrefix("rename to ") {
                    file.path = String(line.dropFirst("rename to ".count))
                    file.url = URL(filePath: root).appending(path: file.path)
                }
                else if line.hasPrefix("Binary files ") { file.isBinary = true }
                continue
            }
            guard let first = line.first else { continue }
            var parsed: DiffLine
            switch first {
            case "+": parsed = DiffLine(kind: .added, newNumber: newLine, text: String(line.dropFirst())); newLine += 1
            case "-": parsed = DiffLine(kind: .removed, oldNumber: oldLine, text: String(line.dropFirst())); oldLine += 1
            case " ": parsed = DiffLine(kind: .context, oldNumber: oldLine, newNumber: newLine, text: String(line.dropFirst())); oldLine += 1; newLine += 1
            default: continue  // "\ No newline at end of file"
            }
            if pendingGap { parsed.gapBefore = true; pendingGap = false }
            file.lines.append(parsed)
        }
        finish()
        return files
    }

    /// The engine's diff of one file (patch text, a few lines of context).
    static func file(from diff: FileDiff, directory: String) -> ChangedFile {
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        let path = diff.file.hasPrefix(base) ? String(diff.file.dropFirst(base.count)) : diff.file
        let url = URL(filePath: diff.file.hasPrefix("/") ? diff.file : base + diff.file)
        let parsed = files(from: "diff --git a/\(path) b/\(path)\n" + diff.patch, root: directory).first
        var file = parsed ?? ChangedFile(path: path, status: .modified, url: url)
        file.path = path
        file.url = url
        file.status = switch diff.status {
        case .added: .added
        case .deleted: .deleted
        default: file.status
        }
        return file
    }

    /// "diff --git a/x b/x" → "x". Paths with spaces are fine; renames use the b side.
    private static func pathFromHeader(_ line: String) -> String {
        let rest = line.dropFirst("diff --git ".count)
        if let range = rest.range(of: " b/", options: .backwards) {
            return String(rest[range.upperBound...])
        }
        return String(rest)
    }

    /// "@@ -12,7 +12,9 @@" → (12, 12).
    private static func hunkStarts(_ line: String) -> (old: Int, new: Int) {
        let parts = line.split(separator: " ")
        func start(_ part: Substring?) -> Int {
            guard let part else { return 1 }
            let number = part.dropFirst().split(separator: ",").first.flatMap { Int($0) } ?? 1
            return max(number, 1)
        }
        return (start(parts.dropFirst().first), start(parts.dropFirst(2).first))
    }
}
