import Foundation

/// Every file in a project's folders, for filtering the file tree and for @ mentions.
nonisolated enum ProjectFiles {
    struct File: Identifiable, Hashable, Sendable {
        /// Relative to its folder; with several folders, starting with the folder's name.
        let path: String
        let url: URL
        /// Which of the project's folders it's in: 0 is the primary one.
        var folder = 0
        /// How "@" names it: inside the primary folder, where the agent works, its path there;
        /// elsewhere, after its folder's name, which the agent knows.
        var mention: String
        /// When it last changed, when asked for: the newest come first before anything's typed.
        var modified: Date?

        var id: URL { url }
        var name: String { url.lastPathComponent }
        /// One of the project's folders, listed by name ("api/").
        var isFolder: Bool { path.hasSuffix("/") }
    }

    /// What "@" can point at: with several folders, each folder first, then every file, with
    /// when it last changed.
    static func mentionable(_ roots: [URL]) -> [File] {
        (roots.count > 1 ? roots.enumerated().map { File(path: $1.lastPathComponent + "/", url: $1, folder: $0, mention: $1.lastPathComponent + "/") } : []) + newestFirst(list(roots, dated: true))
    }

    /// Files sorted by when they last changed, newest first: what a list shows before
    /// anything's typed. Sorted once here, off the main thread.
    static func newestFirst(_ files: [File]) -> [File] {
        files.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    /// The files in `roots`, the primary folder's first; `dated`, with when each last changed.
    /// Slow for big trees: call it off the main thread.
    static func list(_ roots: [URL], dated: Bool = false) -> [File] {
        roots.enumerated().flatMap { index, root in
            let prefix = roots.count > 1 ? root.lastPathComponent + "/" : ""
            return listFiles(in: root).map { path in
                let url = root.appending(path: path)
                // (A machine's files go without: a date each would be a round trip each.)
                let modified = dated && url.isFileURL ? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate : nil
                return File(path: prefix + path, url: url, folder: index, mention: index == 0 ? path : prefix + path, modified: modified)
            }
        }
    }

    /// git's list (tracked and new, without ignored files) in a repository; otherwise a
    /// walk that skips the usual heavy folders.
    private static func listFiles(in root: URL) -> [String] {
        // Names as they are (git quotes ones with accents, CJK or emoji otherwise), once each (a
        // file in conflict is listed for each side), as many as a walk gives.
        if let listed = Git.run(["-c", "core.quotepath=off", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: RemoteFolder.folder(of: root)) {
            var seen = Set<String>()
            return listed.split(separator: "\0").map(String.init).filter { seen.insert($0).inserted }.prefix(20_000).map { $0 }
        }
        let skip: Set<String> = [".git", "node_modules", "build", "DerivedData", ".build", "Pods", "dist", ".next"]
        if !root.isFileURL { return RemoteShell.files(in: root, skipping: skip, limit: 20_000) ?? [] }
        var files: [String] = []
        // Paths relative to the folder as the walk gives them, also where the folder, or one it's
        // in, is a link (/tmp, a cloud drive's).
        guard let walker = FileManager.default.enumerator(atPath: root.resolvingSymlinksInPath().path) else { return [] }
        while let path = walker.nextObject() as? String {
            if skip.contains((path as NSString).lastPathComponent) { walker.skipDescendants(); continue }
            if walker.fileAttributes?[.type] as? FileAttributeType != .typeDirectory {
                files.append(path)
                if files.count >= 20_000 { break }
            }
        }
        return files
    }
}
