import Foundation
import Testing
@testable import MDViewerCore

private actor DelayedReads {
    private var next = 0
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    func read() async throws -> String {
        next += 1
        let id = next
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    func contains(_ id: Int) -> Bool { pending[id] != nil }
    func finish(_ id: Int, _ source: String) { pending.removeValue(forKey: id)?.resume(returning: source) }
}
private actor RetryingReads {
    private var attempts = 0
    func read() throws -> String {
        attempts += 1
        if attempts < 3 { throw POSIXError(.EAGAIN) }
        return "recovered"
    }
    func count() -> Int { attempts }
}
private struct RefreshTimeout: Error { }

struct DocumentRefreshTests {
    @Test(arguments: [false, true]) @MainActor
    func assetEventsDuringRenderReplayAfterNewPathsCommit(existingPreview: Bool) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("document.md")
        try Data("unchanged".utf8).write(to: file)
        var generation = 0, renders = 0
        var watcher: AssetWatcher?
        weak var session: DocumentRefresh?
        let eventRender = existingPreview ? 2 : 1
        let refresh = DocumentRefresh(location: try DocumentLocation(file), invalidate: { generation += 1; return generation },
            assetWatcherFactory: { root, document, callback in
                let created = try AssetWatcher(root: root, document: document, onChange: callback)
                watcher = created; return created
            }, render: { _, version in
                renders += 1
                // Simulate delivery after reading a newly referenced image but before commit.
                let batch = AssetPolicy.images(references: renders >= eventRender ? ["new.png"] : [], root: root)
                if renders == eventRender {
                    watcher?.receive(paths: Array(batch.resolvedPaths), flags: [0])
                }
                session?.updateAssetPaths(batch.resolvedPaths, generation: version)
            })
        session = refresh
        defer { refresh.close() }
        try refresh.start()
        if existingPreview {
            try await wait { refresh.completedGeneration > 0 }
            refresh.reload()
        }
        try await wait { refresh.completedGeneration == generation && renders == eventRender + 1 }
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(renders == eventRender + 1)
    }

    @Test @MainActor func currentAssetPathsReloadUnchangedSourceAndCloseStopsEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("document.md")
        try Data("unchanged".utf8).write(to: file)
        let allowed = root.resolvingSymlinksInPath().appendingPathComponent("allowed.png").path
        let unrelated = root.resolvingSymlinksInPath().appendingPathComponent("unrelated.png").path
        var generation = 0, renders = 0
        var watcher: AssetWatcher?
        let refresh = DocumentRefresh(location: try DocumentLocation(file), invalidate: { generation += 1; return generation },
            assetWatcherFactory: { root, document, callback in
                let created = try AssetWatcher(root: root, document: document, onChange: callback)
                watcher = created; return created
            }, render: { _, _ in renders += 1 })
        defer { refresh.close() }
        try refresh.start()
        try await wait { refresh.completedGeneration > 0 }
        let current = refresh.completedGeneration
        refresh.updateAssetPaths([allowed], generation: current)
        refresh.updateAssetPaths([unrelated], generation: current - 1)
        watcher?.receive(paths: [allowed], flags: [0])
        try await wait { refresh.completedGeneration > current }
        #expect(renders == 2)
        refresh.close()
        let completed = refresh.completedGeneration
        refresh.updateAssetPaths([allowed], generation: generation)
        watcher?.receive(paths: [allowed], flags: [0])
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(refresh.completedGeneration == completed && renders == 2)
    }

    @Test @MainActor func assetStreamFailureKeepsSourceReloadAndWarningRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("document.md")
        try Data("initial".utf8).write(to: file)
        var generation = 0, attempts = 0, displayed = "", warning = false
        let refresh = DocumentRefresh(location: try DocumentLocation(file), invalidate: { generation += 1; return generation },
            assetWatcherFactory: { _, _, _ in attempts += 1; throw POSIXError(.EIO) },
            render: { source, _ in displayed = source })
        defer { refresh.close() }
        refresh.onState = { if case .warning = $0 { warning = true } }
        try refresh.start()
        try await wait { displayed == "initial" }
        try Data("source change".utf8).write(to: file)
        try await wait { displayed == "source change" }
        try FileManager.default.removeItem(at: file)
        try await wait { warning }
        #expect(refresh.hasGoodPreview && displayed == "source change")
        try Data("recreated".utf8).write(to: file)
        try await wait { displayed == "recreated" }
        let before = refresh.completedGeneration
        refresh.reload()
        try await wait { refresh.completedGeneration > before }
        #expect(attempts == 1)
    }

    @MainActor private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw RefreshTimeout()
    }

    @Test(arguments: ["/tmp", "/private/tmp"])
    @MainActor
    func temporaryParentSupportsLiveRefresh(parent: String) async throws {
        let file = URL(fileURLWithPath: parent, isDirectory: true)
            .appendingPathComponent("MDViewer-watch-\(UUID().uuidString) 雪 % '.md")
        try Data("initial".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        var generation = 0, displayed = "", warning = ""
        let refresh = DocumentRefresh(
            location: try DocumentLocation(file),
            invalidate: { generation += 1; return generation },
            render: { source, _ in displayed = source })
        defer { refresh.close() }
        refresh.onState = { state in
            if case .warning(let message) = state { warning = message }
            if case .displayed = state { warning = "" }
        }

        try refresh.start()
        try await wait { displayed == "initial" && warning.isEmpty }
        try Data("direct".utf8).write(to: file)
        try await wait { displayed == "direct" && warning.isEmpty }
        try Data("atomic".utf8).write(to: file, options: .atomic)
        try await wait { displayed == "atomic" && warning.isEmpty }

        try FileManager.default.removeItem(at: file)
        try await wait { !warning.isEmpty }
        #expect(displayed == "atomic")
        #expect(warning.hasPrefix("Preview is out of date"))

        try Data("recreated".utf8).write(to: file)
        try await wait { displayed == "recreated" && warning.isEmpty }
        #expect(refresh.hasGoodPreview)
    }

    @Test @MainActor
    func missingWatchParentPreservesENOENT() throws {
        let missing = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("MDViewer-missing-\(UUID().uuidString)")
            .appendingPathComponent("document.md")
        var generation = 0
        let refresh = DocumentRefresh(
            location: try DocumentLocation(missing),
            invalidate: { generation += 1; return generation },
            render: { _, _ in })
        defer { refresh.close() }
        do {
            try refresh.start()
            Issue.record("Missing parent directory must fail watch startup")
        } catch let error as POSIXError {
            #expect(error.code == .ENOENT)
        }
    }

    @Test @MainActor func reorderedReadsAndCloseCannotWin() async throws {
        let reads = DelayedReads()
        let location = try DocumentLocation(URL(fileURLWithPath: "/tmp/deterministic.md"))
        var generation = 0, rendered: [String] = []
        let refresh = DocumentRefresh(location: location, invalidate: { generation += 1; return generation },
            read: { _ in try await reads.read() }, render: { source, _ in rendered.append(source) })
        defer { refresh.close() }
        refresh.reload()
        try await wait { await reads.contains(1) }
        refresh.reload()
        try await wait { await reads.contains(2) }
        await reads.finish(2, "new")
        try await wait { refresh.completedGeneration == 2 }
        await reads.finish(1, "old")
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(rendered == ["new"])
        #expect(refresh.completedGeneration == 2)
        refresh.reload()
        try await wait { await reads.contains(3) }
        refresh.close()
        await reads.finish(3, "after close")
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(rendered == ["new"])
        #expect(refresh.isClosed)
    }

    @Test @MainActor func transientReadRetriesAreBoundedAndRecover() async throws {
        let reads = RetryingReads()
        var generation = 0, displayed = ""
        let refresh = DocumentRefresh(location: try DocumentLocation(URL(fileURLWithPath: "/tmp/retries.md")),
            invalidate: { generation += 1; return generation }, read: { _ in try await reads.read() },
            render: { source, _ in displayed = source })
        defer { refresh.close() }
        refresh.reload()
        try await wait { refresh.hasGoodPreview }
        #expect(displayed == "recovered")
        #expect(await reads.count() == 3)
    }

    @Test @MainActor func failedReloadKeepsLastGoodState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("document.md")
        try Data("good".utf8).write(to: file)
        var generation = 0, displayed = "", warning = ""
        let refresh = DocumentRefresh(location: try DocumentLocation(file), invalidate: { generation += 1; return generation },
            render: { source, _ in displayed = source })
        defer { refresh.close() }
        refresh.onState = { if case .warning(let message) = $0 { warning = message } }
        refresh.reload()
        try await wait { refresh.hasGoodPreview }
        try FileManager.default.removeItem(at: file)
        refresh.reload()
        try await wait { !warning.isEmpty }
        #expect(displayed == "good")
        #expect(warning.hasPrefix("Preview is out of date"))
        #expect(refresh.completedGeneration == 1)
    }
}
