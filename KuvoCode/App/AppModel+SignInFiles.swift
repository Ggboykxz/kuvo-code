import Foundation
import OpenCodeKit

extension AppModel {
    /// Integrations whose servers keep their sign-in in files of their own (Outlook's, from its
    /// code sign-in), in the integration's folder: those files go between this Mac and a machine,
    /// the newer one winning, so signing in on one does for both. Each copy keeps the time it
    /// was changed, so the two settle rather than going back and forth.
    func syncSignInFiles(with engine: MachineEngine) async {
        let machine = engine.machine.id
        // Those added in Settings.
        let added = Set(engineConfig.value(at: MCPSettings.path)?.object?.keys.map(\.self) ?? [])
        for (id, names) in Integrations.signInFiles where added.contains(id) {
            for name in names {
                let local = AppInfo.supportDirectory.appending(path: "integrations/\(id)/\(name)")
                let remote = "\"$HOME/\(RemoteEngineInstaller.root)/integrations/\(id)/\(name)\""
                await Task.detached {
                    let here = (try? local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
                    // Unknown when SSH failed (left for the next pass): taken as none there, a
                    // sign-in the machine renewed would be overwritten with this Mac's older one.
                    guard let output = RemoteShell.run("stat -c %Y \(remote) 2>/dev/null || echo 0", on: machine),
                          let there = Double(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                    if here > there + 1 {
                        // Over SSH's own connection, readable by you alone there.
                        _ = try? await SSHConnection(destination: machine).run(
                            "umask 077; mkdir -p \"$(dirname \(remote))\" && cat >\(remote).new && mv -f \(remote).new \(remote) && touch -d @\(Int(here)) \(remote)",
                            input: local)
                    } else if there > here + 1, let data = RemoteShell.run("cat \(remote)", on: machine), !data.isEmpty {
                        try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        guard (try? data.write(to: local, options: .atomic)) != nil else { return }
                        try? FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: Date(timeIntervalSince1970: there)], ofItemAtPath: local.path)
                    }
                }.value
            }
        }
    }
}
