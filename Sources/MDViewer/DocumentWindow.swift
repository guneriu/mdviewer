import AppKit
import MDViewerCore

@MainActor
final class DocumentWindow: NSWindowController, NSWindowDelegate {
    let location: DocumentLocation
    private let host: RenderHost
    private let status = NSTextField(labelWithString: "Loading…")
    private let search = NSSearchField()
    private let findBar = NSStackView()
    private var rendered = false
    private var refresh: DocumentRefresh!
    private var pendingFragment: String?
    var onClose: (() -> Void)?
    var onRendered: (() -> Void)?
    var onOpenMarkdown: ((URL, String?) -> Void)?

    init(location: DocumentLocation, followChanges: Bool = false) throws {
        self.location = location
        guard let resources = Bundle.main.resourceURL else { throw ViewerError.invalidDocument }
        host = try RenderHost(resourceDirectory: resources.appendingPathComponent("Web"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.title = location.requestedURL.lastPathComponent
        window.representedURL = location.requestedURL
        window.isReleasedWhenClosed = false
        window.center()
        search.placeholderString = "Find in document"
        search.setAccessibilityLabel("Find in document")
        search.target = self
        search.action = #selector(findNext(_:))
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        findBar.orientation = .horizontal
        findBar.addArrangedSubview(search)
        for (title, action) in [("Previous", #selector(findPrevious(_:))), ("Next", #selector(findNext(_:))), ("Done", #selector(hideFind(_:)))] {
            let button = NSButton(title: title, target: self, action: action)
            button.setAccessibilityLabel("\(title) find result")
            findBar.addArrangedSubview(button)
        }
        findBar.isHidden = true
        let stack = NSStackView(views: [findBar, host.webView, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        window.contentView = stack
        host.webView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        status.setContentHuggingPriority(.required, for: .vertical)
        status.lineBreakMode = .byTruncatingMiddle
        status.setAccessibilityLabel("Document path and status")
        status.toolTip = location.requestedURL.path
        host.webView.setAccessibilityLabel("Markdown document")
        host.onLink = { [weak self] target in self?.route(target) }
        refresh = DocumentRefresh(location: location, invalidate: { [weak host] in host?.invalidate() ?? 0 }) { [weak host] source, generation in
            guard let host else { throw CancellationError() }
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                host.render(source: source, root: location.assetRoot, document: location.canonicalURL, generation: generation) { continuation.resume(with: $0) }
            }
        }
        refresh.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .loading: self.status.stringValue = "Loading — \(location.requestedURL.path)"
            case .warning(let message): self.status.stringValue = "\(message) — \(location.requestedURL.path)"
            case .displayed:
                self.status.stringValue = location.requestedURL.path; self.rendered = true
                if let fragment = self.pendingFragment { self.host.scrollToFragment(fragment); self.pendingFragment = nil }
                self.onRendered?()
            }
        }
        host.onFailure = { [weak self] error in self?.status.stringValue = "Preview unavailable — \(error.localizedDescription)" }
        host.onRecovery = { [weak self] in self?.refresh.reload() }
        host.setFollowChanges(followChanges)
        host.load()
        do { try refresh.start() } catch { status.stringValue = error.localizedDescription; refresh.reload() }
    }

    required init?(coder: NSCoder) { fatalError("Programmatic windows only") }

    func reload() { if !host.isReady { host.load() }; refresh.reload() }
    func setFollowChanges(_ enabled: Bool) { host.setFollowChanges(enabled) }

    func navigate(fragment: String) {
        if rendered { host.scrollToFragment(fragment) } else { pendingFragment = fragment }
    }

    func showFind() { findBar.isHidden = false; window?.makeFirstResponder(search) }
    func zoom(by multiplier: Double) { host.zoom(by: multiplier) }
    func resetZoom() { host.resetZoom() }

    @objc private func hideFind(_ sender: Any?) { findBar.isHidden = true; window?.makeFirstResponder(host.webView) }
    @objc private func findNext(_ sender: Any?) { find(backwards: false) }
    @objc private func findPrevious(_ sender: Any?) { find(backwards: true) }
    private func find(backwards: Bool) {
        guard !search.stringValue.isEmpty else { return }
        host.find(search.stringValue, backwards: backwards) { [weak self] found in
            guard let self else { return }
            self.status.stringValue = found ? self.location.requestedURL.path : "No match — \(self.location.requestedURL.path)"
        }
    }

    private func route(_ target: LinkTarget) {
        switch target {
        case .fragment(let fragment): navigate(fragment: fragment)
        case .markdown(let url, let fragment): onOpenMarkdown?(url, fragment)
        case .external(let url): NSWorkspace.shared.open(url)
        case .reveal(let url):
            let alert = NSAlert()
            alert.messageText = "Reveal linked file in Finder?"
            alert.informativeText = url.path
            alert.addButton(withTitle: "Reveal")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    func windowWillClose(_ notification: Notification) { refresh.close(); host.close(); onClose?() }
}
