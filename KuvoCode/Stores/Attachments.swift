import AppKit
import OpenCodeKit
import UniformTypeIdentifiers

/// Gets what the user attached ready for the engine. The engine gives the model text,
/// images (PNG, JPEG, GIF, WebP), PDFs and folder listings, up to 20 MB each, and drops
/// anything else. So other image formats are converted first, and files the model can't
/// take (an archive, a video, an image for a model without vision, anything too big)
/// go as paths in a note, for the agent to open with its tools.
nonisolated enum Attachments {
    static let maxBytes = 20 * 1024 * 1024
    private static let engineImageTypes: [UTType] = [.png, .jpeg, .gif, .webP]

    enum Kind { case text, image, pdf, folder, other }

    struct Prepared {
        var files: [OpenCodeAPI.PromptFile] = []
        /// Sent as paths, in the note.
        var paths: [String] = []
    }

    /// Where pasted images and converted copies are kept.
    static var directory: URL {
        AppInfo.supportDirectory.appending(path: "Attachments")
    }

    static func kind(of url: URL) -> Kind {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        if values?.isDirectory == true { return .folder }
        if let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .text) { return .text }
        }
        // Makefile, .env, a log without an extension: the engine reads these as text too.
        return looksLikeText(url) ? .text : .other
    }

    /// How a file will be sent to `model`.
    enum Route {
        case content
        /// As a path, with why (shown on the composer's chip). A warning means the model
        /// would have read it, if it could.
        case path(reason: String, isWarning: Bool)
    }

    static func route(_ url: URL, for model: Model?) -> Route {
        let input = model?.capabilities.input
        let name = model?.name ?? "This model"
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let tooBig = Route.path(reason: "It's over 20 MB, so the agent gets its path and opens it with its tools.", isWarning: true)
        switch kind(of: url) {
        case .folder:
            return .content
        case .text:
            return size <= maxBytes ? .content : tooBig
        case .pdf:
            if input.map({ !$0.contains("pdf") }) == true { return .path(reason: "\(name) can't read PDFs, so the agent gets its path and opens it with its tools.", isWarning: true) }
            return size <= maxBytes ? .content : tooBig
        case .image:
            if input.map({ !$0.contains("image") }) == true { return .path(reason: "\(name) can't see images, so the agent gets its path instead.", isWarning: true) }
            return .content
        case .other:
            return .path(reason: "The model can't read this kind of file directly, so the agent gets its path and opens it with its tools.", isWarning: false)
        }
    }

    /// Splits `urls` into files the engine gets and paths for the note, for `model`.
    static func prepare(_ urls: [URL], for model: Model?) -> Prepared {
        var prepared = Prepared()
        for url in urls {
            switch route(url, for: model) {
            case .content where kind(of: url) == .image:
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if let file = engineImage(from: url, size: size) {
                    prepared.files.append(file)
                } else {
                    prepared.paths.append(url.path)
                }
            case .content:
                prepared.files.append(.init(uri: url.absoluteString, name: url.lastPathComponent))
            case .path:
                prepared.paths.append(url.path)
            }
        }
        return prepared
    }

    /// The image as a format and size the engine takes, converting it if needed.
    private static func engineImage(from url: URL, size: Int) -> OpenCodeAPI.PromptFile? {
        let type = UTType(filenameExtension: url.pathExtension)
        if size <= maxBytes, let type, engineImageTypes.contains(where: { type.conforms(to: $0) }) {
            return .init(uri: url.absoluteString, name: url.lastPathComponent)
        }
        guard let image = NSImage(contentsOf: url), let copy = save(image, named: url.deletingPathExtension().lastPathComponent) else { return nil }
        return .init(uri: copy.absoluteString, name: url.lastPathComponent)
    }

    // MARK: The note

    private static let noteStart = "<attached-files>"
    private static let noteEnd = "</attached-files>"

    /// The message text with the note for files sent as paths.
    static func text(_ text: String, adding paths: [String]) -> String {
        guard !paths.isEmpty else { return text }
        let note = [noteStart, "Open these attached files with your tools if you need them:"] + paths + [noteEnd]
        return (text.isEmpty ? "" : text + "\n\n") + note.joined(separator: "\n")
    }

    /// A message's text without the note, and the paths it listed.
    static func split(_ text: String) -> (text: String, paths: [String]) {
        guard let start = text.range(of: noteStart, options: .backwards),
              let end = text.range(of: noteEnd, range: start.upperBound..<text.endIndex) else { return (text, []) }
        let paths = text[start.upperBound..<end.lowerBound]
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
        let rest = (text[..<start.lowerBound] + text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (rest, paths)
    }

    // MARK: Files we write

    /// Saves a pasted or converted image as PNG (JPEG for opaque photos, which would
    /// otherwise be huge), and returns where.
    static func save(_ image: NSImage, named name: String) -> URL? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        let opaque = !bitmap.hasAlpha
        let large = bitmap.pixelsWide * bitmap.pixelsHigh > 4_000_000
        let (data, ext) = opaque && large
            ? (bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]), "jpg")
            : (bitmap.representation(using: .png, properties: [:]), "png")
        guard let data else { return nil }
        return write(data, named: name, extension: ext)
    }

    /// A unique file in the attachments folder.
    static func write(_ data: Data, named name: String, extension ext: String) -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory.appending(path: "\(name).\(ext)")
            var counter = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = directory.appending(path: "\(name) \(counter).\(ext)")
                counter += 1
            }
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// A name like the system's screenshots: "Pasted Image 2026-10-13 at 15.32.10".
    static var pastedImageName: String {
        "Pasted Image " + Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)", timeZone: .current, calendar: .current))
    }

    private static func looksLikeText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8192), !data.isEmpty else { return false }
        if data.contains(0) { return false }
        // A multi-byte character can be cut at the end of the sample.
        return (0...3).contains { String(data: data.dropLast($0), encoding: .utf8) != nil }
    }
}
