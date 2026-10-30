import AppKit
import MDViewerCore
import UniformTypeIdentifiers
import WebKit

private struct ProbeFailure: Error, CustomStringConvertible { let description: String }

@main
@MainActor
struct M0Integration {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(description: message) }
        checks += 1
        print("PASS \(message)")
        fflush(stdout)
    }

    static func js(_ host: RenderHost, _ script: String, arguments: [String: Any] = [:]) async throws -> Any {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            host.webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) {
                continuation.resume(with: $0)
            }
        }
    }

    static func render(_ host: RenderHost, source: String, root: URL) async throws {
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            host.render(source: source, root: root) { continuation.resume(with: $0) }
        }
    }

    static func waitUntil(_ message: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<100 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ProbeFailure(description: "Timed out: \(message)")
    }

    static func run() async throws {
        guard CommandLine.arguments.count == 2, let resources = Bundle.main.resourceURL else {
            throw ProbeFailure(description: "Run the packaged probe with a prepared fixture directory")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = try DocumentLocation(root.appendingPathComponent("safe.md")).read()
        let hostile = try DocumentLocation(root.appendingPathComponent("hostile.md")).read()
        let initialPreviewStart = Date()
        let host = try RenderHost(resourceDirectory: resources.appendingPathComponent("Web"), diagnostics: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host.webView
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            host.onReady = { host.onReady = nil; host.onFailure = nil; continuation.resume() }
            host.onFailure = { error in host.onReady = nil; host.onFailure = nil; continuation.resume(throwing: error) }
            host.load()
        }
        let ready = try await js(host, "return typeof window.renderMarkdown === 'function' && typeof window.prepareMarkdown === 'function'") as? Bool
        try check(ready == true, "real WKWebView loaded bundled custom-scheme script")
        try check(host.gateway.served.contains("mdviewer://bundle/styles.css"), "bundled stylesheet served outside cwd")
        try check(!host.webView.configuration.websiteDataStore.isPersistent, "nonpersistent WebKit data store")
        let csp = try await js(host, "return document.querySelector('meta[http-equiv]').content") as? String
        try check(csp == AssetGateway.csp, "meta CSP equals native response policy")
        try await render(host, source: source, root: root)
        try await waitUntil("raster decode") {
            try await js(host, "return [...document.images].some(i => i.complete && i.naturalWidth === 1)") as? Bool == true
        }
        print("TIMING isolated WebKit creation → shell → first raster preview: \(String(format: "%.3f", Date().timeIntervalSince(initialPreviewStart))) s (not actual-app cold launch)")
        let heading = try await js(host, "return document.querySelector('h1').textContent") as? String
        try check(heading == "M0 safe fixture", "Markdown source transferred as WebKit argument and heading rendered")
        try check(host.gateway.served.filter { $0.hasPrefix("mdviewer://asset/") }.count == 1, "in-root raster served through opaque capability")
        let oldImage = try await js(host, "return document.images[0].src") as! String
        try await render(host, source: hostile, root: root)
        let inert = try await js(host, "return document.querySelectorAll('#document script, #document img').length === 0 && !window.documentExecuted && document.getElementById('document').textContent.includes('<script>')") as? Bool
        try check(inert == true, "hostile raw HTML, script delimiters and unsafe images stay inert")
        let blocked = try await js(host, "return document.querySelectorAll('.blocked-image').length") as? Int
        let rejectedImageSyntax = try await js(host, "return document.getElementById('document').textContent.includes('![script]') && document.getElementById('document').textContent.includes('![absolute file]')") as? Bool
        try check(blocked == 6 && rejectedImageSyntax == true, "all eight unsafe image references blocked: six placeholders and two parser-rejected inert forms")
        let servedBefore = host.gateway.served.count
        let attacks: [String] = [
            "https://mdviewer-m0.invalid/image.png", "http://mdviewer-m0.invalid/image.png",
            "file:///etc/passwd", "data:image/svg+xml,<svg/>",
            "mdviewer://asset/%2e%2e/outside.png", "mdviewer://asset/forged-session/1/fake",
            oldImage
        ]
        let attackResult = try await js(host, #"""
            window.cspViolations = [];
            document.addEventListener('securitypolicyviolation', e => window.cspViolations.push({directive:e.effectiveDirective, uri:e.blockedURI}));
            window.attackImages = urls.map(url => {
                const node = document.createElement('img'); node.src = url;
                document.body.append(node); return node;
            });
            const inline = document.createElement('script');
            inline.textContent = 'window.inlineExecuted = true'; document.head.append(inline);
            const script = document.createElement('script'); script.src = 'https://mdviewer-m0.invalid/script.js'; document.head.append(script);
            const missing = document.createElement('script'); missing.src = 'mdviewer://bundle/not-allowlisted.js'; document.head.append(missing);
            window.fetchBlocked = false;
            fetch('https://mdviewer-m0.invalid/connect').catch(() => { window.fetchBlocked = true; });
            return true;
            """#, arguments: ["urls": attacks]) as? Bool
        try check(attackResult == true, "adversarial subresources inserted into real WebKit DOM")
        try await waitUntil("CSP and gateway rejection") {
            try await js(host, "return window.fetchBlocked && window.cspViolations.length >= 5 && window.attackImages.every(i => i.complete)") as? Bool == true
        }
        let outcomes = try await js(host, "return {forbiddenDecoded:window.attackImages.slice(0,-1).filter(i => i.naturalWidth > 0).length, cachedPreviousRaster:window.attackImages.at(-1).naturalWidth > 0, inline:!!window.inlineExecuted, violations:window.cspViolations, fetchBlocked:window.fetchBlocked}") as! [String: Any]
        print("OBSERVED \(outcomes)")
        // WebKit can reuse an already decoded image without consulting the gateway, even with no-store.
        // Reusing previously authorized bytes is not a new filesystem read. New renders use fresh URLs.
        try check(outcomes["forbiddenDecoded"] as? Int == 0, "remote/file/data/out-of-root/forged images cannot decode")
        try check(outcomes["inline"] as? Bool == false, "CSP prevents dynamically inserted inline script execution")
        try check(outcomes["fetchBlocked"] as? Bool == true, "CSP connect-src blocks fetch")
        try check(host.gateway.served.count == servedBefore, "forbidden custom-scheme requests serve zero bytes")
        try check(host.gateway.requests.contains("mdviewer://bundle/not-allowlisted.js"), "unlisted script reaches gateway but is denied")
        let directives = (outcomes["violations"] as? [[String: String]] ?? []).compactMap { $0["directive"] }
        try check(directives.contains("img-src") && directives.contains("script-src-elem") && directives.contains("connect-src"), "WebKit reports enforced CSP for images, scripts and connections")
        _ = try await js(host, "location.href='https://mdviewer-m0.invalid/navigation'; return true")
        try await waitUntil("navigation rejection") { host.blockedNavigations > 0 }
        try check(host.webView.url == AssetGateway.shellURL, "unsolicited navigation cancelled by native delegate")
        _ = try await js(host, "location.href='javascript:window.scriptURLExecuted=true'; return true")
        try await Task.sleep(nanoseconds: 200_000_000)
        let scriptURLExecuted = try await js(host, "return !!window.scriptURLExecuted") as? Bool
        try check(scriptURLExecuted == false, "javascript: navigation cannot execute")
        let types = ["md", "markdown"].compactMap { UTType(filenameExtension: $0)?.identifier }
        print("OBSERVED UTI \(types)")
        try check(types == ["net.daringfireball.markdown", "net.daringfireball.markdown"], "both extensions resolve to declared imported Markdown UTI")
        try await testCapabilityIntegrity(host, root: root, window: window)
        try await testRendererAndLinks(host, root: root, window: window)
        try await testDirectoryWatch()
        try await testLiveRefresh(host, resources: resources, fixtureRoot: root)
        try await testHardening(host, root: root, resources: resources)
        print("M0-M4 WEBKIT INTEGRATION PASSED: \(checks) checks")
    }

    static func click(_ host: RenderHost, window: NSWindow, label: String) async throws {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        try await waitUntil("probe key window for trusted click") { window.isKeyWindow && NSApp.isActive }
        let point = try await js(host, "document.addEventListener('click', e => window.__lastClick = {trusted:e.isTrusted, text:e.target.textContent, x:e.clientX, y:e.clientY}, {once:true,capture:true}); const a = [...document.querySelectorAll('a')].find(a => a.textContent === label); a.scrollIntoView({block:'center'}); const r = a.getBoundingClientRect(); return {x:r.x+r.width/2, y:r.y+r.height/2}", arguments: ["label": label]) as! [String: Double]
        try await Task.sleep(nanoseconds: 100_000_000)
        let view = host.webView
        let location = view.convert(NSPoint(x: point["x"]!, y: view.isFlipped ? point["y"]! : view.bounds.height - point["y"]!), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            try await waitUntil("active probe during trusted mouse event") { window.isKeyWindow && NSApp.isActive }
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        var trusted = false
        for _ in 0..<100 {
            trusted = try await js(host, "return window.__lastClick?.trusted === true && window.__lastClick?.text === label", arguments: ["label": label]) as? Bool == true
            if trusted { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard trusted else {
            let observed = try await js(host, "const a = [...document.querySelectorAll('a')].find(a => a.textContent === label); const r = a.getBoundingClientRect(); return {lastClick:window.__lastClick ?? null, rect:{x:r.x,y:r.y,width:r.width,height:r.height}, atPoint:document.elementFromPoint(x,y)?.outerHTML, scroll:scrollY}", arguments: ["label": label, "x": point["x"]!, "y": point["y"]!])
            throw ProbeFailure(description: "Expected real trusted click: \(label), key=\(window.isKeyWindow), active=\(NSApp.isActive), responder=\(String(describing: window.firstResponder)), point=\(point), observed=\(observed)")
        }
    }

    static func testCapabilityIntegrity(_ host: RenderHost, root: URL, window: NSWindow) async throws {
        let source = "# Intro\n\n![[x](https://evil.invalid/)](Images/pixel.png)\n\n[Docs](#intro)\n\n![a ![b](Images/not-present.png)](Images/pixel.png) ![d](Images/./pixel.png)"
        let discovered = try await js(host, "return window.prepareMarkdown(source)", arguments: ["source": source]) as! [String: [String]]
        try check(discovered["links"] == ["#intro"] && discovered["images"]?.contains("Images/not-present.png") == false, "image alt children never discover link/image capabilities")
        try await render(host, source: source, root: root)
        try await waitUntil("nested alt images") { try await js(host, "return [...document.querySelectorAll('#document img')].every(i => i.complete && i.naturalWidth === 1)") as? Bool == true }
        let correct = try await js(host, "const images = [...document.querySelectorAll('#document img')]; return images.length === 3 && images[1].src === images[2].src") as? Bool
        try check(correct == true, "nested alt images do not shift subsequent image capabilities; aliases deduplicate")
        try await click(host, window: window, label: "Docs")
        let focused = try await js(host, "return document.activeElement.id") as? String
        try check(focused == "user-content-heading-intro", "trusted Docs click after hostile image alt routes to intro, not external target")
        try await render(host, source: "# Intro\n\n## Café\n\n## Intro\n\n## Intro", root: root)
        let fragments = try await js(host, "return window.scrollToFragment('Intro') && document.activeElement.id === 'user-content-heading-intro' && window.scrollToFragment('Cafe\\u0301') && document.activeElement.id === 'user-content-heading-café' && window.scrollToFragment('intro-3') && document.activeElement.id === 'user-content-heading-intro-3'") as? Bool
        try check(fragments == true, "fragment fallback normalizes case/NFC while exact duplicate IDs win")
    }

    static func testRendererAndLinks(_ host: RenderHost, root: URL, window: NSWindow) async throws {
        let source = try DocumentLocation(root.appendingPathComponent("renderer.md")).read()
        try await render(host, source: source, root: root)
        let constructs = try await js(host, "return ['h1','h2','strong','em','s','code','blockquote','hr','ol','ul','table','th','td'].every(s => document.querySelector('#document '+s))") as? Bool
        try check(constructs == true, "full Markdown headings/emphasis/strike/code/quote/rule/lists/tables render in WebKit")
        let ids = try await js(host, "return [...document.querySelectorAll('h2')].map(h => h.id)") as? [String]
        try check(ids == ["user-content-heading-duplicate", "user-content-heading-duplicate-2", "user-content-heading-duplicate-2-2", "user-content-heading-日本-語"], "heading anchors are unique, deterministic and Unicode-preserving after named-property sanitization")
        let tasks = try await js(host, "const tasks = [...document.querySelectorAll('input')]; return tasks.length === 2 && tasks.every(t => t.disabled && t.type === 'checkbox' && t.getAttribute('aria-label')) && !tasks[0].checked && tasks[1].checked") as? Bool
        try check(tasks == true, "task lists use disabled labeled checkboxes with correct checked state")
        let code = try await js(host, "return !!document.querySelector('code.language-javascript .hljs-keyword') && document.querySelector('code.language-mermaid').textContent.includes('graph TD') && !document.querySelector('code.language-mermaid span') && document.querySelectorAll('pre')[2].textContent.includes('<script>neverExecute()</script>')") as? Bool
        try check(code == true, "explicit JavaScript highlighting and escaped Mermaid/hostile unknown-language fallback")
        try await waitUntil("reference and titled images") { try await js(host, "const images = [...document.querySelectorAll('#document img')]; return images.length === 3 && images.every(i => i.complete && i.naturalWidth === 1)") as? Bool == true }
        let decodedImages = try await js(host, "const images = [...document.querySelectorAll('#document img')]; return images.length === 3 && images.every(i => i.complete && i.naturalWidth === 1)") as? Bool
        try check(decodedImages == true, "inline, angle-delimited, titled and reference-style images decode via native parser-discovered gateway")
        let inert = try await js(host, "return !window.documentExecuted && document.querySelectorAll('#document script,#document svg,#document iframe,#document [onerror]').length === 0 && document.getElementById('document').textContent.includes('${notEvaluated}')") as? Bool
        try check(inert == true, "raw HTML/events/SVG/frames and script delimiters stay literal through full renderer")
        let safeURLs = try await js(host, "return [...document.querySelectorAll('#document a[href]')].every(a => a.getAttribute('href').startsWith('mdviewer://link/')) && document.querySelectorAll('a.blocked-link:not([href])').length === 2") as? Bool
        try check(safeURLs == true, "only opaque native-approved link capabilities enter DOM; executable/custom links have no href")
        var routed: [LinkTarget] = []
        host.onLink = { routed.append($0) }
        _ = try await js(host, "[...document.querySelectorAll('a')].find(a => a.textContent === 'Web').click(); return true")
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(routed.isEmpty && host.webView.url == AssetGateway.shellURL, "synthetic clicks cannot open external applications or navigate shell")
        try await click(host, window: window, label: "Fragment")
        let fragment = try await js(host, "return document.activeElement.id") as? String
        try check(fragment == "user-content-heading-日本-語" && routed.isEmpty, "real WebKit link activation scrolls/focuses same-document Unicode heading without leaving shell")
        for label in ["Markdown", "Outside markdown", "Web", "Email", "Reveal"] { try await click(host, window: window, label: label) }
        try check(routed.count == 5, "five real WebKit user activations routed natively; no external app launched by probe")
        if routed.count == 5 {
            try check(routed[0] == .markdown(root.appendingPathComponent("space ü 日本.markdown"), fragment: "target") && routed[1] == .markdown(root.deletingLastPathComponent().appendingPathComponent("outside.md"), fragment: nil), "local Markdown routing preserves literal paths/fragments and permits explicit parent-directory links")
            try check(routed[2] == .external(URL(string: "https://example.com/report")!) && routed[3] == .external(URL(string: "mailto:reader@example.com")!) && routed[4] == .reveal(root.appendingPathComponent("Images/pixel.png")), "https/mailto and non-Markdown reveal classified without embedded navigation")
        }
        try check(host.webView.url == AssetGateway.shellURL, "all explicit link actions leave trusted shell loaded")
        let found = await withCheckedContinuation { continuation in host.find("Completed task") { continuation.resume(returning: $0) } }
        let absent = await withCheckedContinuation { continuation in host.find("not-present-987654321") { continuation.resume(returning: $0) } }
        try check(found && !absent, "native WKWebView find reports existing and missing text")
        host.zoom(by: 1.2)
        try check(abs(host.webView.pageZoom - 1.2) < 0.001, "native page zoom increases")
        host.zoom(by: 0.0001)
        try check(host.webView.pageZoom == 0.5, "native page zoom lower bound")
        host.resetZoom()
        try check(host.webView.pageZoom == 1, "native page zoom resets to actual size")
        let selectable = try await js(host, "const range = document.createRange(); range.selectNodeContents(document.querySelector('h1')); const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range); return selection.toString() === 'Features & safety' && getComputedStyle(document.querySelector('pre')).overflowX === 'auto' && getComputedStyle(document.querySelector('table')).overflowX === 'auto'") as? Bool
        try check(selectable == true, "rendered text selectable and wide code/table overflow scrolls")
        try await render(host, source: source, root: root)
        let repeatIDs = try await js(host, "return [...document.querySelectorAll('h2')].map(h => h.id)") as? [String]
        try check(ids == repeatIDs, "heading identifiers stable across repeated renders")
        try await render(host, source: "", root: root)
        let empty = try await js(host, "return document.querySelector('.empty-document').textContent") as? String
        try check(empty == "Empty document", "empty source has an explicit readable state")
        host.onLink = nil
    }

    static func testDirectoryWatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MDViewer-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var events = 0
        let watcher = try DirectoryWatcher(directory: directory) { events += 1 }
        defer { watcher.stop() }
        let file = directory.appendingPathComponent("watched.md")
        try Data("initial".utf8).write(to: file)
        try await waitUntil("parent directory create") { events > 0 }
        let before = events
        try Data("atomic replacement".utf8).write(to: file, options: .atomic)
        try await waitUntil("parent directory atomic replacement") { events > before }
        let replacedSource = try String(contentsOf: file, encoding: .utf8)
        try check(replacedSource == "atomic replacement", "parent-directory watcher sees atomic replacement under packaged non-sandbox configuration")
        let replaced = events
        try FileManager.default.removeItem(at: file)
        try await waitUntil("parent directory deletion") { events > replaced }
        let removed = events
        try Data("recreated".utf8).write(to: file)
        try await waitUntil("parent directory recreation") { events > removed }
        try check(events >= 4, "parent directory watcher survives delete/recreate")
    }

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--fifo-initial" {
                    try await testFIFORefresh(initial: true)
                } else if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--fifo-replacement" {
                    try await testFIFORefresh(initial: false)
                } else if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--tmp-refresh" {
                    try await testTemporaryParentRefresh(parentPath: "/tmp")
                } else if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--private-tmp-refresh" {
                    try await testTemporaryParentRefresh(parentPath: "/private/tmp")
                } else if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--asset-image-events" {
                    try await testAssetImages("events")
                } else if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--asset-image-directory" {
                    try await testAssetImages("directory")
                } else if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--asset-image-filtering" {
                    try await testAssetImages("filtering")
                } else if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--asset-tmp-parent" {
                    try await testAssetImages("tmp-parent")
                } else {
                    try await run()
                }
                fflush(stdout); exit(0)
            }
            catch { fputs("M0 INTEGRATION FAILED: \(error)\n", stderr); exit(1) }
        }
        application.run()
    }
}
