import OpenCodeKit
import SwiftUI

/// Adding a machine: an SSH host this Mac can reach with its keys, checked before it's kept.
struct MachineSheet: View {
    /// Called with the machine once it's added and connecting.
    var added: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var destination = ""
    @State private var hosts: [String] = []
    @State private var isChecking = false
    @State private var failure: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add Machine")
                    .font(.title2.weight(.bold))
                Text("A Linux server you reach with SSH, like a home server or a VPS. Its projects open next to this Mac’s, and their sessions run there.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                WellGroup(isActive: isFocused) {
                    WellRow(isActive: isFocused) {
                        Image(systemName: "server.rack")
                    } content: {
                        TextField("SSH host", text: $destination, prompt: Text(verbatim: "my-server or user@host"))
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .focused($isFocused)
                            .onSubmit(add)
                    }
                    ForEach(suggestions, id: \.self) { host in
                        WellDivider()
                        Button { destination = host } label: {
                            WellRow {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 12, weight: .medium))
                            } content: {
                                Text(host)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(WellRowButtonStyle())
                    }
                }
                .font(.system(size: 15))

                if let failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text("Kuvo Code connects with your SSH keys and agent, and installs its engine in ~/.kuvo-code there.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                if isChecking {
                    Spinner(size: 16)
                    Text("Connecting…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                Button("Add Machine", action: add)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(trimmed.isEmpty || isChecking)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 520)
        .onAppear { isFocused = true }
        .task { hosts = await Task.detached { SSHConfig.hosts() }.value }
        .onChange(of: destination) { failure = nil }
    }

    private var trimmed: String { destination.trimmingCharacters(in: .whitespaces) }

    /// Hosts from `~/.ssh/config` that match what's typed, leaving out the ones added already.
    private var suggestions: [String] {
        let added = Set(app.machines.list.map(\.id))
        let matches = hosts.filter { !added.contains($0) && $0 != trimmed && (trimmed.isEmpty || $0.localizedCaseInsensitiveContains(trimmed)) }
        return Array(matches.prefix(4))
    }

    private func add() {
        let destination = trimmed
        guard !destination.isEmpty, !isChecking else { return }
        if app.machines.engine(destination) != nil {
            added(destination)
            dismiss()
            return
        }
        isChecking = true
        failure = nil
        Task {
            defer { isChecking = false }
            do {
                try await RemoteEngineInstaller(connection: SSHConnection(destination: destination), cache: AppInfo.supportDirectory.appending(path: "engine-linux")).check()
            } catch {
                failure = error.localizedDescription
                return
            }
            app.addMachine(destination)
            added(destination)
            dismiss()
        }
    }
}

/// The hosts named in `~/.ssh/config` (and the files it includes), without patterns.
nonisolated enum SSHConfig {
    static func hosts() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var hosts: [String] = []
        var seen = Set<String>()
        func read(_ url: URL, depth: Int) {
            guard depth < 4, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
                guard let keyword = words.first?.lowercased(), !keyword.hasPrefix("#") else { continue }
                if keyword == "host" {
                    for host in words.dropFirst() where !host.contains(where: { "*?!".contains($0) }) && seen.insert(host).inserted {
                        hosts.append(host)
                    }
                } else if keyword == "include" {
                    for pattern in words.dropFirst() {
                        let path = pattern.hasPrefix("~/") ? home.appending(path: String(pattern.dropFirst(2))).path
                            : pattern.hasPrefix("/") ? pattern : home.appending(path: ".ssh/" + pattern).path
                        for match in glob(path) { read(URL(filePath: match), depth: depth + 1) }
                    }
                }
            }
        }
        read(home.appending(path: ".ssh/config"), depth: 0)
        return hosts
    }

    private static func glob(_ pattern: String) -> [String] {
        var result = glob_t()
        defer { globfree(&result) }
        guard Darwin.glob(pattern, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { result.gl_pathv[$0].map { String(cString: $0) } }
    }
}
