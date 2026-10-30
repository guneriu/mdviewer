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

    @Test @MainActor func inFlightEventsReplayOnceAndClearOnEmptyCancelOrStop() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let pointer = try #require(realpath(root.path, nil)); defer { free(pointer) }
        let physical = URL(fileURLWithPath: String(cString: pointer))
        let source = physical.appendingPathComponent("doc.md")
        let image = physical.appendingPathComponent("new.png").path
        var changes = 0
        let watcher = try AssetWatcher(root: root, document: source) { changes += 1 }
        defer { watcher.stop() }
        watcher.beginUpdate()
        watcher.receive(paths: [source.path, physical.path + "-sibling/new.png"], flags: [0, 0])
        watcher.updatePaths([image])
        #expect(changes == 0)
        watcher.updatePaths([])
        watcher.beginUpdate()
        watcher.receive(paths: [image, image], flags: [0, 0])
        watcher.updatePaths([image])
        #expect(changes == 1)
        watcher.updatePaths([image])
        #expect(changes == 1)
        watcher.updatePaths([])
        watcher.beginUpdate()
        watcher.receive(paths: [image], flags: [0])
        watcher.updatePaths([])
        watcher.updatePaths([image])
        #expect(changes == 1)
        watcher.updatePaths([])
        watcher.beginUpdate()
        watcher.receive(paths: [image], flags: [0])
        watcher.cancelUpdate()
        watcher.updatePaths([image])
        #expect(changes == 1)
        watcher.updatePaths([])
        watcher.beginUpdate()
        watcher.receive(paths: [image], flags: [0])
        watcher.stop()
        watcher.updatePaths([image])
        #expect(changes == 1)
    }

    @Test @MainActor func disappearingOwnerReleasesWatcher() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var calls: [String] = []
        var liveStreams = 0
        let operations = AssetStreamOperations(
            stop: { calls.append("stop"); FSEventStreamStop($0) },
            invalidate: { calls.append("invalidate"); FSEventStreamInvalidate($0) },
            release: { calls.append("release"); liveStreams -= 1; FSEventStreamRelease($0) })
        weak var weakWatcher: AssetWatcher?
        do {
            let watcher = try AssetWatcher(root: root, document: root.appendingPathComponent("doc.md"),
                caseSensitive: true, streamOperations: operations) {}
            liveStreams += 1
            weakWatcher = watcher
        }
        #expect(weakWatcher == nil)
        #expect(calls == ["stop", "invalidate", "release"] && liveStreams == 0)
        let watcher = try AssetWatcher(root: root, document: root.appendingPathComponent("doc.md"),
            caseSensitive: true, streamOperations: operations) {}
        liveStreams += 1
        watcher.stop(); watcher.stop()
        #expect(calls == ["stop", "invalidate", "release", "stop", "invalidate", "release"])
        #expect(liveStreams == 0)
    }
}
