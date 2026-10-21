import Foundation
import OpenCodeKit
import Testing
@testable import KuvoCode

/// One computer reached at two addresses (its name on the local network and over Tailscale) is
/// one machine: whichever is added later, or found to be the same once both connect, becomes one
/// of the other's addresses. Nothing there is signed out or stopped (that machine's engine is the
/// other's), and what was kept under its name (projects, their settings, bots) is the other's.
@MainActor
@Suite(.serialized) struct MachineAddressesTests {
    init() {
        TestEnvironment.prepare()
        Self.clean()
    }

    private static func clean() {
        for key in ["machines", "machines.waiting", "machines.waitingSince", "projectFolders", "projectSettings", "worktrees"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func machines(_ names: String...) -> Machines {
        let machines = Machines()
        for name in names { machines.add(name) }
        return machines
    }

    @Test(arguments: [false, true])
    func theSameComputerAtTwoAddressesIsOneMachine(laterFirst: Bool) {
        defer { Self.clean() }
        let machines = machines("lokum-tailscale", "hetzner", "lokum-local")
        var folded: [(String, String)] = []
        machines.onFolded = { folded.append(($0, $1)) }
        let identity = "0123456789abcdef0123456789abcdef"
        machines.note("fedcba9876543210fedcba9876543210", of: "hetzner")
        if laterFirst {
            machines.note(identity, of: "lokum-local")
            machines.note(identity, of: "lokum-tailscale")
        } else {
            machines.note(identity, of: "lokum-tailscale")
            machines.note(identity, of: "lokum-local")
        }
        #expect(machines.list.map(\.id) == ["lokum-tailscale", "hetzner"], "the one added first stays")
        #expect(machines.list.first?.addresses == ["lokum-tailscale", "lokum-local"])
        #expect(machines.engine("lokum-local") == nil)
        #expect(folded.map(\.0) == ["lokum-local"] && folded.map(\.1) == ["lokum-tailscale"])
        #expect(machines.folded?.address == "lokum-local")
        // Nothing waits to sign it out or stop it there.
        let waiting = UserDefaults.standard.dictionary(forKey: "machines.waiting") as? [String: [String]] ?? [:]
        #expect(!waiting.values.joined().contains { $0.hasPrefix(Machines.removalMark) })

        // Kept as one after a relaunch.
        let again = Machines()
        #expect(again.list.map(\.id) == ["lokum-tailscale", "hetzner"])
        #expect(again.list.first?.otherAddresses == ["lokum-local"])
        #expect(again.list.first?.identity == identity)
    }

    /// A machine already here, added at another address: one of its addresses, not a second
    /// machine; added again, nothing changes; forgotten, the machine stays.
    @Test func anAddressAddedAndForgotten() {
        defer { Self.clean() }
        let machines = machines("lokum-tailscale")
        machines.note("0123456789abcdef0123456789abcdef", of: "lokum-tailscale")
        #expect(machines.machine(calling: "0123456789abcdef0123456789abcdef")?.id == "lokum-tailscale")
        machines.addAddress("lokum-local", to: "lokum-tailscale")
        machines.addAddress("lokum-local", to: "lokum-tailscale")
        #expect(machines.list.map(\.addresses) == [["lokum-tailscale", "lokum-local"]])
        #expect(machines.engine("lokum-tailscale")?.machine.addresses == ["lokum-tailscale", "lokum-local"])
        machines.removeAddress("lokum-local", from: "lokum-tailscale")
        #expect(machines.list.map(\.addresses) == [["lokum-tailscale"]])
    }

    /// Two different computers stay two machines.
    @Test func differentComputersStayApart() {
        defer { Self.clean() }
        let machines = machines("box", "vps")
        machines.note("0123456789abcdef0123456789abcdef", of: "box")
        machines.note("fedcba9876543210fedcba9876543210", of: "vps")
        #expect(machines.list.map(\.id) == ["box", "vps"])
        #expect(machines.list.allSatisfy { $0.otherAddresses == nil })
    }

    /// What was kept under the later name is the other's: its projects (and their other
    /// folders), and its bots, which live on the same computer.
    @Test func whatWasKeptUnderItsNameMovesOver() throws {
        defer { Self.clean() }
        let workspace = Workspace()
        let web = RemoteFolder.folder("/srv/web", on: "lokum-local")
        workspace.addFolder(web)
        workspace.addFolder(RemoteFolder.folder("/srv/api", on: "lokum-tailscale"))
        workspace.saveProject(web, settings: Workspace.ProjectSettings(name: "Website", folders: [RemoteFolder.folder("/srv/shared", on: "lokum-local")], run: "npm run dev"))

        workspace.fold("lokum-local", into: "lokum-tailscale")
        let moved = RemoteFolder.folder("/srv/web", on: "lokum-tailscale")
        #expect(workspace.folders.contains(moved))
        #expect(!workspace.folders.contains(web))
        #expect(workspace.settings[moved]?.name == "Website")
        #expect(workspace.settings[moved]?.folders == [RemoteFolder.folder("/srv/shared", on: "lokum-tailscale")])
        #expect(workspace.settings[web] == nil)
    }
}
