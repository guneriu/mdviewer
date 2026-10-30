import Darwin
import Foundation
import ImageIO
import Testing
@testable import MDViewerCore

struct AssetPolicyTests {
    @Test func inRootTraversalRendersButEscapesAreNotRefreshCandidates() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = fixture.appendingPathComponent("root")
        try fm.createDirectory(at: root.appendingPathComponent("img"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+afo8AAAAASUVORK5CYII=")!
        try png.write(to: root.appendingPathComponent("a.png"))
        try png.write(to: fixture.appendingPathComponent("outside.png"))
        let pointer = try #require(realpath(root.path, nil)); defer { free(pointer) }
        let physical = URL(fileURLWithPath: String(cString: pointer))
        let accepted = AssetPolicy.images(references: ["img/../a.png"], root: root)
        #expect(accepted.references["img/../a.png"] != nil && accepted.resources.count == 1)
        #expect(accepted.resolvedPaths == [physical.appendingPathComponent("a.png").path])
        for path in ["../outside.png", "img/../../outside.png", "../missing.png", "img/../../missing.png"] {
            let rejected = AssetPolicy.images(references: [path], root: root)
            #expect(rejected.resources.isEmpty && rejected.references.isEmpty && rejected.resolvedPaths.isEmpty)
        }
        let missing = AssetPolicy.images(references: ["img/../missing.png"], root: root)
        #expect(missing.resources.isEmpty)
        #expect(missing.resolvedPaths == [physical.appendingPathComponent("missing.png").path])
    }

    @Test func physicalRefreshCandidatesIncludeRejectedAndMissingButNotUnsafePaths() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("MDViewer-assets-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("img"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let pointer = try #require(realpath(root.path, nil))
        defer { free(pointer) }
        let physical = URL(fileURLWithPath: String(cString: pointer))
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+afo8AAAAASUVORK5CYII=")!
        try png.write(to: root.appendingPathComponent("a.png"))
        try png.write(to: root.appendingPathComponent("café.png"))
        try fm.linkItem(at: root.appendingPathComponent("a.png"), to: root.appendingPathComponent("hard.png"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("alias.png"), withDestinationURL: root.appendingPathComponent("a.png"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        try fm.createSymbolicLink(at: root.appendingPathComponent("dangling.png"), withDestinationURL: root.appendingPathComponent("absent.png"))
        #expect(mkfifo(root.appendingPathComponent("fifo.png").path, 0o600) == 0)
        for (name, data) in [("zero.png", Data()), ("invalid.png", Data("partial".utf8)), ("unsupported.svg", png), ("large.png", png)] {
            try data.write(to: root.appendingPathComponent(name))
        }
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("large.png"))
        try handle.truncate(atOffset: 26 * 1024 * 1024); try handle.close()
        let candidates = ["a.png", "hard.png", "cafe\u{301}.png", "zero.png", "invalid.png", "unsupported.svg", "large.png", "img/missing.png", "future/a.png"]
        let unsafe = ["../outside.png", "%2e%2e/outside.png", "https://example.invalid/a.png", "file:///tmp/a.png", "escape/a.png", "fifo.png", "dangling.png", "a.png?x=1", "a.png#x", "a%00.png"]
        let batch = AssetPolicy.images(references: candidates + unsafe + ["alias.png"], root: root)
        #expect(batch.resolvedPaths == Set(candidates.map { physical.appendingPathComponent($0).path }))
        #expect(batch.resources.count == 2)
        #expect(batch.references.count == 4)
        for name in ["zero.png", "invalid.png", "unsupported.svg", "large.png"] { #expect(batch.references[name] == nil) }
        // A placeholder commit must not retire the trigger for a later valid rewrite.
        try Data().write(to: root.appendingPathComponent("a.png"))
        let rejected = AssetPolicy.images(references: ["a.png"], root: root)
        #expect(rejected.resources.isEmpty && rejected.resolvedPaths == [physical.appendingPathComponent("a.png").path])
        try png.write(to: root.appendingPathComponent("a.png"))
        #expect(AssetPolicy.images(references: ["a.png"], root: root).resources.count == 1)
        var limits = ImageLimits(); limits.uniqueImages = 1
        let bounded = AssetPolicy.images(references: ["a.png", "café.png", "one.png", "two.png"], root: root, limits: limits)
        #expect(bounded.resolvedPaths == [physical.appendingPathComponent("a.png").path, physical.appendingPathComponent("one.png").path])
        limits = ImageLimits(); limits.totalBytes = 0
        let overBudget = AssetPolicy.images(references: ["a.png"], root: root, limits: limits)
        #expect(overBudget.resources.isEmpty && overBudget.resolvedPaths.count == 1 && overBudget.bytesRead == 0)
    }

    @Test func containmentUsesComponentsAndResolvesSymlinks() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = temp.appendingPathComponent("root")
        let sibling = temp.appendingPathComponent("root-other")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let outside = sibling.appendingPathComponent("outside.png")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+afo8AAAAASUVORK5CYII=")!
        try png.write(to: outside)
        // Prove these exact bytes are an allowed raster when their directory is the root.
        #expect(try AssetPolicy.raster(reference: "outside.png", root: sibling).mimeType == "image/png")
        let alias = root.appendingPathComponent("escape.png")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        #expect(!AssetPolicy.contains(outside, root: root))
        #expect(!AssetPolicy.contains(alias, root: root))
        #expect(!AssetPolicy.contains(root, root: root))
        #expect(AssetPolicy.contains(root.appendingPathComponent("sub/image.png"), root: root))
        for path in ["../root-other/outside.png", "%2e%2e/root-other/outside.png", "escape.png", "https://example.invalid/a.png", "javascript:alert(1)", "data:image/png;base64,AA", "file:///etc/passwd", "/etc/passwd", "//host/a.png", "a.svg", "a.png?x=1", "a.png#x", "%ZZ", "outside%00.png", "pixel.png%00.png"] {
            #expect(throws: (any Error).self, Comment(rawValue: path)) { try AssetPolicy.raster(reference: path, root: root) }
        }
    }

    @Test func oversizedSparseImageRejectedBeforeRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+afo8AAAAASUVORK5CYII=")!.write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 26 * 1024 * 1024)
        try handle.close()
        #expect(throws: (any Error).self) { try AssetPolicy.raster(reference: "large.png", root: root) }
    }

    @Test func boundedImageBatchAndInodeDeduplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+afo8AAAAASUVORK5CYII=")!
        try png.write(to: root.appendingPathComponent("a.png"))
        try png.write(to: root.appendingPathComponent("b.png"))
        try FileManager.default.linkItem(at: root.appendingPathComponent("a.png"), to: root.appendingPathComponent("hard.png"))
        let aliases = (0..<1000).map { String(repeating: "./", count: $0 % 20) + "a.png" } + ["%61.png", "hard.png"]
        let batch = AssetPolicy.images(references: aliases, root: root)
        #expect(batch.readCount == 1 && batch.bytesRead == png.count && batch.resources.count == 1)
        #expect(batch.references.count == 22)
        var limits = ImageLimits(); limits.uniqueImages = 1
        #expect(AssetPolicy.images(references: ["a.png", "b.png"], root: root, limits: limits).resources.count == 1)
        limits = ImageLimits(); limits.totalBytes = png.count
        #expect(AssetPolicy.images(references: ["a.png", "b.png"], root: root, limits: limits).bytesRead == png.count)
        limits = ImageLimits(); limits.references = 1
        #expect(AssetPolicy.images(references: ["a.png", "b.png"], root: root, limits: limits).references.count == 1)
        limits = ImageLimits(); limits.totalPixels = 1
        #expect(AssetPolicy.images(references: ["a.png", "b.png"], root: root, limits: limits).resources.count == 1)
        limits = ImageLimits(); limits.perImagePixels = 0
        #expect(AssetPolicy.images(references: ["a.png"], root: root, limits: limits).resources.isEmpty)
        limits = ImageLimits(); limits.dimension = 0
        #expect(AssetPolicy.images(references: ["a.png"], root: root, limits: limits).resources.isEmpty)
        limits = ImageLimits(); limits.frames = 0
        #expect(AssetPolicy.images(references: ["a.png"], root: root, limits: limits).resources.isEmpty)
    }

    @Test func oversizedMetadataAndAnimationRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+afo8AAAAASUVORK5CYII=")!
        for (name, width, height) in [("dimension.png", 20_000, 1)] {
            var bytes = png
            var header: [UInt8] = []
            for value in [width, height] {
                for shift in [24, 16, 8, 0] { header.append(UInt8((value >> shift) & 255)) }
            }
            bytes.replaceSubrange(16..<24, with: header)
            var crc: UInt32 = 0xffffffff
            for byte in bytes[12..<29] {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
            }
            crc ^= 0xffffffff
            bytes.replaceSubrange(29..<33, with: [UInt8((crc >> 24) & 255), UInt8((crc >> 16) & 255), UInt8((crc >> 8) & 255), UInt8(crc & 255)])
            let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            #expect(properties[kCGImagePropertyPixelWidth as String] as? Int == width)
            try bytes.write(to: root.appendingPathComponent(name))
            #expect(AssetPolicy.images(references: [name], root: root).resources.isEmpty)
        }
        let imageSource = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let animation = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(animation, "com.compuserve.gif" as CFString, 33, nil))
        for _ in 0..<33 { CGImageDestinationAddImage(destination, image, nil) }
        #expect(CGImageDestinationFinalize(destination))
        try (animation as Data).write(to: root.appendingPathComponent("frames.gif"))
        let animatedSource = try #require(CGImageSourceCreateWithData(animation, nil))
        #expect(CGImageSourceGetCount(animatedSource) == 33)
        #expect(AssetPolicy.images(references: ["frames.gif"], root: root).resources.isEmpty)
    }

    @Test func rasterBytesValidatedNotJustExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+afo8AAAAASUVORK5CYII="
        try Data(base64Encoded: base64)!.write(to: root.appendingPathComponent("pixel ü.png"))
        #expect(try AssetPolicy.raster(reference: "pixel%20%C3%BC.png", root: root).mimeType == "image/png")
        #expect(throws: (any Error).self) { try AssetPolicy.raster(reference: "pixel%20%C3%BC.png%00.png", root: root) }
        try Data("<script>bad</script>".utf8).write(to: root.appendingPathComponent("fake.png"))
        #expect(throws: (any Error).self) { try AssetPolicy.raster(reference: "fake.png", root: root) }
    }
}
