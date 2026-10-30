import CoreServices
import Darwin
import Foundation

/// Internal injection seam verifies every C teardown operation against real streams.
internal struct AssetStreamOperations {
    var stop: (FSEventStreamRef) -> Void = { FSEventStreamStop($0) }
    var invalidate: (FSEventStreamRef) -> Void = { FSEventStreamInvalidate($0) }
    var release: (FSEventStreamRef) -> Void = { FSEventStreamRelease($0) }
}

private final class AssetEventContext {
    var receive: (([String], [FSEventStreamEventFlags]) -> Void)?
}

/// Owns the C resource independently of actor-isolated watcher state, including on deinit.
private final class AssetEventStream {
    let context = AssetEventContext()
    var stream: FSEventStreamRef?
    private let operations: AssetStreamOperations

    init(operations: AssetStreamOperations) { self.operations = operations }

    func stop() {
        context.receive = nil
        guard let stream else { return }
        self.stream = nil
        operations.stop(stream)
        operations.invalidate(stream)
        operations.release(stream)
    }
    deinit { stop() }
}

/// A trigger-only stream: event paths are matched in memory, never opened or resolved.
@MainActor
public final class AssetWatcher {
    private let lifetime: AssetEventStream
    private let caseSensitive: Bool
    private let rootPath: String
    private let documentPath: String
    private let onChange: () -> Void
    private var watchedPaths: Set<String> = []
    private var ancestorPaths: Set<String> = []
    private var stopped = false
    private var updating = false
    private var pendingPaths: [String: Bool] = [:] // Value records whether a directory event occurred.
    private var pendingUnknown = false

    public convenience init(root: URL, document: URL, onChange: @escaping () -> Void) throws {
        let sensitive = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames != false
        try self.init(root: root, document: document, caseSensitive: sensitive, onChange: onChange)
    }

    // startsNativeStream is disabled only by deterministic injected-event tests.
    internal init(root: URL, document: URL, caseSensitive: Bool, startsNativeStream: Bool = true,
                  streamOperations: AssetStreamOperations = AssetStreamOperations(), onChange: @escaping () -> Void) throws {
        guard let pointer = realpath(root.path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(pointer) }
        let physicalRoot = String(cString: pointer)
        let source: String
        if let sourcePointer = realpath(document.path, nil) {
            source = String(cString: sourcePointer); free(sourcePointer)
        } else {
            source = URL(fileURLWithPath: physicalRoot).appendingPathComponent(document.lastPathComponent).path
        }
        self.lifetime = AssetEventStream(operations: streamOperations)
        self.caseSensitive = caseSensitive
        self.rootPath = Self.normalize(physicalRoot, caseSensitive: caseSensitive)
        self.documentPath = Self.normalize(source, caseSensitive: caseSensitive)
        self.onChange = onChange
        guard startsNativeStream else { return }
        lifetime.context.receive = { [weak self] paths, flags in self?.receive(paths: paths, flags: flags) }
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(lifetime.context).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<AssetEventContext>.fromOpaque(info).retain()
                return info
            }, release: { info in
                if let info { Unmanaged<AssetEventContext>.fromOpaque(info).release() }
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let strings = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let paths = (0..<count).map { String(cString: strings[$0]) }
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
            Unmanaged<AssetEventContext>.fromOpaque(info).takeUnretainedValue().receive?(paths, flags)
        }, &context, [physicalRoot] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else {
            lifetime.stop(); throw POSIXError(.EIO)
        }
        lifetime.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else { lifetime.stop(); throw POSIXError(.EIO) }
    }

    private static func normalize(_ path: String, caseSensitive: Bool) -> String {
        let canonical = path.decomposedStringWithCanonicalMapping
        return caseSensitive ? canonical : canonical.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).decomposedStringWithCanonicalMapping
    }
    private func normalize(_ path: String) -> String { Self.normalize(path, caseSensitive: caseSensitive) }

    internal func beginUpdate() {
        guard !stopped else { return }
        cancelUpdate()
        updating = true
    }

    internal func cancelUpdate() {
        updating = false
        pendingPaths.removeAll()
        pendingUnknown = false
    }

    public func updatePaths(_ paths: Set<String>) {
        guard !stopped, paths.count <= 512 else { return }
        watchedPaths = Set(paths.map { normalize($0) })
        ancestorPaths.removeAll()
        let rootComponents = (rootPath as NSString).pathComponents
        for path in watchedPaths {
            let components = (path as NSString).pathComponents
            guard components.count > rootComponents.count, components.starts(with: rootComponents) else { continue }
            var parent = (path as NSString).deletingLastPathComponent
            while true {
                ancestorPaths.insert(parent)
                if parent == rootPath { break }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        let replay = !watchedPaths.isEmpty && (pendingUnknown || pendingPaths.contains { path, isDirectory in
            watchedPaths.contains(path) || (isDirectory && ancestorPaths.contains(path))
        })
        cancelUpdate()
        if replay { onChange() }
    }

    internal func receive(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard !stopped, paths.count == flags.count else { return }
        let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        for (path, flag) in zip(paths, flags) {
            let key = normalize(path)
            if updating {
                if flag & rescanFlags != 0 {
                    pendingUnknown = true
                } else if !pendingUnknown, key != documentPath, key == rootPath || key.hasPrefix(rootPath + "/") {
                    if pendingPaths[key] == nil && pendingPaths.count == 512 {
                        pendingUnknown = true
                    } else {
                        pendingPaths[key] = (pendingPaths[key] ?? false) || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
                    }
                }
            }
            guard !watchedPaths.isEmpty else { continue }
            if flag & rescanFlags != 0 { onChange(); return }
            if key == documentPath { continue }
            if watchedPaths.contains(key) || (flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 && ancestorPaths.contains(key)) {
                onChange(); return
            }
        }
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        lifetime.stop()
        cancelUpdate()
        watchedPaths.removeAll(); ancestorPaths.removeAll()
    }
}
