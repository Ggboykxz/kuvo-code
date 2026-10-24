import Foundation
import Testing
@testable import KuvoCode

/// Settings › Storage (K5): what Kuvo Code keeps on this Mac, by kind, adds up to what's in its
/// data folder: the coding agents it installed, your bots' and chats' folders and whatever else is
/// there are counted, not left out of the total.
@MainActor
@Suite(.serialized) struct StorageReportTests {
    let support = AppInfo.supportDirectory

    private func write(_ path: String, bytes: Int) throws -> URL {
        let url = support.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    @Test func theKindsAddUpToTheDataFolder() throws {
        TestEnvironment.prepare()
        let made = [
            try write("agents/runtime/claude-code/node_modules/sdk.js", bytes: 400_000),
            try write("bots/bot_test/notes.md", bytes: 120_000),
            try write("Chats/plan.txt", bytes: 60_000),
            try write("Attachments/photo.png", bytes: 30_000),
        ]
        defer { for url in made { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }

        let report = StorageReport.measure(worktrees: [])
        #expect(report.size(of: .agents) == StorageReport.size(of: support.appending(path: "agents")), "the coding agents are a kind of their own")
        #expect(report.size(of: .agents) >= 400_000)
        #expect(report.size(of: .attachments) >= 30_000)
        #expect(report.size(of: .other) >= StorageReport.size(of: support.appending(path: "bots")) + StorageReport.size(of: support.appending(path: "Chats")),
                "bots' and chats' folders are counted")
        #expect(report.total >= StorageReport.size(of: support), "everything in the data folder is counted: \(report.total) of \(StorageReport.size(of: support))")
    }
}
