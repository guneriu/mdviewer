import AppKit
import Darwin
import Foundation
import MDViewerCore

extension M0Integration {
    static func imageFixture(width: Int, height: Int = 1) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        memset(bitmap.bitmapData!, 255, bitmap.bytesPerRow * height)
        return bitmap.representation(using: .png, properties: [:])!
    }

    static func testAssetImages(_ scenario: String) async throws {
        let fm = FileManager.default
        let token = "MDViewer-asset-\(UUID().uuidString)"
        let temporaryParent = scenario == "tmp-parent"
        let root = temporaryParent ? URL(fileURLWithPath: "/tmp") : fm.temporaryDirectory.appendingPathComponent(token)
        let imageDirectory = root.appendingPathComponent(temporaryParent ? token : "img")
        try fm.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(temporaryParent ? "\(token).md" : "document.md")
        defer {
            if temporaryParent { try? fm.removeItem(at: imageDirectory); try? fm.removeItem(at: file) }
            else { try? fm.removeItem(at: root) }
        }
        let image = imageDirectory.appendingPathComponent("a.png")
        let missing = imageDirectory.appendingPathComponent("new.png")
        let prefix = imageDirectory.lastPathComponent
        var references = ["\(prefix)/a.png", "\(prefix)/new.png"]
        var outsideRoot: URL?
        if scenario == "filtering" {
            let outside = fm.temporaryDirectory.appendingPathComponent("\(token)-outside")
            outsideRoot = outside
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            try imageFixture(width: 1).write(to: outside.appendingPathComponent("target.png"))
            try fm.createSymbolicLink(at: imageDirectory.appendingPathComponent("escape.png"), withDestinationURL: outside.appendingPathComponent("target.png"))
            references += ["img/escape.png", "img/café.png"]
            let sensitive = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames != false
            if !sensitive { references[1] = "img/New.png" }
            else { print("SKIP case-insensitive real event: case-sensitive fixture volume (both modes covered by native seam)") }
            try imageFixture(width: 1).write(to: imageDirectory.appendingPathComponent("café.png"))
        }
        defer { if let outsideRoot { try? fm.removeItem(at: outsideRoot) } }
        try imageFixture(width: 1).write(to: image)
        try Data(references.map { "![image](\($0))" }.joined(separator: "\n").utf8).write(to: file)
        var generation = 0, renders = 0
        var report: ((Set<String>, Int) -> Void)?
        let refresh = DocumentRefresh(location: try DocumentLocation(file), invalidate: { generation += 1; return generation }) { _, version in
            let paths = AssetPolicy.images(references: references, root: root).resolvedPaths
            report?(paths, version)
            renders += 1
        }
        report = { [weak refresh] in refresh?.updateAssetPaths($0, generation: $1) }
        defer { refresh.close() }
        try refresh.start()
        try await waitUntil("initial image watcher render") { renders == 1 }
        try await Task.sleep(nanoseconds: 500_000_000)
        let baseline = renders
        func change(_ label: String, _ mutate: () throws -> Void) async throws {
            let before = renders, started = Date()
            try mutate()
            try await waitUntil(label) { renders > before }
            let elapsed = Date().timeIntervalSince(started)
            print("TIMING asset \(scenario) \(label): \(String(format: "%.3f", elapsed)) s")
            try check(elapsed < 1, "\(label) completes within 1 second")
            try await Task.sleep(nanoseconds: 500_000_000)
            try check(renders == before + 1, "\(label) settles at exactly one completed render")
        }
        switch scenario {
        case "events":
            try await change("image overwrite") { try imageFixture(width: 2).write(to: image) }
            try await change("atomic image replacement") { try imageFixture(width: 3).write(to: image, options: .atomic) }
            try await change("image deletion") { try fm.removeItem(at: image) }
            try await change("image recreation") { try imageFixture(width: 4).write(to: image) }
            try await change("missing image creation") { try imageFixture(width: 5).write(to: missing) }
        case "directory":
            let prepared = root.appendingPathComponent("prepared-\(UUID().uuidString)")
            try fm.createDirectory(at: prepared, withIntermediateDirectories: true)
            try imageFixture(width: 6).write(to: prepared.appendingPathComponent("a.png"))
            try await Task.sleep(nanoseconds: 500_000_000)
            try await change("whole image directory replacement") {
                try fm.moveItem(at: imageDirectory, to: root.appendingPathComponent("old-img"))
                // Rename into the absent directory, never merge into the old one.
                try fm.moveItem(at: prepared, to: imageDirectory)
            }
        case "filtering":
            let before = refresh.completedGeneration
            try imageFixture(width: 2).write(to: imageDirectory.appendingPathComponent("unreferenced.png"))
            try imageFixture(width: 2).write(to: outsideRoot!.appendingPathComponent("target.png"))
            try imageFixture(width: 2).write(to: outsideRoot!.appendingPathComponent("unrelated.png"))
            try await Task.sleep(nanoseconds: 500_000_000)
            try check(refresh.completedGeneration == before && renders == baseline, "unreferenced sibling, escaping target and outside writes do not reload")
            try await change("Unicode-normalized image overwrite") {
                try imageFixture(width: 3).write(to: imageDirectory.appendingPathComponent("cafe\u{301}.png"))
            }
            try await change("missing case-aware image creation") { try imageFixture(width: 4).write(to: missing) }
        case "tmp-parent":
            try await change("physical /tmp image match") { try imageFixture(width: 2).write(to: image) }
            let before = refresh.completedGeneration
            refresh.close()
            try imageFixture(width: 3).write(to: image)
            try await Task.sleep(nanoseconds: 500_000_000)
            try check(refresh.completedGeneration == before && renders == baseline + 1, "close prevents /tmp asset event publication")
        default: preconditionFailure("Unknown asset scenario")
        }
        print("ASSET \(scenario == "tmp-parent" ? "TMP PARENT" : "IMAGE \(scenario.uppercased())") PASSED: \(checks) checks")
    }

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
