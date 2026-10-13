import Testing
@testable import OpenCodeKit

@Test func pinsAnEngineVersion() {
    #expect(!OpenCodeEngine.version.isEmpty)
}
