import AppKit
import WebKit

@MainActor
public final class RenderHost: NSObject, WKNavigationDelegate, WKUIDelegate {
    public let gateway: AssetGateway
    public let webView: WKWebView
    public var onReady: (() -> Void)?
    public var onFailure: ((Error) -> Void)?
    public var onLink: ((LinkTarget) -> Void)?
    public var onRecovery: (() -> Void)?
    public private(set) var blockedNavigations = 0
    public private(set) var contentProcessRecoveries = 0
    public private(set) var generation = 0
    public private(set) var isReady = false
    private var linkTargets: [URL: LinkTarget] = [:]
    private var committedLinks: [URL: LinkTarget] = [:]
    private var linkStages: [Int: [URL: LinkTarget]] = [:]
    private var committedLinkGeneration = 0
    private var renderTask: Task<Void, Never>?
    private var pendingRender: (() -> Void)?
    private var cancelPending: (() -> Void)?
    private var closed = false
    private var loadingShell = false
    private var shellEpoch = 0
    private var followChanges = false
    private var applyingFollowChangesEpoch: Int?

    public func setFollowChanges(_ enabled: Bool) {
        followChanges = enabled
        guard isReady, !closed else { return }
        applyFollowChanges(epoch: shellEpoch)
    }

    private func applyFollowChanges(epoch: Int) {
        guard !closed, shellEpoch == epoch, applyingFollowChangesEpoch == nil else { return }
        let applied = followChanges
        applyingFollowChangesEpoch = epoch
        webView.callAsyncJavaScript("await window.setFollowChanges(enabled); return true",
            arguments: ["enabled": applied], in: nil, in: .page) { [weak self] result in
            guard let self, !self.closed, self.shellEpoch == epoch,
                  self.applyingFollowChangesEpoch == epoch else { return }
            self.applyingFollowChangesEpoch = nil
            switch result {
            case .failure(let error):
                self.shellFailed(error)
            case .success:
                if self.followChanges != applied {
                    self.applyFollowChanges(epoch: epoch)
                    return
                }
                if !self.isReady {
                    self.isReady = true
                    self.loadingShell = false
                    let pending = self.pendingRender
                    self.pendingRender = nil
                    self.cancelPending = nil
                    pending?()
                    self.onReady?()
                }
            }
        }
    }

    public init(resourceDirectory: URL, diagnostics: Bool = false) throws {
        gateway = try AssetGateway(resourceDirectory: resourceDirectory, diagnostics: diagnostics)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(gateway, forURLScheme: "mdviewer")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    public func load() {
        contentProcessRecoveries = 0
        loadShell()
    }

    private func loadShell() {
        guard !closed, !loadingShell else { return }
        isReady = false; loadingShell = true; shellEpoch += 1
        applyingFollowChangesEpoch = nil
        let epoch = shellEpoch
        let rules = #"[{"trigger":{"url-filter":"^[a-zA-Z][a-zA-Z0-9+.-]*:","url-filter-is-case-sensitive":false},"action":{"type":"block"}},{"trigger":{"url-filter":"^mdviewer://"},"action":{"type":"ignore-previous-rules"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "MDViewer-DenyNetwork-M0", encodedContentRuleList: rules) { [weak self] list, error in
            guard let self, !self.closed, epoch == self.shellEpoch else { return }
            guard let list else { self.loadingShell = false; self.onFailure?(error ?? ViewerError.forbiddenAsset); return }
            let controller = self.webView.configuration.userContentController
            controller.removeAllContentRuleLists()
            controller.add(list)
            self.webView.load(URLRequest(url: AssetGateway.shellURL))
        }
    }

    @discardableResult public func invalidate() -> Int {
        generation += 1
        renderTask?.cancel()
        cancelPending?(); pendingRender = nil; cancelPending = nil
        if isReady {
            webView.callAsyncJavaScript("return window.setRenderGeneration(generation)", arguments: ["generation": generation], in: nil, in: .page, completionHandler: nil)
        }
        return generation
    }

    public func render(source: String, root: URL, document: URL? = nil, generation requested: Int? = nil,
                       completion: @escaping @MainActor @Sendable (Result<Any, Error>) -> Void) {
        let version = requested ?? invalidate()
        guard !closed, version == generation else { completion(.failure(CancellationError())); return }
        guard isReady else {
            cancelPending?()
            cancelPending = { completion(.failure(CancellationError())) }
            pendingRender = { [weak self] in self?.render(source: source, root: root, document: document, generation: version, completion: completion) }
            return
        }
        let epoch = shellEpoch
        renderTask = Task { [weak self] in
            guard let self else { completion(.failure(CancellationError())); return }
            var staged: ImageStage?
            var addedLinks: [URL: LinkTarget] = [:]
            var committed = false
            do {
                try self.requireCurrent(version)
                _ = try await self.evaluate("return window.setRenderGeneration(generation)", ["generation": version])
                try self.requireCurrent(version)
                let value = try await self.evaluate("return window.prepareMarkdown(source)", ["source": source])
                try self.requireCurrent(version)
                guard let references = value as? [String: [String]], let images = references["images"], let links = references["links"] else { throw ViewerError.invalidDocument }
                let batch = try await DocumentIO.shared.images(images, root: root)
                try self.requireCurrent(version)
                let stage = self.gateway.stage(batch); staged = stage
                var urls: [String: String] = [:]
                for reference in links.prefix(4096) {
                    guard let target = LinkPolicy.target(reference: reference, document: document ?? root.appendingPathComponent("document.md")) else { continue }
                    let url = URL(string: "mdviewer://link/\(UUID().uuidString)")!
                    addedLinks[url] = target; urls[reference] = url.absoluteString
                }
                try self.requireCurrent(version)
                let prepared = try await self.evaluate("return window.stageMarkdown(source, images, links, generation)", ["source": source, "images": stage.urls, "links": urls, "generation": version]) as? Bool
                try self.requireCurrent(version)
                guard prepared == true else { throw CancellationError() }
                self.linkStages[version] = addedLinks; self.rebuildLinks()
                let applied = try await self.evaluate("return window.commitMarkdown(generation)", ["generation": version]) as? Bool
                committed = applied == true
                // A committed DOM retains its capabilities even if invalidated while the reply travelled.
                guard committed, !self.closed, epoch == self.shellEpoch else { throw CancellationError() }
                self.gateway.commit(stage)
                self.linkStages.removeValue(forKey: version)
                if version >= self.committedLinkGeneration {
                    self.committedLinkGeneration = version; self.committedLinks = addedLinks
                }
                self.rebuildLinks()
                try self.requireCurrent(version)
                completion(.success(version))
            } catch {
                if !committed || epoch != self.shellEpoch {
                    if let staged { self.gateway.discard(staged) }
                    self.linkStages.removeValue(forKey: version); self.rebuildLinks()
                }
                completion(.failure(error))
            }
        }
    }

    private func rebuildLinks() {
        linkTargets = committedLinks
        for stage in linkStages.values { linkTargets.merge(stage) { _, new in new } }
    }

    private func requireCurrent(_ version: Int) throws {
        guard !closed, version == generation, !Task.isCancelled else { throw CancellationError() }
    }

    private func evaluate(_ script: String, _ arguments: [String: Any]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { continuation.resume(with: $0) }
        }
    }

    public func close() {
        guard !closed else { return }
        closed = true; isReady = false; loadingShell = false; shellEpoch += 1
        applyingFollowChangesEpoch = nil
        invalidate(); webView.stopLoading(); gateway.retireImages()
        linkTargets.removeAll(); committedLinks.removeAll(); linkStages.removeAll()
        onReady = nil; onFailure = nil; onLink = nil; onRecovery = nil
    }

    public func scrollToFragment(_ fragment: String) {
        webView.callAsyncJavaScript("return window.scrollToFragment(fragment)", arguments: ["fragment": fragment], in: nil, in: .page, completionHandler: nil)
    }
    public func zoom(by multiplier: Double) { webView.pageZoom = min(3, max(0.5, webView.pageZoom * multiplier)) }
    public func resetZoom() { webView.pageZoom = 1 }
    public func find(_ text: String, backwards: Bool = false, completion: @escaping @MainActor (Bool) -> Void) {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards; configuration.wraps = true; configuration.caseSensitive = false
        webView.find(text, configuration: configuration) { result in completion(result.matchFound) }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed else { return }
        applyFollowChanges(epoch: shellEpoch)
    }
    private func shellFailed(_ error: Error) {
        guard !closed, (error as NSError).code != NSURLErrorCancelled else { return }
        applyingFollowChangesEpoch = nil
        isReady = false; loadingShell = false; onFailure?(error)
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { shellFailed(error) }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { shellFailed(error) }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !closed else { return }
        isReady = false; loadingShell = false; shellEpoch += 1
        applyingFollowChangesEpoch = nil
        invalidate(); gateway.retireImages()
        linkTargets.removeAll(); committedLinks.removeAll(); linkStages.removeAll()
        guard contentProcessRecoveries < 2 else { onFailure?(ViewerError.contentProcessTerminated); return }
        contentProcessRecoveries += 1
        onRecovery?()
        loadShell()
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if !closed, loadingShell, navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.request.url == AssetGateway.shellURL, navigationAction.navigationType == .other {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if !closed, navigationAction.navigationType == .linkActivated, navigationAction.sourceFrame.isMainFrame,
               navigationAction.targetFrame?.isMainFrame == true, !navigationAction.shouldPerformDownload,
               let url = navigationAction.request.url, let target = linkTargets[url] {
                if case .fragment(let fragment) = target { scrollToFragment(fragment) } else { onLink?(target) }
            } else { blockedNavigations += 1 }
        }
    }
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
}
