import AppKit
import MDViewerCore
import WebKit

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
        host.onAssetPaths = { [weak refresh] paths, generation in refresh?.updateAssetPaths(paths, generation: generation) }
        defer { refresh.close(); host.onAssetPaths = nil }
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
        try await testImageOnlyRefresh(resources: resources, fixtureRoot: fixtureRoot)
        try await testCommittedAssetPaths(resources: resources, root: root)
        try await testRenderTransactions(host, root: root)
        try await testFollowPreferenceLifecycle(resources: resources, root: root)
        try await testFollowPreferenceRace(resources: resources, root: root, recoverWhileHeld: false)
        try await testFollowPreferenceRace(resources: resources, root: root, recoverWhileHeld: true)
    }

    static func testImageOnlyRefresh(resources: URL, fixtureRoot: URL) async throws {
        let root = fixtureRoot.appendingPathComponent("image-refresh-\(UUID().uuidString)")
        let fm = FileManager.default
        let directory = root.appendingPathComponent("img")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let image = directory.appendingPathComponent("a.png")
        let missing = directory.appendingPathComponent("new.png")
        let file = root.appendingPathComponent("images.md")
        let sensitive = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == true
        let reference = sensitive ? "new.png" : "New.png"
        if sensitive { print("SKIP case-insensitive WebKit image creation: case-sensitive fixture volume") }
        let source = "![a](img/a.png) ![missing](img/\(reference))"
        try Data(source.utf8).write(to: file)
        try imageFixture(width: 1).write(to: image)
        let host = try RenderHost(resourceDirectory: resources.appendingPathComponent("Web"))
        var renders = 0
        let location = try DocumentLocation(file)
        let refresh = DocumentRefresh(location: location, invalidate: { [weak host] in host?.invalidate() ?? 0 }) { [weak host] source, version in
            guard let host else { throw CancellationError() }
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                host.render(source: source, root: location.assetRoot, document: location.canonicalURL, generation: version) {
                    continuation.resume(with: $0)
                }
            }
            renders += 1
        }
        host.onAssetPaths = { [weak refresh] paths, version in refresh?.updateAssetPaths(paths, generation: version) }
        defer { refresh.close(); host.close() }
        host.setFollowChanges(true)
        host.load()
        try refresh.start()
        try await waitUntil("initial image-only preview decoded") {
            guard renders == 1 else { return false }
            return try await js(host, "const i = document.querySelector('#document img[alt=a]'); return !!i && i.complete && i.naturalWidth === 1") as? Bool == true
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        func change(_ label: String, alt: String = "a", width: Int?, _ mutate: () throws -> Void) async throws {
            let before = renders
            let oldURL = try await js(host, "return document.querySelector('#document img[alt=" + alt + "]')?.src || ''") as! String
            let started = Date()
            try mutate()
            try await waitUntil(label) {
                guard renders > before else { return false }
                return try await js(host, """
                    const i = document.querySelector('#document img[alt="' + alt + '"]');
                    if (width === null) return !i && [...document.querySelectorAll('#document .blocked-image')].some(n => n.textContent === 'Blocked or missing image: ' + alt);
                    return !!i && i.complete && i.naturalWidth === width && i.src !== oldURL;
                    """, arguments: ["alt": alt, "width": width.map { $0 as Any } ?? NSNull(), "oldURL": oldURL]) as? Bool == true
            }
            let elapsed = Date().timeIntervalSince(started)
            print("TIMING WebKit \(label): \(String(format: "%.3f", elapsed)) s")
            try check(elapsed < 1, "\(label) decodes or blocks with a fresh capability within 1 second")
            try await Task.sleep(nanoseconds: 500_000_000)
            try check(renders == before + 1, "\(label) settles at exactly one completed browser render")
        }
        try await change("image-only overwrite", width: 2) { try imageFixture(width: 2).write(to: image) }
        try await change("image-only delete", width: nil) { try fm.removeItem(at: image) }
        try await change("image-only recreate", width: 3) { try imageFixture(width: 3).write(to: image) }
        try await change("missing case-aware image creation", alt: "missing", width: 4) { try imageFixture(width: 4).write(to: missing) }
        try await change("zero-byte image rejection", width: nil) { try Data().write(to: image) }
        try await change("zero-byte image recovery", width: 5) { try imageFixture(width: 5).write(to: image) }
        try await change("invalid mid-write image rejection", width: nil) { try Data("incomplete image".utf8).write(to: image) }
        try await change("invalid mid-write image recovery", width: 6) { try imageFixture(width: 6).write(to: image) }
        try await change("over-budget image rejection", width: nil) {
            let handle = try FileHandle(forWritingTo: image)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 26 * 1024 * 1024)
        }
        try await change("over-budget image recovery", width: 7) { try imageFixture(width: 7).write(to: image) }
        try await change("atomic image-only replacement", width: 8) { try imageFixture(width: 8).write(to: image, options: .atomic) }
        let prepared = root.appendingPathComponent("prepared-\(UUID().uuidString)")
        try fm.createDirectory(at: prepared, withIntermediateDirectories: true)
        try imageFixture(width: 9).write(to: prepared.appendingPathComponent("a.png"))
        try imageFixture(width: 4).write(to: prepared.appendingPathComponent(reference))
        try await Task.sleep(nanoseconds: 500_000_000)
        try await change("whole-directory image-only replacement", width: 9) {
            try fm.moveItem(at: directory, to: root.appendingPathComponent("old-img"))
            try fm.moveItem(at: prepared, to: directory)
        }
        let unchangedSource = try location.read()
        try check(unchangedSource == source, "image-only browser operations never change the Markdown source")
        _ = try await js(host, "window.prepareMarkdown = () => new Promise(resolve => window.releaseImageClose = () => resolve({images: [], links: []})); return true")
        try imageFixture(width: 10).write(to: image)
        try await waitUntil("asset event rendering before close") { try await js(host, "return typeof window.releaseImageClose === 'function'") as? Bool == true }
        let before = renders, completed = refresh.completedGeneration
        refresh.close(); host.close()
        _ = try await js(host, "window.releaseImageClose(); return true")
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(renders == before && refresh.completedGeneration == completed, "close blocks queued image render completion and publication")
    }

    static func testCommittedAssetPaths(resources: URL, root: URL) async throws {
        let host = try RenderHost(resourceDirectory: resources.appendingPathComponent("Web"))
        defer { host.close() }
        var reports: [(Set<String>, Int)] = []
        host.onAssetPaths = { reports.append(($0, $1)) }
        host.load()
        try await waitUntil("asset report host ready") { host.isReady }
        try await render(host, source: "![a](pixel.png) ![missing](img/new.png)", root: root)
        let expected = AssetPolicy.images(references: ["pixel.png", "img/new.png"], root: root).resolvedPaths
        try check(reports.count == 1 && reports[0].0 == expected && reports[0].1 == host.generation,
                  "only successful current commit reports accepted and missing image candidates")
        for method in ["prepareMarkdown", "stageMarkdown", "commitMarkdown"] {
            _ = try await js(host, "window.savedMethod = window[method]; window[method] = (...args) => new Promise(resolve => window.releaseMethod = () => resolve(window.savedMethod(...args))); return true", arguments: ["method": method])
            let pending = Task { try await render(host, source: "![missing](other.png)", root: root) }
            try await waitUntil("held \(method) asset report") { try await js(host, "return typeof window.releaseMethod === 'function'") as? Bool == true }
            _ = host.invalidate()
            _ = try await js(host, "window[method] = window.savedMethod; window.releaseMethod(); delete window.releaseMethod; return true", arguments: ["method": method])
            _ = await pending.result
            try check(reports.count == 1, "stale \(method) cannot publish image watch paths")
        }
        _ = try await js(host, "window.savedStage = window.stageMarkdown; window.stageMarkdown = () => { throw new Error('injected report failure') }; return true")
        var failed = false
        do { try await render(host, source: "![missing](failure.png)", root: root) } catch { failed = true }
        try check(failed && reports.count == 1 && reports[0].0 == expected, "stage failure preserves last successful image path report")
        _ = try await js(host, "window.stageMarkdown = window.savedStage; return true")
        try await render(host, source: "", root: root)
        try check(reports.count == 2 && reports[1].0.isEmpty, "empty successful commit clears image watch paths")
        _ = try await js(host, "window.prepareMarkdown = () => new Promise(resolve => window.releaseClosed = () => resolve({images: [], links: []})); return true")
        let closing = Task { try await render(host, source: "closing", root: root) }
        try await waitUntil("prepare before close") { try await js(host, "return typeof window.releaseClosed === 'function'") as? Bool == true }
        host.close()
        _ = try await js(host, "window.releaseClosed(); return true")
        _ = await closing.result
        try check(reports.count == 2 && host.onAssetPaths == nil, "close clears callback and prevents late path publication")
    }

    static func testFollowPreferenceLifecycle(resources: URL, root: URL) async throws {
        let host = try RenderHost(resourceDirectory: resources.appendingPathComponent("Web"))
        defer { host.close() }
        host.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.setFollowChanges(true)
        host.load()
        try await waitUntil("follow preference host ready") { host.isReady }
        let original = (0..<300).map { "Preference paragraph \($0)\n\n" }.joined()
        for phase in ["initial", "disabled", "reload", "recovery"] {
            if phase == "disabled" { host.setFollowChanges(false) }
            if phase == "reload" {
                host.setFollowChanges(true)
                host.load()
                try await waitUntil("follow preference reloaded") { host.isReady }
            }
            if phase == "recovery" {
                host.onRecovery = { host.render(source: original, root: root) { _ in } }
                host.webViewWebContentProcessDidTerminate(host.webView)
                try await waitUntil("follow preference recovered") { host.isReady }
            }
            try await render(host, source: original, root: root)
            _ = try await js(host, "scrollTo(0, 900); return true")
            try await Task.sleep(nanoseconds: 80_000_000)
            try await render(host, source: original + "Changed preference end", root: root)
            let visible = try await js(host, "const r = document.querySelector('#document').lastElementChild.getBoundingClientRect(); return r.bottom > 0 && r.top < innerHeight") as? Bool
            let anchored = try await js(host, "return Math.abs(scrollY - 900) < 5 && !document.querySelector('.changed-flash')") as? Bool
            try check(phase == "disabled" ? anchored == true : visible == true,
                      "native Follow Changes preference \(phase) applies before rendering")
        }
    }

    static func testFollowPreferenceRace(resources: URL, root: URL, recoverWhileHeld: Bool) async throws {
        let host = try RenderHost(resourceDirectory: resources.appendingPathComponent("Web"))
        defer {
            host.webView.configuration.userContentController.removeAllUserScripts()
            host.close()
        }
        host.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let intercept = """
            window.followShell = crypto.randomUUID();
            window.followApplied = [];
            let first = true;
            Object.defineProperty(window, 'setFollowChanges', {
              configurable: true,
              set(fn) {
                Object.defineProperty(window, 'setFollowChanges', {
                  configurable: true, writable: true,
                  value: enabled => {
                    const apply = () => { fn(enabled); window.followApplied.push(enabled); };
                    if (!first) { apply(); return; }
                    first = false;
                    return new Promise(resolve => {
                      window.followHeld = true;
                      window.releaseFollowApply = () => { apply(); resolve(true); };
                    });
                  }
                });
              }
            });
            """
        host.webView.configuration.userContentController.addUserScript(WKUserScript(
            source: intercept, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        var readyCount = 0
        var rendered = false
        var renderFailure: Error?
        var appliedAtReady: [Bool]?
        host.onReady = {
            readyCount += 1
            host.webView.callAsyncJavaScript("return window.followApplied", arguments: [:], in: nil, in: .page) { result in
                if case .success(let value) = result { appliedAtReady = value as? [Bool] }
            }
        }
        let original = (0..<300).map { "Race paragraph \($0)\n\n" }.joined()
        let queueRender = {
            host.render(source: original, root: root) { result in
                switch result {
                case .success: rendered = true
                case .failure(let error): renderFailure = error
                }
            }
        }
        host.setFollowChanges(true)
        host.load()
        try await waitUntil("first preference apply held") { try await js(host, "return window.followHeld === true") as? Bool == true }
        try check(!host.isReady && readyCount == 0, "held preference apply gates readiness")
        if recoverWhileHeld {
            let oldShell = try await js(host, "return window.followShell") as! String
            host.onRecovery = queueRender
            host.webViewWebContentProcessDidTerminate(host.webView)
            try await waitUntil("replacement preference apply held") {
                try await js(host, "return window.followShell !== oldShell && window.followHeld === true", arguments: ["oldShell": oldShell]) as? Bool == true
            }
            try check(!host.isReady && readyCount == 0, "stale preference completion cannot ready the held replacement shell")
        } else {
            queueRender()
        }
        host.setFollowChanges(false)
        _ = try await js(host, """
            const commit = window.commitMarkdown;
            window.commitMarkdown = generation => {
              window.followAtCommit = [...window.followApplied];
              return commit(generation);
            };
            window.releaseFollowApply();
            return true;
            """)
        try await waitUntil("latest preference queued render") { (rendered && appliedAtReady != nil) || renderFailure != nil }
        if let renderFailure { throw renderFailure }
        let applied = try await js(host, "return window.followAtCommit") as? [Bool]
        try check(applied == [true, false] && appliedAtReady == [true, false] && readyCount == 1 && host.isReady,
                  "latest false preference precedes queued commit and onReady\(recoverWhileHeld ? " after held recovery" : "")")
        _ = try await js(host, "scrollTo(0, 900); return true")
        try await Task.sleep(nanoseconds: 80_000_000)
        try await render(host, source: original + "Changed race end", root: root)
        let anchored = try await js(host, "return Math.abs(scrollY - 900) < 5 && !document.querySelector('.changed-flash')") as? Bool
        try check(anchored == true, "in-flight preference toggle anchors instead of following\(recoverWhileHeld ? " after recovery" : "")")
        _ = try await js(host, "delete window.releaseFollowApply; delete window.followHeld; return true")
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
        try await testContentAnchors(host, root: root)
        try await testFollowChanges(host, root: root)
        try await testFollowNavigationFindZoom(host, root: root)
    }

    static func testContentAnchors(_ host: RenderHost, root: URL) async throws {
        let original = (0..<300).map { "Paragraph \($0)\n\n" }.joined()
        try await render(host, source: original, root: root)
        _ = try await js(host, "scrollTo(0, 900); return true")
        try await Task.sleep(nanoseconds: 80_000_000)
        let anchor = try await js(host, """
            const node = [...document.querySelector('#document').children]
              .find(n => n.getBoundingClientRect().bottom > 0);
            return { text: node.textContent, top: node.getBoundingClientRect().top };
            """) as! [String: Any]
        let prefix = (0..<50).map { "Inserted \($0)\n\n" }.joined()
        try await render(host, source: prefix + original, root: root)
        let restored = try await js(host, """
            const node = [...document.querySelector('#document').children].find(n => n.textContent === text);
            return node.getBoundingClientRect().top;
            """, arguments: ["text": anchor["text"]!]) as! Double
        try check(abs(restored - (anchor["top"] as! Double)) < 5,
                  "inserting 50 blocks above preserves visible content within 5 px")
        try await testLateImageAnchors(host, root: root, original: original)
        try await render(host, source: original, root: root)
        _ = try await js(host, "scrollTo(0, 900); return true")
        try await Task.sleep(nanoseconds: 80_000_000)
        let deleted = try await js(host, """
            const nodes = [...document.querySelector('#document').children];
            const i = nodes.findIndex(n => n.getBoundingClientRect().bottom > 0);
            return { text: nodes[i].textContent, previous: nodes[i-1].textContent,
                     top: nodes[i-1].getBoundingClientRect().top };
            """) as! [String: Any]
        let withoutAnchor = original.replacingOccurrences(of: "\(deleted["text"]!)\n\n", with: "")
        try await render(host, source: prefix + withoutAnchor, root: root)
        let previousTop = try await js(host, "return [...document.querySelector('#document').children].find(n => n.textContent === text).getBoundingClientRect().top", arguments: ["text": deleted["previous"]!]) as! Double
        try check(abs(previousTop - (deleted["top"] as! Double)) < 5, "deleted visible anchor restores predecessor to its own saved offset within 5 px")

        let duplicates = (0..<300).map { _ in "Repeated paragraph\n\n" }.joined()
        for offset in [900, 1800] {
            try await render(host, source: duplicates, root: root)
            _ = try await js(host, "scrollTo(0, offset); return true", arguments: ["offset": offset])
            try await Task.sleep(nanoseconds: 80_000_000)
            let duplicate = try await js(host, """
                const nodes = [...document.querySelector('#document').children];
                const i = nodes.findIndex(n => n.getBoundingClientRect().bottom > 0);
                return { index: i, top: nodes[i].getBoundingClientRect().top };
                """) as! [String: Any]
            try await render(host, source: prefix + duplicates, root: root)
            let top = try await js(host, "return document.querySelector('#document').children[index + 50].getBoundingClientRect().top", arguments: ["index": duplicate["index"]!]) as! Double
            try check(abs(top - (duplicate["top"] as! Double)) < 5, "unchanged duplicate occurrence at \(offset) anchors independently within 5 px")
        }
        try await render(host, source: prefix, root: root)
        let bounded = try await js(host, "return scrollY >= 0 && scrollY <= Math.max(0, document.documentElement.scrollHeight - innerHeight)") as? Bool
        try check(bounded == true, "replacing all old blocks keeps pixel fallback within bounds")
        try await render(host, source: "Short paragraph", root: root)
        let short = try await js(host, "return scrollY === 0") as? Bool
        try check(short == true, "long-to-short replacement clamps scroll to zero")

        try await render(host, source: original, root: root)
        _ = try await js(host, "scrollTo(0, 900); return true")
        try await Task.sleep(nanoseconds: 80_000_000)
        _ = try await js(host, """
            window.staleAnchor = [...document.querySelector('#document').children].find(n => n.getBoundingClientRect().bottom > 0);
            window.staleAnchorTop = window.staleAnchor.getBoundingClientRect().top;
            window.savedStage = window.stageMarkdown;
            window.stageMarkdown = (...args) => {
              const staged = window.savedStage(...args);
              return new Promise(resolve => window.releaseAnchorStage = () => resolve(staged));
            };
            return true;
            """)
        let stale = Task { try await render(host, source: "Stale blocks", root: root) }
        try await waitUntil("staged anchor invalidation") { try await js(host, "return typeof window.releaseAnchorStage === 'function'") as? Bool == true }
        _ = host.invalidate()
        _ = try await js(host, "window.stageMarkdown = window.savedStage; window.releaseAnchorStage(); return true")
        _ = await stale.result
        let untouched = try await js(host, "return window.staleAnchor.isConnected && Math.abs(window.staleAnchor.getBoundingClientRect().top - window.staleAnchorTop) < 5") as? Bool
        try check(untouched == true, "invalidated staged render changes neither visible blocks nor geometry")
        try await render(host, source: prefix + original, root: root)
        let staleRestored = try await js(host, "return [...document.querySelector('#document').children].find(n => n.textContent === window.staleAnchor.textContent).getBoundingClientRect().top - window.staleAnchorTop") as! Double
        try check(abs(staleRestored) < 5, "invalidated staged render leaves committed anchor identities unchanged")
        _ = try await js(host, "delete window.staleAnchor; return true")
    }

    static func testFollowChanges(_ host: RenderHost, root: URL) async throws {
        let paragraphs = (0..<300).map { "Follow paragraph \($0)\n\n" }
        let original = paragraphs.joined()
        for enabled in [false, true] {
            _ = try await js(host, "window.setFollowChanges(enabled); return true", arguments: ["enabled": enabled])
            for kind in ["edit", "insert", "delete", "unchanged"] {
                try await render(host, source: original, root: root)
                _ = try await js(host, "scrollTo(0, 900); return true")
                try await Task.sleep(nanoseconds: 80_000_000)
                _ = try await js(host, "window.followAnchor = [...document.querySelector('#document').children].find(n => n.getBoundingClientRect().bottom > 0).textContent; window.followTop = [...document.querySelector('#document').children].find(n => n.textContent === window.followAnchor).getBoundingClientRect().top; return true")
                let changed: String
                switch kind {
                case "edit": changed = paragraphs.dropLast().joined() + "Edited final paragraph"
                case "insert": changed = original + "Inserted final paragraph"
                case "delete": changed = paragraphs.dropLast().joined()
                default: changed = original
                }
                try await render(host, source: changed, root: root)
                let result = try await js(host, """
                    const nodes = [...document.querySelector('#document').children];
                    const last = nodes.at(-1), rect = last.getBoundingClientRect();
                    return { visible: rect.bottom > 0 && rect.top < innerHeight,
                      flash: !!document.querySelector('.changed-flash'),
                      offset: nodes.find(n => n.textContent === window.followAnchor).getBoundingClientRect().top - window.followTop };
                    """) as! [String: Any]
                if enabled && kind != "unchanged" {
                    try check(result["visible"] as? Bool == true && result["flash"] as? Bool == true, "Follow Changes on follows and highlights offscreen \(kind)")
                } else {
                    try check(abs(result["offset"] as! Double) < 5 && result["flash"] as? Bool == false, "Follow Changes \(enabled ? "unchanged" : "off " + kind) preserves anchor without flash")
                }
            }
        }
        _ = try await js(host, "scrollTo(0, 900); return true")
        try await Task.sleep(nanoseconds: 80_000_000)
        try await render(host, source: original + "Flash expiry", root: root)
        let flashStarted = try await js(host, "return !!document.querySelector('.changed-flash')") as? Bool
        try check(flashStarted == true, "changed-flash class is present immediately after following a change")
        try await Task.sleep(nanoseconds: 800_000_000)
        let flashActive = try await js(host, "return !!document.querySelector('.changed-flash')") as? Bool
        try check(flashActive == true, "changed-flash class remains present at 0.8 seconds")
        try await waitUntil("flash removed after 1.2 seconds") { try await js(host, "return !document.querySelector('.changed-flash')") as? Bool == true }
        try check(true, "changed-flash class is removed within bounded wait after 1.2 seconds")

        let fresh = try RenderHost(resourceDirectory: Bundle.main.resourceURL!.appendingPathComponent("Web"))
        defer { fresh.close() }
        fresh.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        fresh.load()
        try await waitUntil("first-render host ready") { fresh.isReady }
        _ = try await js(fresh, "window.setFollowChanges(true); return true")
        try await render(fresh, source: original, root: root)
        let first = try await js(fresh, "return scrollY === 0 && !document.querySelector('.changed-flash')") as? Bool
        try check(first == true, "first render never follows or highlights")

        // The probe delays a fresh image capability and grows its layout before the load event.
        try await render(host, source: "![late](pixel.png)\n\n" + original, root: root)
        _ = try await js(host, "scrollTo(0, 900); return true")
        try await Task.sleep(nanoseconds: 80_000_000)
        _ = try await js(host, """
            window.followImageDone = false;
            window.followCommit = window.commitMarkdown;
            window.commitMarkdown = generation => {
              const accepted = window.followCommit(generation);
              const image = document.querySelector('#document img'), url = image.src;
              image.removeAttribute('src');
              image.addEventListener('load', () => window.followImageDone = true, {once:true});
              setTimeout(() => { image.height = 1600; image.src = url; }, 150);
              return accepted;
            };
            return true;
            """)
        try await render(host, source: "![late](pixel.png)\n\n" + paragraphs.dropLast().joined() + "Late image changed end", root: root)
        try await waitUntil("followed late image") { try await js(host, "return window.followImageDone") as? Bool == true }
        let followed = try await js(host, "const n = document.querySelector('#document').lastElementChild, r = n.getBoundingClientRect(); return r.bottom > 0 && r.top < innerHeight") as? Bool
        try check(followed == true, "late image settles the followed block rather than the pre-follow anchor")
        _ = try await js(host, "window.commitMarkdown = window.followCommit; window.setFollowChanges(false); return true")
    }

    static func testFollowNavigationFindZoom(_ host: RenderHost, root: URL) async throws {
        host.setFollowChanges(true)
        let source = (0..<200).map { "Navigation paragraph \($0)\n\n" }.joined() + "# Target\n\nFind this phrase"
        try await render(host, source: source, root: root)
        _ = try await js(host, "scrollTo(0, 0); window.navigationNode = document.querySelector('#document').firstElementChild; return true")
        let generation = host.generation
        let blocked = host.blockedNavigations
        host.scrollToFragment("target")
        try await waitUntil("Follow Changes fragment visible") {
            try await js(host, "const n = document.getElementById('user-content-heading-target'), r = n.getBoundingClientRect(); return r.bottom > 0 && r.top < innerHeight && document.activeElement === n") as? Bool == true
        }
        try check(true, "Follow Changes preserves fragment navigation visibility and focus")
        let found = await withCheckedContinuation { continuation in
            host.find("Find this phrase") { continuation.resume(returning: $0) }
        }
        try check(found, "Follow Changes preserves native WebKit find")
        host.zoom(by: 1.2)
        try check(abs(host.webView.pageZoom - 1.2) < 0.001, "Follow Changes preserves page zoom")
        host.zoom(by: 10)
        try check(host.webView.pageZoom == 3, "Follow Changes preserves maximum zoom bound")
        host.zoom(by: 0.01)
        try check(host.webView.pageZoom == 0.5, "Follow Changes preserves minimum zoom bound")
        host.resetZoom()
        let unchanged = try await js(host, "return window.navigationNode === document.querySelector('#document').firstElementChild && Number(document.querySelector('#document').dataset.generation) === generation", arguments: ["generation": generation]) as? Bool
        try check(host.webView.pageZoom == 1 && host.generation == generation && host.blockedNavigations == blocked && unchanged == true,
                  "fragment/find/zoom never render or navigate the shell and reset restores scale")
        host.setFollowChanges(false)
        _ = try await js(host, "delete window.navigationNode; return true")
    }

    static func testLateImageAnchors(_ host: RenderHost, root: URL, original: String) async throws {
        let name = UUID().uuidString + ".png"
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 1600,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = root.appendingPathComponent(name)
        try bitmap.representation(using: .png, properties: [:])!.write(to: image)
        defer { try? FileManager.default.removeItem(at: image) }
        for error in [false, true] {
            try await render(host, source: original, root: root)
            _ = try await js(host, "scrollTo(0, 900); return true")
            try await Task.sleep(nanoseconds: 80_000_000)
            _ = try await js(host, """
                window.imageAnchor = [...document.querySelector('#document').children]
                  .find(n => n.getBoundingClientRect().bottom > 0).textContent;
                window.imageTop = [...document.querySelector('#document').children]
                  .find(n => n.textContent === window.imageAnchor).getBoundingClientRect().top;
                window.imageEventDone = false;
                window.imageCommit = window.commitMarkdown;
                window.commitMarkdown = generation => {
                  const accepted = window.imageCommit(generation);
                  const image = document.querySelector('#document img');
                  const url = image.src;
                  image.removeAttribute('src');
                  image.addEventListener(fail ? 'error' : 'load', () => window.imageEventDone = true, {once:true});
                  setTimeout(() => {
                    if (fail) image.height = 1600;
                    image.src = fail ? 'mdviewer://bundle/missing-image.png' : url;
                  }, 150);
                  return accepted;
                };
                return true;
                """, arguments: ["fail": error])
            try await render(host, source: "![tall](\(name))\n\n" + original, root: root)
            let immediate = try await js(host, "return [...document.querySelector('#document').children].find(n => n.textContent === window.imageAnchor).getBoundingClientRect().top - window.imageTop") as! Double
            try check(abs(immediate) < 5, "late image \(error ? "error" : "load") preserves immediate anchor within 5 px")
            try await waitUntil("delayed image event") {
                try await js(host, "return window.imageEventDone && (fail || (document.querySelector('#document img').complete && document.querySelector('#document img').naturalWidth > 0))", arguments: ["fail": error]) as? Bool == true
            }
            let settled = try await js(host, "return [...document.querySelector('#document').children].find(n => n.textContent === window.imageAnchor).getBoundingClientRect().top - window.imageTop") as! Double
            try check(abs(settled) < 5, "late image \(error ? "error" : "load") settles anchor within 5 px")
            _ = try await js(host, "window.commitMarkdown = window.imageCommit; return true")
        }
        for input in ["scroll", "wheel", "keydown", "fragment", "none"] {
            try await render(host, source: "![tall](\(name))\n\n" + original, root: root)
            try await waitUntil("cancellation image decode") { try await js(host, "return document.querySelector('#document img').complete") as? Bool == true }
            _ = try await js(host, "scrollTo(0, 2500); return true")
            try await Task.sleep(nanoseconds: 80_000_000)
            try await render(host, source: "![tall](\(name))\n\n" + original, root: root)
            _ = try await js(host, """
                if (input === 'scroll') scrollTo(0, scrollY + 120);
                else if (input === 'fragment') window.scrollToFragment('missing');
                else if (input !== 'none') dispatchEvent(new Event(input));
                return true;
                """, arguments: ["input": input])
            try await Task.sleep(nanoseconds: 80_000_000)
            let correction = try await js(host, """
                const before = scrollY;
                const image = document.querySelector('#document img');
                image.style.height = '2400px';
                image.dispatchEvent(new Event('error'));
                return Math.abs(scrollY - before);
                """) as! Double
            if input == "none" {
                try check(correction > 100, "without input, late-image error re-anchors the viewport by more than 100 px")
            } else {
                try check(correction < 5, "\(input) cancels late-image viewport corrections (\(correction) px)")
            }
        }
        _ = try await js(host, """
            const container = document.querySelector('#document');
            window.imageListeners = new Set();
            window.addImageListener = container.addEventListener;
            window.removeImageListener = container.removeEventListener;
            container.addEventListener = function(type, listener, options) {
              if (type === 'load' || type === 'error') window.imageListeners.add(listener);
              return window.addImageListener.call(this, type, listener, options);
            };
            container.removeEventListener = function(type, listener, options) {
              window.imageListeners.delete(listener);
              return window.removeImageListener.call(this, type, listener, options);
            };
            return true;
            """)
        try await render(host, source: original, root: root)
        _ = try await js(host, "window.previousImageListeners = [...window.imageListeners]; return true")
        try await render(host, source: original, root: root)
        let retired = try await js(host, "return window.previousImageListeners.length > 0 && window.previousImageListeners.every(l => !window.imageListeners.has(l)) && window.imageListeners.size > 0") as? Bool
        try check(retired == true, "second accepted commit retires previous image settling listeners")
        try await Task.sleep(nanoseconds: 1_050_000_000)
        let expired = try await js(host, "return window.imageListeners.size === 0") as? Bool
        try check(expired == true, "image settling listeners expire after one second")
        _ = try await js(host, "const c = document.querySelector('#document'); c.addEventListener = window.addImageListener; c.removeEventListener = window.removeImageListener; return true")
    }
}
