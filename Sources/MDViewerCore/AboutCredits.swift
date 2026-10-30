import AppKit

/// Credits line shown in the standard About panel (MDViewer → About MDViewer).
public enum AboutCredits {
    public static let authorProfile = URL(string: "https://github.com/guneriu")!

    /// About panel options: credits, and an empty build number so the panel shows
    /// "Version 0.1.0" rather than "Version 0.1.0 (2)". CFBundleVersion stays in Info.plist.
    @MainActor public static func panelOptions() -> [NSApplication.AboutPanelOptionKey: Any] {
        [.credits: attributedString(), .version: ""]
    }

    public static func attributedString() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let credits = NSMutableAttributedString(string: "Made with love using Pi by ", attributes: base)
        var link = base
        link[.link] = authorProfile
        credits.append(NSAttributedString(string: "@guneriu", attributes: link))
        return credits
    }
}
