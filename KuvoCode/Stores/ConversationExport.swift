import Foundation
import OpenCodeKit

/// A conversation as Markdown, to paste into an issue or a chat: your messages, the agent's
/// replies, and a line for each step it took, as the transcript words them.
enum ConversationExport {
    static func markdown(title: String, messages: [Message], directory: String) -> String {
        var blocks = ["# " + title]
        var speaker: String?
        // The agent's steps, listed together until it says something.
        var steps: [String] = []
        func say(_ who: String, _ text: String) {
            if !steps.isEmpty {
                let list = steps.map { "- " + $0 }.joined(separator: "\n")
                steps = []
                say("Agent", list)
            }
            if speaker != who { blocks.append("**\(who)**") }
            speaker = who
            blocks.append(text)
        }
        for message in messages {
            switch message {
            case .user(let user):
                let (withComments, paths) = Attachments.split(CommandMessages.shared.text(of: user))
                let (text, comments) = ReviewComments.split(withComments)
                var lines = comments.map { "> On \($0.location): \($0.text)" }
                if !text.isEmpty { lines.append(text) }
                let attached = (user.files ?? []).compactMap(\.name) + paths.map { ($0 as NSString).lastPathComponent }
                if !attached.isEmpty { lines.append("Attached: " + attached.joined(separator: ", ")) }
                if !lines.isEmpty { say("You", lines.joined(separator: "\n\n")) }
            case .assistant(let assistant):
                for block in assistant.content {
                    switch block {
                    case .text(let text) where !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                        say("Agent", text.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    case .tool(let call):
                        steps.append(ToolCallView.summary(of: call, in: directory))
                    default:
                        break
                    }
                }
            case .shell(let shell):
                let output = shell.output?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                say("You", "Ran `\(shell.command)`" + (output.isEmpty ? "" : "\n\n```\n\(output)\n```"))
            case .compaction:
                say("Agent", "_Summarized the conversation so far._")
            default:
                break
            }
        }
        if !steps.isEmpty { say("Agent", "") }
        return blocks.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    /// The whole conversation, oldest first, without what an undo took back.
    static func messages(of session: Session, api: OpenCodeAPI, pageSize: Int = 200) async throws -> [Message] {
        var page = try await api.messages(session: session.id, limit: pageSize)
        var messages = page.data
        while let cursor = page.cursor?.next ?? page.cursor?.previous, !page.data.isEmpty, messages.count < 20_000 {
            let older = try await api.messages(session: session.id, limit: pageSize, before: cursor)
            guard !older.data.isEmpty, !messages.contains(where: { $0.id == older.data.last?.id }) else { break }
            messages = older.data + messages
            page = older
        }
        if let revert = session.revert, let index = messages.firstIndex(where: { $0.id == revert.messageID }) {
            messages = Array(messages[..<index])
        }
        return messages
    }
}
