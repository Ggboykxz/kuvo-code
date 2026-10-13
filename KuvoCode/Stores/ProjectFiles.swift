import Foundation

/// Every file in a project's folders, for filtering the file tree and for @ mentions.
nonisolated enum ProjectFiles {
    struct File: Identifiable, Hashable, Sendable {
        /// Relative to its folder; with several folders, starting with the folder's name.
        let path: String
        let url: URL

        var id: URL { url }
    }

    /// The files in `roots`, the primary folder's first. Slow for big trees: call it off the
    /// main thread.
    static func list(_ roots: [URL]) -> [File] {
        roots.flatMap { root in
            let prefix = roots.count > 1 ? root.lastPathComponent + "/" : ""
            return listFiles(in: root.path).map { File(path: prefix + $0, url: root.appending(path: $0)) }
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
