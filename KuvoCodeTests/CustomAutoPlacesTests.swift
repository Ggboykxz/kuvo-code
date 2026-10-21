import Foundation
import OpenCodeKit
import Testing
@testable import KuvoCode

/// Custom Auto's lists are each place's own (Settings › Custom Auto, the place picked at its top):
/// this Mac's coding agents keep theirs and a machine's keep its own, made from the models each
/// has. Saving one place's lists changes nothing of another's. The agents' bridges are stubbed.
@MainActor
@Suite(.serialized) struct CustomAutoPlacesTests {
    /// A bridge's Custom Auto, as it keeps it: the lists it was last given, and how often.
    nonisolated final class Bridge: @unchecked Sendable {
        private let lock = NSLock()
        private var lists: [[String: Any]]
        private(set) var saves = 0
        let url: String

        init(port: Int, name: String) {
            url = "http://127.0.0.1:\(port)"
            lists = [["id": "auto", "name": name, "entries": []]]
            StubWeb.handle(url + "/api/kuvo/auto") { [weak self] request, body in
                guard let self else { return StubWeb.Answer(status: 503) }
                return self.lock.withLock {
                    if request.httpMethod == "PUT", let sent = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["lists"] as? [[String: Any]] {
                        self.lists = sent
                        self.saves += 1
                    }
                    return StubWeb.json(["data": ["entries": [], "lists": self.lists, "limits": []]])
                }
            }
        }

        var names: [String] { lock.withLock { lists.compactMap { $0["name"] as? String } } }
        var saved: Int { lock.withLock { saves } }
        var endpoint: ServerEndpoint { ServerEndpoint(url: URL(string: url)!, password: "test") }
    }

    @Test func eachPlaceKeepsItsOwnLists() async throws {
        TestEnvironment.prepare()
        StubWeb.start(hosts: ["127.0.0.1"])
        defer { StubWeb.stop() }
        let macBridge = Bridge(port: 47981, name: "Mac list")
        let boxBridge = Bridge(port: 47980, name: "Box list")
        let mac = OutsideAgents()
        let box = OutsideAgents(machine: "box")
        mac.connect(macBridge.endpoint, folderPrefix: "")
        box.connect(boxBridge.endpoint, folderPrefix: RemoteFolder.prefix(for: "box"))
        defer {
            mac.disconnect()
            box.disconnect()
        }
        await mac.loadAuto()
        await box.loadAuto()
        #expect(mac.auto.all.map(\.name) == ["Mac list"])
        #expect(box.auto.all.map(\.name) == ["Box list"])

        let sonnet = AutoEntry(ModelRef(id: "sonnet", providerID: "claude-code"))
        try await box.saveAuto([AutoList.Named(id: "auto", name: "Box list", entries: [sonnet]), AutoList.Named(id: "auto-fast", name: "Fast", entries: [])])
        #expect(boxBridge.names == ["Box list", "Fast"])
        #expect(macBridge.saved == 0, "a machine's lists are its own: this Mac's stay as they were")
        #expect(mac.auto.all.map(\.name) == ["Mac list"])

        try await mac.saveAuto([AutoList.Named(id: "auto", name: "Bugfixes", entries: [])])
        #expect(macBridge.names == ["Bugfixes"])
        #expect(boxBridge.saved == 1, "and this Mac's don't go to the machine")
        #expect(box.auto.all.map(\.name) == ["Box list", "Fast"])
    }
}

/// Settings made on this Mac are your machines' too (unlike Custom Auto's lists): a mode added
/// here, like a security audit, is in what a machine's engine starts with, so one connected
/// starts over with it (once nothing runs there) and shows it in its sessions' mode menu.
@MainActor
@Suite(.serialized) struct MachineSettingsTests {
    @Test func aModeAddedHereGoesToMachines() async throws {
        TestEnvironment.prepare()
        let app = AppModel()
        let config = app.engineConfig
        let before = await app.machineEnvironment()[RemoteServer.privateSettingsVariable] ?? ""
        #expect(!before.contains("security-audit"))
        defer { config.set(nil, at: ["agents", "security-audit"]) }

        var saved = 0
        config.onSaved = { saved += 1 }
        config.set(.object(["description": .string("Audits the code for security problems"), "mode": .string("primary"),
                            "prompt": .string("Look for security problems.")]), at: ["agents", "security-audit"])
        #expect(saved == 1, "machines are told when settings are saved")
        let after = try #require(await app.machineEnvironment()[RemoteServer.privateSettingsVariable])
        let agents = try #require((try JSONSerialization.jsonObject(with: Data(after.utf8)) as? [String: Any])?["agents"] as? [String: Any])
        #expect((agents["security-audit"] as? [String: Any])?["description"] as? String == "Audits the code for security problems")
    }
}
