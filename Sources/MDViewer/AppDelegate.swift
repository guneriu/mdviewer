import AppKit
import MDViewerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var documents: [URL: DocumentWindow] = [:]
    private let followChangesItem = NSMenuItem(title: "Follow Changes",
        action: #selector(toggleFollowChanges(_:)), keyEquivalent: "f")
    private var followChanges: Bool { UserDefaults.standard.bool(forKey: "MDViewerFollowChanges") }

    @objc private func toggleFollowChanges(_ sender: Any?) {
        let enabled = !followChanges
        UserDefaults.standard.set(enabled, forKey: "MDViewerFollowChanges")
        followChangesItem.state = enabled ? .on : .off
        for document in documents.values { document.setFollowChanges(enabled) }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        buildMenus()
        diagnostic("launch")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    // Single open path for Finder, Launch Services, cold/warm opens, and the open panel.
    func application(_ application: NSApplication, open urls: [URL]) {
        diagnostic("open-event", extra: ["count": urls.count])
        for url in urls {
            do {
                let location = try DocumentLocation(url)
                let key = location.canonicalURL
                if let existing = documents[key] {
                    existing.showWindow(nil)
                    existing.window?.makeKeyAndOrderFront(nil)
                    diagnostic("focus", extra: ["canonical": key.path])
                    continue
                }
                let controller = try DocumentWindow(location: location, followChanges: followChanges)
                documents[key] = controller
                controller.onOpenMarkdown = { [weak self] url, fragment in
                    guard let self else { return }
                    self.application(NSApp, open: [url])
                    if let fragment, let linked = try? DocumentLocation(url) { self.documents[linked.canonicalURL]?.navigate(fragment: fragment) }
                }
                controller.onClose = { [weak self] in self?.documents.removeValue(forKey: key) }
                controller.onRendered = { [weak self] in self?.diagnostic("rendered", extra: ["canonical": key.path]) }
                controller.showWindow(nil)
                controller.window?.makeKeyAndOrderFront(nil)
                diagnostic("created", extra: ["canonical": key.path, "requested": url.path])
            } catch {
                diagnostic("error", extra: ["message": error.localizedDescription])
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "md")!, .init(filenameExtension: "markdown")!]
        if panel.runModal() == .OK { application(NSApp, open: panel.urls) }
    }

    @objc private func reloadDocument(_ sender: Any?) {
        documents.values.first { $0.window === NSApp.keyWindow }?.reload()
    }

    private var currentDocument: DocumentWindow? { documents.values.first { $0.window === NSApp.keyWindow } }
    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: AboutCredits.panelOptions())
    }
    @objc private func findDocument(_ sender: Any?) { currentDocument?.showFind() }
    @objc private func zoomIn(_ sender: Any?) { currentDocument?.zoom(by: 1.2) }
    @objc private func zoomOut(_ sender: Any?) { currentDocument?.zoom(by: 1 / 1.2) }
    @objc private func resetZoom(_ sender: Any?) { currentDocument?.resetZoom() }

    private func buildMenus() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            item.submenu = submenu
            main.addItem(item)
            return submenu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            menu.addItem(item)
        }
        let app = menu("MDViewer")
        add(app, "About MDViewer", #selector(showAbout(_:)), "", target: self)
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        app.addItem(services)
        NSApp.servicesMenu = services.submenu
        app.addItem(.separator())
        add(app, "Hide MDViewer", #selector(NSApplication.hide(_:)), "h")
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "")
        app.addItem(.separator())
        add(app, "Quit MDViewer", #selector(NSApplication.terminate(_:)), "q")
        let file = menu("File")
        add(file, "Open…", #selector(openDocument(_:)), "o", target: self)
        add(file, "Reload", #selector(reloadDocument(_:)), "r", target: self)
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        let edit = menu("Edit")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        add(edit, "Find…", #selector(findDocument(_:)), "f", target: self)
        let view = menu("View")
        add(view, "Zoom In", #selector(zoomIn(_:)), "+", target: self)
        add(view, "Zoom Out", #selector(zoomOut(_:)), "-", target: self)
        add(view, "Actual Size", #selector(resetZoom(_:)), "0", target: self)
        let equalZoom = NSMenuItem(title: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "=")
        equalZoom.target = self
        equalZoom.isAlternate = true
        equalZoom.isHidden = true
        equalZoom.allowsKeyEquivalentWhenHidden = true
        view.addItem(equalZoom)
        followChangesItem.target = self
        followChangesItem.keyEquivalentModifierMask = [.command, .shift]
        followChangesItem.state = followChanges ? .on : .off
        view.addItem(followChangesItem)
        let window = menu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "")
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }

    // Explicit opt-in test stdout; never log source contents or enable in normal launches.
    private func diagnostic(_ event: String, extra: [String: Any] = [:]) {
        guard ProcessInfo.processInfo.environment["MDVIEWER_M0_EVENTS"] == "1" else { return }
        var entry = extra
        entry["event"] = event
        entry["pid"] = ProcessInfo.processInfo.processIdentifier
        entry["windows"] = documents.count
        if let bytes = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
           let line = String(data: bytes, encoding: .utf8) {
            print(line)
            fflush(stdout)
        }
    }
}
