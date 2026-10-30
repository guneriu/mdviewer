import Darwin
import Foundation

public struct DocumentLocation: Hashable, Sendable {
    public static let maximumBytes = 10 * 1024 * 1024
    public let requestedURL: URL
    public let canonicalURL: URL
    public var assetRoot: URL { canonicalURL.deletingLastPathComponent() }

    public init(_ url: URL) throws {
        guard url.isFileURL, !url.path.contains("\0"), ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            throw ViewerError.invalidDocument
        }
        requestedURL = url.standardizedFileURL
        canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func read() throws -> String {
        let fd = Darwin.open(canonicalURL.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { throw ViewerError.invalidDocument }
        guard before.st_size <= Self.maximumBytes else { throw ViewerError.tooLarge }
        var bytes = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard bytes.count <= Self.maximumBytes else { throw ViewerError.tooLarge }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              bytes.count == after.st_size else { throw POSIXError(.EAGAIN) }
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
        guard let source = String(data: bytes, encoding: .utf8) else { throw ViewerError.invalidEncoding }
        return source
    }
}

public enum ViewerError: LocalizedError {
    case invalidDocument, tooLarge, invalidEncoding, forbiddenAsset, contentProcessTerminated
    public var errorDescription: String? {
        switch self {
        case .invalidDocument: return "Choose a regular .md or .markdown file."
        case .tooLarge: return "The document exceeds the 10 MiB limit."
        case .invalidEncoding: return "The document is not valid UTF-8."
        case .forbiddenAsset: return "This image is missing, unsupported, or outside the document directory."
        case .contentProcessTerminated: return "The preview process stopped repeatedly. Press Cmd-R to retry."
        }
    }
}
