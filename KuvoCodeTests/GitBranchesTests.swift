import Foundation
import Testing
@testable import KuvoCode

/// Worktrees' branches and their way back, on real repositories: a branch named after its
/// session's title (in any language), a name already taken, one already pushed kept as it is;
/// merging back, a conflict leaving the folder as it was; and the pull request page for a remote.
@MainActor
@Suite struct GitBranchesTests {
    @Test(arguments: [
        ("Trim note titles", "trim-note-titles"),
        ("Giriş düzeltmesi", "giris-duzeltmesi"),
        ("Café: crème brûlée!", "cafe-creme-brulee"),
        ("Исправить вход", "ispravit-vhod"),
        ("Fix #42 — login (again)", "fix-42-login-again"),
        ("A very long title that keeps going well past the limit of forty", "a-very-long-title-that-keeps-going-well"),
    ])
    func aBranchNamedAfterItsTitle(title: String, slug: String) {
        #expect(Git.slug(title) == slug)
    }

    @Test func aNameTakenGetsANumber() throws {
        let repo = try TestRepository()
        try repo.write("a.txt", "a\n")
        try repo.commitAll()
        try repo.git("branch", "kuvo/fix")
        #expect(try Git.newBranch(named: "kuvo/fix", in: repo.path) == "kuvo/fix-2")
        #expect(Git.currentBranch(in: repo.path) == "kuvo/fix-2")
        #expect(Git.renameBranch("kuvo/fix-2", to: "kuvo/fix", in: repo.path) == "kuvo/fix-3")
    }

    /// One already pushed keeps its name: its pull request would lose track of it.
    @Test func aPushedBranchKeepsItsName() throws {
        let repo = try TestRepository(), remote = try TestRepository()
        try repo.write("a.txt", "a\n")
        try repo.commitAll()
        try repo.git("remote", "add", "origin", remote.path)
        try repo.git("checkout", "-q", "-b", "kuvo/tmp-1")
        try repo.git("push", "-q", "-u", "origin", "kuvo/tmp-1")
        #expect(Git.renameBranch("kuvo/tmp-1", to: "kuvo/fix-login", in: repo.path) == nil)
        #expect(Git.currentBranch(in: repo.path) == "kuvo/tmp-1")
    }

    @Test func mergingBack() throws {
        let repo = try TestRepository()
        try repo.write("a.txt", "one\n")
        try repo.commitAll()
        try repo.git("checkout", "-q", "-b", "work")
        try repo.write("b.txt", "new\n")
        try repo.commitAll("Work")
        try repo.git("checkout", "-q", "main")
        #expect(Git.merge("work", into: repo.path, environment: [:]) == .merged)
        #expect(repo.read("b.txt") == "new\n")
    }

    /// A conflict: the files named, and the folder back as it was (not in the middle of a merge).
    @Test func aConflictLeavesTheFolderAsItWas() throws {
        let repo = try TestRepository()
        try repo.write("a.txt", "one\n")
        try repo.commitAll()
        try repo.git("checkout", "-q", "-b", "work")
        try repo.write("a.txt", "theirs\n")
        try repo.commitAll("Work")
        try repo.git("checkout", "-q", "main")
        try repo.write("a.txt", "ours\n")
        try repo.commitAll("Main")
        #expect(Git.merge("work", into: repo.path, environment: [:]) == .conflict(["a.txt"]))
        #expect(repo.read("a.txt") == "ours\n")
        #expect(try repo.status().isEmpty)
        #expect(!repo.exists(".git/MERGE_HEAD"))
    }

    /// Where a remote's pull requests are made, whichever way the remote is written; without the
    /// name, password or port it may carry.
    @Test(arguments: [
        ("git@github.com:acme/app.git", "https://github.com/acme/app"),
        ("https://github.com/acme/app.git", "https://github.com/acme/app"),
        ("https://me:ghp_secret@github.com/acme/app", "https://github.com/acme/app"),
        ("ssh://git@gitlab.com:22/group/sub/app.git", "https://gitlab.com/group/sub/app"),
        ("/local/path/repo", nil),
    ])
    func aRemotesWebPage(remote: String, page: String?) {
        #expect(Git.webPage(of: remote)?.absoluteString == page)
    }
}
