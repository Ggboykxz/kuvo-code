import SwiftUI
import WebKit

/// Signing in to a service the agent uses on its site (X, Discord…), in Settings: the site, in the
/// browser the agent and your bots browse with, on this Mac or on one of your machines (each
/// keeps its own sign-ins), and whether it's signed in there.
struct SiteSignInPage: View {
    let service: Integrations.Service
    let done: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    /// Where you sign in: "" for this Mac, else a machine's ID.
    @State private var place = ""
    @State private var pages = SignInPages()
    /// The page opened on each machine, by machine, closed when you're done.
    @State private var machinePages: [String: String] = [:]
    @State private var opening: String?

    private static let shape = RoundedRectangle(cornerRadius: 14)

    private var machine: String? { place.isEmpty ? nil : place }

    private var machines: [MachineEngine] {
        app.machines.list.compactMap { app.machines.engine($0.id) }.filter(\.isReady)
    }

    private var placeName: String {
        machine.flatMap { app.machines.engine($0)?.machine.name } ?? "this Mac"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            browser
        }
        .padding(.horizontal, SettingsMetrics.inset - 20)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .onAppear {
            pages.open(service.site)
            #if DEBUG
            // KUVO_DEMO_SIGN_IN_PLACE=<machine>: on that machine.
            if let machine = ProcessInfo.processInfo.environment["KUVO_DEMO_SIGN_IN_PLACE"] {
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    place = machine
                }
            }
            #endif
        }
        .onChange(of: place) { openOnMachine() }
        // Whether it's signed in, as you sign in.
        .task {
            while !Task.isCancelled {
                await SiteSignIns.shared.refresh(app)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onExitCommand(perform: close)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: service.symbol)
                .font(.system(size: 19))
                .foregroundStyle(.secondary)
                .frame(width: 42, height: 42)
                .background(Surface.well(scheme), in: .rect(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text("Sign in to \(service.title)")
                        .font(.system(size: 17, weight: .semibold))
                    if let signedIn = SiteSignIns.shared.isSignedIn(service.id, on: machine) {
                        SignedInBadge(signedIn: signedIn)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                Text(machine == nil
                     ? "The agent and your bots on this Mac browse signed in as you."
                     : "Bots on \(placeName) browse in its own browser, signed in as you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if !machines.isEmpty {
                PillPicker(options: [.init(value: "", title: "This Mac", symbol: "laptopcomputer")]
                    + machines.map { .init(value: $0.machine.id, title: $0.machine.name, symbol: "server.rack") },
                           selection: $place)
            }
            Button("Done", action: close)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .animation(.ui, value: SiteSignIns.shared.isSignedIn(service.id, on: machine))
    }

    /// The page, in a card of its own.
    private var browser: some View {
        Group {
            if let machine, let engine = app.machines.engine(machine) {
                if let id = machinePages[machine] {
                    MachineBrowserPane(browser: engine.browser, page: id) {
                        EmptyView()
                    } onSubmit: { address in
                        engine.browser.load(address)
                    }
                } else {
                    VStack(spacing: 10) {
                        Spinner(size: 18)
                        Text("Opening \(service.title) on \(engine.machine.name)…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let session = pages.top {
                BrowserPane(session: session) { EmptyView() }
                    .id(ObjectIdentifier(session))
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Surface.cardFill(scheme, focused: true), in: Self.shape)
        .clipShape(Self.shape)
        .specularRim(Self.shape)
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.08), radius: 10, y: 3)
    }

    private func openOnMachine() {
        guard let machine, machinePages[machine] == nil, opening != machine, let engine = app.machines.engine(machine) else { return }
        opening = machine
        Task {
            if let id = await engine.browser.newPage(service.site) { machinePages[machine] = id }
            opening = nil
        }
    }

    private func close() {
        for (machine, id) in machinePages { app.machines.engine(machine)?.browser.close(id) }
        machinePages = [:]
        pages.closeAll()
        done()
    }
}

/// Signed in there or not, as its cookies say.
private struct SignedInBadge: View {
    let signedIn: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: signedIn ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(signedIn ? Color.green : Color.secondary)
            Text(signedIn ? "Signed in" : "Not signed in yet")
                .foregroundStyle(signedIn ? .primary : .secondary)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(signedIn ? Color.green.opacity(0.14) : Color.primary.opacity(0.06), in: .capsule)
    }
}

/// The page's tabs on this Mac: the site, and a window it opens over it (a "Continue with
/// Google" popup), until that closes.
@Observable
final class SignInPages {
    private(set) var stack: [BrowserSession] = []

    var top: BrowserSession? { stack.last }

    func open(_ address: String) {
        guard stack.isEmpty else { return }
        stack.append(make(configuration: nil, address: address))
    }

    private func make(configuration: WKWebViewConfiguration?, address: String?) -> BrowserSession {
        let session = BrowserSession(configuration: configuration)
        session.openWindow = { [weak self] configuration in
            guard let self else { return nil }
            let window = make(configuration: configuration, address: nil)
            stack.append(window)
            return window.webView
        }
        session.onClose = { [weak self, weak session] in
            self?.stack.removeAll { $0 === session }
        }
        if let address { session.load(address) }
        return session
    }

    func closeAll() {
        stack = []
    }
}
