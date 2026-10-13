import OpenCodeKit
import SwiftUI

/// What the agent changed in the latest turn, file by file.
struct ChangesInspector: View {
    let model: SessionModel

    var body: some View {
        Group {
            if model.changes.isEmpty {
                ContentUnavailableView("No Changes", systemImage: "doc.text.magnifyingglass", description: Text("Files the agent edits in this turn show up here."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("\(model.changes.count) \(model.changes.count == 1 ? "file" : "files") changed")
                                .font(.headline)
                            Spacer()
                            DiffStat(additions: model.changes.reduce(0) { $0 + $1.additions }, deletions: model.changes.reduce(0) { $0 + $1.deletions })
                        }
                        ForEach(model.changes) { diff in
                            DiffView(diff: diff, title: relative(diff.file), maxLines: 400)
                                .contextMenu {
                                    Button("Show in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: absolute(diff.file))])
                                    }
                                    Button("Open") { NSWorkspace.shared.open(URL(filePath: absolute(diff.file))) }
                                }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .animation(.ui, value: model.changes.map(\.file))
    }

    private var directory: String { model.session.location.directory }

    private func relative(_ path: String) -> String {
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    private func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path)
    }
}
