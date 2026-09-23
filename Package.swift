// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Murmur", targets: ["Murmur"]),
    ],
    targets: [
        // Platform-independent logic: config, hotkey state machine, transcription
        // and cleanup clients. Builds and tests on Linux too.
        .target(name: "MurmurCore"),
        // The macOS app: event tap, microphone, pasteboard, menu bar, pill.
        .executableTarget(
            name: "Murmur",
            dependencies: ["MurmurCore"],
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("AVFoundation", .when(platforms: [.macOS])),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
                .linkedFramework("ServiceManagement", .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(name: "MurmurCoreTests", dependencies: ["MurmurCore"]),
    ]
)
