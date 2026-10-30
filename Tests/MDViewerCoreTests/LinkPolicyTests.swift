import Foundation
import Testing
@testable import MDViewerCore

@Suite struct LinkPolicyTests {
    let document = URL(fileURLWithPath: "/tmp/reports/current.md")

    @Test func explicitSafeTargets() {
        #expect(LinkPolicy.target(reference: "#日本-2", document: document) == .fragment("日本-2"))
        #expect(LinkPolicy.target(reference: "https://example.com/report#part", document: document) == .external(URL(string: "https://example.com/report#part")!))
        #expect(LinkPolicy.target(reference: "http://example.com", document: document) != nil)
        #expect(LinkPolicy.target(reference: "mailto:reader@example.com", document: document) != nil)
        #expect(LinkPolicy.target(reference: "../space%20%C3%BC.markdown#heading", document: document) == .markdown(URL(fileURLWithPath: "/tmp/space ü.markdown"), fragment: "heading"))
        #expect(LinkPolicy.target(reference: "picture.png", document: document) == .reveal(URL(fileURLWithPath: "/tmp/reports/picture.png")))
    }

    @Test func unsafeAndMalformedTargets() {
        for reference in ["javascript:alert(1)", "data:text/html,test", "vbscript:foo", "file:///etc/passwd", "custom:run", "//example.com/test", "https:///", "https://user:pass@example.com/", "https://example.com\n/", "file.sh", "run.command", "tool.app", "run.py", "script.js", "file%00.md", "folder%5cfile.md", "bad%ZZ.md", "picture.png?query", ""] {
            #expect(LinkPolicy.target(reference: reference, document: document) == nil, "Rejected: \(reference)")
        }
    }

    @Test func canonicalMarkdownAndExecutableFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.md")
        try Data("# Hello".utf8).write(to: target)
        let alias = root.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        #expect(LinkPolicy.target(reference: "alias.md", document: root.appendingPathComponent("current.md")) == .markdown(target, fragment: nil))
        let executable = root.appendingPathComponent("tool")
        try Data("#!/bin/sh".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        #expect(LinkPolicy.target(reference: "tool", document: root.appendingPathComponent("current.md")) == nil)
    }
}
