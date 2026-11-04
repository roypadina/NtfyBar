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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .target(
            name: "NtfyBarCore",
            // ICU regex with a time limit (SafeRegex); ships with macOS.
            linkerSettings: [.linkedLibrary("icucore")]
        ),
        .executableTarget(
            name: "NtfyBarApp",
            dependencies: ["NtfyBarCore", .product(name: "Sparkle", package: "Sparkle")],
            // SwiftUI/AppKit glue: Swift 5 mode avoids strict-concurrency friction with AppKit delegates.
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle.framework is embedded in Contents/Frameworks (Scripts/package_app.sh).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "NtfyBarCoreTests",
            dependencies: ["NtfyBarCore"]
        )
    ]
)
