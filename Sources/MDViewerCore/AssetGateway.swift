import Darwin
import Foundation
import ImageIO
import WebKit

public struct GatewayResource: Sendable {
    public let data: Data
    public let mimeType: String
}

public struct ImageLimits: Sendable {
    public var perImageBytes = 25 * 1024 * 1024
    public var totalBytes = 64 * 1024 * 1024
    public var uniqueImages = 256
    public var references = 2048
    public var dimension = 16384
    public var perImagePixels = 16_000_000
    public var totalPixels = 64_000_000
    public var frames = 32
    public init() {}
}

public struct FileIdentity: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
}

public struct ImageBatch: Sendable {
    public fileprivate(set) var references: [String: FileIdentity] = [:]
    public fileprivate(set) var resources: [FileIdentity: GatewayResource] = [:]
    public fileprivate(set) var readCount = 0
    public fileprivate(set) var bytesRead = 0
    public fileprivate(set) var resolvedPaths: Set<String> = []
    fileprivate var existingPaths: Set<String> = []
    fileprivate var missingPaths: Set<String> = []
    fileprivate var pixels = 0
}

public enum AssetPolicy {
    public static func contains(_ url: URL, root: URL) -> Bool {
        let parent = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let child = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return child.count > parent.count && child.starts(with: parent)
    }

    public static func images(references: [String], root: URL, limits: ImageLimits = ImageLimits()) -> ImageBatch {
        var batch = ImageBatch()
        for reference in references.prefix(limits.references) {
            if Task.isCancelled { break }
            guard batch.references[reference] == nil else { continue }
            try? load(reference: reference, root: root, limits: limits, batch: &batch)
        }
        batch.resolvedPaths = batch.existingPaths.union(batch.missingPaths)
        return batch
    }

    public static func raster(reference: String, root: URL) throws -> GatewayResource {
        var batch = ImageBatch()
        try load(reference: reference, root: root, limits: ImageLimits(), batch: &batch)
        return batch.resources[batch.references[reference]!]!
    }

    /// Resolve existing ancestors once in policy, never from watcher event paths.
    private static func candidate(reference: String, root: URL) throws -> (url: URL, missing: Bool) {
        guard let parts = URLComponents(string: reference), parts.scheme == nil,
              parts.host == nil, parts.query == nil, parts.fragment == nil,
              let path = parts.percentEncodedPath.removingPercentEncoding,
              !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
            throw ViewerError.forbiddenAsset
        }
        guard !path.split(separator: "/").contains(".."), let rootPointer = realpath(root.path, nil) else {
            throw ViewerError.forbiddenAsset
        }
        defer { free(rootPointer) }
        let physicalRoot = URL(fileURLWithPath: String(cString: rootPointer), isDirectory: true)
        var ancestor = physicalRoot.appendingPathComponent(path).standardizedFileURL
        var suffix: [String] = []
        while true {
            if let pointer = realpath(ancestor.path, nil) {
                defer { free(pointer) }
                var target = URL(fileURLWithPath: String(cString: pointer))
                if !suffix.isEmpty {
                    var info = stat()
                    guard lstat(target.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                        throw ViewerError.forbiddenAsset
                    }
                }
                for component in suffix.reversed() { target.appendPathComponent(component) }
                let parent = physicalRoot.pathComponents, child = target.pathComponents
                guard child.count > parent.count, child.starts(with: parent) else { throw ViewerError.forbiddenAsset }
                return (target, !suffix.isEmpty)
            }
            guard errno == ENOENT else { throw ViewerError.forbiddenAsset }
            // A dangling final/ancestor symlink is not a missing path candidate.
            var info = stat()
            guard lstat(ancestor.path, &info) != 0, errno == ENOENT,
                  ancestor.pathComponents.count > physicalRoot.pathComponents.count else { throw ViewerError.forbiddenAsset }
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
    }

    private static func load(reference: String, root: URL, limits: ImageLimits, batch: inout ImageBatch) throws {
        let resolved = try candidate(reference: reference, root: root)
        let target = resolved.url
        let fd = Darwin.open(target.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            let missing = errno == ENOENT
            if missing, resolved.missing, batch.missingPaths.count < limits.uniqueImages {
                batch.missingPaths.insert(target.path)
            }
            throw ViewerError.forbiddenAsset
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        var actualPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              fcntl(fd, F_GETPATH, &actualPath) == 0,
              contains(URL(fileURLWithPath: String(cString: actualPath)), root: root) else {
            throw ViewerError.forbiddenAsset
        }
        if batch.existingPaths.count < limits.uniqueImages {
            batch.existingPaths.insert(String(cString: actualPath))
        }
        let mime: String
        let expectedType: String
        switch target.pathExtension.lowercased() {
        case "png": (mime, expectedType) = ("image/png", "public.png")
        case "jpg", "jpeg": (mime, expectedType) = ("image/jpeg", "public.jpeg")
        case "gif": (mime, expectedType) = ("image/gif", "com.compuserve.gif")
        case "webp": (mime, expectedType) = ("image/webp", "org.webmproject.webp")
        default: throw ViewerError.forbiddenAsset
        }
        let identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
        if batch.resources[identity] != nil { batch.references[reference] = identity; return }
        let budget = min(limits.perImageBytes, limits.totalBytes - batch.bytesRead)
        guard batch.readCount < limits.uniqueImages, info.st_size > 0, info.st_size <= budget else { throw ViewerError.forbiddenAsset }
        // Account even rejected bytes: many distinct malformed images cannot evade aggregate limits.
        batch.readCount += 1
        let bytes = try handle.read(upToCount: budget + 1) ?? Data()
        batch.bytesRead += bytes.count
        guard bytes.count <= budget,
              let image = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(image) as String? == expectedType else { throw ViewerError.forbiddenAsset }
        let frames = CGImageSourceGetCount(image)
        guard frames > 0, frames <= limits.frames else { throw ViewerError.forbiddenAsset }
        var pixels = 0
        for index in 0..<frames {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(image, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= limits.dimension, height <= limits.dimension else { throw ViewerError.forbiddenAsset }
            pixels += width * height
            guard pixels <= limits.perImagePixels, pixels <= limits.totalPixels - batch.pixels else { throw ViewerError.forbiddenAsset }
        }
        batch.pixels += pixels
        batch.resources[identity] = GatewayResource(data: bytes, mimeType: mime)
        batch.references[reference] = identity
    }
}

public struct ImageStage {
    let id: Int
    let resources: [String: GatewayResource]
    public let urls: [String: String]
}

/// The web process sees bounded opaque capabilities, never filesystem paths.
@MainActor
public final class AssetGateway: NSObject, WKURLSchemeHandler {
    public static let shellURL = URL(string: "mdviewer://bundle/shell.html")!
    public static let csp = "default-src 'none'; script-src mdviewer://bundle; style-src mdviewer://bundle; img-src mdviewer://asset; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
    private var resources: [String: GatewayResource] = [:]
    private let sessionID = UUID().uuidString
    private var generation = 0
    private var committedID = 0
    private var committedURLs = Set<String>()
    private var pendingURLs: [Int: Set<String>] = [:]
    public private(set) var requests: [String] = []
    public private(set) var served: [String] = []
    private let diagnostics: Bool

    public init(resourceDirectory: URL, diagnostics: Bool = false) throws {
        self.diagnostics = diagnostics
        super.init()
        for (name, mime) in [("shell.html", "text/html"), ("renderer.js", "text/javascript"), ("styles.css", "text/css")] {
            resources["mdviewer://bundle/\(name)"] = GatewayResource(
                data: try Data(contentsOf: resourceDirectory.appendingPathComponent(name)), mimeType: mime)
        }
    }

    public func stage(_ batch: ImageBatch) -> ImageStage {
        generation += 1
        var urls: [FileIdentity: String] = [:]
        var staged: [String: GatewayResource] = [:]
        for (identity, resource) in batch.resources {
            let url = "mdviewer://asset/\(sessionID)/\(generation)/\(UUID().uuidString)"
            urls[identity] = url
            staged[url] = resource
        }
        resources.merge(staged) { _, new in new }
        pendingURLs[generation] = Set(staged.keys)
        return ImageStage(id: generation, resources: staged, urls: batch.references.compactMapValues { urls[$0] })
    }

    public func commit(_ stage: ImageStage) {
        pendingURLs.removeValue(forKey: stage.id)
        if stage.id >= committedID { committedID = stage.id; committedURLs = Set(stage.resources.keys) }
        prune()
    }
    public func discard(_ stage: ImageStage) { pendingURLs.removeValue(forKey: stage.id); prune() }
    private func prune() {
        let retained = pendingURLs.values.reduce(committedURLs) { $0.union($1) }
        resources = resources.filter { $0.key.hasPrefix("mdviewer://bundle/") || retained.contains($0.key) }
    }
    public func retireImages() { committedURLs.removeAll(); pendingURLs.removeAll(); prune() }
    public func containsCapability(_ url: String) -> Bool { resources[url] != nil }

    public func images(references: [String], root: URL) -> [String: String] {
        let staged = stage(AssetPolicy.images(references: references, root: root))
        commit(staged)
        return staged.urls
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(ViewerError.forbiddenAsset); return
        }
        if diagnostics { requests.append(url.absoluteString); if requests.count > 256 { requests.removeFirst() } }
        guard urlSchemeTask.request.httpMethod == "GET", let resource = resources[url.absoluteString] else {
            urlSchemeTask.didFailWithError(ViewerError.forbiddenAsset); return
        }
        if diagnostics { served.append(url.absoluteString); if served.count > 256 { served.removeFirst() } }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": resource.mimeType, "Content-Security-Policy": Self.csp,
            "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"
        ])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(resource.data)
        urlSchemeTask.didFinish()
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
