// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "clearmic",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CDeepFilter",
            linkerSettings: [
                .unsafeFlags(["-L", "vendor/lib"]),
                .linkedLibrary("df"),
                // System libraries the Rust static library needs.
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("iconv"),
                .linkedLibrary("resolv"),
            ]),
        .target(name: "ClearMicCore", dependencies: ["CDeepFilter"]),
        .executableTarget(name: "clearmic", dependencies: ["ClearMicCore"]),
        .testTarget(name: "ClearMicCoreTests", dependencies: ["ClearMicCore"]),
    ]
)
