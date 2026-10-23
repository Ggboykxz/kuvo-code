import Foundation
import Testing
@testable import KuvoCode

/// Bringing over Claude Code's subagents and slash commands (Settings › Agents and › Commands,
/// "From Claude Code"), as Claude Code writes them in ~/.claude: each agent with its name,
/// description and instructions, never in place of one of the engine's own; each command by its
/// file's name, in Claude Code's folders too, with its prompt as written. A made-up ~/.claude in
/// the test's own folder.
@Suite struct ClaudeCodeImportTests {
    let claude = AppInfo.testRoot.appending(path: "dot-claude-\(UUID().uuidString.prefix(6))")

    private func write(_ path: String, _ text: String) throws {
        let url = claude.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func itsAgentsComeOverWithTheirInstructions() throws {
        defer { try? FileManager.default.removeItem(at: claude) }
        try write("agents/code-reviewer.md", """
            ---
            name: code-reviewer
            description: Use this agent after writing code.\\nIt reviews for bugs: logic, edge cases.
            tools: Read, Grep, Glob
            model: sonnet
            color: blue
            ---

            You are a senior reviewer. Read the diff, then list what's wrong, worst first.
            """)
        // Named as one of the engine's own: it comes over beside it, not over it.
        try write("agents/plan.md", "---\nname: Plan\ndescription: Plans a feature\n---\nWrite the plan first.\n")
        // No header at all: by its file's name.
        try write("agents/Release Notes.md", "Write release notes from the commits since the last tag.\n")
        try write("agents/notes.txt", "not an agent")

        let agents = ClaudeAgents.load(from: claude.appending(path: "agents"))
        #expect(agents.map(\.id).sorted() == ["code-reviewer", "plan-claude", "release-notes"])
        let reviewer = try #require(agents.first { $0.id == "code-reviewer" })
        #expect(reviewer.description == "Use this agent after writing code.\nIt reviews for bugs: logic, edge cases.")
        #expect(reviewer.instructions == "You are a senior reviewer. Read the diff, then list what's wrong, worst first.")
        #expect(agents.first { $0.id == "release-notes" }?.instructions.hasPrefix("Write release notes") == true)
    }

    @Test func itsCommandsComeOverInItsFoldersToo() throws {
        defer { try? FileManager.default.removeItem(at: claude) }
        try write("commands/review.md", """
            ---
            description: Review a pull request
            argument-hint: [pr-number]
            ---
            Review pull request #$ARGUMENTS: what it changes, and what could break.
            """)
        try write("commands/frontend/component.md", "Make a React component named $ARGUMENTS, with a test.\n")
        try write("commands/empty.md", "---\ndescription: nothing yet\n---\n")

        let commands = ClaudeCommands.load(from: claude.appending(path: "commands"))
        #expect(commands.map(\.id) == ["frontend-component", "review"], "one with nothing to say is left out")
        let review = try #require(commands.first { $0.id == "review" })
        #expect(review.description == "Review a pull request")
        #expect(review.template == "Review pull request #$ARGUMENTS: what it changes, and what could break.")
    }
}
