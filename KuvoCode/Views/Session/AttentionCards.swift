import OpenCodeKit
import SwiftUI

/// The agent wants to do something that needs your OK.
struct PermissionCard: View {
    let request: PermissionRequest
    let directory: String
    let reply: (PermissionRequest.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let message = request.message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let diff = request.diffs.first {
                DiffView(diff: diff, title: relative(diff.file), maxLines: 14)
            } else if !request.resources.isEmpty {
                Text(request.resources.map(relative).joined(separator: "\n"))
                    .transcriptCodeFont()
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Sunk in like a code block, as it's paths and commands.
                    .recessedWell(RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 8) {
                Button("Deny", role: .cancel) { reply(.reject) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Always Allow") { reply(.always) }
                    .help(alwaysHelp)
                Button("Allow") { reply(.once) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .padding(16)
    }

    private var subject: String {
        request.resources.first.map(relative) ?? "this"
    }

    private var title: String {
        switch request.action {
        case "edit", "patch": "Allow editing \(subject)?"
        case "write": "Allow writing \(subject)?"
        case "read": "Allow reading \(subject)?"
        case "shell": request.resources.count > 1 ? "Allow running these commands?" : "Allow running this command?"
        case "external_directory": "Allow working outside the project?"
        case "subagent": "Allow starting the \(subject) agent?"
        case "webfetch": "Allow fetching \(subject)?"
        default: "Allow \(request.action.replacingOccurrences(of: "_", with: " "))?"
        }
    }

    private var symbol: String {
        switch request.action {
        case "edit", "patch", "write": "pencil.circle.fill"
        case "shell": "terminal.fill"
        case "external_directory": "folder.badge.questionmark"
        default: "hand.raised.fill"
        }
    }

    private var alwaysHelp: String {
        let patterns = request.save ?? request.resources
        return patterns.isEmpty ? "Don't ask again for this in this project" : "Don't ask again for: " + patterns.joined(separator: ", ")
    }

    private func relative(_ path: String) -> String {
        let directory = RemoteFolder.parse(directory)?.path ?? directory
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}

/// The agent asked you something (its question tool), or a tool needs details.
struct QuestionCard: View {
    let form: FormRequest
    let submit: (FormAnswer) -> Void
    let dismiss: () -> Void

    @State private var answers: FormAnswer = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text(form.isQuestion ? "The agent has a question" : form.title)
                    .font(.headline)
                Spacer()
                Button("Skip", action: dismiss)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            FormFieldsView(fields: form.fields, answers: $answers, style: .question)
            HStack {
                Spacer()
                Button("Answer") { submit(answers) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!FormFieldsView.isComplete(form.fields, answers))
            }
        }
        .padding(16)
        .onAppear { answers = FormFieldsView.defaults(for: form.fields) }
    }
}
