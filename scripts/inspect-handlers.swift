import CoreServices
import Foundation
import UniformTypeIdentifiers

// Read-only Launch Services observation: never register defaults or invoke a setter.
var result: [String: [String: Any]] = [:]
for ext in ["md", "markdown"] {
    guard let identifier = UTType(filenameExtension: ext)?.identifier else {
        fputs("No UTI for .\(ext)\n", stderr)
        exit(1)
    }
    let defaultHandler = LSCopyDefaultRoleHandlerForContentType(identifier as CFString, .all)?.takeRetainedValue() as String?
    let handlers = LSCopyAllRoleHandlersForContentType(identifier as CFString, .all)?.takeRetainedValue() as? [String] ?? []
    result[ext] = ["uti": identifier, "default": defaultHandler ?? NSNull(), "handlers": handlers.sorted()]
}
let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
print(String(decoding: bytes, as: UTF8.self))
