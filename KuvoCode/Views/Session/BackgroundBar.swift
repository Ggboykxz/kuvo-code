import OpenCodeKit
import SwiftUI

/// Commands the agent left running in the background, in a bar over the composer like the
/// others that say what the agent or its engine is doing (the queue below is only your
/// messages): one line that says so, and under it each command, how long it has run, what it
/// has printed, and Stop. Hidden, the line stays, still drawing itself. When one ends, the engine
/// tells the agent, and it carries on.
struct BackgroundBar: View {
    let jobs: [ShellJob]
    let api: OpenCodeAPI?
    let directory: String
    @Binding var isHidden: Bool
    let stop: (ShellJob) -> Void

    private static let rowHeight: CGFloat = 30
    private static let visibleRows = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isHidden {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(jobs) { job in
                            BackgroundJobRow(job: job, api: api, directory: directory) { stop(job) }
                                .frame(height: Self.rowHeight)
                        }
                    }
                }
                .frame(height: CGFloat(min(jobs.count, Self.visibleRows)) * Self.rowHeight)
                .scrollBounceBehavior(.basedOnSize)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .animation(.ui, value: jobs.map(\.id))
    }

    private var header: some View {
        Button {
            withAnimation(.ui) { isHidden.toggle() }
        } label: {
            HStack(spacing: 10) {
                Spinner(size: 14)
                    .frame(width: 18)
                Text(jobs.count == 1 ? "Running in the background" : "\(jobs.count) commands running in the background")
                    .font(.system(size: 13, weight: .medium))
                if isHidden, jobs.count == 1, let job = jobs.first {
                    Text(job.command.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isHidden ? 180 : 0))
            }
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .frame(height: 36)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isHidden ? "Show what runs in the background" : "Hide them: this line stays while they run")
        .accessibilityLabel(jobs.count == 1 ? "Running in the background" : "\(jobs.count) commands running in the background")
        .accessibilityValue(isHidden ? "Hidden" : "Shown")
    }
}

private struct BackgroundJobRow: View {
    let job: ShellJob
    let api: OpenCodeAPI?
    let directory: String
    let stop: () -> Void
    @State private var showsOutput = false

    var body: some View {
        HStack(spacing: 10) {
            Text(job.command.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(job.command)
            if let started = job.time?.started {
                Text(Date(timeIntervalSince1970: started / 1000), style: .timer)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("How long it has been running")
            }
            Button("Output", systemImage: "text.alignleft") { showsOutput.toggle() }
                .buttonStyle(TextButtonStyle())
                .font(.system(size: 13))
                .help("What it has printed so far")
                .popover(isPresented: $showsOutput, arrowEdge: .top) {
                    ShellOutputView(job: job, api: api, directory: directory)
                }
            Button("Stop", systemImage: "stop.circle") { stop() }
                .buttonStyle(TextButtonStyle())
                .font(.system(size: 13))
                .help("Stop it: the agent hears that it ended, with what it printed")
        }
        // Under the line's words, past its mark.
        .padding(.leading, 42)
        .padding(.trailing, 10)
    }
}

/// The end of what a command has printed, read again every moment while it shows.
private struct ShellOutputView: View {
    let job: ShellJob
    let api: OpenCodeAPI?
    let directory: String
    @State private var text = ""

    /// How much of the end it shows, in bytes.
    private static let tail = 24_000

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Nothing printed yet." : text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .defaultScrollAnchor(.bottom)
        .frame(width: 520, height: 300)
        .task {
            while !Task.isCancelled {
                if let api, let size = try? await api.shellOutput(job.id, limit: 1, directory: directory).size {
                    let start = max(0, size - Self.tail)
                    if let read = try? await api.shellOutput(job.id, from: start, limit: Self.tail, directory: directory) {
                        // Begun partway: from the first whole line.
                        let output = start > 0 ? read.output.drop { $0 != "\n" }.dropFirst() : Substring(read.output)
                        let trimmed = String(output).trimmingCharacters(in: .newlines)
                        if trimmed != text { text = trimmed }
                    }
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}

extension TranscriptView {
    /// The line for a background command's end: how it went, and what it ran.
    static func backgroundEnd(_ notice: Message.Notice) -> String {
        let command = (notice.description ?? "").split(separator: "\n").first.map(String.init) ?? ""
        let short = command.count > 80 ? command.prefix(79) + "…" : Substring(command)
        let exit = notice.metadata?["exit"]?.int
        let stopped = notice.metadata?["signal"]?.string != nil
        let outcome = switch (notice.metadata?["state"]?.string, exit) {
        case _ where stopped: "Background command stopped"
        case ("completed", 0?), ("completed", nil): "Background command finished"
        case (_, let code?) where code != 0: "Background command failed (exit \(code))"
        default: "Background command stopped"
        }
        return short.isEmpty ? outcome : "\(outcome): \(short)"
    }
}
