import Foundation
import Testing
@testable import KuvoCode

/// Settings' tabs, as VS Code's (K1): a page you open comes in the preview tab, which the next
/// page takes the place of; doing something in a page keeps its tab, and the next page gets one
/// of its own; a page that's open already comes forward; ⌘-click opens one more, kept; a page with
/// something open in it (an editor, with what you typed) isn't replaced. The tabs, the page in
/// view and which is the preview are there the next time Settings opens.
@MainActor
@Suite(.serialized) struct SettingsTabsTests {
    init() {
        TestEnvironment.prepare()
        for key in ["settings.tabs", "settings.previewTab", SettingsPage.storageKey] { UserDefaults.standard.removeObject(forKey: key) }
        // Tabs are for the tab bar, which you turn on.
        UserDefaults.standard.set(true, forKey: TabBar.showsKey)
    }

    /// Without the tab bar (as it starts), Settings shows one page at a time: each page you open
    /// takes the place of the one in view, ⌘-click included.
    @Test func withoutTheTabBarOnePageAtATime() {
        UserDefaults.standard.removeObject(forKey: TabBar.showsKey)
        defer { UserDefaults.standard.set(true, forKey: TabBar.showsKey) }
        let tabs = SettingsTabs()
        tabs.show(.accounts)
        tabs.keepSelected()
        tabs.show(.machines)
        #expect(pages(tabs) == [.machines], "even after you worked in a page")
        tabs.show(.git, inNewTab: true)
        #expect(pages(tabs) == [.git])
        #expect(tabs.page == .git)
    }

    private func pages(_ tabs: SettingsTabs) -> [SettingsPage?] { tabs.tabs.map(\.page) }

    @Test func pagesTakeThePreviewTabUntilYouWorkInOne() {
        let tabs = SettingsTabs()
        #expect(pages(tabs) == [.general], "the first time: General, only looked at")

        tabs.show(.accounts)
        #expect(pages(tabs) == [.accounts], "it takes the preview tab's place")

        tabs.keepSelected()  // You connected an account there.
        tabs.show(.machines)
        #expect(pages(tabs) == [.accounts, .machines], "the one you worked in stays; the next gets a tab beside it")
        tabs.show(.git)
        #expect(pages(tabs) == [.accounts, .git])

        tabs.show(.accounts)
        #expect(pages(tabs) == [.accounts, .git], "an open page comes forward, no second tab")
        #expect(tabs.page == .accounts)

        tabs.show(.accounts, inNewTab: true)
        #expect(pages(tabs) == [.accounts, .accounts, .git], "⌘-click opens one more, beside the one in view")
    }

    /// An editor open in the preview tab, with what you typed: the next page doesn't take its place.
    @Test func aPageWithAnEditorOpenIsntReplaced() {
        let tabs = SettingsTabs()
        tabs.show(.agents)
        tabs.show(.commands, isBusy: { _ in true })
        #expect(pages(tabs) == [.agents, .commands])
    }

    @Test func theyreThereTheNextTime() {
        let tabs = SettingsTabs()
        tabs.show(.accounts)
        tabs.keepSelected()
        tabs.show(.panel)
        tabs.show(.storage)
        let again = SettingsTabs()
        #expect(pages(again) == [.accounts, .storage])
        #expect(again.page == .storage, "on the page you were on")
        again.show(.browser)
        #expect(pages(again) == [.accounts, .browser], "and Storage was still only a preview")
    }

    @Test func closingLeavesOneAndShowsItsNeighbor() throws {
        let tabs = SettingsTabs()
        tabs.show(.accounts)
        tabs.keepSelected()
        tabs.show(.machines)
        tabs.keepSelected()
        tabs.show(.git)
        tabs.keepSelected()
        tabs.select(try #require(tabs.tabs.first { $0.page == .machines }).id)
        let machines = Machines()
        tabs.close(tabs.selectedID, machines: machines)
        #expect(pages(tabs) == [.accounts, .git])
        #expect(tabs.page == .git, "the neighbor, as browsers do")
        tabs.closeOthers(than: nil, machines: machines)
        #expect(tabs.tabs.count == 1, "one is always left")
    }
}
