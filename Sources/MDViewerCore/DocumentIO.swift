import Foundation

/// Serial off-main filesystem work bounds concurrent reads across all document windows.
public actor DocumentIO {
    public static let shared = DocumentIO()
    public func read(_ location: DocumentLocation) async throws -> String {
        try Task.checkCancellation()
        return try location.read()
    }
    public func images(_ references: [String], root: URL) async throws -> ImageBatch {
        try Task.checkCancellation()
        return AssetPolicy.images(references: references, root: root)
    }
}
