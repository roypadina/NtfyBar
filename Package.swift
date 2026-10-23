// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NtfyBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "NtfyBarCore",
            targets: ["NtfyBarCore"]
        ),
        .executable(
            name: "NtfyBarApp",
            targets: ["NtfyBarApp"]
        )
    ],
    targets: [
        .target(
            name: "NtfyBarCore"
        ),
        .executableTarget(
            name: "NtfyBarApp",
            dependencies: ["NtfyBarCore"],
            // SwiftUI/AppKit glue: Swift 5 mode avoids strict-concurrency friction with AppKit delegates.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NtfyBarCoreTests",
            dependencies: ["NtfyBarCore"]
        )
    ]
)
