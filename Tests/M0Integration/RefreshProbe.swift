import AppKit
import MDViewerCore

extension M0Integration {
    static func testLiveRefresh(_ host: RenderHost, resources: URL, fixtureRoot: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixtureRoot.appendingPathComponent("Images/pixel.png"), to: root.appendingPathComponent("pixel.png"))
        let file = root.appendingPathComponent("live.md")
        let location = try DocumentLocation(file)
        try Data("# Initial".utf8).write(to: file)
        let refresh = DocumentRefresh(location: location, invalidate: { host.invalidate() }) { source, generation in
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                host.render(source: source, root: root, document: file, generation: generation) { continuation.resume(with: $0) }
            }
        }
        defer { refresh.close() }
        var warning = ""
        refresh.onState = { state in if case .warning(let message) = state { warning = message }; if state == .displayed { warning = "" } }
        try refresh.start()
        try await waitUntil("initial live render") { refresh.hasGoodPreview }
        for (index, name) in ["Direct", "Truncate", "Atomic"].enumerated() {
            let start = Date()
            if index == 1 {
                let handle = try FileHandle(forWritingTo: file)
                try handle.truncate(atOffset: 0)
                try await Task.sleep(nanoseconds: 30_000_000)
                try handle.write(contentsOf: Data("# \(name)".utf8)); try handle.close()
            } else { try Data("# \(name)".utf8).write(to: file, options: index == 2 ? .atomic : []) }
            try await waitUntil("\(name) save") { try await js(host, "return document.querySelector('h1')?.textContent === expected", arguments: ["expected": name]) as? Bool == true }
            let elapsed = Date().timeIntervalSince(start)
            print("TIMING settled \(name) save: \(String(format: "%.3f", elapsed)) s")
            try check(elapsed < 1, "\(name) save refreshes actual DOM within 1 second")
        }
        try FileManager.default.removeItem(at: file)
        try await waitUntil("deleted warning") { !warning.isEmpty }
        let lastGood = try await js(host, "return document.querySelector('h1')?.textContent") as? String
        try check(lastGood == "Atomic" && warning.hasPrefix("Preview is out of date"), "deleted source keeps last good DOM with stale warning")
        try Data("# Recreated".utf8).write(to: file)
        try await waitUntil("recreated source") { guard warning.isEmpty else { return false }; return try await js(host, "return document.querySelector('h1')?.textContent === 'Recreated'") as? Bool == true }
        try check(warning.isEmpty, "delete/recreate rebinds watcher and clears warning")
        for index in 0..<12 {
            try Data("# Rapid \(index)".utf8).write(to: file, options: .atomic)
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        let settled = Date()
        try await waitUntil("rapid final save") { try await js(host, "return document.querySelector('h1')?.textContent === 'Rapid 11'") as? Bool == true }
        try check(Date().timeIntervalSince(settled) < 1, "rapid atomic saves display only latest settled source within 1 second")
        try Data([0xff]).write(to: file)
        try await waitUntil("encoding warning") { warning.contains("UTF-8") }
        let encodingKeptDOM = try await js(host, "return document.querySelector('h1')?.textContent === 'Rapid 11'") as? Bool
        try check(encodingKeptDOM == true, "invalid encoding retains last good DOM")
        try Data("# Recovered".utf8).write(to: file)
        try await waitUntil("encoding recovery") { guard warning.isEmpty else { return false }; return try await js(host, "return document.querySelector('h1')?.textContent === 'Recovered'") as? Bool == true }
        refresh.close()
        let closedGeneration = host.generation
        try Data("# After close".utf8).write(to: file)
        try await Task.sleep(nanoseconds: 350_000_000)
        try check(host.generation == closedGeneration && refresh.isClosed, "close cancels debounce/retries and stops directory/file watchers")

        let queued = try RenderHost(resourceDirectory: resources.appendingPathComponent("Web"))
        defer { queued.close() }
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            queued.render(source: "# Queued", root: root) { continuation.resume(with: $0) }
            queued.load()
        }
        let queuedDOM = try await js(queued, "return document.querySelector('h1')?.textContent === 'Queued'") as? Bool
        try check(queuedDOM == true, "reload before shell readiness is queued and rendered")
        try await testRenderTransactions(host, root: root)
    }

    static func testRenderTransactions(_ host: RenderHost, root: URL) async throws {
        try await render(host, source: "# Last good", root: root)
        _ = try await js(host, "window.originalPrepare = window.prepareMarkdown; window.prepareMarkdown = source => source.includes('SLOW') ? new Promise(resolve => window.releasePrepare = () => resolve(window.originalPrepare(source))) : window.originalPrepare(source); return true")
        let old = Task { try await render(host, source: "# SLOW old", root: root) }
        try await waitUntil("delayed prepare") { try await js(host, "return typeof window.releasePrepare === 'function'") as? Bool == true }
        try await render(host, source: "# Newest\n\n![raster](pixel.png)", root: root)
        let retainedImage = try await js(host, "return document.querySelector('#document img').src") as! String
        _ = try await js(host, "window.releasePrepare(); window.prepareMarkdown = window.originalPrepare; return true")
        _ = await old.result
        let preparedDOM = try await js(host, "return document.querySelector('h1').textContent === 'Newest'") as? Bool
        try check(preparedDOM == true, "reordered prepare completion cannot replace newer DOM")

        _ = try await js(host, "window.originalCommit = window.commitMarkdown; window.commitMarkdown = generation => new Promise(resolve => window.releaseCommit = () => resolve(window.originalCommit(generation))); return true")
        let delayed = Task { try await render(host, source: "# Delayed commit", root: root) }
        try await waitUntil("delayed commit") { try await js(host, "return typeof window.releaseCommit === 'function'") as? Bool == true }
        _ = host.invalidate()
        _ = try await js(host, "window.commitMarkdown = window.originalCommit; window.releaseCommit(); return true")
        _ = await delayed.result
        let committedDOM = try await js(host, "return document.querySelector('h1').textContent === 'Newest'") as? Bool
        try check(committedDOM == true, "DOM commit has a final in-WebKit generation guard")

        _ = try await js(host, "window.originalStage = window.stageMarkdown; window.stageMarkdown = () => { throw new Error('injected renderer failure') }; return true")
        var renderFailed = false
        do { try await render(host, source: "# Must fail", root: root) } catch { renderFailed = true }
        _ = try await js(host, "window.stageMarkdown = window.originalStage; return true")
        let failureDOM = try await js(host, "return document.querySelector('h1').textContent === 'Newest'") as? Bool
        try check(renderFailed && failureDOM == true && host.gateway.containsCapability(retainedImage), "failed staging preserves last good DOM and its image capabilities")
        _ = try await js(host, "window.stageMarkdown = (...args) => { const staged = window.originalStage(...args); return new Promise(resolve => window.releaseStage = () => resolve(staged)) }; return true")
        let staged = Task { try await render(host, source: "# Stale stage\n\n![raster](pixel.png)", root: root) }
        try await waitUntil("delayed staging") { try await js(host, "return typeof window.releaseStage === 'function'") as? Bool == true }
        _ = host.invalidate()
        _ = try await js(host, "window.stageMarkdown = window.originalStage; window.releaseStage(); return true")
        _ = await staged.result
        let stagedDOM = try await js(host, "return document.querySelector('h1').textContent === 'Newest'") as? Bool
        try check(stagedDOM == true && host.gateway.containsCapability(retainedImage), "stale stage completion preserves committed DOM and capabilities")
        try await render(host, source: (0..<300).map { "Paragraph \($0)\n\n" }.joined(), root: root)
        _ = try await js(host, "scrollTo(0, 900); return true")
        try await Task.sleep(nanoseconds: 80_000_000)
        let position = try await js(host, "return scrollY") as! Double
        try await render(host, source: (0..<305).map { "Paragraph \($0)\n\n" }.joined(), root: root)
        let restored = try await js(host, "return scrollY") as! Double
        try check(position > 0 && abs(restored - position) < 5, "successful refresh preserves practical scroll offset")
        try check(!host.gateway.containsCapability(retainedImage), "successful replacement retires previous committed image capabilities")
    }
}
