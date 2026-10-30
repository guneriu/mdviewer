import Foundation
import Testing
@testable import MDViewerCore

struct DirectoryWatcherTests {
    @Test func acceptsRegularFilesAndDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("document.md")
        try Data("regular".utf8).write(to: file)
        for path in [root, file] {
            let watcher = try DirectoryWatcher(directory: path, onChange: {})
            watcher.stop()
        }
    }

    @Test func rejectsSymlinksAndPreservesOpenErrors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing.md")
        do {
            _ = try DirectoryWatcher(directory: missing, onChange: {})
            Issue.record("Missing watch target must be rejected")
        } catch let error as POSIXError { #expect(error.code == .ENOENT) }
        let target = root.appendingPathComponent("regular.md")
        try Data("regular".utf8).write(to: target)
        let link = root.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do {
            _ = try DirectoryWatcher(directory: link, onChange: {})
            Issue.record("Watcher must not follow final symlink")
        } catch let error as POSIXError { #expect(error.code == .ELOOP) }
    }
}
