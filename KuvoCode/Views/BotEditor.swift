import AppKit
import OpenCodeKit
import SwiftUI

/// Making a bot, or changing one, in the window's main card: how it looks, its name and job,
/// and, for a new one, where it lives and works. An existing bot also shows its waiting wake-ups
/// and its memory.
struct BotEditor: View {
    /// The bot being changed; nil for a new one.
    let bot: Bot?
    /// Back to what was there before.
    let close: () -> Void
    /// Called with the new bot, once it's made.
    var created: (Bot) -> Void = { _ in }

    @Environment(AppModel.self) private var app
    @Environment(Bots.self) private var bots
    @Environment(Workspace.self) private var workspace
    @Environment(Catalog.self) private var catalog
    @LastModel private var lastModel
    @State private var look: BotLook
    /// Its default model.
    @State private var model: ModelRef?
    /// How it talks.
    @State private var personality: String?
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
    /// The template a new bot started from.
    @State private var template: String?
    @State private var isHoveringAvatar = false
    @FocusState private var focus: Field?

    private enum Field { case name, job, instructions }

    /// `recipe`: a shared bot that a new one starts from.
    init(bot: Bot?, recipe: BotRecipe? = nil, close: @escaping () -> Void, created: @escaping (Bot) -> Void = { _ in }) {
        self.bot = bot
        self.close = close
        self.created = created
        _look = State(initialValue: bot?.look ?? recipe?.look ?? .random())
        _name = State(initialValue: bot?.name ?? recipe?.name ?? "")
        _job = State(initialValue: bot?.job ?? recipe?.job ?? "")
        _instructions = State(initialValue: bot?.instructions ?? recipe?.instructions ?? "")
        _machine = State(initialValue: bot?.machine)
        _project = State(initialValue: bot?.project)
        _model = State(initialValue: bot?.model)
        _personality = State(initialValue: bot?.personality ?? recipe?.personalityHere())
    }

    /// The models of the engine where it lives.
    private var placeCatalog: Catalog {
        machine.flatMap { app.machines.engine($0)?.catalog } ?? catalog
    }

    private var isNew: Bool { bot == nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                form
                    .frame(maxWidth: 600)
                    .padding(.horizontal, Metrics.gutter + 8)
                    .padding(.top, 24)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            #if DEBUG
            // KUVO_DEMO_EDIT_BOT=bottom: opens scrolled to its wake-ups and memory.
            .defaultScrollAnchor(ProcessInfo.processInfo.environment["KUVO_DEMO_EDIT_BOT"] == "bottom" ? .bottom : nil)
            #endif
            footer
                .frame(maxWidth: 600)
                .padding(.horizontal, Metrics.gutter + 8)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
        }
        .onAppear {
            if isNew { focus = .name }
            // A bot made before bots had a model: the one its conversation uses.
            if model == nil { model = bot.flatMap { workspace.session($0.sessionID)?.model } ?? lastModel ?? placeCatalog.defaultModel?.ref }
        }
        .sheet(isPresented: $showsAddMachine) {
            MachineSheet { machine = $0; project = nil }
        }
        .alert("Delete \(bot?.name ?? "This Bot")?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) {
                guard let bot else { return }
                close()
                Task { await bots.delete(bot) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its conversation, memory and wake-ups are deleted. This can’t be undone." + (bot?.project != nil ? " The project it worked in isn’t touched." : ""))
        }
    }

    private var form: some View {
            VStack(alignment: .leading, spacing: 20) {
                if isNew {
                    section("Start From", note: "Fills in a name, job and look to change as you like; or start from nothing.") {
                        TemplatePicker(selection: template) { use($0) }
                    }
                }

                identity

                section("Look") {
                    LookPicker(look: $look)
                }

                section("Personality", note: "How it talks, in its own conversation and in group chats.") {
                    PersonalityPicker(selection: $personality)
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

                section("Model", note: "It uses this in group chats, and in its own conversation unless you pick another there.") {
                    WellGroup {
                        ModelChip(selection: model, onSelect: { model = $0 }, opensBelow: true) { current, variant in
                            WellRow {
                                if let current { ProviderLogo(id: current.makerLogoID, size: 16) } else { Image(systemName: "cpu") }
                            } content: {
                                HStack(spacing: 6) {
                                    Text(current?.name ?? "Choose a Model")
                                        .foregroundStyle(.primary)
                                    if let variant {
                                        Text("· \(EffortLevel.title(variant))")
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    MenuChevron()
                                }
                            }
                            .contentShape(.rect)
                        }
                        .environment(placeCatalog)
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
                    // Where it lives stays where it was made.
                    section("Lives On") {
                        WellGroup {
                            WellRow {
                                Image(systemName: bot.machine == nil ? "laptopcomputer" : "server.rack")
                            } content: {
                                HStack(spacing: 8) {
                                    Text(bot.machine.map { app.machines.engine($0)?.machine.name ?? $0 } ?? "This Mac")
                                    if let engine = bot.machine.flatMap({ app.machines.engine($0) }) {
                                        MachineStatus(engine: engine)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                    section("Wake-Ups", note: "The bot schedules these itself: wake-ups to carry on later, and watches, which check something without its model and wake it when that changes. Add a wake-up of your own, and at its time what it says to do arrives in its conversation.") {
                        WakeList(bot: bot)
                    }
                    section("Memory") {
                        WellGroup {
                            Button {
                                app.utilities.show(RemoteFolder.fileURL(bot.memoryFile, in: bot.directory))
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
            if let bot {
                Button("Delete Bot…", role: .destructive) { confirmsDelete = true }
                    .buttonStyle(.glass)
                Button("Export…") { BotRecipe.export(bot) }
                    .buttonStyle(.glass)
                    .help("Save a file to share \(bot.name): its look, job, instructions and personality")
            }
            if isWorking {
                Spinner(size: 16)
                Text(isNew ? "Setting it up…" : "Saving…")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel, action: close)
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
                BotAvatar(look: look, size: 76, noticed: isHoveringAvatar)
                    .onHover { isHoveringAvatar = $0 }
                    // A little bounce at each new look.
                    .keyframeAnimator(initialValue: 1.0, trigger: look) { content, scale in
                        content.scaleEffect(scale, anchor: .bottom)
                    } keyframes: { _ in
                        SpringKeyframe(1.14, duration: 0.14)
                        SpringKeyframe(0.95, duration: 0.14)
                        SpringKeyframe(1.0, duration: 0.24)
                    }
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
            bot.model = model
            bot.personality = personality
            Task { await bots.update(bot) }
            close()
            return
        }
        isWorking = true
        failure = nil
        Task {
            defer { isWorking = false }
            do {
                let bot = try await bots.create(name: trimmedName, job: job, instructions: instructions, look: look, personality: personality, model: model, machine: machine, project: project)
                created(bot)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// Fills the form from a template.
    private func use(_ template: BotTemplate) {
        withAnimation(.ui) {
            self.template = template.id
            name = template.name
            job = template.job
            instructions = template.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            look = template.look
            personality = template.personality
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

/// Bots to start from: each with its look, name and job.
private struct TemplatePicker: View {
    let selection: String?
    let pick: (BotTemplate) -> Void

    var body: some View {
        WellGroup {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 172), spacing: 6)], spacing: 6) {
                ForEach(BotTemplate.all) { template in
                    TemplateTile(template: template, isOn: selection == template.id) { pick(template) }
                }
            }
            .padding(8)
        }
    }

    private struct TemplateTile: View {
        let template: BotTemplate
        let isOn: Bool
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(alignment: .top, spacing: 10) {
                    BotAvatar(look: template.look, size: 30, noticed: isHovering)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.name)
                            .font(.system(size: 13, weight: .semibold))
                        Text(template.job)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isOn ? AnyShapeStyle(.tint.opacity(0.14)) : isHovering ? AnyShapeStyle(Color.primary.opacity(0.06)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
                .contentShape(.rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .accessibilityAddTraits(isOn ? .isSelected : [])
            .help(template.wantsProject ? "Works best in one of your projects" : "")
        }
    }
}

/// Color, shape and face, each a row of choices drawn as the bot would look with it. A picked
/// color has a quiet ring, as in Settings › Appearance; a picked shape or face sits on accent
/// glass, the app's mark for what's selected.
private struct LookPicker: View {
    @Binding var look: BotLook

    var body: some View {
        WellGroup {
            row("Color") {
                ForEach(BotLook.Tint.allCases) { tint in
                    Button {
                        withAnimation(.ui) { look.color = tint }
                    } label: {
                        Circle()
                            .fill(tint.color)
                            .frame(width: 20, height: 20)
                            .overlay { Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5) }
                            .padding(3.5)
                            .overlay {
                                if look.color == tint { Circle().strokeBorder(.primary.opacity(0.55), lineWidth: 1.5) }
                            }
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .help(tint.title)
                    .accessibilityLabel(tint.title)
                    .accessibilityAddTraits(look.color == tint ? .isSelected : [])
                }
            }
            WellDivider()
            row("Shape") {
                ForEach(BotLook.Form.allCases) { form in
                    Tile(isOn: look.shape == form, help: form.title) { look.shape = form } label: {
                        BotAvatar(look: BotLook(color: look.color, shape: form, face: look.face), size: 26, animates: false)
                    }
                }
            }
            WellDivider()
            row("Face") {
                ForEach(BotLook.Face.allCases) { face in
                    Tile(isOn: look.face == face, help: face.title) { look.face = face } label: {
                        BotAvatar(look: BotLook(color: look.color, shape: look.shape, face: face), size: 26, animates: false)
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
            HStack(spacing: 4) { choices() }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 48)
    }

    /// A shape or face to pick: on accent glass when it's the one, a soft fill under the pointer.
    private struct Tile<Label: View>: View {
        let isOn: Bool
        let help: String
        let action: () -> Void
        @ViewBuilder let label: Label
        @State private var isHovering = false

        var body: some View {
            Button {
                withAnimation(.ui) { action() }
            } label: {
                label
                    .frame(width: 38, height: 38)
                    .background(isHovering && !isOn ? Pressable.hoverFill : .clear, in: .rect(cornerRadius: 10))
                    .accentGlass(RoundedRectangle(cornerRadius: 10), isOn: isOn)
                    .contentShape(.rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .help(help)
            .accessibilityLabel(help)
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }
    }
}

/// Its personality: Kuvo Code's, yours, or none, as tiles; the one picked described below; and
/// your own made or changed right here.
private struct PersonalityPicker: View {
    @Binding var selection: String?
    @Environment(Bots.self) private var bots
    /// A personality of yours being made (no ID yet) or changed.
    @State private var draft: Draft?
    @FocusState private var draftFocus: DraftField?

    private struct Draft {
        var id: String?
        var name = ""
        var description = ""
    }

    private enum DraftField { case name, description }

    private var store: Personalities { .shared }
    private var picked: Personality? { store.personality(selection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WellGroup {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 6)], spacing: 6) {
                    Tile(symbol: "circle.dashed", name: "None", isOn: selection == nil) { selection = nil }
                    ForEach(store.all) { personality in
                        Tile(symbol: personality.symbol, name: personality.name, isOn: selection == personality.id) {
                            selection = personality.id
                        }
                        .contextMenu {
                            if personality.isCustom {
                                Button("Edit…") { edit(personality) }
                                Button("Delete", role: .destructive) { delete(personality) }
                            }
                        }
                    }
                    Tile(symbol: "plus", name: "New…", isOn: false, isQuiet: true) {
                        draft = Draft()
                        draftFocus = .name
                    }
                    .help("Write a personality of your own")
                }
                .padding(8)
                WellDivider()
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(picked?.description ?? "No personality of its own: it talks the way its model does.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let picked, picked.isCustom {
                        Button("Edit") { edit(picked) }
                            .buttonStyle(TextButtonStyle())
                        Button("Delete") { delete(picked) }
                            .buttonStyle(TextButtonStyle())
                    }
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .animation(.ui, value: selection)
            }
            if draft != nil { form }
        }
        .animation(.ui, value: draft == nil)
    }

    /// Making or changing one of yours: its name, and how it talks.
    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            WellGroup(isActive: draftFocus != nil) {
                WellRow(isActive: draftFocus == .name) {
                    Image(systemName: "person.crop.circle")
                } content: {
                    TextField("Name", text: Binding(get: { draft?.name ?? "" }, set: { draft?.name = $0 }), prompt: Text("Name, like Night Owl"))
                        .textFieldStyle(.plain)
                        .focused($draftFocus, equals: .name)
                }
                WellDivider()
                TextField("How it talks", text: Binding(get: { draft?.description ?? "" }, set: { draft?.description = $0 }),
                          prompt: Text("How it talks, like Quiet and precise. Explains with examples, and asks before assuming."), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...6)
                    .focused($draftFocus, equals: .description)
                    .padding(12)
            }
            HStack {
                Spacer()
                Button("Cancel") { draft = nil }
                    .buttonStyle(.glass)
                Button(draft?.id == nil ? "Add Personality" : "Save Personality", action: saveDraft)
                    .buttonStyle(.glassProminent)
                    .disabled(!canSave)
            }
        }
        .transition(.opacity.combined(with: .offset(y: -6)))
    }

    private var canSave: Bool {
        guard let draft else { return false }
        return !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func edit(_ personality: Personality) {
        draft = Draft(id: personality.id, name: personality.name, description: personality.description)
        draftFocus = .description
    }

    private func delete(_ personality: Personality) {
        store.delete(personality)
        if selection == personality.id { selection = nil }
        Task { await bots.personalityChanged(personality.id) }
    }

    private func saveDraft() {
        guard canSave, let draft else { return }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = draft.id, var personality = store.personality(id) {
            personality.name = name
            personality.description = description
            store.update(personality)
            Task { await bots.personalityChanged(id) }
        } else {
            selection = store.add(name: name, description: description).id
        }
        self.draft = nil
    }

    /// A personality to pick: on accent glass when it's the one, a soft fill under the pointer.
    private struct Tile: View {
        let symbol: String
        let name: String
        let isOn: Bool
        var isQuiet = false
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button {
                withAnimation(.ui) { action() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 18)
                    Text(name)
                        .lineLimit(1)
                        .foregroundStyle(isQuiet ? .secondary : .primary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(isHovering && !isOn ? Pressable.hoverFill : .clear, in: .rect(cornerRadius: 8))
                .accentGlass(RoundedRectangle(cornerRadius: 8), isOn: isOn)
                .contentShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }
    }
}

/// A bot's waiting wake-ups, each with a way to cancel it, and one of yours to add.
private struct WakeList: View {
    let bot: Bot
    @Environment(Bots.self) private var bots
    /// The wake-up you're adding, while you are.
    @State private var draft: Draft?
    @State private var failure: String?
    @State private var isAdding = false
    @FocusState private var noteFocused: Bool

    private struct Draft {
        var due = Draft.nextHour
        var every: Wakes.Repeat?
        var note = ""

        /// The next hour on the hour, at least a quarter of an hour away.
        static var nextHour: Date {
            let hour = Calendar.current.dateInterval(of: .hour, for: .now)?.end ?? .now.addingTimeInterval(3600)
            return hour.timeIntervalSinceNow < 15 * 60 ? hour.addingTimeInterval(3600) : hour
        }
    }

    /// The repeats to pick from.
    private static let repeats: [Wakes.Repeat?] = [nil, .hours(1), .days(1), .weekdays, .weeks(1)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            list
            if draft != nil { form }
        }
        .animation(.ui, value: draft == nil)
        #if DEBUG
        // KUVO_DEMO_ADD_WAKE=<note>: opens adding a wake-up, every day, with that note;
        // KUVO_DEMO_ADD_WAKE_NOW adds it too.
        .task {
            let environment = ProcessInfo.processInfo.environment
            guard let note = environment["KUVO_DEMO_ADD_WAKE"] else { return }
            draft = Draft(every: .days(1), note: note)
            if environment["KUVO_DEMO_ADD_WAKE_NOW"] != nil {
                try? await Task.sleep(for: .seconds(1))
                add()
            }
        }
        #endif
    }

    private var list: some View {
        let wakes = bots.wakes[bot.id] ?? []
        let watches = bots.watches[bot.id] ?? []
        return WellGroup {
            WellRow {
                Image(systemName: "pause.circle")
            } content: {
                Toggle(isOn: Binding(get: { bots.paused.contains(bot.id) }, set: { pause in Task { await bots.setPaused(pause, bot) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pause Wake-Ups")
                        Text("They wait until you turn this off; the ones that came due meanwhile go then.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.vertical, 8)
            }
            WellDivider()
            if wakes.isEmpty && watches.isEmpty {
                WellRow {
                    Image(systemName: "alarm")
                } content: {
                    Text("None waiting")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(watches.enumerated()), id: \.element.id) { index, watch in
                if index > 0 { WellDivider() }
                WellRow {
                    Image(systemName: "eye")
                } content: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Watches " + (Wakes.Repeat(watch.every)?.words ?? "every \(watch.every)") + ", and wakes when this changes")
                                .font(.system(size: 13, weight: .medium))
                            Text(watch.check)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(watch.note)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 8)
                        Spacer(minLength: 8)
                        Button("Stop Watching", systemImage: "minus.circle.fill") {
                            Task { await bots.cancelWatch(watch, of: bot) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(RemoveButtonStyle())
                        .help("Stop this watch")
                    }
                }
            }
            if !watches.isEmpty && !wakes.isEmpty { WellDivider() }
            ForEach(Array(wakes.enumerated()), id: \.element.id) { index, wake in
                if index > 0 { WellDivider() }
                WellRow {
                    Image(systemName: wake.every == nil ? "alarm" : "repeat")
                } content: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            (Text(wake.due, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                                + Text(wake.every.map { ", then \($0.words)" } ?? ""))
                                .font(.system(size: 13, weight: .medium))
                            Text(wake.note)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 8)
                        Spacer(minLength: 8)
                        Button("Wake Up Now") {
                            Task { try? await bots.wakeNow(wake, of: bot) }
                        }
                        .buttonStyle(TextButtonStyle())
                        .help(wake.every == nil ? "Send this wake-up now, to see the job run" : "Send this wake-up now, to see the job run; it still comes back at its time")
                        Button("Cancel Wake-Up", systemImage: "minus.circle.fill") {
                            Task { await bots.cancelWake(wake, of: bot) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(RemoveButtonStyle())
                        .help("Cancel this wake-up")
                    }
                }
            }
            if draft == nil {
                WellDivider()
                HStack {
                    Button {
                        draft = Draft()
                        failure = nil
                        noteFocused = true
                    } label: {
                        Label("Add Wake-Up…", systemImage: "plus")
                    }
                    .buttonStyle(TextButtonStyle(outset: true))
                    .help("Schedule a wake-up yourself: what the bot does, and when")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .task { await bots.readWakes(bot) }
    }

    /// When, how often, and what the bot does then.
    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            WellGroup(isActive: noteFocused) {
                WellRow {
                    Image(systemName: "clock")
                } content: {
                    HStack(spacing: 10) {
                        PlainDatePicker(date: Binding(get: { draft?.due ?? .now }, set: { draft?.due = $0 }), from: .now)
                            .accessibilityLabel("When")
                        Spacer(minLength: 8)
                        Picker("Repeats", selection: Binding(get: { draft?.every }, set: { draft?.every = $0 })) {
                            ForEach(Self.repeats, id: \.self) { every in
                                Text(every.map { $0.words.prefix(1).uppercased() + $0.words.dropFirst() } ?? "Once").tag(every)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .padding(.vertical, 6)
                }
                WellDivider()
                TextField("What to do", text: Binding(get: { draft?.note ?? "" }, set: { draft?.note = $0 }),
                          prompt: Text("What \(bot.name) does then, like Send me the morning digest"), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...5)
                    .focused($noteFocused)
                    .padding(12)
            }
            HStack {
                if let failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { draft = nil }
                    .buttonStyle(.glass)
                Button("Add Wake-Up", action: add)
                    .buttonStyle(.glassProminent)
                    .disabled(isAdding || (draft?.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
            }
        }
        .transition(.opacity.combined(with: .offset(y: -6)))
    }

    private func add() {
        guard let draft, !isAdding else { return }
        isAdding = true
        Task {
            defer { isAdding = false }
            do {
                try await bots.addWake(to: bot, at: draft.due, every: draft.every, note: draft.note)
                self.draft = nil
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
