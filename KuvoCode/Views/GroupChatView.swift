import OpenCodeKit
import SwiftUI

/// A group chat: what you and its bots said, the one talking now, and where you write. The
/// bots answer one at a time; you can write any time, and the one talking hears it at once.
struct GroupChatView: View {
    let group: BotGroup
    @Environment(BotGroups.self) private var groups
    @Environment(Bots.self) private var bots
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var followsEnd = true
    @State private var isScrolling = false

    private var members: [Bot] { group.members.compactMap { bots.bot($0) } }
    private var draftKey: String { BotGroups.tabKey(group.id) }

    var body: some View {
        let messages = groups.messages(in: group.id)
        let speaker = groups.speaking[group.id].flatMap { bots.bot($0) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(messages) { message in
                    GroupMessageRow(message: message, author: message.author.flatMap { bots.bot($0) }, members: members) {
                        undo(from: message)
                    }
                        .id(message.id)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
                if let speaker {
                    TypingRow(bot: speaker)
                        .id("typing")
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 16)
            .padding(.bottom, 32)
            .readableColumn()
            .animation(.ui, value: messages.map(\.id))
            .animation(.ui, value: speaker?.id)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollPhaseChange { _, phase in isScrolling = phase != .idle }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 40
        } action: { _, atEnd in
            if isScrolling { followsEnd = atEnd }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, new in
            guard followsEnd, !isScrolling, new != old else { return }
            position.scrollTo(edge: .bottom)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .overlay {
            if messages.isEmpty && speaker == nil {
                GroupIntro(group: group, members: members)
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                if groups.paused.contains(group.id) && speaker == nil {
                    PausedBar { groups.keepGoing(group.id) }
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
                GroupComposer(
                    text: Binding(get: { Drafts.shared[draftKey].text }, set: { Drafts.shared[draftKey].text = $0 }),
                    placeholder: "Message \(group.name)…",
                    members: members,
                    isTalking: groups.discussing.contains(group.id),
                    send: send,
                    stop: { groups.stop(group.id) }
                )
            }
            .animation(.ui, value: groups.paused.contains(group.id))
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 16)
            .readableColumn()
        }
        .onAppear { groups.markViewed(group.id) }
        .onChange(of: messages.count) { groups.markViewed(group.id) }
    }

    /// Takes the chat back to before your message, which comes back to the composer, ahead of
    /// anything already there.
    private func undo(from message: GroupMessage) {
        guard let text = groups.undo(from: message.id, in: group.id) else { return }
        let draft = Drafts.shared[draftKey].text
        Drafts.shared[draftKey].text = [text, draft].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private func send() {
        let text = Drafts.shared[draftKey].text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        groups.send(text, to: group.id)
        Drafts.shared[draftKey].text = ""
        followsEnd = true
        position.scrollTo(edge: .bottom)
    }
}

/// One message: yours in a bubble on the right, a bot's beside its face, Kuvo Code's own
/// quietly in the middle.
private struct GroupMessageRow: View {
    let message: GroupMessage
    let author: Bot?
    /// The chat's bots, for their mentions.
    let members: [Bot]
    /// Takes the chat back to before this message of yours.
    let undo: () -> Void
    @State private var hovering = false
    @State private var confirmsUndo = false

    /// Under the pointer; KUVO_DEMO_SHOW_HOVER shows every message's buttons, for screenshots.
    private var isHovering: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["KUVO_DEMO_SHOW_HOVER"] != nil { return true }
        #endif
        return hovering
    }

    var body: some View {
        if message.kind == .note {
            Label(message.text, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        } else if message.author == nil {
            VStack(alignment: .trailing, spacing: 2) {
                UserBubble(text: message.text, styled: GroupMentions.styled(message.text, bots: members))
                // Always laid out, shown under the pointer: nothing moves when they appear.
                HStack(spacing: 0) {
                    Text(MessageTime.sentAt(message.time))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 6)
                    CopyButton(text: message.text, help: "Copy")
                    MessageActionButton(symbol: "arrow.uturn.backward", help: "Undo From Here…") { confirmsUndo = true }
                }
                .opacity(isHovering ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: isHovering)
            }
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Copy") { copy() }
                Divider()
                Button("Undo From Here…") { confirmsUndo = true }
            }
            .alert("Undo from this message?", isPresented: $confirmsUndo) {
                Button("Undo", action: undo)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The chat goes back to before this message, and the message comes back to the composer. The bots are told to set aside what was taken back.")
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                if let author {
                    // Still: the bot moves in its row, or where it's typing.
                    BotAvatar(look: author.look, size: 28, noticed: isHovering, animates: false)
                } else {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(author?.name ?? "A bot that left")
                            .font(.callout.weight(.semibold))
                        if message.kind == .wrapUp {
                            Label("Wrap-Up", systemImage: "checklist")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .recessedWell(Capsule())
                        }
                        Text(message.time, format: .dateTime.hour().minute())
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        // Shown under the pointer, always laid out.
                        CopyButton(text: message.text, help: "Copy")
                            .opacity(isHovering ? 1 : 0)
                            .animation(.easeOut(duration: 0.12), value: isHovering)
                    }
                    .frame(height: 20)
                    MarkdownText(text: message.text, mentions: members)
                }
            }
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Copy") { copy() }
            }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }
}

/// The bot talking now, at work.
private struct TypingRow: View {
    let bot: Bot

    var body: some View {
        HStack(spacing: 10) {
            BotAvatar(look: bot.look, size: 28, mood: .working)
            ShimmerText(text: "\(bot.name) is thinking…")
                .font(.callout)
        }
    }
}

/// Before anything's been said: who's here and how it goes.
private struct GroupIntro: View {
    let group: BotGroup
    let members: [Bot]

    var body: some View {
        let lead = members.first
        VStack(spacing: 12) {
            GroupAvatar(faces: members.map { GroupAvatar.Face(look: $0.look) }, size: 76)
            VStack(spacing: 4) {
                Text(group.name)
                    .font(.title2.weight(.semibold))
                Text(group.purpose.flatMap { $0.isEmpty ? nil : $0 } ?? ListFormatter.localizedString(byJoining: members.map(\.name)))
                    .foregroundStyle(.secondary)
            }
            Text("Bring them something to talk through. \(lead.map { "\($0.name) goes first, the" } ?? "The") others weigh in and answer each other, and \(lead.map { "\($0.name) sums up" } ?? "it's summed up") at the end. Write @ and a name to ask someone directly.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(.bottom, 120)
    }
}

/// A discussion that reached its limit of turns: carry on, or leave it there.
private struct PausedBar: View {
    let keepGoing: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
            Text("Paused after a good few turns, so it doesn’t run on.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Keep Going", action: keepGoing)
                .buttonStyle(.glass)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.composerRadius))
    }
}

/// Where you write to the group: the message, a quick way to ask one of its bots, and send
/// (or stop, while they talk).
private struct GroupComposer: View {
    @Binding var text: String
    let placeholder: String
    let members: [Bot]
    let isTalking: Bool
    let send: () -> Void
    let stop: () -> Void
    @Environment(\.messageFont) private var messageFont
    @FocusState private var isFocused: Bool

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(messageFont.body)
                .lineLimit(1...10)
                .focused($isFocused)
                .onKeyPress(.return, phases: .down) { press in
                    // Return sends; Shift-Return starts a new line.
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                        text += "\n"
                        return .handled
                    }
                    send()
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard isTalking else { return .ignored }
                    stop()
                    return .handled
                }
            HStack(spacing: 2) {
                // Each bot: a click asks it by name.
                ForEach(members) { bot in
                    Button {
                        mention(bot)
                    } label: {
                        BotAvatar(look: bot.look, size: 20, animates: false)
                            .frame(width: 30, height: 28)
                            .hoverHighlight(in: Capsule(), mutesInk: true)
                    }
                    .buttonStyle(.plain)
                    .help("Ask \(bot.name)")
                }
                Spacer(minLength: 0)
                if isTalking && !canSend {
                    Button(action: stop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(ActionButtonStyle(isAccent: false))
                    .glassEffect(.regular, in: .circle)
                    .help("Stop the Discussion (Esc)")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(ActionButtonStyle())
                    .glassEffect(.regular, in: .circle)
                    .disabled(!canSend)
                    .help("Send (Return)")
                }
            }
            .padding(.leading, -8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 7)
        .modifier(ComposerSurface())
        .onAppear { isFocused = true }
    }

    /// "@Mira " where the message goes on.
    private func mention(_ bot: Bot) {
        if !text.isEmpty, !(text.last?.isWhitespace ?? true) { text += " " }
        text += "@\(bot.name) "
        isFocused = true
    }
}
