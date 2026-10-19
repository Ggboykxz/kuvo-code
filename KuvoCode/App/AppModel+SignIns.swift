import Foundation
import OpenCodeKit

extension AppModel {
    /// Your accounts (API keys, sign-ins like ChatGPT's or GitHub Copilot's) and the integrations
    /// you signed in to here (Notion, Linear…) work on your machines too: each is copied between
    /// this Mac's engine and a machine's, the newer one winning (a service may hand out a new
    /// refresh token each time it's used, and the other copy then stops working). The older copy
    /// goes, so they don't pile up. Sign-outs it hasn't taken yet go first.
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
        await replaceWhileAway(engine, api: remote)
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
            // Two of your accounts with one label here (two GitLab accounts on one host): the label
            // can't say which the machine's copy is of.
            let byLabel = ours.filter { $0.integrationID == mine.integrationID && $0.label == mine.label }.count == 1
            await exchange(mine, yours, here: mine.integrationID, there: mine.integrationID, mac: mac, remote: remote, byLabel: byLabel)
        }
    }

    /// Puts this Mac's sign-in or key on the machine, in place of the one there, unless that's the
    /// same, or the machine's is the newer of the two (it renewed it), which comes back here
    /// instead: true if the machine's changed, false if this Mac's did. For another account than
    /// the machine's (one you switched to here), or another key, this Mac's.
    @discardableResult
    private func exchange(_ mine: CredentialEntry, _ yours: CredentialEntry?, here local: String, there far: String,
                          mac: OpenCodeAPI, remote: OpenCodeAPI, byLabel: Bool = true) async -> Bool? {
        if let yours, Self.isSameAccount(mine, yours, byLabel: byLabel) {
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
    /// (a copy keeps it), when the label names one account.
    private static func isSameAccount(_ one: CredentialEntry, _ other: CredentialEntry, byLabel: Bool = true) -> Bool {
        if let a = accountID(one), let b = accountID(other) { return a == b }
        return byLabel && one.label == other.label
    }

    /// The account a sign-in is for, as its service names it (the engine keeps it in its metadata).
    private static func accountID(_ entry: CredentialEntry) -> String? {
        entry.value["metadata"]?["accountID"]?.string ?? entry.value["accountId"]?.string
    }

    /// Connects an integration's server again after a sign-in (or a Try Again), in every folder
    /// its engine has open, as each runs its own: `machine`'s engine, or this Mac's for nil.
    func reconnect(_ server: String, api: OpenCodeAPI, machine: String?) async {
        try? await api.connectMCP(server)
        for folder in workspace.openFolders(on: machine) { try? await api.connectMCP(server, directory: folder) }
    }

    /// Signs out of `integration` (a server's or an account's, which engines name alike), here and
    /// on every machine: those connected now right after, the others when they next connect. Each
    /// machine keeps it to do until its copy is gone, so a removal that fails (the connection
    /// dropped meanwhile) is tried again with the next sync; the sync copies only what this Mac
    /// has, so it would never take that copy away by itself.
    func forgetSignIn(_ integration: String) {
        let mac = api
        Task {
            if let mac, let entries = try? await mac.credentialEntries() {
                for entry in entries where entry.integrationID == integration { try? await mac.removeCredential(entry.id) }
            }
            // Only after this Mac's is gone: one it still has counts as signed in to again.
            var pending = Self.pendingSignOuts.filter { id, _ in machines.list.contains { $0.id == id } }
            for machine in machines.list where !(pending[machine.id] ?? []).contains(integration) {
                pending[machine.id, default: []].append(integration)
            }
            Self.pendingSignOuts = pending
            for engine in machines.engines.values where engine.isReady { nudgeSignIns(engine) }
        }
    }

    /// The sign-outs each machine still has to take, by machine.
    private static var pendingSignOuts: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: "machineSignOuts") as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue.isEmpty ? nil : newValue, forKey: "machineSignOuts") }
    }

    /// Signs `engine`'s machine out of what you signed out of here, unless you've signed in to it
    /// again since. One it couldn't is left for the next time.
    private func signOutWhileAway(_ engine: MachineEngine, api remote: OpenCodeAPI) async {
        let id = engine.machine.id
        guard let missed = Self.pendingSignOuts[id], let mac = api,
              let ours = try? await mac.credentialEntries(), let theirs = try? await remote.credentialEntries() else { return }
        var done: Set<String> = []
        for integration in Set(missed) {
            var removed = true
            // Signed in to here again: the sync copies that one over instead.
            if !ours.contains(where: { $0.integrationID == integration }) {
                for entry in theirs where entry.integrationID == integration {
                    if (try? await remote.removeCredential(entry.id)) == nil { removed = false }
                }
            }
            if removed { done.insert(integration) }
        }
        // As the list is now: a sign-out made meanwhile stays on it.
        var pending = Self.pendingSignOuts
        let left = (pending[id] ?? []).filter { !done.contains($0) }
        pending[id] = left.isEmpty ? nil : left
        Self.pendingSignOuts = pending
    }

    /// You removed one of several accounts with `integration` here: each machine's copy (maybe of
    /// the one removed) goes, and the one in use here is copied in its place, now or when the
    /// machine next connects.
    func replaceSignIn(_ integration: String) {
        var pending = Self.pendingReplacements.filter { id, _ in machines.list.contains { $0.id == id } }
        for machine in machines.list where !(pending[machine.id] ?? []).contains(integration) {
            pending[machine.id, default: []].append(integration)
        }
        Self.pendingReplacements = pending
        syncSignIns()
    }

    /// The copies each machine still has to drop, by machine.
    private static var pendingReplacements: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: "machineReplacements") as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue.isEmpty ? nil : newValue, forKey: "machineReplacements") }
    }

    private func replaceWhileAway(_ engine: MachineEngine, api remote: OpenCodeAPI) async {
        let id = engine.machine.id
        guard let integrations = Self.pendingReplacements[id], let theirs = try? await remote.credentialEntries() else { return }
        var done: Set<String> = []
        for integration in Set(integrations) {
            var removed = true
            for entry in theirs where entry.integrationID == integration {
                if (try? await remote.removeCredential(entry.id)) == nil { removed = false }
            }
            if removed { done.insert(integration) }
        }
        var pending = Self.pendingReplacements
        let left = (pending[id] ?? []).filter { !done.contains($0) }
        pending[id] = left.isEmpty ? nil : left
        Self.pendingReplacements = pending
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
