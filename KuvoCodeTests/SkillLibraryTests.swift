import Foundation
import Testing
@testable import KuvoCode

/// Settings › Skills › Get Skills: a repository's skills, each listed once, and installing one
/// copies just its files, with a note of where it came from. GitHub is stubbed (StubWeb).
@Suite(.serialized) struct SkillLibraryTests {
    let repository = SkillLibrary.Repository(owner: "acme", name: "skills", title: "Acme", summary: "")
    let folder: URL

    init() throws {
        TestEnvironment.prepare()
        folder = AppInfo.testRoot.appending(path: "Skills/\(UUID().uuidString)")
        StubWeb.start(hosts: ["api.github.com", "raw.githubusercontent.com"])
    }

    private func tree(_ files: [String], truncated: Bool = false) throws {
        let entries = files.map { ["path": $0, "type": "blob"] }
        try StubWeb.answer("https://api.github.com/repos/acme/skills/git/trees/main?recursive=1", json: ["tree": entries, "truncated": truncated])
    }

    @Test func eachSkillIsListedOnce() async throws {
        defer { StubWeb.stop() }
        try tree([
            "README.md",
            "skills/pdf/SKILL.md", "skills/pdf/scripts/fill.py",
            "skills/docx/SKILL.md",
            // Copies kept for other tools, in hidden folders.
            ".claude/skills/pdf/SKILL.md", ".claude/skills/pdf/scripts/fill.py",
            ".openclaw/skills/docx/SKILL.md",
            // Only in a hidden folder: still listed.
            ".claude/skills/only-here/SKILL.md",
        ])
        let listing = try await SkillLibrary.skills(in: repository)
        #expect(listing.skills.map(\.name).sorted() == ["docx", "only-here", "pdf"])
        let pdf = try #require(listing.skills.first { $0.name == "pdf" })
        #expect(pdf.path == "skills/pdf")
        #expect(pdf.files.sorted() == ["skills/pdf/SKILL.md", "skills/pdf/scripts/fill.py"])
        #expect(!listing.isPartial)
    }

    /// A skill inside another's folder keeps its own files.
    @Test func nestedSkillsKeepTheirFiles() async throws {
        defer { StubWeb.stop() }
        try tree(["a/SKILL.md", "a/notes.md", "a/b/SKILL.md", "a/b/c.txt"])
        let skills = try await SkillLibrary.skills(in: repository).skills
        #expect(skills.first { $0.path == "a" }?.files.sorted() == ["a/SKILL.md", "a/notes.md"])
        #expect(skills.first { $0.path == "a/b" }?.files.sorted() == ["a/b/SKILL.md", "a/b/c.txt"])
    }

    /// A repository that is one skill, named after it, without its hidden folders.
    @Test func aRepositoryThatIsOneSkill() async throws {
        defer { StubWeb.stop() }
        try tree(["SKILL.md", "reference.md", ".github/workflows/ci.yml"])
        let skills = try await SkillLibrary.skills(in: repository).skills
        #expect(skills.map(\.name) == ["skills"])
        #expect(skills.first?.files.sorted() == ["SKILL.md", "reference.md"])
    }

    @Test func githubLimitingSaysSo() async throws {
        defer { StubWeb.stop() }
        try StubWeb.answer("https://api.github.com/repos/acme/skills/git/trees/main?recursive=1", status: 403, json: [:])
        await #expect(throws: SkillLibrary.Failure.self) { try await SkillLibrary.skills(in: repository) }
        do { _ = try await SkillLibrary.skills(in: repository) } catch {
            #expect(error.localizedDescription.contains("limiting"))
        }
    }

    @Test func installingCopiesItsFilesAndWhereFrom() async throws {
        defer { StubWeb.stop(); try? FileManager.default.removeItem(at: folder) }
        try tree(["skills/pdf/SKILL.md", "skills/pdf/scripts/fill.py"])
        StubWeb.answer("https://raw.githubusercontent.com/acme/skills/main/skills/pdf/SKILL.md", text: "---\nname: pdf\n---\nFill PDFs.\n")
        StubWeb.answer("https://raw.githubusercontent.com/acme/skills/main/skills/pdf/scripts/fill.py", text: "print('hi')\n")
        let pdf = try #require(try await SkillLibrary.skills(in: repository).skills.first)
        try await SkillLibrary.install(pdf, into: folder)
        #expect(FileManager.default.contents(atPath: folder.appending(path: "pdf/scripts/fill.py").path) == Data("print('hi')\n".utf8))
        #expect(SkillLibrary.installed(in: folder)["pdf"] == SkillLibrary.Source(repository: "acme/skills", path: "skills/pdf"))
        // Again: one by that name is there already.
        await #expect(throws: SkillLibrary.Failure.self) { try await SkillLibrary.install(pdf, into: folder) }
    }

    /// A file that can't be fetched leaves nothing half-installed.
    @Test func aFailedInstallLeavesNothing() async throws {
        defer { StubWeb.stop(); try? FileManager.default.removeItem(at: folder) }
        try tree(["skills/pdf/SKILL.md", "skills/pdf/scripts/fill.py"])
        StubWeb.answer("https://raw.githubusercontent.com/acme/skills/main/skills/pdf/SKILL.md", text: "x")
        let pdf = try #require(try await SkillLibrary.skills(in: repository).skills.first)
        await #expect(throws: SkillLibrary.Failure.self) { try await SkillLibrary.install(pdf, into: folder) }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "pdf").path))
        #expect(SkillLibrary.installed(in: folder).isEmpty)
    }
}
