// swift-tools-version: 5.9
// The Apple built-in Cashu wallet (HavenApp/Services/Cashu, symlinked) run
// against the real engine and the local test mint. Needs a host libhaven.a:
// run scripts/cashu-swift-test.sh, which builds it and serves the mint.
import Foundation
import PackageDescription

let libDir = ProcessInfo.processInfo.environment["CASHU_LIBHAVEN_DIR"] ?? "/private/tmp/nv-cashu-swift"

let package = Package(
    name: "CashuWalletTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CHavenCashu",
            path: "Sources/CHavenCashu",
            linkerSettings: [
                .unsafeFlags(["-L\(libDir)", "-lhaven"]),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedLibrary("resolv"),
            ]
        ),
        .target(name: "CashuWallet", dependencies: ["CHavenCashu"], path: "Sources/CashuWallet"),
        .testTarget(name: "CashuWalletTests", dependencies: ["CashuWallet"], path: "Tests/CashuWalletTests"),
    ]
)
