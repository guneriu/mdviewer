import Foundation

public enum LinkTarget: Equatable, Sendable {
    case fragment(String)
    case external(URL)
    case markdown(URL, fragment: String?)
    case reveal(URL)
}

public enum LinkPolicy {
    public static func target(reference: String, document: URL) -> LinkTarget? {
        guard !reference.isEmpty, !reference.contains("\\"),
              reference.range(of: "%(?![0-9A-Fa-f]{2})", options: .regularExpression) == nil,
              !reference.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: reference), parts.user == nil, parts.password == nil else { return nil }
        if let scheme = parts.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                guard let host = parts.host, !host.isEmpty, let url = parts.url else { return nil }
                return .external(url)
            case "mailto":
                guard parts.host == nil, !parts.path.isEmpty, let url = parts.url else { return nil }
                return .external(url)
            default: return nil
            }
        }
        guard parts.host == nil, parts.query == nil,
              let path = parts.percentEncodedPath.removingPercentEncoding,
              !path.contains("\0"), !path.contains("\\") else { return nil }
        if path.isEmpty {
            guard let fragment = parts.fragment else { return nil }
            return .fragment(fragment)
        }
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : document.deletingLastPathComponent().appendingPathComponent(path))
            .standardizedFileURL.resolvingSymlinksInPath()
        if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
            return .markdown(url, fragment: parts.fragment)
        }
        let executables = ["app", "sh", "bash", "zsh", "command", "scpt", "applescript", "js", "py", "rb", "pl", "workflow", "webloc", "url", "exe"]
        guard !executables.contains(url.pathExtension.lowercased()),
              !FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return .reveal(url)
    }
}
