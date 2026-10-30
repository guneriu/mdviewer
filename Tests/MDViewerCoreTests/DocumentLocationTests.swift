import Darwin
import Foundation
import Testing
@testable import MDViewerCore

struct DocumentLocationTests {
    @Test func canonicalIdentityAndLiteralFilename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("space ü 日本 '% $(false).md")
        try Data([0xef, 0xbb, 0xbf] + Array("# literal".utf8)).write(to: original)
        let alias = root.appendingPathComponent("alias.markdown")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        #expect(try DocumentLocation(original).canonicalURL == DocumentLocation(alias).canonicalURL)
        #expect(try DocumentLocation(alias).read() == "# literal")
    }

    @Test func nonregularAndReplacedFifoNeverBlock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("race.md")
        try Data("initial".utf8).write(to: file)
        let location = try DocumentLocation(file)
        try FileManager.default.removeItem(at: file)
        #expect(throws: (any Error).self) { try location.read() }
        #expect(mkfifo(file.path, 0o600) == 0)
        let start = Date()
        #expect(throws: (any Error).self) { try location.read() }
        #expect(Date().timeIntervalSince(start) < 0.5)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try location.read() }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("elsewhere.md"))
        #expect(throws: (any Error).self) { try location.read() }
    }

    @Test func readErrorsAndEmptyDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.md")
        try Data().write(to: file)
        #expect(try DocumentLocation(file).read() == "")
        try Data([0xff, 0xfe, 0x00]).write(to: file)
        #expect(throws: (any Error).self) { try DocumentLocation(file).read() }
        try Data(repeating: 65, count: DocumentLocation.maximumBytes + 1).write(to: file)
        #expect(throws: (any Error).self) { try DocumentLocation(file).read() }
        #expect(throws: (any Error).self) { try DocumentLocation(URL(string: "https://example.invalid/a.md")!) }
        #expect(throws: (any Error).self) { try DocumentLocation(root.appendingPathComponent("script.sh")) }
    }
}
