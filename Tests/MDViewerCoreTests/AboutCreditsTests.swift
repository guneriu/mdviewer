import AppKit
import Testing
@testable import MDViewerCore

struct AboutCreditsTests {
    @Test func creditsNameAuthorAndLinkGitHubProfile() throws {
        let credits = AboutCredits.attributedString()
        #expect(credits.string == "Made with love using Pi by @guneriu")
        let handle = (credits.string as NSString).range(of: "@guneriu")
        var range = NSRange()
        let link = credits.attribute(.link, at: handle.location, effectiveRange: &range) as? URL
        #expect(link == URL(string: "https://github.com/guneriu"))
        #expect(range == handle)
        #expect(credits.attribute(.link, at: 0, effectiveRange: nil) == nil)
    }

    @Test func creditsAdaptToDarkMode() {
        let credits = AboutCredits.attributedString()
        let color = credits.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.labelColor)
    }
}
