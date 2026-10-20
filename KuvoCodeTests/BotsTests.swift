import Foundation
import Testing
@testable import KuvoCode

/// Bots and group chats: a bot's job as its memory keeps it, and who does what when a lead splits
/// the work in a group chat, and when a bot passes.
@Suite struct BotsTests {
    // MARK: A bot's job, in its memory

    /// The whole job section, its own sub-headings and code included, up to the next section.
    @Test func theJobIsTheWholeSection() throws {
        let memory = """
        # Ci's memory

        ## Job
        Keeps CI green.

        ### Rules
        Never push to main.
        ```sh
        # run the tests first
        swift test
        ```
        #1 priority: flaky tests

        ## Notes
        The runner is slow on Mondays.
        """
        let job = try #require(Bots.job(inMemory: memory))
        #expect(job.line == "Keeps CI green")
        #expect(job.section.contains("Never push to main."))
        #expect(job.section.contains("swift test"))
        #expect(job.section.contains("#1 priority: flaky tests"))
        #expect(!job.section.contains("slow on Mondays"))
    }

    @Test(arguments: ["## Job", "# Job", "## My job", "## Job — what I do", "## Job: keeps CI green"])
    func headingsThatNameTheJob(heading: String) {
        #expect(Bots.job(inMemory: "# Memory\n\n\(heading)\nKeeps CI green\n") != nil)
    }

    @Test(arguments: ["## Job log", "## Job history", "## Jobs done"])
    func headingsThatDont(heading: String) {
        #expect(Bots.job(inMemory: "# Memory\n\n\(heading)\nRan the build\n") == nil)
    }

    @Test func aJobWrittenInEditBotReadsBack() throws {
        let memory = Bots.addingJob("Keeps CI green.", details: "Watch the main branch.\nFix what breaks.", to: Bots.blankMemory("Ci"))
        let job = try #require(Bots.job(inMemory: memory))
        #expect(job.line == "Keeps CI green")
        #expect(job.section.contains("Fix what breaks."))
        #expect(Bots.job(inMemory: Bots.blankMemory("Ci")) == nil)
    }

    /// Details from Edit Bot go into the job section the bot wrote, even one with nothing under its
    /// heading yet, and before the next section.
    @Test(arguments: ["## Job\n\n## Notes\nOld note\n", "## Job\nKeeps CI green\n\n## Notes\nOld note\n", "## Job\n"])
    func detailsGoIntoTheJobSection(sections: String) throws {
        let memory = Bots.addingDetails("Watch the main branch.", toJobIn: "# Ci's memory\n\n" + sections)
        let job = try #require(Bots.job(inMemory: memory))
        #expect(job.section.contains("Watch the main branch."))
        if sections.contains("Old note") { #expect(memory.contains("## Notes\nOld note")) }
    }

    // MARK: Group chats

    @Test(arguments: ["PASS", "Pass.", "pass", "[pass] nothing to add", "Pass, nothing new from me", "PASS — I agree with Ada"])
    func passing(text: String) {
        #expect(BotGroups.isPass(text))
    }

    /// A message that only starts with the word is something said.
    @Test(arguments: ["Pass rate is 98% on main.", "Pass: CI is green now.", "Passing the tests needs a fix first", "Password reset is done"])
    func notPassing(text: String) {
        #expect(!BotGroups.isPass(text))
    }

    @Test func splittingTheWork() {
        let wrapUp = """
        Here's the plan:
        1. **@Samantha**: write the release notes
        - @Sam (after @Samantha): post them
        - Sam: tag the release
        * @Ghost: not in this chat
        WAIT
        GO
        """
        let (parts, go) = GroupWork.parts(in: wrapUp, names: ["Sam", "Samantha"])
        #expect(go)
        #expect(parts.map(\.name) == ["Samantha", "Sam"])
        #expect(parts[0].task == "write the release notes")
        #expect(parts[1].task == "- post them\n- tag the release")
        #expect(parts[1].after == ["Samantha"])
    }

    @Test func theLastGoOrWaitWins() {
        #expect(!GroupWork.parts(in: "@Sam: do it\nGO\nWAIT", names: ["Sam"]).go)
    }
}
