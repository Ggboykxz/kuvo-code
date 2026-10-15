import AppKit
import OpenCodeKit
import SwiftUI

/// Making a bot, or changing one: how it looks, its name and job, and, for a new one, where it
/// lives and works. An existing bot also shows its waiting wake-ups and its memory.
struct BotSheet: View {
    /// The bot being changed; nil for a new one.
    let bot: Bot?
    /// Called with the new bot, once it's made.
    var created: (Bot) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @Environment(Bots.self) private var bots
    @Environment(Workspace.self) private var workspace
    @State private var look: BotLook
    @State private var name: String
    @State private var job: String
    @State private var instructions: String
    /// The machine it lives on; nil for this Mac.
    @State private var machine: String?
    /// The project it works in; nil for a folder of its own.
    @State private var project: String?
    @State private var showsAddMachine = false
    @State private var isWorking = false
    @State private var failure: String?
    @State private var confirmsDelete = false
    @FocusState private var focus: Field?

    private enum Field { case name, job, instructions }

    init(bot: Bot?, created: @escaping (Bot) -> Void = { _ in }) {
        self.bot = bot
        self.created = created
        _look = State(initialValue: bot?.look ?? .random())
        _name = State(initialValue: bot?.name ?? "")
        _job = State(initialValue: bot?.job ?? "")
        _instructions = State(initialValue: bot?.instructions ?? "")
        _machine = State(initialValue: bot?.machine)
        _project = State(initialValue: bot?.project)
    }

    private var isNew: Bool { bot == nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                form
                    .padding([.horizontal, .top], 28)
                    .padding(.bottom, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 640)
            .fixedSize(horizontal: false, vertical: true)
            footer
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 24)
        }
        .frame(width: 560)
        .onAppear { if isNew { focus = .name } }
        .sheet(isPresented: $showsAddMachine) {
            MachineSheet { machine = $0; project = nil }
        }
        .alert("Delete \(bot?.name ?? "This Bot")?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) {
                guard let bot else { return }
                dismiss()
                Task { await bots.delete(bot) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its conversation, memory and wake-ups are deleted. This can’t be undone." + (bot?.project != nil ? " The project it worked in isn’t touched." : ""))
        }
    }

    private var form: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text(isNew ? "New Bot" : "Edit Bot")
                    .font(.title2.weight(.bold))

                identity

                section("Look") {
                    LookPicker(look: $look)
                }

                section("Job", note: "Bots act on this every time they work. Say what to watch, what to make, and what never to do without asking.") {
                    WellGroup(isActive: focus == .instructions) {
                        TextField("Instructions", text: $instructions, prompt: Text("Every morning, check the open issues labeled bug, reproduce the new ones and comment with what you found."), axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(4...10)
                            .focused($focus, equals: .instructions)
                            .padding(12)
                    }
                }

                if isNew {
                    section("Lives On", note: machine == nil ? "On this Mac, it works while the Mac is awake." : "On a machine, it keeps working, and wakes itself up, while your Mac is off.") {
                        WellGroup {
                            locationMenu
                            WellDivider()
                            folderMenu
                        }
                    }
                } else if let bot {
                    section("Wake-Ups", note: "The bot schedules these itself, to carry on later.") {
                        WakeList(bot: bot)
                    }
                    section("Memory") {
                        WellGroup {
                            Button {
                                app.utilities.show(RemoteFolder.fileURL(bot.memoryFile, in: bot.directory))
                                dismiss()
                            } label: {
                                WellRow {
                                    Image(systemName: "brain")
                                } content: {
                                    HStack {
                                        Text("Show in the Panel")
                                        Spacer()
                                        Text("MEMORY.md")
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(WellRowButtonStyle())
                        }
                    }
                }

                if let failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !isNew {
                Button("Delete Bot…", role: .destructive) { confirmsDelete = true }
                    .buttonStyle(.glass)
            }
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                Text(isNew ? "Setting it up…" : "Saving…")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.glass)
            Button(isNew ? "Create Bot" : "Save", action: save)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(trimmedName.isEmpty || isWorking)
        }
        .controlSize(.large)
    }

    /// The avatar, large, beside its name and job; shuffling picks a new look.
    private var identity: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(spacing: 8) {
                BotAvatar(look: look, size: 76)
                    .animation(.ui, value: look)
                Button {
                    withAnimation(.ui) { look = .random() }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(TextButtonStyle(outset: true))
                .help("A random look")
            }
            .frame(width: 92)
            WellGroup(isActive: focus == .name || focus == .job) {
                WellRow(isActive: focus == .name) {
                    Image(systemName: "face.smiling")
                } content: {
                    TextField("Name", text: $name, prompt: Text("Name, like Scout"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .focused($focus, equals: .name)
                }
                WellDivider()
                WellRow(isActive: focus == .job) {
                    Image(systemName: "briefcase")
                } content: {
                    TextField("Job", text: $job, prompt: Text("What it does, like Keeps CI green"))
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .job)
                }
            }
        }
    }

    // MARK: Where it lives and works

    private var locationMenu: some View {
        NativeMenuButton(opensBelow: true) {
            let menu = NSMenu()
            menu.addItem(ActionItem("This Mac", image: NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil), checked: machine == nil) {
                machine = nil
                project = nil
            })
            for engine in app.machines.list.compactMap({ app.machines.engine($0.id) }) {
                menu.addItem(ActionItem(engine.machine.name, subtitle: engine.statusText, image: NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil), checked: machine == engine.machine.id) {
                    machine = engine.machine.id
                    project = nil
                    if case .failed = engine.state { app.connect(engine) }
                })
            }
            menu.addItem(.separator())
            menu.addItem(ActionItem("Add Machine…") { showsAddMachine = true })
            return menu
        } label: {
            LocationRow(machine: machine.flatMap { app.machines.engine($0) })
        }
    }

    /// Its own folder, or one of the projects where it lives.
    private var folderMenu: some View {
        let projects = workspace.projects.filter { RemoteFolder.machine(of: $0.directory) == machine }
        return NativeMenuButton(opensBelow: true) {
            let menu = NSMenu()
            menu.addItem(ActionItem("Its Own Folder", subtitle: "A workspace of its own, beside its memory", image: NSImage(systemSymbolName: "folder.badge.person.crop", accessibilityDescription: nil), checked: project == nil) {
                project = nil
            })
            if !projects.isEmpty {
                menu.addItem(.separator())
                menu.addItem(.sectionHeader(title: "Projects"))
                for item in projects {
                    menu.addItem(ActionItem(item.name, image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil), checked: project == item.directory) {
                        project = item.directory
                    })
                }
            }
            return menu
        } label: {
            WellRow {
                Image(systemName: project == nil ? "folder.badge.person.crop" : "folder")
            } content: {
                HStack(spacing: 8) {
                    Text("Works in")
                        .foregroundStyle(.secondary)
                    Text(project.map(workspace.projectName) ?? "Its own folder")
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    MenuChevron()
                }
            }
            .contentShape(.rect)
        }
    }

    // MARK: Saving

    private func save() {
        guard !trimmedName.isEmpty, !isWorking else { return }
        let job = job.trimmingCharacters(in: .whitespacesAndNewlines)
        if var bot {
            bot.name = trimmedName
            bot.job = job
            bot.instructions = instructions
            bot.look = look
            Task { await bots.update(bot) }
            dismiss()
            return
        }
        isWorking = true
        failure = nil
        Task {
            defer { isWorking = false }
            do {
                let bot = try await bots.create(name: trimmedName, job: job, instructions: instructions, look: look, machine: machine, project: project)
                created(bot)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func section(_ title: String, note: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
            if let note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Color, shape and face, each a row of choices drawn as the bot would look with it.
private struct LookPicker: View {
    @Binding var look: BotLook

    var body: some View {
        WellGroup {
            row("Color") {
                ForEach(BotLook.Tint.allCases) { tint in
                    choice(isOn: look.color == tint, help: tint.title) { look.color = tint } label: {
                        Circle()
                            .fill(tint.color)
                            .frame(width: 20, height: 20)
                            .overlay { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1) }
                    }
                }
            }
            WellDivider()
            row("Shape") {
                ForEach(BotLook.Form.allCases) { form in
                    choice(isOn: look.shape == form, help: form.title) { look.shape = form } label: {
                        BotAvatar(look: BotLook(color: look.color, shape: form, face: look.face), size: 26)
                    }
                }
            }
            WellDivider()
            row("Face") {
                ForEach(BotLook.Face.allCases) { face in
                    choice(isOn: look.face == face, help: face.title) { look.face = face } label: {
                        BotAvatar(look: BotLook(color: look.color, shape: look.shape, face: face), size: 26)
                    }
                }
            }
        }
    }

    private func row(_ title: String, @ViewBuilder choices: () -> some View) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
                .padding(.leading, 12)
            HStack(spacing: 6) { choices() }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 46)
    }

    /// One choice: a ring in the accent color when it's the one picked.
    private func choice(isOn: Bool, help: String, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button {
            withAnimation(.ui) { action() }
        } label: {
            label()
                .padding(3)
                .overlay {
                    Circle()
                        .strokeBorder(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A bot's waiting wake-ups, each with a way to cancel it.
private struct WakeList: View {
    let bot: Bot
    @Environment(Bots.self) private var bots

    var body: some View {
        let wakes = bots.wakes[bot.id] ?? []
        WellGroup {
            if wakes.isEmpty {
                WellRow {
                    Image(systemName: "alarm")
                } content: {
                    Text("None waiting")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(wakes.enumerated()), id: \.element.id) { index, wake in
                if index > 0 { WellDivider() }
                WellRow {
                    Image(systemName: "alarm")
                } content: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(wake.due, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                                .font(.system(size: 13, weight: .medium))
                            Text(wake.note)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 8)
                        Spacer(minLength: 8)
                        Button("Cancel Wake-Up", systemImage: "minus.circle.fill") {
                            Task { await bots.cancelWake(wake, of: bot) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(RemoveButtonStyle())
                        .help("Cancel this wake-up")
                    }
                }
            }
        }
        .task { await bots.readWakes(bot) }
    }
}
