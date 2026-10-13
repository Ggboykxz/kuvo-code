import AppKit
import OpenCodeKit
import SwiftUI
import UniformTypeIdentifiers

/// Something attached to a message: kept by the engine, still on its way (a local file),
/// or sent as a path for the agent to open.
nonisolated enum AttachmentItem: Identifiable, Sendable {
    case stored(Message.User.Attachment, id: String)
    case local(URL)
    case path(String)

    var id: String {
        switch self {
        case .stored(_, let id): id
        case .local(let url): url.absoluteString
        case .path(let path): "path:" + path
        }
    }

    var name: String {
        switch self {
        case .stored(let file, _): file.name ?? file.fileURL?.lastPathComponent ?? "Attachment"
        case .local(let url): url.lastPathComponent
        case .path(let path): (path as NSString).lastPathComponent
        }
    }

    /// The file on disk, if it's still there.
    var fileURL: URL? {
        let url: URL? = switch self {
        case .stored(let file, _): file.fileURL
        case .local(let url): url
        case .path(let path): URL(filePath: path)
        }
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// From the file name first (a `.swift` file is more than "text"), then the stored type.
    var type: UTType? {
        let byName = UTType(filenameExtension: (name as NSString).pathExtension)
        if case .stored(let file, _) = self { return byName ?? UTType(mimeType: file.mime) }
        return byName
    }

    var isImage: Bool { type?.conforms(to: .image) == true }

    /// "PNG image · 1.2 MB".
    var detail: String {
        let kind = isFolder ? "Folder" : type?.localizedDescription?.capitalizedFirst ?? "File"
        guard let bytes = byteCount, !isFolder else { return kind }
        return kind + " · " + bytes.formatted(.byteCount(style: .file))
    }

    private var isFolder: Bool {
        if case .stored(let file, _) = self { return file.mime == "application/x-directory" }
        return (try? fileURL?.resourceValues(forKeys: [.isDirectoryKey]))??.isDirectory == true
    }

    private var byteCount: Int? {
        if case .stored(let file, _) = self, let data = file.data { return data.count * 3 / 4 }
        return (try? fileURL?.resourceValues(forKeys: [.fileSizeKey]))??.fileSize
    }

    func loadImage() async -> NSImage? {
        if let cached = AttachmentImages.cache.object(forKey: id as NSString) { return cached }
        let item = self
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            if let url = item.fileURL, let image = NSImage(contentsOf: url) { return image }
            if case .stored(let file, _) = item, let bytes = file.bytes { return NSImage(data: bytes) }
            return nil
        }.value
        if let image { AttachmentImages.cache.setObject(image, forKey: id as NSString) }
        return image
    }

    /// Opens it in its app; a pasted image that only the engine has is written out first.
    func open() {
        if let url = fileURL {
            NSWorkspace.shared.open(url)
        } else if case .stored(let file, _) = self, let bytes = file.bytes {
            let ext = type?.preferredFilenameExtension ?? (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            if let url = Attachments.write(bytes, named: base, extension: ext.isEmpty ? "dat" : ext) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func revealInFinder() {
        if let url = fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

/// Decoded pictures, so scrolling the transcript doesn't decode them again. NSCache is thread-safe.
nonisolated enum AttachmentImages {
    nonisolated(unsafe) static let cache = NSCache<NSString, NSImage>()
}

nonisolated private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - In the composer

/// A file waiting to be sent: a preview or its icon, its name and kind, and a remove
/// button. Files that go as a path say so (in orange when the model can't read them);
/// the reason shows on hover.
struct ComposerAttachment: View {
    let url: URL
    var route: Attachments.Route = .content
    let remove: () -> Void
    @State private var isHovering = false

    var body: some View {
        let item = AttachmentItem.local(url)
        HStack(spacing: 8) {
            AttachmentIcon(item: item, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isPath ? "Sent as a path" : item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .frame(maxWidth: 170, alignment: .leading)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .gray)
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .opacity(isHovering ? 1 : 0)
            .help("Remove")
        }
        .onHover { isHovering = $0 }
        .help(reason.map { "\(url.path)\n\($0)" } ?? url.path)
    }

    private var reason: String? {
        if case .path(let reason, _) = route { return reason }
        return nil
    }

    private var isPath: Bool { reason != nil }

    private var isWarning: Bool {
        if case .path(_, let isWarning) = route { return isWarning }
        return false
    }
}

/// A thumbnail for images, the file's own icon otherwise.
private struct AttachmentIcon: View {
    let item: AttachmentItem
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image, item.isImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: 6))
            } else {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: size, height: size)
            }
        }
        .task(id: item.id) { if item.isImage { image = await item.loadImage() } }
    }

    private var icon: NSImage {
        if let url = item.fileURL { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: item.type ?? .data)
    }
}

// MARK: - In the transcript

/// A message's attachments, above its text: images as pictures, other files as rows.
struct MessageAttachments: View {
    let items: [AttachmentItem]

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            let images = items.filter(\.isImage)
            if !images.isEmpty {
                TrailingFlow(spacing: 6) {
                    ForEach(images) { item in
                        AttachmentPicture(item: item, height: images.count == 1 ? 220 : 140)
                    }
                }
            }
            ForEach(items.filter { !$0.isImage }) { item in
                AttachmentRow(item: item)
            }
        }
    }
}

private struct AttachmentPicture: View {
    let item: AttachmentItem
    let height: CGFloat
    @State private var image: NSImage?

    private static let maxWidth: CGFloat = 360

    var body: some View {
        Group {
            if let image {
                let size = fitted(image.size)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.fill.tertiary)
                    .frame(width: height * 1.4, height: height)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
        .contentShape(.rect(cornerRadius: 12))
        .onTapGesture(count: 2) { item.open() }
        .contextMenu { AttachmentMenu(item: item) }
        .help("\(item.name) — double-click to open")
        .task(id: item.id) { image = await item.loadImage() }
    }

    /// The picture's own shape, at most `height` tall and `maxWidth` wide, never enlarged.
    private func fitted(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: height, height: height) }
        let scale = min(Self.maxWidth / size.width, height / size.height, 1)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

private struct AttachmentRow: View {
    let item: AttachmentItem

    var body: some View {
        Button(action: item.open) {
            HStack(spacing: 10) {
                AttachmentIcon(item: item, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 260, alignment: .leading)
            }
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .background(.fill.tertiary, in: .rect(cornerRadius: 14))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .contextMenu { AttachmentMenu(item: item) }
        .help(item.fileURL?.path ?? item.name)
    }
}

private struct AttachmentMenu: View {
    let item: AttachmentItem

    var body: some View {
        Button("Open") { item.open() }
        Button("Show in Finder") { item.revealInFinder() }
            .disabled(item.fileURL == nil)
    }
}

/// Lays views out in rows that wrap, aligned to the trailing edge (like a sent message).
private struct TrailingFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.maxX - row.width
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, next > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
