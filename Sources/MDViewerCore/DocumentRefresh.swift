import Darwin
import Foundation

@MainActor
public final class DocumentRefresh {
    public enum State: Equatable { case loading, displayed, warning(String) }
    public typealias Reader = @Sendable (DocumentLocation) async throws -> String
    public typealias Renderer = @MainActor (String, Int) async throws -> Void
    public var onState: ((State) -> Void)?
    public private(set) var hasGoodPreview = false
    public private(set) var isClosed = false
    public private(set) var completedGeneration = 0
    private let location: DocumentLocation
    private let invalidate: () -> Int
    private let read: Reader
    private let render: Renderer
    private var task: Task<Void, Never>?
    private var directoryWatcher: DirectoryWatcher?
    private var fileWatcher: DirectoryWatcher?
    private var snapshot: FileSnapshot?
    private var latest = 0

    public init(location: DocumentLocation, invalidate: @escaping () -> Int,
                read: @escaping Reader = { try await DocumentIO.shared.read($0) },
                render: @escaping Renderer) {
        self.location = location; self.invalidate = invalidate; self.read = read; self.render = render
    }

    public func start() throws {
        guard !isClosed, directoryWatcher == nil else { return }
        let parent = try Self.physicalParentDirectoryURL(location.assetRoot)
        directoryWatcher = try DirectoryWatcher(directory: parent) { [weak self] in self?.changed() }
        snapshot = FileSnapshot(location.canonicalURL)
        rebindFile()
        reload()
    }

    public func reload(debounce: Bool = false) {
        guard !isClosed else { return }
        task?.cancel()
        let generation = invalidate(); latest = generation
        onState?(.loading)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if debounce { try await Task.sleep(nanoseconds: 200_000_000) }
                try self.requireCurrent(generation)
                var source: String?
                var failure: Error = ViewerError.invalidDocument
                for delay in [UInt64(0), 80_000_000, 160_000_000, 240_000_000] {
                    if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                    try self.requireCurrent(generation)
                    do {
                        let value = try await self.read(self.location)
                        try self.requireCurrent(generation)
                        source = value; break
                    } catch is CancellationError { throw CancellationError() }
                    catch { failure = error }
                }
                try self.requireCurrent(generation)
                guard let source else { throw failure }
                try await self.render(source, generation)
                try self.requireCurrent(generation)
                self.hasGoodPreview = true; self.completedGeneration = generation
                self.onState?(.displayed)
            } catch is CancellationError { }
            catch {
                guard !self.isClosed, self.latest == generation else { return }
                self.onState?(.warning((self.hasGoodPreview ? "Preview is out of date — " : "Unable to read document — ") + error.localizedDescription))
            }
        }
    }

    private static func physicalParentDirectoryURL(_ directory: URL) throws -> URL {
        guard let physicalPath = Darwin.realpath(directory.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.free(physicalPath) }
        return URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
    }

    private func requireCurrent(_ generation: Int) throws {
        guard !isClosed, latest == generation, !Task.isCancelled else { throw CancellationError() }
    }
    private func changed() {
        guard !isClosed else { return }
        let current = FileSnapshot(location.canonicalURL)
        guard current != snapshot else { return } // Unrelated sibling saves do not reload this document.
        snapshot = current
        rebindFile()
        reload(debounce: true)
    }
    private func rebindFile() {
        fileWatcher?.stop()
        fileWatcher = try? DirectoryWatcher(directory: location.canonicalURL) { [weak self] in self?.changed() }
    }
    public func close() {
        guard !isClosed else { return }
        isClosed = true; latest = invalidate()
        task?.cancel(); task = nil
        fileWatcher?.stop(); directoryWatcher?.stop()
        fileWatcher = nil; directoryWatcher = nil; onState = nil
    }
    deinit { task?.cancel() }
}

private struct FileSnapshot: Equatable {
    let device: dev_t, inode: ino_t, size: off_t, mode: mode_t
    let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
    init?(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        device = info.st_dev; inode = info.st_ino; size = info.st_size; mode = info.st_mode
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
    }
}
