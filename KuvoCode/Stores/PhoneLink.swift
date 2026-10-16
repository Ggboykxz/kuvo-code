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
    private(set) var status = Status.off
    /// The link a phone pairs with, while Settings › Phone shows it: good for ten minutes, once.
    private(set) var pairing: PairingLink?
    @ObservationIgnored private var pairingEnds = ContinuousClock.now

    var relay: URL {
        get { UserDefaults.standard.string(forKey: "phoneLink.relay").flatMap(URL.init(string:)) ?? Self.defaultRelay }
        set {
            UserDefaults.standard.set(newValue.absoluteString, forKey: "phoneLink.relay")
            restart()
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
        phones = (try? JSONDecoder().decode([Phone].self, from: Data(contentsOf: Self.file))) ?? []
    }

    private static func loadIdentity() -> (key: LinkKey, secret: RelaySecret) {
        let key = keychain("key").flatMap { try? LinkKey(rawRepresentation: $0) } ?? {
            let key = LinkKey()
            setKeychain(key.rawRepresentation, for: "key")
            return key
        }()
        let secret = keychain("secret").flatMap(RelaySecret.init(bytes:)) ?? {
            let secret = RelaySecret()
            setKeychain(secret.bytes, for: "secret")
            return secret
        }()
        return (key, secret)
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
        log.info("Paired a phone")
        return true
    }

    /// Kuvo's own routes, beside the engine's.
    private func answer(_ request: LinkRequest) -> (Int, Data) {
        struct Info: Encodable { var kind = "mac"; var name: String; var app: String; var engine: String }
        // The machines a phone reaches directly comes with the machines' bridges.
        struct Hosts: Encodable { var hosts: [String] = [] }
        let encoder = JSONEncoder()
        switch request.path {
        case "kuvo/info":
            return (200, (try? encoder.encode(Info(name: Self.computerName, app: AppInfo.version, engine: OpenCodeEngine.version))) ?? Data())
        case "kuvo/hosts":
            return (200, (try? encoder.encode(Hosts())) ?? Data())
        default:
            return (404, Data())
        }
    }

    private func save() {
        try? JSONEncoder().encode(phones).write(to: Self.file, options: .atomic)
    }

    // MARK: Keychain

    private static var service: String { (Bundle.main.bundleIdentifier ?? "run.kuvo.code") + ".phone-link" }

    private static func keychain(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
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
