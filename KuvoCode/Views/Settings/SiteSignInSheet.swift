import SwiftUI
import WebKit

/// Signing in to a service the agent uses on its site (X, Discord…): the site, over Settings, in
/// the browser the agent and your bots browse with, on this Mac or on one of your machines (each
/// keeps its own sign-ins).
struct SiteSignInSheet: View {
    let service: Integrations.Service
    let done: () -> Void
    @Environment(AppModel.self) private var app
    /// Where you sign in: nil for this Mac, else a machine's ID.
    @State private var place: String?
    @State private var pages = SignInPages()
    /// The page opened on each machine, by machine, closed with the sheet.
    @State private var machinePages: [String: String] = [:]
    @State private var opening: String?

    private var machines: [MachineEngine] {
        app.machines.list.compactMap { app.machines.engine($0.id) }.filter(\.isReady)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: service.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in to \(service.title)")
                        .font(.headline)
                    Text(place == nil
                         ? "The agent and your bots on this Mac browse signed in as you."
                         : "Bots on \(machineName(place)) browse there, in a browser of its own, signed in as you.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !machines.isEmpty {
                    Picker("Where", selection: $place) {
                        Text("This Mac").tag(String?.none)
                        ForEach(machines, id: \.machine.id) { engine in
                            Text(engine.machine.name).tag(String?.some(engine.machine.id))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 1000, height: 740)
        .onAppear { pages.open(service.site) }
        .onChange(of: place) { openOnMachine() }
    }

    @ViewBuilder private var page: some View {
        if let place, let engine = app.machines.engine(place) {
            if let id = machinePages[place] {
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
            }
        } else if let session = pages.top {
            BrowserPane(session: session) { EmptyView() }
                .id(ObjectIdentifier(session))
        }
    }

    private func machineName(_ id: String?) -> String {
        id.flatMap { app.machines.engine($0)?.machine.name } ?? "the machine"
    }

    private func openOnMachine() {
        guard let place, machinePages[place] == nil, opening != place, let engine = app.machines.engine(place) else { return }
        opening = place
        Task {
            if let id = await engine.browser.newPage(service.site) { machinePages[place] = id }
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

/// The sheet's pages on this Mac: the site, and a window it opens over it (a "Continue with
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
