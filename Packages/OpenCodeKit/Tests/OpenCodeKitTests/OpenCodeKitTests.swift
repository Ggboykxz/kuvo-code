import Foundation
import Testing
@testable import OpenCodeKit

@Test func pinsAnEngineVersion() {
    #expect(!OpenCodeEngine.version.isEmpty)
}

/// The engine says "default" for a session with no effort chosen; it's not a level to send back.
@Test func readsTheDefaultEffortAsNone() throws {
    let reported = try JSONDecoder().decode(ModelRef.self, from: Data(#"{"id":"gpt-6-luna","providerID":"github-copilot","variant":"default"}"#.utf8))
    #expect(reported.variant == nil)
    let encoded = String(decoding: try JSONEncoder().encode(reported), as: UTF8.self)
    #expect(!encoded.contains("variant"))
    #expect(ModelRef(id: "m", providerID: "p", variant: "default").variant == nil)
    #expect(ModelRef(id: "m", providerID: "p", variant: "low").variant == "low")
}
