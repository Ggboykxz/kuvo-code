import Foundation
import OpenCodeKit

extension AppModel {
    /// Your accounts (API keys, sign-ins like ChatGPT's or GitHub Copilot's) and the integrations
    /// you signed in to here (Notion, Linear…) work on your machines too: each is copied between
    /// this Mac's engine and a machine's, the newer one winning (a service may hand out a new
    /// refresh token each time it's used, and the other copy then stops working). The older copy
    /// goes, so they don't pile up. Sign-outs made while it was away go first.
    ///
    /// Once after another with each machine (two at once would each copy the same sign-in), and
    /// each to its end: what it changes is a change that asks for it again, and cut off halfway it
    /// would leave the older copy behind.
    func syncSignIns(with engine: MachineEngine) async {
        let previous = engine.signInTurn
        let turn = Task { [weak self, weak engine] in
            await previous?.value
            guard let self, let engine else { return }
            await self.copySignIns(with: engine)
        }
        engine.signInTurn = turn
        await turn.value
    }

    private func copySignIns(with engine: MachineEngine) async {
        guard let mac = api, let remote = engine.api else { return }
        await signOutWhileAway(engine, api: remote)
        async let macServers = mac.mcpServers()
        async let remoteServers = remote.mcpServers()
        async let macEntries = mac.credentialEntries()
        async let remoteEntries = remote.credentialEntries()
        guard let here = try? await macServers, let there = try? await remoteServers,
              let ours = try? await macEntries, let theirs = try? await remoteEntries else { return }
        for server in here {
            guard let local = server.integrationID, let match = there.first(where: { $0.name == server.name }), let far = match.integrationID,
                  let mine = ours.first(where: { $0.integrationID == local && $0.active && $0.isOAuth }) else { continue }
            let yours = theirs.first { $0.integrationID == far && $0.active && $0.isOAuth }
            switch await exchange(mine, yours, here: local, there: far, mac: mac, remote: remote) {
            case true?: await reconnect(match.name, api: remote, machine: engine.machine.id)
            case false?: await reconnect(server.name, api: mac, machine: nil)
            case nil: break
            }
        }
        // Accounts, each the one in use here: keys and sign-ins alike. (Integrations the catalog
        // names as an account's, not a server's.)
        let integrations = catalog.integrations.isEmpty ? ((try? await mac.integrations()) ?? []) : catalog.integrations
        let accounts = Set(integrations.filter { !$0.isMCP }.map(\.id))
        for mine in ours where mine.active && accounts.contains(mine.integrationID) {
            let yours = theirs.first { $0.integrationID == mine.integrationID && $0.active }
            await exchange(mine, yours, here: mine.integrationID, there: mine.integrationID, mac: mac, remote: remote)
        }
    }

    /// Puts this Mac's sign-in or key on the machine, in place of the one there, unless that's the
    /// same, or the machine's is the newer of the two (it renewed it), which comes back here
    /// instead: true if the machine's changed, false if this Mac's did. For another account than
    /// the machine's (one you switched to here), or another key, this Mac's.
    @discardableResult
    private func exchange(_ mine: CredentialEntry, _ yours: CredentialEntry?, here local: String, there far: String,
                          mac: OpenCodeAPI, remote: OpenCodeAPI) async -> Bool? {
        if let yours, Self.isSameAccount(mine, yours) {
            // Each side renews its own sign-in with the same refresh token: only a new one (from a
            // service that hands out a new one each time) has to go to the other.
            if Self.lasting(mine) == Self.lasting(yours) { return nil }
            if yours.expires > mine.expires {
                // Back to this Mac, and from it to the other machines.
                guard (try? await mac.storeCredential(yours, for: local)) != nil else { return nil }
                try? await mac.removeCredential(mine.id)
                return false
            }
        }
        guard (try? await remote.storeCredential(mine, for: far)) != nil else { return nil }
        if let yours { try? await remote.removeCredential(yours.id) }
        return true
    }

    /// What stays the same while a sign-in renews itself: its refresh token, or a key (or the
    /// whole of something else).
    private static func lasting(_ entry: CredentialEntry) -> JSONValue? {
        entry.value["refresh"] ?? entry.value["key"] ?? entry.value
    }

    /// Copies of one sign-in: the same account, as the service names it, or else the same label
    /// (a copy keeps it).
    private static func isSameAccount(_ one: CredentialEntry, _ other: CredentialEntry) -> Bool {
        if let a = one.value["accountId"]?.string, let b = other.value["accountId"]?.string { return a == b }
        return one.label == other.label
    }

    /// Connects an integration's server again after a sign-in (or a Try Again), in every folder
    /// its engine has open, as each runs its own: `machine`'s engine, or this Mac's for nil.
    func reconnect(_ server: String, api: OpenCodeAPI, machine: String?) async {
        try? await api.connectMCP(server)
        for folder in workspace.openFolders(on: machine) { try? await api.connectMCP(server, directory: folder) }
    }

    /// Signs out of `integration` (a server's or an account's, which engines name alike), here and
    /// on every machine: those not connected now when they next connect.
    func forgetSignIn(_ integration: String) {
        let ready = machines.engines.values.filter(\.isReady)
        let engines = [api].compactMap(\.self) + ready.compactMap(\.api)
        for api in engines {
            Task {
                guard let entries = try? await api.credentialEntries() else { return }
                for entry in entries where entry.integrationID == integration { try? await api.removeCredential(entry.id) }
            }
        }
        var away = Self.signOutsWhileAway
        for machine in machines.list where !ready.contains(where: { $0.machine.id == machine.id }) {
            away[machine.id, default: []].append(integration)
        }
        Self.signOutsWhileAway = away
    }

    /// The sign-outs a machine that wasn't connected missed, by machine.
    private static var signOutsWhileAway: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: "machineSignOuts") as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue.isEmpty ? nil : newValue, forKey: "machineSignOuts") }
    }

    /// Signs `engine`'s machine out of what you signed out of while it wasn't connected, unless
    /// you've signed in to it again here since.
    private func signOutWhileAway(_ engine: MachineEngine, api remote: OpenCodeAPI) async {
        let id = engine.machine.id
        guard let missed = Self.signOutsWhileAway[id], let mac = api,
              let ours = try? await mac.credentialEntries(), let theirs = try? await remote.credentialEntries() else { return }
        for integration in Set(missed) where !ours.contains(where: { $0.integrationID == integration }) {
            for entry in theirs where entry.integrationID == integration { try? await remote.removeCredential(entry.id) }
        }
        Self.signOutsWhileAway[id] = nil
    }

    /// Every connected machine, after a sign-in here (or one renewed by itself).
    func syncSignIns() {
        for engine in machines.engines.values where engine.isReady { nudgeSignIns(engine) }
    }

    /// Soon, once: a sign-in comes with a few changes in a row (stored, made active, the old one
    /// removed), each of them an event, and copying one is one more.
    func nudgeSignIns(_ engine: MachineEngine) {
        engine.signInNudge?.cancel()
        engine.signInNudge = Task { [weak self, weak engine] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let engine, engine.isReady else { return }
            await self?.syncSignIns(with: engine)
        }
    }
}
