import OpenCodeKit
import SwiftUI

/// A group chat: what you and its bots said, the one talking now, and where you write. The
/// bots answer one at a time; you can write any time, and the one talking hears it at once.
struct GroupChatView: View {
    let group: BotGroup
    @Environment(BotGroups.self) private var groups
    @Environment(Bots.self) private var bots
    @State private var scroller = ConversationScroller()
    /// Goes up to have the composer take the keyboard.
    @State private var composerFocus = 0
    /// The quote whose answer takes the keyboard: the one just added.
    @State private var quoteFocus: UUID?

    private var members: [Bot] { group.members.compactMap { bots.bot($0) } }
    private var draftKey: String { BotGroups.tabKey(group.id) }

    var body: some View {
        let messages = groups.messages(in: group.id)
        let speaker = groups.speaking[group.id].flatMap { bots.bot($0) }
        // What you select, to reply to (over the composer) or copy.
        ConversationScroll(scroller: scroller, spacing: 18, change: [messages.last?.id, speaker?.id, String(messages.count)], quote: { text in
            addQuote(text, how: "selection")
        }) {
            ForEach(messages) { message in
                GroupMessageRow(message: message, author: message.author.flatMap { bots.bot($0) }, members: members,
                                reply: { reply(to: message) }) {
                    undo(from: message)
                }
                    .equatable()
                    .id(message.id)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
            if let speaker {
                TypingRow(bot: speaker)
                    .id("typing")
                    .transition(.opacity)
            }
        }
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
                    quotes: Binding(get: { Drafts.shared[draftKey].quotes }, set: { Drafts.shared[draftKey].quotes = $0 }),
                    quoteFocus: quoteFocus,
                    placeholder: "Message \(group.name)…",
                    members: members,
                    isTalking: groups.discussing.contains(group.id),
                    focusRequest: composerFocus,
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

    /// Replies to a bot's message: all of it quoted in the composer, naming the bot so it's the
    /// one to answer.
    private func reply(to message: GroupMessage) {
        addQuote(message.text, how: "message")
        // Named, so it's the one to answer.
        if let name = message.author.flatMap({ bots.bot($0)?.name }), !Drafts.shared[draftKey].text.contains("@" + name) {
            let draft = Drafts.shared[draftKey].text.trimmingCharacters(in: .whitespacesAndNewlines)
            Drafts.shared[draftKey].text = "@\(name) " + draft
        }
    }

    /// A quote to answer, after those there are, as in a session; its answer takes the keyboard.
    private func addQuote(_ text: String, how: String) {
        let count = Drafts.shared[draftKey].quotes.count
        guard let id = Drafts.shared.addQuote(text, to: draftKey) else { return }
        quoteFocus = id
        if Drafts.shared[draftKey].quotes.count > count { Analytics.shared.track("message_replied", ["group": true, "how": how]) }
    }

    /// Takes the chat back to before your message, which comes back to the composer, ahead of
    /// anything already there.
    private func undo(from message: GroupMessage) {
        guard let taken = groups.undo(from: message.id, in: group.id) else { return }
        let (quotes, text) = Quoting.draft(of: taken)
        let draft = Drafts.shared[draftKey].text
        Drafts.shared[draftKey].text = [text, draft].filter { !$0.isEmpty }.joined(separator: "\n\n")
        Drafts.shared[draftKey].quotes = quotes + Drafts.shared[draftKey].quotes
        composerFocus += 1
    }

    private func send() {
        let draft = Drafts.shared[draftKey]
        let message = Quoting.message(quotes: draft.quotes, text: draft.text)
        // A quote you didn't answer goes only with words of yours.
        guard !Quoting.words(of: message).isEmpty else { return }
        groups.send(message, to: group.id)
        Drafts.shared[draftKey].text = ""
        Drafts.shared[draftKey].quotes = []
        scroller.toEnd()
    }
}

/// A meeting you scheduled, come due: its topic, which the bots then talk through.
private struct MeetingRow: View {
    let topic: String
    let at: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "calendar")
                .foregroundStyle(.tint)
                .frame(width: 16)
            Text("\(Text("Meeting").fontWeight(.semibold).foregroundStyle(.primary))  \(Text(topic).foregroundStyle(.secondary))")
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Text(at, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .recessedWell(RoundedRectangle(cornerRadius: 10))
        .help("A meeting you scheduled for this chat")
    }
}

/// One message: yours in a bubble on the right, a bot's beside its face, Kuvo Code's own
/// quietly in the middle.
/// Equal when what it shows is (its actions are the chat's own), so a new message draws only
/// itself.
private struct GroupMessageRow: View, Equatable {
    static func == (lhs: GroupMessageRow, rhs: GroupMessageRow) -> Bool {
        lhs.message == rhs.message && lhs.author == rhs.author && lhs.members == rhs.members && (lhs.reply == nil) == (rhs.reply == nil)
    }

    let message: GroupMessage
    let author: Bot?
    /// The chat's bots, for their mentions.
    let members: [Bot]
    /// Quotes this bot's message (or the part you selected) in the composer.
    var reply: (() -> Void)?
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
        if message.kind == .meeting {
            MeetingRow(topic: message.text, at: message.time)
        } else if message.kind == .note {
            Label(message.text, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        } else if message.author == nil {
            VStack(alignment: .trailing, spacing: 2) {
                UserBubble(text: message.text, style: { GroupMentions.styled($0, bots: members) })
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
                        HStack(spacing: 0) {
                            CopyButton(text: message.text, help: "Copy")
                            if let reply {
                                MessageActionButton(symbol: "arrowshape.turn.up.left", help: "Reply: quotes the part you selected (or the whole message), naming \(author?.name ?? "the bot")", action: reply)
                            }
                        }
                        .opacity(isHovering ? 1 : 0)
                        .animation(.easeOut(duration: 0.12), value: isHovering)
                    }
                    .frame(height: 20)
                    // As a session shows them, at the detail you chose for steps.
                    if let steps = message.steps, !steps.isEmpty {
                        StepsRow(blocks: steps.map(Message.Content.tool), isLive: false, directory: author?.directory ?? "")
                            .padding(.bottom, 2)
                    }
                    MarkdownText(text: message.text, mentions: members)
                }
            }
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Copy") { copy() }
                if let reply { Button("Reply", action: reply) }
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
    /// What you're replying to, each with your answer to it under it, as in a session.
    @Binding var quotes: [Drafts.Quote]
    /// The quote whose answer takes the keyboard (the one just added).
    var quoteFocus: UUID?
    let placeholder: String
    let members: [Bot]
    let isTalking: Bool
    /// Goes up when the composer should take the keyboard (a reply put a quote in it).
    var focusRequest = 0
    let send: () -> Void
    let stop: () -> Void
    @Environment(\.messageFont) private var messageFont
    @FocusState private var isFocused: Bool
    @FocusState private var answering: UUID?

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || quotes.contains { !$0.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !quotes.isEmpty {
                QuoteList(quotes: $quotes, answering: $answering, focus: quoteFocus, font: messageFont.body, onSubmit: send)
            }
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(messageFont.body)
                .lineLimit(1...10)
                .focused($isFocused)
                .onChange(of: focusRequest) { focusAtEnd() }
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
                SendStopButton(stops: isTalking, canSend: canSend, sendHelp: "Send (Return)", stopHelp: "Stop the Discussion (Esc)", send: send, stop: stop)
            }
            .padding(.leading, -8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 7)
        .modifier(ComposerSurface())
        .onAppear(perform: focusAtEnd)
        .onChange(of: quoteFocus) { _, id in answering = id }
    }

    /// The keyboard, with the cursor after what's written, as in a session.
    private func focusAtEnd() {
        isFocused = true
        Composer.cursorToEnd(of: text)
    }

    /// "@Mira " where the message goes on.
    private func mention(_ bot: Bot) {
        if !text.isEmpty, !(text.last?.isWhitespace ?? true) { text += " " }
        text += "@\(bot.name) "
        isFocused = true
    }
}
