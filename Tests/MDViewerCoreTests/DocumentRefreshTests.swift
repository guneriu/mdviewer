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
    @MainActor private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw RefreshTimeout()
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
