import CoreServices
import Darwin
import Foundation
import Testing
@testable import MDViewerCore

struct AssetWatcherTests {
    @Test @MainActor func normalizedMatchingAncestorsLossAndLifetime() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("MDViewer-asset-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pointer = try #require(realpath(root.path, nil)); defer { free(pointer) }
        let physical = URL(fileURLWithPath: String(cString: pointer))
        let fileFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let dirFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        for sensitive in [true, false] {
            var changes = 0
            let source = physical.appendingPathComponent("doc.md").path
            let watcher = try AssetWatcher(root: root, document: URL(fileURLWithPath: source), caseSensitive: sensitive) { changes += 1 }
            defer { watcher.stop() }
            let watched = physical.appendingPathComponent("img/café.png").path
            watcher.updatePaths([watched, physical.appendingPathComponent("future/deep/New.png").path])
            watcher.receive(paths: [physical.appendingPathComponent("img/cafe\u{301}.png").path, watched], flags: [fileFlag, fileFlag])
            #expect(changes == 1)
            watcher.receive(paths: [physical.appendingPathComponent("future/deep/new.png").path], flags: [fileFlag])
            #expect(changes == (sensitive ? 1 : 2))
            let before = changes
            for directory in [physical.path, physical.appendingPathComponent("img").path, physical.appendingPathComponent("future/deep").path] {
                watcher.receive(paths: [directory], flags: [dirFlag])
            }
            #expect(changes == before + 3)
            let filtered = changes
            watcher.receive(paths: [source, physical.appendingPathComponent("img/unreferenced.png").path,
                physical.appendingPathComponent("img-old").path, physical.deletingLastPathComponent().path], flags: [fileFlag, fileFlag, dirFlag, dirFlag])
            #expect(changes == filtered)
            let losses = [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
                kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagRootChanged]
            for loss in losses {
                watcher.receive(paths: [source, "/unrelated"], flags: [FSEventStreamEventFlags(loss) | dirFlag, fileFlag])
            }
            #expect(changes == filtered + 4)
            watcher.receive(paths: [watched], flags: [])
            #expect(changes == filtered + 4)
            watcher.updatePaths([physical.appendingPathComponent("new.png").path])
            watcher.receive(paths: [watched, physical.appendingPathComponent("img").path], flags: [fileFlag, dirFlag])
            #expect(changes == filtered + 4)
            watcher.updatePaths([])
            watcher.receive(paths: [source], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)])
            #expect(changes == filtered + 4)
            watcher.updatePaths([watched])
            watcher.stop(); watcher.stop()
            watcher.receive(paths: [watched, source], flags: [fileFlag, FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)])
            #expect(changes == filtered + 4)
        }
    }

    @Test @MainActor func disappearingOwnerReleasesWatcher() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        weak var weakWatcher: AssetWatcher?
        do {
            let watcher = try AssetWatcher(root: root, document: root.appendingPathComponent("doc.md")) {}
            weakWatcher = watcher
        }
        #expect(weakWatcher == nil)
    }
}
