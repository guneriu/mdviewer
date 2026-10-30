import Darwin
import Foundation
import MDViewerCore

extension M0Integration {
    static func testTemporaryParentRefresh(parentPath: String) async throws {
        let file = URL(fileURLWithPath: parentPath, isDirectory: true)
            .appendingPathComponent("MDViewer-watch-\(UUID().uuidString) 雪 % '.md")
        try Data("initial".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        print("FIXTURE temporary-parent: \(file.path)")
        fflush(stdout)

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

        let started = Date()
        try refresh.start()
        try check(Date().timeIntervalSince(started) < 0.5,
                  "temporary-parent startup returns within 0.5 seconds")
        try await waitUntil("temporary-parent initial preview") {
            displayed == "initial" && warning.isEmpty
        }

        try Data("direct".utf8).write(to: file)
        try await waitUntil("temporary-parent direct write") {
            displayed == "direct" && warning.isEmpty
        }
        try check(refresh.hasGoodPreview, "direct-write refresh retains good-preview state")

        let atomicStarted = Date()
        try Data("atomic".utf8).write(to: file, options: .atomic)
        try await waitUntil("temporary-parent atomic replacement") {
            displayed == "atomic" && warning.isEmpty
        }
        let atomicElapsed = Date().timeIntervalSince(atomicStarted)
        print("TIMING temporary parent \(parentPath) atomic save: \(atomicElapsed) s")
        try check(atomicElapsed < 1.0, "atomic replacement refresh completes within 1 second")

        try FileManager.default.removeItem(at: file)
        try await waitUntil("temporary-parent missing warning") { !warning.isEmpty }
        try check(displayed == "atomic" && warning.hasPrefix("Preview is out of date"),
                  "deletion preserves the last good preview with a warning")

        try Data("recreated".utf8).write(to: file)
        try await waitUntil("temporary-parent recreation") {
            displayed == "recreated" && warning.isEmpty
        }
        try check(refresh.hasGoodPreview, "recreation clears warning and resumes preview")

        let completed = refresh.completedGeneration
        refresh.close()
        try Data("after close".utf8).write(to: file)
        try await Task.sleep(nanoseconds: 350_000_000)
        try check(refresh.isClosed && displayed == "recreated" &&
                  refresh.completedGeneration == completed,
                  "closed session cannot publish another preview")
        print("TMP REFRESH REGRESSION PASSED: \(checks) checks")
    }

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
