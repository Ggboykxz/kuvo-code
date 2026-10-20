import Foundation
import Testing
@testable import KuvoCode

/// The side panel's tabs: each conversation has its own, the panel always has one, closing the
/// window starts every panel over with a single start tab, and a conversation's tab you chose is
/// the one you find when you come back to it. (Starts with Changes, the default for a test's own
/// settings.)
@MainActor
@Suite struct PanelTabsTests {
    let panel = Utilities()

    init() { TestEnvironment.prepare() }

    private var startTabs: [Utilities.Tab] { panel.visibleTabs.filter { $0.kind == .changes } }

    /// Closing the window while a machine's conversation is in view: one start tab, not two.
    @Test func closingTheWindowOnAMachinesConversationLeavesOneStartTab() {
        panel.sessionInView = "ses_remote"
        panel.place = "my-server"
        panel.closeAll()
        #expect(panel.tabs.filter { $0.kind == .changes && $0.owner == panel.panelKey }.count == 1)
        panel.place = nil
        #expect(startTabs.count == 1)
    }

    @Test func closingTheWindowLeavesOneStartTab() {
        panel.sessionInView = "ses_a"
        panel.closeAll()
        #expect(startTabs.count == 1)
    }

    /// Each conversation its own panel, on the tab you left it on.
    @Test func eachConversationKeepsItsTab() {
        panel.sessionInView = "ses_a"
        let changes = panel.selection
        panel.showChanges()
        panel.sessionInView = "ses_b"
        #expect(startTabs.count == 1)
        #expect(panel.selection != changes)
        panel.sessionInView = "ses_a"
        #expect(panel.selection == changes)
    }

    /// The panel always has a tab: closing the last one leaves one in its place.
    @Test func closingTheLastTabLeavesOne() throws {
        panel.sessionInView = "ses_a"
        let only = try #require(panel.visibleTabs.first)
        panel.close(only.id)
        #expect(panel.visibleTabs.count == 1)
    }
}
