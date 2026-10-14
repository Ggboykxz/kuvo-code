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
        (roots.count > 1 ? roots.enumerated().map { File(path: $1.lastPathComponent + "/", url: $1, folder: $0, mention: $1.lastPathComponent + "/") } : []) + list(roots, dated: true)
    }

    /// The files in `roots`, the primary folder's first; `dated`, with when each last changed.
    /// Slow for big trees: call it off the main thread.
    static func list(_ roots: [URL], dated: Bool = false) -> [File] {
        roots.enumerated().flatMap { index, root in
            let prefix = roots.count > 1 ? root.lastPathComponent + "/" : ""
            return listFiles(in: root.path).map { path in
                let url = root.appending(path: path)
                let modified = dated ? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate : nil
                return File(path: prefix + path, url: url, folder: index, mention: index == 0 ? path : prefix + path, modified: modified)
            }
        }
    }

    /// git's list (tracked and new, without ignored files) in a repository; otherwise a
    /// walk that skips the usual heavy folders.
    private static func listFiles(in root: String) -> [String] {
        if let listed = Git.run(["ls-files", "--cached", "--others", "--exclude-standard"], in: root) {
            return listed.split(separator: "\n").map(String.init)
        }
        let skip: Set<String> = [".git", "node_modules", "build", "DerivedData", ".build", "Pods", "dist", ".next"]
        var files: [String] = []
        let base = URL(filePath: root)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        for case let url as URL in walker {
            if skip.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false {
                files.append(String(url.path.dropFirst(base.path.count + 1)))
                if files.count >= 20_000 { break }
            }
        }
        return files
    }
}
