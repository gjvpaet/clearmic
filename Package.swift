// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "clearmic",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CNative",
            linkerSettings: [
                .unsafeFlags(["-L", "vendor/lib"]),
                .linkedLibrary("clearnative"),
                // System libraries the Rust and C++ code needs.
                .linkedLibrary("c++"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("iconv"),
                .linkedLibrary("resolv"),
            ]),
        .target(name: "ClearMicCore", dependencies: ["CNative"]),
        .executableTarget(name: "clearmic", dependencies: ["ClearMicCore"]),
        .testTarget(name: "ClearMicCoreTests", dependencies: ["ClearMicCore", "CNative"]),
    ]
)
