// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Murmur", targets: ["Murmur"]),
        // The desktop widget; scripts/build-app.sh wraps it into Murmur.app/Contents/PlugIns/MurmurWidgets.appex.
        .executable(name: "MurmurWidgets", targets: ["MurmurWidgets"]),
    ],
    targets: [
        // Platform-independent logic: config, hotkey state machine, transcription
        // and cleanup clients. Builds and tests on Linux too.
        .target(name: "MurmurCore"),
        // The desktop widget's views: the widget shows them, and the app's screenshot tests draw them.
        .target(
            name: "MurmurWidgetViews",
            dependencies: ["MurmurCore"],
            linkerSettings: [
                .linkedFramework("SwiftUI", .when(platforms: [.macOS])),
                .linkedFramework("WidgetKit", .when(platforms: [.macOS])),
            ]
        ),
        // The macOS app: event tap, microphone, pasteboard, menu bar, pill.
        .executableTarget(
            name: "Murmur",
            dependencies: ["MurmurCore", "MurmurWidgetViews"],
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("AVFoundation", .when(platforms: [.macOS])),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
                .linkedFramework("ServiceManagement", .when(platforms: [.macOS])),
                .linkedFramework("ScreenCaptureKit", .when(platforms: [.macOS])),
                .linkedFramework("CoreMedia", .when(platforms: [.macOS])),
                .linkedFramework("Speech", .when(platforms: [.macOS])),
                .linkedFramework("WidgetKit", .when(platforms: [.macOS])),
            ]
        ),
        // The widget: sandboxed, separate from the app, reading what the app writes to their app group.
        .executableTarget(
            name: "MurmurWidgets",
            dependencies: ["MurmurCore", "MurmurWidgetViews"],
            linkerSettings: [
                .linkedFramework("SwiftUI", .when(platforms: [.macOS])),
                .linkedFramework("WidgetKit", .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(name: "MurmurCoreTests", dependencies: ["MurmurCore"]),
    ]
)
