import Foundation
import OpenCodeKit
import Testing
@testable import KuvoCode

/// GitHub Copilot's Claude models work although the engine sends a setting they reject: every
/// engine is told not to, for each of Copilot's Claude models as the engine last listed them (not
/// one only these settings put on the list, nor a guess when no list has come yet).
@Suite(.serialized) struct ProviderCompatibilityTests {
    init() {
        TestEnvironment.prepare()
        UserDefaults.standard.removeObject(forKey: "copilotClaudeModels")
    }

    private func model(_ provider: String, _ id: String, family: String?) throws -> Model {
        var json: [String: Any] = ["id": id, "modelID": id, "providerID": provider, "name": id,
                                   "capabilities": ["tools": true, "input": ["text"], "output": ["text"]], "variants": [],
                                   "time": ["released": 1], "cost": [["input": 1, "output": 1]], "status": "active", "enabled": true,
                                   "limit": ["context": 1000, "output": 100]]
        if let family { json["family"] = family }
        return try JSONDecoder().decode(Model.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private var named: Set<String> {
        let providers = ProviderCompatibility.config["providers"] as? [String: Any]
        let copilot = providers?["github-copilot"] as? [String: Any]
        return Set((copilot?["models"] as? [String: Any])?.keys.map { $0 } ?? [])
    }

    @Test func beforeAnyListTheKnownOnes() {
        #expect(named.contains("claude-sonnet-5.5"))
    }

    @Test func copilotsClaudeModelsAsListed() throws {
        ProviderCompatibility.learn(from: [
            try model("github-copilot", "claude-opus-6", family: "claude"),
            try model("github-copilot", "gpt-6", family: "gpt"),
            // Only on the list because these settings named it: not Copilot's.
            try model("github-copilot", "claude-haiku-5.5", family: nil),
            try model("anthropic", "claude-opus-6", family: "claude"),
        ])
        #expect(named == ["claude-opus-6"])
        let settings = ((ProviderCompatibility.config["providers"] as? [String: Any])?["github-copilot"] as? [String: Any])?["models"] as? [String: [String: [String: Bool]]]
        #expect(settings?["claude-opus-6"]?["compatibility"]?["supportsThinkingBlockBinding"] == false)
    }

    /// An engine without a Copilot account says nothing about Copilot's models.
    @Test func noCopilotAccountChangesNothing() throws {
        ProviderCompatibility.learn(from: [try model("github-copilot", "claude-opus-6", family: "claude")])
        ProviderCompatibility.learn(from: [try model("anthropic", "claude-opus-6", family: "claude")])
        #expect(named == ["claude-opus-6"])
    }
}
