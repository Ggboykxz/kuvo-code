import Foundation

/// Branches and worktrees: what a session in a worktree needs to start, and to bring its work
/// back (a merge, or a pull request).
nonisolated extension Git {
    /// The branch `directory` has checked out, or nil (no repository, or no branch).
    static func currentBranch(in directory: String) -> String? {
        let name = run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    /// Where `directory` is in its repository ("" at the top).
    static func pathInRepository(of directory: String) -> String {
        guard let root = run(["rev-parse", "--show-toplevel"], in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return "" }
        return relativePath(of: directory, in: root)
    }

    /// Checks out a new branch at what `directory` has, named `name` or, when that's taken,
    /// `name-2` and so on. Returns the name it got.
    static func newBranch(named name: String, in directory: String) throws -> String {
        var failure = ""
        for suffix in 1...20 {
            let candidate = suffix == 1 ? name : "\(name)-\(suffix)"
            guard run(["rev-parse", "--verify", "--quiet", "refs/heads/" + candidate], in: directory) == nil else { continue }
            guard let complaint = report(["switch", "--quiet", "-c", candidate], in: directory, environment: [:]) else { return candidate }
            failure = complaint
        }
        throw GitFailure(message: failure.isEmpty ? "Couldn't make a branch for the worktree." : failure)
    }

    /// A branch name made from a title: "Trim note titles" is trim-note-titles.
    static func slug(_ title: String, limit: Int = 40) -> String {
        var name = ""
        for word in title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let ascii = word.filter(\.isASCII)
            guard !ascii.isEmpty else { continue }
            let next = name.isEmpty ? String(ascii) : name + "-" + ascii
            if next.count > limit { break }
            name = next
        }
        return name
    }

    /// Renames `branch` to `name` (or `name-2` and so on, when that's taken), unless it's been
    /// pushed: its pull request would lose track of it. Returns the new name.
    static func renameBranch(_ branch: String, to name: String, in directory: String) -> String? {
        guard run(["rev-parse", "--abbrev-ref", branch + "@{upstream}"], in: directory) == nil else { return nil }
        for suffix in 1...20 {
            let candidate = suffix == 1 ? name : "\(name)-\(suffix)"
            guard run(["rev-parse", "--verify", "--quiet", "refs/heads/" + candidate], in: directory) == nil else { continue }
            return report(["branch", "-m", branch, candidate], in: directory, environment: [:]) == nil ? candidate : nil
        }
        return nil
    }

    /// Changes that aren't committed, new files included.
    static func hasUncommittedChanges(in directory: String) -> Bool {
        !(run(["status", "--porcelain"], in: directory) ?? "").isEmpty
    }

    /// How many commits `directory`'s branch has that `base` doesn't.
    static func commitsAhead(of base: String, in directory: String) -> Int {
        Int(run(["rev-list", "--count", base + "..HEAD"], in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    enum MergeResult: Equatable, Sendable {
        case merged
        /// Nothing changed: the merge stopped on these files.
        case conflict([String])
        case failed(String)
    }

    /// Merges `branch` into what `directory` has checked out. A merge that conflicts is
    /// taken back, so the folder is as it was.
    static func merge(_ branch: String, into directory: String, environment: [String: String]) -> MergeResult {
        guard let failure = report(["merge", "--no-edit", branch], in: directory, environment: environment) else { return .merged }
        let conflicted = (run(["diff", "--name-only", "--diff-filter=U"], in: directory) ?? "").split(separator: "\n").map(String.init)
        guard !conflicted.isEmpty else { return .failed(failure) }
        _ = report(["merge", "--abort"], in: directory, environment: environment)
        return .conflict(conflicted)
    }

    /// Pushes what `directory` has checked out to `origin`, and returns the page that opens a
    /// pull request for it on GitHub, or a merge request on GitLab (nil for other hosts).
    static func pushForPullRequest(branch: String, base: String?, in directory: String, environment: [String: String]) throws -> URL? {
        if let failure = report(["push", "-u", "origin", "HEAD"], in: directory, environment: environment) {
            throw GitFailure(message: failure)
        }
        guard let remote = run(["remote", "get-url", "origin"], in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let page = webPage(of: remote) else { return nil }
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))
        let source = branch.addingPercentEncoding(withAllowedCharacters: allowed) ?? branch
        let target = base.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
        // Without a base, the host compares with the repository's main branch.
        if page.host()?.contains("gitlab") == true {
            return URL(string: page.absoluteString + "/-/merge_requests/new?merge_request%5Bsource_branch%5D=\(source)" + (target.map { "&merge_request%5Btarget_branch%5D=\($0)" } ?? ""))
        }
        if page.host()?.contains("github") == true {
            return URL(string: page.absoluteString + "/compare/" + (target.map { "\($0)...\(source)" } ?? source) + "?expand=1")
        }
        return nil
    }

    /// A remote's web page: `git@github.com:me/app.git` and `https://github.com/me/app.git`
    /// are both https://github.com/me/app.
    static func webPage(of remote: String) -> URL? {
        var address = remote
        if address.hasSuffix(".git") { address.removeLast(4) }
        if address.hasPrefix("ssh://") || address.hasPrefix("git://") {
            address = "https://" + address.drop { $0 != "/" }.dropFirst(2)
        } else if !address.contains("://"), let colon = address.firstIndex(of: ":") {
            // scp-like: git@host:owner/repo
            address = "https://" + address[..<colon] + "/" + address[address.index(after: colon)...]
        }
        guard var components = URLComponents(string: address), components.scheme == "https" || components.scheme == "http",
              components.host != nil else { return nil }
        components.scheme = "https"
        components.user = nil
        components.password = nil
        components.port = nil
        return components.url
    }
}

/// What git said when it refused.
struct GitFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
