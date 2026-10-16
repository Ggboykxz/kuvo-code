import CryptoKit
import Foundation
import KuvoLink
import OpenCodeKit
import os
import Security
import SystemConfiguration

/// Kuvo Code for iPhone's way in: this Mac answers the phones you've paired, through the relay,
/// passing what they ask to its engine. Everything between them is encrypted end to end
/// (`Packages/KuvoLink`); the relay only passes bytes along.
///
/// Off until the phone app is out: `defaults write run.kuvo.code phoneLink -bool true`, or
/// KUVO_DEMO_PHONE=1, turns it on, with Settings › Phone.
@Observable
final class PhoneLink {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "phoneLink") || ProcessInfo.processInfo.environment["KUVO_DEMO_PHONE"] != nil
    }

    /// Where the relay is until there's a public one. `defaults write run.kuvo.code
    /// phoneLink.relay wss://…` points elsewhere.
    static let defaultRelay = URL(string: "ws://127.0.0.1:8790")!
    static let pairingTime: Duration = .seconds(600)

    struct Phone: Codable, Hashable, Identifiable {
        /// Its static key, base64url.
        var key: String
        var name: String
        var added: Date
        var id: String { key }
    }

    enum Status: Equatable {
        case off, connecting, connected
        case failed(String)
    }

    private(set) var phones: [Phone] = []
    /// Your machines' bridges, which phones reach directly (with the Mac closed), by machine:
    /// what `kuvo/hosts` tells a phone.
    private(set) var machineHosts: [String: MachineHost] = [:]
    /// The machines that are connected now, for putting the bridge on them; set by AppModel.
    @ObservationIgnored var readyMachines: () -> [MachineEngine] = { [] }
    /// Your bots, for `kuvo/bots`: the phone draws and describes each as the Mac does; set by
    /// AppModel.
    @ObservationIgnored weak var bots: Bots?

    struct MachineHost: Codable, Hashable {
        var name: String
        var address: String
        var key: String
    }

    /// What's kept in phone-link.json.
    private struct Saved: Codable {
        var phones: [Phone] = []
        var machines: [String: MachineHost] = [:]
    }
    private(set) var status = Status.off
    /// The link a phone pairs with, while Settings › Phone shows it: good for ten minutes, once.
    private(set) var pairing: PairingLink?
    @ObservationIgnored private var pairingEnds = ContinuousClock.now

    var relay: URL {
        get { UserDefaults.standard.string(forKey: "phoneLink.relay").flatMap(URL.init(string:)) ?? Self.defaultRelay }
        set {
            UserDefaults.standard.set(newValue.absoluteString, forKey: "phoneLink.relay")
            restart()
            syncMachines()
        }
    }

    /// This Mac's key and relay secret, from the Keychain, made the first time the link is on
    /// (with it off, Kuvo Code keeps nothing for it).
    @ObservationIgnored private lazy var identity: (key: LinkKey, secret: RelaySecret) = Self.loadIdentity()
    private var key: LinkKey { identity.key }
    private var secret: RelaySecret { identity.secret }
    @ObservationIgnored private var server: LinkServer?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var endpoint: ServerEndpoint?
    private let log = Logger(subsystem: "run.kuvo.code", category: "phone")

    private static var file: URL { AppInfo.supportDirectory.appending(path: "phone-link.json") }

    init() {
        let saved = (try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: Self.file))) ?? Saved()
        phones = saved.phones
        machineHosts = saved.machines
    }

    private static func loadIdentity() -> (key: LinkKey, secret: RelaySecret) {
        (kept("key", read: { try? LinkKey(rawRepresentation: $0) }, make: LinkKey.init, bytes: \.rawRepresentation),
         kept("secret", read: RelaySecret.init(bytes:), make: RelaySecret.init, bytes: \.bytes))
    }

    /// One of them from the Keychain, made the first time. One the Keychain won't give out (you
    /// said no when it asked) isn't replaced: phones won't reach this Mac until it's opened again.
    private static func kept<T>(_ account: String, read: (Data) -> T?, make: () -> T, bytes: (T) -> Data) -> T {
        do {
            if let data = try keychain(account), let value = read(data) { return value }
        } catch {
            Logger(subsystem: "run.kuvo.code", category: "phone").error("Couldn’t read the phone link’s \(account, privacy: .public) from the Keychain: \(error.localizedDescription, privacy: .public)")
            return make()
        }
        let value = make()
        setKeychain(bytes(value), for: account)
        return value
    }

    /// This Mac's name, as Sharing settings has it.
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    /// Starts answering phones, through this Mac's engine at `endpoint`, once it's ready.
    func start(endpoint: ServerEndpoint) {
        self.endpoint = endpoint
        guard Self.isEnabled, running == nil else { return }
        server = makeServer(endpoint: endpoint)
        running = Task { await run() }
    }

    func stop() {
        running?.cancel()
        running = nil
        server = nil
        status = .off
    }

    private func restart() {
        guard let endpoint else { return }
        stop()
        start(endpoint: endpoint)
    }

    /// Shows a pairing link (as a QR code) for a phone to scan.
    func beginPairing() {
        pairing = PairingLink(relay: relay, host: secret.address, key: key.publicBytes, name: Self.computerName)
        pairingEnds = .now + Self.pairingTime
    }

    func endPairing() {
        pairing = nil
    }

    func remove(_ phone: Phone) {
        phones.removeAll { $0.id == phone.id }
        save()
        if let key = Data(base64URL: phone.key) { Task { [server] in await server?.forget(phone: key) } }
        syncMachines()
    }

    // MARK: Machines

    /// Puts the bridge on each connected machine, with the phones you've paired now.
    func syncMachines() {
        for engine in readyMachines() { Task { await sync(engine) } }
    }

    /// Puts the bridge (`kuvo-link.js`) on `engine`'s machine, in `~/.kuvo-code/bin`, with the
    /// phones you've paired and the relay, so they reach it directly, with this Mac closed too.
    /// The machine keeps its own keys and tells this Mac only its address and public key. With
    /// no phones, the bridge stops there.
    func sync(_ engine: MachineEngine) async {
        guard Self.isEnabled, engine.isReady else { return }
        let machine = engine.machine
        let folder = FileManager.default.temporaryDirectory.appending(path: Bundle.main.bundleIdentifier ?? "run.kuvo.code").appending(path: "phone-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let script = try Bridge.script
            let hash = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
            let scriptFile = folder.appending(path: Bridge.fileName)
            try script.write(to: scriptFile)
            try await machine.connection.run(RemoteEngineInstaller.script("""
                f="$K/bin/\(Bridge.fileName)"
                if [ "$(sha256sum "$f" 2>/dev/null | cut -c1-64)" = "\(hash)" ]; then cat >/dev/null; else cat >"$f.new" && mv -f "$f.new" "$f"; fi
                """), input: scriptFile)

            struct Setup: Encodable {
                struct Phone: Encodable { var key: String; var name: String }
                var relay: String
                var name: String
                var phones: [Phone]
            }
            let settings = folder.appending(path: "setup.json")
            try JSONEncoder().encode(Setup(relay: relay.absoluteString, name: machine.name, phones: phones.map { .init(key: $0.key, name: $0.name) })).write(to: settings)
            let output = try await machine.connection.run(RemoteEngineInstaller.script("""
                KUVO_HOME="$K" BUN_BE_BUN=1 BUN_RUNTIME_TRANSPILER_CACHE_PATH=0 "$E" "$K/bin/\(Bridge.fileName)" setup
                """), input: settings)
            struct Answer: Decodable { var address: String?; var key: String? }
            let answer = try? JSONDecoder().decode(Answer.self, from: Data(output.utf8))
            if let address = answer?.address, let key = answer?.key {
                machineHosts[machine.id] = MachineHost(name: machine.name, address: address, key: key)
            } else {
                machineHosts[machine.id] = nil
            }
            save()
        } catch {
            log.error("Couldn't set up the phone link on a machine: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A machine you removed: phones stop being told about it.
    func forget(machine id: String) {
        guard machineHosts.removeValue(forKey: id) != nil else { return }
        save()
    }

    // MARK: Answering

    private func run() async {
        var attempt = 0
        while !Task.isCancelled, let server {
            status = .connecting
            do {
                let connection = try await WebSocketRelay.connect(to: relay, secret: secret)
                status = .connected
                attempt = 0
                await server.serve(connection)
            } catch {
                status = .failed("Can’t reach the relay at \(relay.host() ?? relay.absoluteString).")
            }
            attempt += 1
            try? await Task.sleep(for: .seconds(min(60, 1 << min(attempt, 6))))
        }
    }

    private func makeServer(endpoint: ServerEndpoint) -> LinkServer {
        let hello = HostHello(kind: .mac, name: Self.computerName, app: AppInfo.version, engine: OpenCodeEngine.version)
        let base = endpoint.url.absoluteString.hasSuffix("/") ? endpoint.url : URL(string: endpoint.url.absoluteString + "/")!
        let password = endpoint.password
        return LinkServer(key: key, hello: hello) { [weak self] key, hello in
            await self?.authorize(key, hello) ?? false
        } handle: { [weak self] request, _ in
            guard request.path.hasPrefix("kuvo/") else { return EngineRoutes.forward(request, to: base, password: password) }
            return AsyncThrowingStream { continuation in
                Task { @MainActor in
                    let (status, body) = self?.answer(request) ?? (503, Data())
                    continuation.yield(.head(status: status, headers: ["content-type": "application/json"]))
                    continuation.yield(.body(body))
                    continuation.finish()
                }
            }
        } connect: { request, _, input in
            // Terminals: the engine's, in a project's folder.
            EngineRoutes.connect(request, to: base, password: password, input: input)
        }
    }

    /// Lets in a phone you've paired, or one showing the pairing link's token (once, in time).
    private func authorize(_ key: Data, _ hello: PhoneHello) -> Bool {
        let encoded = key.base64URL
        if phones.contains(where: { $0.key == encoded }) { return true }
        guard let pairing, ContinuousClock.now < pairingEnds, let token = hello.pair.flatMap({ Data(base64URL: $0) }),
              token.count == pairing.token.count, zip(token, pairing.token).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0
        else { return false }
        phones.append(Phone(key: encoded, name: String(hello.name.prefix(100)), added: .now))
        save()
        self.pairing = nil
        syncMachines()
        log.info("Paired a phone")
        return true
    }

    /// Kuvo's own routes, beside the engine's.
    private func answer(_ request: LinkRequest) -> (Int, Data) {
        /// `chats`: the folder of conversations of no project, which the phone lists as Chats.
        struct Info: Encodable { var kind = "mac"; var name: String; var app: String; var engine: String; var chats: String }
        struct Hosts: Encodable {
            struct Host: Encodable { var kind = "machine"; var name: String; var address: String; var key: String; var relay: String }
            var hosts: [Host]
        }
        let encoder = JSONEncoder()
        switch request.path {
        case "kuvo/info":
            return (200, (try? encoder.encode(Info(name: Self.computerName, app: AppInfo.version, engine: OpenCodeEngine.version, chats: Workspace.chatsFolder))) ?? Data())
        case "kuvo/bots":
            // Each bot by its session (here or on a machine): its name, look and job, and what
            // the Mac knows of it that its session doesn't say: paused, when it next wakes (in
            // seconds since 1970), how many things it watches.
            struct Listed: Encodable {
                struct Entry: Encodable {
                    var session: String, name: String, look: BotLook, machine: String?, job: String
                    var paused: Bool, wakes: Double?, watching: Int
                }
                var bots: [Entry]
            }
            let entries = (bots?.list ?? []).map { bot in
                Listed.Entry(
                    session: bot.sessionID, name: bot.name, look: bot.look, machine: bot.machine, job: bot.job,
                    paused: bots?.paused.contains(bot.id) == true,
                    wakes: bots?.wakes[bot.id]?.map(\.due).min()?.timeIntervalSince1970,
                    watching: bots?.watches[bot.id]?.count ?? 0)
            }
            return (200, (try? encoder.encode(Listed(bots: entries))) ?? Data())
        case "kuvo/hosts":
            let hosts = machineHosts.values.sorted { $0.name < $1.name }.map { Hosts.Host(name: $0.name, address: $0.address, key: $0.key, relay: relay.absoluteString) }
            return (200, (try? encoder.encode(Hosts(hosts: hosts))) ?? Data())
        default:
            return (404, Data())
        }
    }

    private func save() {
        try? JSONEncoder().encode(Saved(phones: phones, machines: machineHosts)).write(to: Self.file, options: .atomic)
    }

    // MARK: Keychain

    private static var service: String { (Bundle.main.bundleIdentifier ?? "run.kuvo.code") + ".phone-link" }

    /// The item, or nil when there's none; throws when the Keychain can't be read.
    private static func keychain(_ account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func setKeychain(_ data: Data, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) != errSecItemNotFound { return }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Kuvo Code phone link"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
