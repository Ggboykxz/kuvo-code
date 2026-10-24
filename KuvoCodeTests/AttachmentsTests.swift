import Foundation
import Testing
import UniformTypeIdentifiers
@testable import KuvoCode

/// Files you paste or the agent hands back are written into Kuvo Code's Attachments folder, never
/// elsewhere and never over another file, whatever their names say; a message you edit gets its
/// files back, each once.
@Suite(.serialized) struct AttachmentsTests {
    init() { TestEnvironment.prepare() }

    private var folder: String { Attachments.directory.standardizedFileURL.path }

    /// A name that tries to lead elsewhere (../, an absolute path, a hidden name, control
    /// characters) still lands in the folder, as a plain file.
    @Test(arguments: ["../../../../tmp/escaped", "/etc/passwd", ".hidden", "a\u{0}b:c", "..", "   "])
    func aNameCantLeadOutOfTheFolder(name: String) throws {
        let url = try #require(Attachments.write(Data("x".utf8), named: name, extension: "txt"))
        #expect(url.standardizedFileURL.deletingLastPathComponent().path == folder)
        #expect(!url.lastPathComponent.hasPrefix("."))
        #expect(!url.lastPathComponent.contains(":"))
    }

    /// The same name twice: two files, the first kept as it was.
    @Test func theSameNameTwiceKeepsBoth() throws {
        let name = "screenshot-\(UUID().uuidString.prefix(8))"
        let first = try #require(Attachments.write(Data("one".utf8), named: name, extension: "png"))
        let second = try #require(Attachments.write(Data("two".utf8), named: name, extension: "png"))
        #expect(first != second)
        #expect(try Data(contentsOf: first) == Data("one".utf8))
        #expect(try Data(contentsOf: second) == Data("two".utf8))
    }

    /// A file that came as data opens as what it is (its type's extension, not its name's), marked
    /// as downloaded so macOS checks it.
    @Test func aReceivedFileIsWhatItsTypeSays() throws {
        let url = try #require(Attachments.writeReceived(Data("%PDF-1.4".utf8), named: "invoice.pdf.app", type: .pdf))
        #expect(url.pathExtension == "pdf")
        let quarantine = try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine != nil)
    }

    /// Edit on a sent message: its own files, then the ones its note names that are still on this
    /// Mac, each once; a machine's copy of one of its own isn't named again.
    @Test func editingAMessageRestoresItsFilesOnce() throws {
        let own = try #require(Attachments.write(Data("a".utf8), named: "own", extension: "png"))
        let named = try #require(Attachments.write(Data("b".utf8), named: "named", extension: "log"))
        let gone = Attachments.directory.appending(path: "deleted-\(UUID().uuidString).txt").path
        let machineCopy = "/home/me/.kuvo-code/attachments/0a1b2c3d/\(own.lastPathComponent)"
        let restored = Attachments.restored([own], noting: [named.path, own.path, gone, machineCopy])
        #expect(restored.map(\.path) == [own.path, named.path])
    }
}
