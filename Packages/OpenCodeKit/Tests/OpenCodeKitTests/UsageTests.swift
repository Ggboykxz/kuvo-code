import Foundation
import Testing
@testable import OpenCodeKit

struct UsageTests {
    @Test func namesWindowsByLength() {
        #expect(UsageClient.windowName(seconds: 18_000) == "5-hour")
        #expect(UsageClient.windowName(seconds: 604_800) == "Weekly")
        #expect(UsageClient.windowName(seconds: 86_400) == "Daily")
        #expect(UsageClient.windowName(seconds: nil) == "Usage")
    }

    @Test func readsTheAccountFromAChatGPTToken() {
        // {"https://api.openai.com/auth":{"chatgpt_account_id":"acct_123"}}, unsigned.
        let payload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_123"}}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        #expect(UsageClient.chatGPTAccount(in: "e30.\(payload).sig") == "acct_123")
        #expect(UsageClient.chatGPTAccount(in: "not-a-jwt") == nil)
    }

    @Test func clampsMeters() {
        #expect(UsageMeter(id: "a", label: "A", used: 1.4).used == 1)
        #expect(UsageMeter(id: "b", label: "B", used: -0.2).remaining == 1)
    }
}
