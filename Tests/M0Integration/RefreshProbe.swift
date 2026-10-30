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
        try await testContentAnchors(host, root: root)
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
        for input in ["scroll", "wheel", "keydown", "fragment"] {
            try await render(host, source: "![tall](\(name))\n\n" + original, root: root)
            try await waitUntil("cancellation image decode") { try await js(host, "return document.querySelector('#document img').complete") as? Bool == true }
            _ = try await js(host, "scrollTo(0, 2500); return true")
            try await Task.sleep(nanoseconds: 80_000_000)
            try await render(host, source: "![tall](\(name))\n\n" + original, root: root)
            _ = try await js(host, """
                if (input === 'scroll') scrollTo(0, scrollY + 120);
                else if (input === 'fragment') window.scrollToFragment('missing');
                else dispatchEvent(new Event(input));
                return true;
                """, arguments: ["input": input])
            try await Task.sleep(nanoseconds: 80_000_000)
            let uncorrected = try await js(host, """
                const before = scrollY;
                const image = document.querySelector('#document img');
                image.style.height = '2400px';
                image.dispatchEvent(new Event('error'));
                return Math.abs(scrollY - before) < 5;
                """) as? Bool
            try check(uncorrected == true, "\(input) cancels late-image viewport corrections")
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
