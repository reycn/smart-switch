// swift-tools-version: 5.9
// Builds the SmartSwitch executable against the Rust static lib (core/) and PermissionFlow.
// `build.sh` runs `cargo build` first, then `swift build`, then assembles the .app bundle.
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "SmartSwitch",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jaywcjlove/PermissionFlow.git", from: "2.11.2"),
    ],
    targets: [
        // C ABI of the Rust core (core/ffi/include/ss_core.h); the .a comes from cargo.
        .target(
            name: "SSCore",
            path: "core/ffi",
            linkerSettings: [
                .unsafeFlags(["-L\(root)/core/target/release"]),
                .linkedLibrary("ss_core"),
                .linkedLibrary("iconv"),
            ]
        ),
        .executableTarget(
            name: "SmartSwitch",
            dependencies: [
                "SSCore",
                .product(name: "PermissionFlow", package: "PermissionFlow"),
            ],
            path: "app",
            exclude: ["Info.plist"]
        ),
    ]
)
