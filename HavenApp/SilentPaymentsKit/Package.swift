// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SilentPaymentsKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "SilentPaymentsKit",
            targets: ["SilentPaymentsKit"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/21-DOT-DEV/swift-secp256k1.git",
            from: "0.21.0"
        ),
    ],
    targets: [
        .target(
            name: "SilentPaymentsKit",
            dependencies: [
                .product(name: "libsecp256k1", package: "swift-secp256k1"),
            ],
            path: "Sources/SilentPaymentsKit"
        ),
        .testTarget(
            name: "SilentPaymentsKitTests",
            dependencies: ["SilentPaymentsKit"],
            path: "Tests/SilentPaymentsKitTests"
        ),
    ]
)
