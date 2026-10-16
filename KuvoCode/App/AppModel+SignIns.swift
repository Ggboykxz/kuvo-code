import OpenCodeKit

extension AppModel {
    /// Integrations you signed in to here (Notion, Linear…) work on your machines too: each
    /// sign-in is copied between this Mac's engine and a machine's, the newer one winning (a
    /// service may hand out a new refresh token each time it's used, and the other copy then
    /// stops working). The older copy goes, so they don't pile up.
    func syncSignIns(with engine: MachineEngine) async {
        guard let mac = api, let remote = engine.api else { return }
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
            if mine.expires > (yours?.expires ?? -1) {
                guard (try? await remote.storeCredential(mine, for: far)) != nil else { continue }
                if let yours { try? await remote.removeCredential(yours.id) }
                try? await remote.connectMCP(match.name)
            } else if let yours, yours.expires > mine.expires {
                // The machine's is newer (it refreshed): back to this Mac.
                guard (try? await mac.storeCredential(yours, for: local)) != nil else { continue }
                try? await mac.removeCredential(mine.id)
                try? await mac.connectMCP(server.name)
            }
        }
    }

    /// Signs out of `integration` (a server's, which engines name alike), here and on every
    /// connected machine.
    func forgetSignIn(_ integration: String) {
        let engines = [api].compactMap(\.self) + machines.engines.values.filter(\.isReady).compactMap(\.api)
        for api in engines {
            Task {
                guard let entries = try? await api.credentialEntries() else { return }
                for entry in entries where entry.integrationID == integration { try? await api.removeCredential(entry.id) }
            }
        }
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
