import Darwin
import Foundation
import MDViewerCore

extension M0Integration {
    static func testFIFORefresh(initial: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MDViewer-FIFO-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("document.md")
        if initial {
            try check(mkfifo(file.path, 0o600) == 0, "create initial FIFO without a writer")
        } else {
            try Data("last good".utf8).write(to: file)
        }
        var generation = 0, displayed = "", warning = ""
        let refresh = DocumentRefresh(location: try DocumentLocation(file), invalidate: { generation += 1; return generation },
            render: { source, _ in displayed = source })
        defer { refresh.close() }
        refresh.onState = { state in
            if case .warning(let message) = state { warning = message }
            if case .displayed = state { warning = "" }
        }
        let started = Date()
        try refresh.start()
        let elapsed = Date().timeIntervalSince(started)
        print("TIMING FIFO scenario \(initial ? "initial" : "replacement") start: \(elapsed) s")
        try check(elapsed < 0.5, "DocumentRefresh.start returns within 0.5 seconds")
        if !initial {
            try await waitUntil("initial regular file preview") { displayed == "last good" }
            try FileManager.default.removeItem(at: file)
            try check(mkfifo(file.path, 0o600) == 0, "replace watched regular document with FIFO without a writer")
        }
        try await waitUntil("FIFO read warning without main-actor freeze") { !warning.isEmpty }
        var rejectedFIFO = false
        do {
            let watcher = try DirectoryWatcher(directory: file, onChange: {})
            watcher.stop()
        } catch let error as POSIXError { rejectedFIFO = error.code == .EINVAL }
        try check(rejectedFIFO, "watcher rejects FIFO descriptor with EINVAL")
        try check(initial ? displayed.isEmpty && warning.hasPrefix("Unable to read document") : displayed == "last good" && warning.hasPrefix("Preview is out of date"), "FIFO warning preserves initial/last-good preview state")
        try FileManager.default.removeItem(at: file)
        try Data("recreated".utf8).write(to: file)
        try await waitUntil("FIFO replaced by valid document recovers") { displayed == "recreated" && warning.isEmpty }
        try check(refresh.hasGoodPreview, "parent watcher recovers after valid document recreation")
        try Data("atomic save".utf8).write(to: file, options: .atomic)
        try await waitUntil("file watcher rebind after FIFO recovery") { displayed == "atomic save" }
        try check(warning.isEmpty, "normal atomic save still reloads after FIFO recovery")
        print("FIFO REGRESSION PASSED: \(checks) checks")
    }
}
