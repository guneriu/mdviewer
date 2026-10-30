import AppKit

// AppKit's process entry runs on the main thread; make that isolation explicit in Swift 5 mode.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
