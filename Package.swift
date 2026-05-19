// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DuplicateMe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MediaFingerprint", targets: ["MediaFingerprint"]),
        .library(name: "ScanCore", targets: ["ScanCore"]),
        .library(name: "ScanStore", targets: ["ScanStore"]),
        .executable(name: "duplicate-me", targets: ["ScanCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "6.3.2")
    ],
    targets: [
        .target(
            name: "MediaFingerprint",
            path: "Sources/MediaFingerprint"
        ),
        .target(
            name: "ScanCore",
            dependencies: ["MediaFingerprint"],
            path: "Sources/ScanCore"
        ),
        .target(
            name: "ScanStore",
            dependencies: ["ScanCore"],
            path: "Sources/ScanStore"
        ),
        .executableTarget(
            name: "ScanCLI",
            dependencies: ["ScanCore", "ScanStore"],
            path: "Sources/ScanCLI",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ScanCoreTests",
            dependencies: ["ScanCore", "ScanStore", "MediaFingerprint", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/ScanCoreTests"
        ),
        .testTarget(
            name: "MediaFingerprintTests",
            dependencies: ["MediaFingerprint", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/MediaFingerprintTests"
        )
    ]
)
