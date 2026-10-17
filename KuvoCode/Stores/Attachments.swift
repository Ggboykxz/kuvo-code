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
        /// Where the files sent with their contents are, in the note too: the model gets what's in
        /// them, and their names, but not where they are, so it went looking for them.
        var included: [String] = []
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
                    prepared.included.append(url.path)
                } else {
                    prepared.paths.append(url.path)
                }
            case .content:
                prepared.files.append(.init(uri: url.absoluteString, name: url.lastPathComponent))
                prepared.included.append(url.path)
            case .path:
                prepared.paths.append(url.path)
            }
        }
        return prepared
    }

    /// The same, for an engine on `machine`, which can't read this Mac's files: what the model
    /// takes goes inline, as data (a folder as its listing, as the engine lists one); anything
    /// else is copied to the machine, into Kuvo Code's folder there, for the agent to open with
    /// its tools. A file that can't be copied goes as a note that it's on the user's Mac. Where
    /// the inline ones are on the Mac isn't said: the agent there couldn't open them.
    static func prepare(_ urls: [URL], for model: Model?, machine: String) -> Prepared {
        let here = prepare(urls, for: model)
        var prepared = Prepared()
        for file in here.files {
            guard let url = URL(string: file.uri), url.isFileURL else { continue }
            if let inline = inlined(url) {
                prepared.files.append(.init(uri: inline, name: file.name))
            } else {
                prepared.paths.append(url.path)
            }
        }
        let batch = String(UUID().uuidString.prefix(8)).lowercased()
        for path in here.paths {
            prepared.paths.append(RemoteShell.upload(URL(filePath: path), into: "\(RemoteEngineInstaller.root)/attachments/\(batch)", on: machine)
                ?? "\(path) (on the user's Mac: it couldn't be copied to this machine)")
        }
        return prepared
    }

    /// A file as a data URI, or a folder as the engine lists one; nil when it can't be read.
    private static func inlined(_ url: URL) -> String? {
        if kind(of: url) == .folder {
            guard let names = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
            let entries = names.map { entry in
                let isFolder = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                return (name: entry.lastPathComponent + (isFolder ? "/" : ""), isFolder: isFolder)
            }
            .sorted { $0.isFolder != $1.isFolder ? $0.isFolder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return "data:text/plain;base64," + Data(entries.map(\.name).joined(separator: "\n").utf8).base64EncodedString()
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        let mime = kind(of: url) == .text ? "text/plain" : (type?.preferredMIMEType ?? "application/octet-stream")
        return "data:\(mime);base64," + data.base64EncodedString()
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

    private static let includedHeading = "The attached files are on disk here (what's in them is in this message already):"
    private static let pathsHeading = "Open these attached files with your tools if you need them:"
    private static let note = MessageBlock(start: "<attached-files>", end: "</attached-files>", headings: [includedHeading, pathsHeading])

    /// The message text with the note: where the files sent with it are, and the files sent as
    /// paths.
    static func text(_ text: String, for prepared: Prepared) -> String {
        let text = note.escaping(text)
        var lines: [String] = []
        if !prepared.included.isEmpty { lines += [includedHeading] + prepared.included }
        if !prepared.paths.isEmpty { lines += [pathsHeading] + prepared.paths }
        guard !lines.isEmpty else { return text }
        return (text.isEmpty ? "" : text + "\n\n") + ([note.start] + lines + [note.end]).joined(separator: "\n")
    }

    /// A message's text without the note that ends it, and the paths of the files it sent as
    /// paths (the others are the message's own files).
    static func split(_ text: String) -> (text: String, paths: [String]) {
        guard let (before, lines) = note.split(text) else { return (text, []) }
        var heading = ""
        var paths: [String] = []
        for line in lines.map(String.init) {
            if note.headings.contains(line) {
                heading = line
            } else if line.hasPrefix("/"), heading != includedHeading {
                paths.append(line)
            }
        }
        return (before.trimmingCharacters(in: .whitespacesAndNewlines), paths)
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
