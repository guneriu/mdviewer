import Darwin
import Foundation

/// Watches a directory or file descriptor; callers rebind after replacement.
public final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?

    public init(directory: URL, queue: DispatchQueue = .main, onChange: @escaping () -> Void) throws {
        // O_EVTONLY alone waits for a writer on a FIFO, including during main-actor rebinds.
        let fd = Darwin.open(directory.path, O_EVTONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw error
        }
        let type = info.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else {
            Darwin.close(fd)
            throw POSIXError(.EINVAL)
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .attrib, .link, .revoke], queue: queue)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    public func stop() { source?.cancel(); source = nil }
    deinit { source?.cancel() }
}
