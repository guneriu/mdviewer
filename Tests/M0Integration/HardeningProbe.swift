import AppKit
import MDViewerCore
import WebKit

extension M0Integration {
    static func testHardening(_ host: RenderHost, root: URL, resources: URL) async throws {
        let source = try DocumentLocation(root.appendingPathComponent("hardening.md")).read()
        let servedBefore = host.gateway.served.count
        try await render(host, source: source, root: root)
        let inert = try await js(host, "return !window.hardeningExecuted && !document.querySelector('#document script,#document img,#document iframe,#document object,#document form,#document svg,#document style,#document meta,#document [onerror],#document [srcset]') && [...document.querySelectorAll('#document a')].every(a => !a.hasAttribute('href'))") as? Bool
        try check(inert == true && host.gateway.served.count == servedBefore, "extended hostile fixture stays inert with zero image bytes served")
        let languages = try await js(host, "return [...document.querySelectorAll('#document pre code')].length === 8 && [...document.querySelectorAll('#document pre code')].every(c => c.querySelector('span[class^=hljs]'))") as? Bool
        try check(languages == true, "all eight explicit bundled highlight grammars render without autodetection")
        let stored = try await js(host, "return {local:localStorage.length, session:sessionStorage.length, cookie:document.cookie}") as! [String: Any]
        try check(stored["local"] as? Int == 0 && stored["session"] as? Int == 0 && stored["cookie"] as? String == "", "render pipeline stores no document text in local/session storage or cookies")
        let windowCount = NSApp.windows.count
        _ = try await js(host, "window.open('https://mdviewer-m4.invalid/popup','_blank'); const frame = document.createElement('iframe'); frame.src='https://mdviewer-m4.invalid/frame'; document.body.append(frame); const object = document.createElement('object'); object.type='text/html'; object.data='https://mdviewer-m4.invalid/object'; document.body.append(object); return true")
        try await waitUntil("frame CSP violation") { try await js(host, "return window.cspViolations.some(v => v.directive === 'frame-src')") as? Bool == true }
        let frameBlocked = try await js(host, "return window.cspViolations.some(v => v.directive === 'frame-src') && document.querySelector('object').contentDocument === null") as? Bool
        try check(frameBlocked == true && host.webView.url == AssetGateway.shellURL && NSApp.windows.count == windowCount, "frame CSP enforced; object has no embedded document and popup creates no window")
        let previousBlocks = host.blockedNavigations
        _ = try await js(host, "location.href='mdviewer://bundle/shell.html'; return true")
        try await waitUntil("unsolicited shell reload rejected") { host.blockedNavigations > previousBlocks }
        let retained = try await js(host, "return document.querySelector('h1')?.textContent === 'Untrusted document'") as? Bool
        try check(retained == true, "unsolicited same-shell navigation cannot discard current preview")
        let records = await host.webView.configuration.websiteDataStore.allDataRecords()
        try check(records.isEmpty, "ephemeral data store has no website records after rendering hostile content")
        try await testPipelinePerformance(host, root: root)
        try await testRendererMismatch(host)
        try await testRuleReloads(host)
        try await testContentProcessRecovery(resources: resources, root: root)
    }

    static func testRendererMismatch(_ host: RenderHost) async throws {
        let result = try await js(host, #"""
            const descriptor = Object.getOwnPropertyDescriptor(Element.prototype, 'innerHTML');
            // Alter only this disposable probe's template construction; no production hook.
            Object.defineProperty(HTMLTemplateElement.prototype, 'innerHTML', {
                configurable: true,
                set(value) {
                    descriptor.set.call(this, value);
                    this.content.append(document.createElement('a'));
                }
            });
            try {
                const applied = window.renderMarkdown('[safe](#heading) ![safe](Images/pixel.png)',
                    {'Images/pixel.png':'mdviewer://asset/mismatch/test'},
                    {'#heading':'mdviewer://link/mismatch-test'}, generation);
                return applied && document.querySelectorAll('#document a').length === 2
                    && document.querySelectorAll('#document img').length === 1
                    && !document.querySelector('#document [href],#document [src],#document [srcset]');
            } finally { delete HTMLTemplateElement.prototype.innerHTML; }
            """#, arguments: ["generation": host.generation]) as? Bool
        try check(result == true, "forced token/DOM count mismatch strips every link and image capability")
    }

    static func testRuleReloads(_ host: RenderHost) async throws {
        for iteration in 1...4 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                host.onReady = { host.onReady = nil; host.onFailure = nil; continuation.resume() }
                host.onFailure = { error in host.onReady = nil; host.onFailure = nil; continuation.resume(throwing: error) }
                host.load()
            }
            let protected = try await js(host, "return document.querySelector('meta[http-equiv]').content === policy && typeof window.renderMarkdown === 'function'", arguments: ["policy": AssetGateway.csp]) as? Bool
            try check(protected == true && host.isReady, "bounded shell reload \(iteration) retains renderer and deny-network policy")
        }
    }

    static func testPipelinePerformance(_ host: RenderHost, root: URL) async throws {
        let cases: [(String, String)] = [100_000, 200_000, 400_000].map { ("unclosed-title-\($0)", "[a]: /u \"" + String(repeating: "x\n", count: $0)) }
            + [5_000, 10_000, 20_000].map { ("unclosed-label-\($0)", "[" + String(repeating: "a\n", count: $0)) }
        for (name, source) in cases {
            let start = Date()
            try await render(host, source: source, root: root)
            let elapsed = Date().timeIntervalSince(start)
            print("TIMING full native/WebKit pipeline \(name), \(source.utf8.count) bytes: \(String(format: "%.3f", elapsed)) s")
            try check(elapsed < 5, "bounded bundled parse/tasklist/sanitize/stage/commit: \(name)")
        }
        let report = "# Representative report\n\n" + String(repeating: "Offline read-only Markdown report text with **emphasis** and `inline code`. ", count: 13_500)
        let start = Date()
        try await render(host, source: report, root: root)
        let elapsed = Date().timeIntervalSince(start)
        let heading = try await js(host, "return document.querySelector('h1')?.textContent === 'Representative report'") as? Bool
        print("TIMING warm report \(report.utf8.count) bytes: \(String(format: "%.3f", elapsed)) s (target <1s, measured not promised)")
        try check(heading == true && elapsed < 5, "representative near-1MiB report completes full bundled native/WebKit pipeline")
    }

    static func testContentProcessRecovery(resources: URL, root: URL) async throws {
        let host = try RenderHost(resourceDirectory: resources.appendingPathComponent("Web"))
        defer { host.close() }
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            host.render(source: "# Before recovery", root: root) { continuation.resume(with: $0) }; host.load()
        }
        var recovered = 0
        var failed = false
        host.onFailure = { _ in failed = true }
        host.onRecovery = {
            host.render(source: "# Recovered process", root: root) { if case .success = $0 { recovered += 1 } }
        }
        for expected in 1...2 {
            host.webViewWebContentProcessDidTerminate(host.webView)
            try await waitUntil("content-process recovery \(expected)") { recovered == expected }
        }
        let restored = try await js(host, "return document.querySelector('h1')?.textContent === 'Recovered process'") as? Bool
        try check(restored == true && host.contentProcessRecoveries == 2, "simulated content-process termination reloads shell and queued preview twice")
        host.webViewWebContentProcessDidTerminate(host.webView)
        try check(failed && !host.isReady && host.contentProcessRecoveries == 2, "automatic content-process recovery is bounded with actionable retry error")
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            host.render(source: "# Manual recovery", root: root) { continuation.resume(with: $0) }; host.load()
        }
        let manual = try await js(host, "return document.querySelector('h1')?.textContent === 'Manual recovery'") as? Bool
        try check(manual == true && host.contentProcessRecoveries == 0 && host.gateway.requests.isEmpty, "manual retry restores preview, resets recovery budget; production URL diagnostics disabled")
        host.close()
        host.webViewWebContentProcessDidTerminate(host.webView)
        try check(!host.isReady && recovered == 2, "closed host ignores content-process callbacks")
    }
}

private extension WKWebsiteDataStore {
    func allDataRecords() async -> [WKWebsiteDataRecord] {
        await withCheckedContinuation { continuation in fetchDataRecords(ofTypes: Self.allWebsiteDataTypes()) { continuation.resume(returning: $0) } }
    }
}
