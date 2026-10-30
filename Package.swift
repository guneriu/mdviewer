// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MDViewer",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MDViewer", targets: ["MDViewer"])],
    targets: [
        .target(name: "MDViewerCore"),
        .executableTarget(name: "MDViewer", dependencies: ["MDViewerCore"]),
        .testTarget(name: "MDViewerCoreTests", dependencies: ["MDViewerCore"]),
        .executableTarget(name: "M0Integration", dependencies: ["MDViewerCore"], path: "Tests/M0Integration")
    ]
)
