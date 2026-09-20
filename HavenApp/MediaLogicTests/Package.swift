// swift-tools-version: 5.9
// Unit tests for the pure-Foundation media logic shared by the macOS and iOS
// apps. The app's Xcode project has no test bundle, so this package compiles
// the SAME source files (symlinked from HavenApp/Models) and tests them
// directly. Run: `cd HavenApp/MediaLogicTests && swift test`.
import PackageDescription

let package = Package(
    name: "MediaLogicTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MediaLogic", path: "Sources/MediaLogic"),
        .testTarget(
            name: "MediaLogicTests",
            dependencies: ["MediaLogic"],
            path: "Tests/MediaLogicTests",
            // A trimmed capture of a real tenor.com search page, so the parser
            // is tested against bytes the site actually served rather than
            // against our idea of them.
            resources: [.copy("Fixtures")]
        ),
    ]
)
