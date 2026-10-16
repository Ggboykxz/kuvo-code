import Foundation
import os

/// A value kept in one of Kuvo Code's JSON files: read whole, written whole and atomically, its
/// folder made as needed. A file that's there but won't read (from a newer version, or damaged)
/// is set aside as `<name>.unreadable.json` before anything can write over it, so what was in it
/// isn't lost; the log says so.
nonisolated enum JSONFile {
    /// What's in `file`, or nil when there's nothing there or it won't read.
    static func read<Value: Decodable>(_ type: Value.Type, from file: URL, isoDates: Bool = false) -> Value? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        if isoDates { decoder.dateDecodingStrategy = .iso8601 }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            let aside = file.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: file, to: aside)
            log.error("\(file.lastPathComponent, privacy: .public) couldn't be read and was set aside as \(aside.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Writes `value` to `file`; false (and a line in the log) if it couldn't.
    @discardableResult
    static func write<Value: Encodable>(_ value: Value, to file: URL, isoDates: Bool = false, readable: Bool = false) -> Bool {
        let encoder = JSONEncoder()
        if isoDates { encoder.dateEncodingStrategy = .iso8601 }
        if readable { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(value).write(to: file, options: .atomic)
            return true
        } catch {
            log.error("\(file.lastPathComponent, privacy: .public) wasn't saved: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static let log = Logger(subsystem: "run.kuvo.code", category: "files")
}
