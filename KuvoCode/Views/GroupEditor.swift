import AppKit
import SwiftUI

/// Making a group chat, or changing one, in the window's main card: its name, its bots, and
/// which of them leads.
struct GroupEditor: View {
    /// The chat being changed; nil for a new one.
    let group: BotGroup?
    /// Makes a bot, when there aren't enough for a chat.
    let newBot: () -> Void
    /// Back to what was there before.
    let close: () -> Void
    /// Called with the new chat, once it's made.
    var created: (BotGroup) -> Void = { _ in }

    @Environment(Bots.self) private var bots
    @Environment(BotGroups.self) private var groups
    @State private var name: String
    @State private var purpose: String
    /// Its bots, in order: the first leads.
    @State private var members: [String]
    @State private var confirmsDelete = false
    @FocusState private var focus: Field?

    private enum Field { case name, purpose }

    init(group: BotGroup?, newBot: @escaping () -> Void, close: @escaping () -> Void, created: @escaping (BotGroup) -> Void = { _ in }) {
        self.group = group
        self.newBot = newBot
        self.close = close
        self.created = created
        _name = State(initialValue: group?.name ?? "")
        _purpose = State(initialValue: group?.purpose ?? "")
        _members = State(initialValue: group?.members ?? [])
    }

    private var isNew: Bool { group == nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var picked: [Bot] { members.compactMap { bots.bot($0) } }
    private var canSave: Bool { !trimmedName.isEmpty && picked.count >= 2 }

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
            footer
                .frame(maxWidth: 600)
                .padding(.horizontal, Metrics.gutter + 8)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
        }
        .onAppear { if isNew { focus = .name } }
        .alert("Delete \(group?.name ?? "This Group Chat")?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) {
                guard let group else { return }
                close()
                Task { await groups.delete(group) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its messages are deleted, and its bots stop remembering it. This can’t be undone.")
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Its picture and who's in it, beside its name and what it's for, as a bot's editor has
            // its face beside its name and job.
            HStack(alignment: .center, spacing: 18) {
                VStack(spacing: 8) {
                    Group {
                        if picked.isEmpty {
                            Image(systemName: "person.2")
                                .font(.system(size: 30, weight: .light))
                                .foregroundStyle(.tertiary)
                        } else {
                            GroupAvatar(faces: picked.map { GroupAvatar.Face(look: $0.look) }, size: 76)
                        }
                    }
                    .frame(width: 76, height: 76)
                    Text(picked.isEmpty ? "No bots yet" : picked.count == 1 ? "1 bot" : "\(picked.count) bots")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .frame(width: 92)
                .animation(.ui, value: members)
                WellGroup(isActive: focus != nil) {
                    WellRow(isActive: focus == .name) {
                        Image(systemName: "bubble.left.and.bubble.right")
                    } content: {
                        TextField("Name", text: $name, prompt: Text("Name, like Release Planning"))
                            .textFieldStyle(.plain)
                            .font(.system(size: 15, weight: .medium))
                            .focused($focus, equals: .name)
                    }
                    WellDivider()
                    WellRow(isActive: focus == .purpose) {
                        Image(systemName: "target")
                    } content: {
                        TextField("Purpose", text: $purpose, prompt: Text("What it's for, like Plan each week's release"))
                            .textFieldStyle(.plain)
                            .focused($focus, equals: .purpose)
                    }
                }
                // The rows keep their height; the picture beside them is taller.
                .fixedSize(horizontal: false, vertical: true)
            }

            section("Bots", note: "Pick two or more. They answer one at a time, and each remembers the chat in its own conversation.") {
                WellGroup {
                    ForEach(Array(bots.list.enumerated()), id: \.element.id) { index, bot in
                        if index > 0 { WellDivider() }
                        MemberRow(bot: bot, isOn: members.contains(bot.id)) {
                            withAnimation(.ui) {
                                if let index = members.firstIndex(of: bot.id) { members.remove(at: index) } else { members.append(bot.id) }
                            }
                        }
                    }
                    if bots.list.count < 2 {
                        if !bots.list.isEmpty { WellDivider() }
                        Button(action: newBot) {
                            WellRow {
                                Image(systemName: "plus.circle")
                            } content: {
                                Text(bots.list.isEmpty ? "Make a Bot" : "Make Another Bot")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(WellRowButtonStyle())
                    }
                }
            }

            if picked.count >= 2 {
                section("Leads", note: "The lead speaks first, keeps it on track and sums up at the end.") {
                    WellGroup {
                        leadMenu
                    }
                }
            }
        }
    }

    private var leadMenu: some View {
        NativeMenuButton(opensBelow: true) {
            let menu = NSMenu()
            for bot in picked {
                menu.addItem(ActionItem(bot.name, subtitle: bot.job.isEmpty ? nil : bot.job, checked: bot.id == members.first) {
                    withAnimation(.ui) {
                        members.removeAll { $0 == bot.id }
                        members.insert(bot.id, at: 0)
                    }
                })
            }
            return menu
        } label: {
            WellRow {
                if let lead = picked.first { BotAvatar(look: lead.look, size: 22, animates: false) } else { Image(systemName: "star") }
            } content: {
                HStack(spacing: 8) {
                    Text(picked.first?.name ?? "")
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    MenuChevron()
                }
            }
            .contentShape(.rect)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !isNew {
                Button("Delete Group Chat…", role: .destructive) { confirmsDelete = true }
                    .buttonStyle(.glass)
            }
            Spacer()
            Button("Cancel", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.glass)
            Button(isNew ? "Start Group Chat" : "Save", action: save)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(!canSave)
        }
        .controlSize(.large)
    }

    private func save() {
        guard canSave else { return }
        let members = picked.map(\.id)
        let purpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        if var group {
            group.name = trimmedName
            group.purpose = purpose.isEmpty ? nil : purpose
            group.members = members
            Task { await groups.update(group) }
            close()
        } else {
            created(groups.create(name: trimmedName, purpose: purpose.isEmpty ? nil : purpose, members: members))
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

/// A bot to have in the chat or not: its face, name and job, and a check when it's in.
private struct MemberRow: View {
    let bot: Bot
    let isOn: Bool
    let toggle: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                BotAvatar(look: bot.look, size: 26, noticed: isHovering, animates: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bot.name)
                    if !bot.job.isEmpty {
                        Text(bot.job)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 50)
            .background(isHovering ? Pressable.hoverFill : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
